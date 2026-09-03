import Foundation

/// 内嵌的 Python 推理服务脚本 v2（mlx-vlm 封装 + 版面保持转换引擎，仅监听 127.0.0.1）。
/// 运行时由 MLXServerManager 写入 ~/Library/Application Support/DocuMind/mlx/mlx_server.py 并执行。
///
/// v2 新增：
/// - /ocr 返回结构化块 blocks（category/bbox/content/page），bbox 归一化到 0-1
/// - /convert：PDF -> 逐页 grounding OCR -> Layout Engine -> python-docx 生成
///   （标题样式 / markdown 表格 -> 真表格 / bbox 裁剪页面插图 / 分页符）
/// - /health 附带转换进度 convert:{current,total}
enum MLXServerScript {

    static let source = #"""
#!/usr/bin/env python3
# DocuMind 本地 OCR 推理服务 v2（mlx-vlm + python-docx，仅监听 127.0.0.1）
import argparse
import base64
import io
import json
import os
import re
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = {"status": "loading", "model": None, "error": None, "convert": None}
model = None
processor = None
model_config = None
gen_lock = threading.Lock()

# <|det|>category [x1, y1, x2, y2]<|/det|>content
DET_RE = re.compile(r'<\|det\|>([^<\s]+)(?:\s*\[([^\]]*)\])?\s*<\|/det\|>(.*)')

PROMPTS = {
    "text": "Free OCR.",
    "markdown": "<|grounding|>Convert the document to markdown.",
}


# ---------- 输出清理 / 结构化解析 ----------

def detok(text):
    # 分词伪影（SentencePiece 风格标记）
    return str(text).replace("Ġ", " ").replace("Ċ", "\n")


def clean_inline(text):
    for tok in ("<|det|>", "<|/det|>", "<|grounding|>", "<image>",
                "<|endoftext|>", "</s>", "<s>"):
        text = text.replace(tok, "")
    return text.strip()


def norm_bbox(b):
    # 模型坐标系不确定（0-1 / 0-1000 / 1024 视图像素），按量级归一化到 0-1
    if not b or len(b) != 4:
        return []
    try:
        vals = [float(v) for v in b]
    except ValueError:
        return []
    mx = max(abs(v) for v in vals)
    div = 1.0 if mx <= 1.5 else (1000.0 if mx <= 1005.0 else 1024.0)
    return [min(max(v / div, 0.0), 1.0) for v in vals]


def parse_blocks(raw, page_index):
    # 返回 (blocks, plain_text)；det 块之外的行并入当前块
    blocks = []
    cur = None
    for line in detok(raw).splitlines():
        s = line.rstrip()
        if not s.strip():
            continue
        m = DET_RE.match(s.strip())
        if m:
            category = m.group(1).strip()
            bbox = norm_bbox(m.group(2).split(",")) if m.group(2) else []
            content = m.group(3).strip()
            if cur is not None:
                blocks.append(cur)
            cur = {"category": category, "bbox": bbox, "content": content, "page": page_index}
        else:
            if cur is None:
                cur = {"category": "text", "bbox": [], "content": s, "page": page_index}
            else:
                cur["content"] += "\n" + s
    if cur is not None:
        blocks.append(cur)
    plain = "\n\n".join(b["content"] for b in blocks if b["content"]).strip()
    return blocks, plain


# ---------- 模型加载 / 推理 ----------

def load_model(repo):
    global model, processor, model_config
    from mlx_vlm import load
    from mlx_vlm.utils import load_config
    print("[mlx-server] loading model: %s" % repo, flush=True)
    model, processor = load(repo)
    try:
        model_config = load_config(repo)
    except Exception:
        model_config = None
    state["status"] = "ready"


def run_generate_raw(pil_image, mode):
    from mlx_vlm import generate
    try:
        from mlx_vlm.prompt_utils import apply_chat_template
    except Exception:
        apply_chat_template = None

    prompt_text = PROMPTS.get(mode, PROMPTS["text"])
    prompt = None
    if apply_chat_template is not None and model_config is not None:
        try:
            prompt = apply_chat_template(processor, model_config, prompt_text, num_images=1)
        except Exception:
            prompt = None
    if prompt is None:
        prompt = "<image>" + prompt_text

    with gen_lock:
        out = generate(
            model, processor,
            prompt=prompt,
            image=pil_image,
            max_tokens=8192,
            temperature=0.0,
            repetition_penalty=1.05,
            verbose=False,
        )
    return str(getattr(out, "text", out))


def ocr_image(image_bytes, mode):
    from PIL import Image
    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    raw = run_generate_raw(img, mode)
    blocks, plain = parse_blocks(raw, 0)
    return clean_inline(plain), blocks


# ---------- Layout Engine：PDF -> DOCX ----------

def _open_pdf(pdf_bytes):
    try:
        import pymupdf as fitz
    except ImportError:
        import fitz
    return fitz, fitz.open(stream=pdf_bytes, filetype="pdf")


def _add_markdown_table(doc, md_text):
    rows = []
    for line in md_text.splitlines():
        s = line.strip()
        if not s.startswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        # 跳过分隔行 |---|---|
        if all(set(c) <= set("-: ") for c in cells):
            continue
        rows.append(cells)
    if not rows:
        doc.add_paragraph(md_text)
        return
    cols = max(len(r) for r in rows)
    table = doc.add_table(rows=len(rows), cols=cols)
    try:
        table.style = "Table Grid"
    except Exception:
        pass
    for ri, row in enumerate(rows):
        for ci in range(cols):
            table.cell(ri, ci).text = row[ci] if ci < len(row) else ""


def _crop_figure(fitz, page, nb, tmp_dir, index):
    # 按归一化 bbox 裁剪页面区域，返回图片路径
    rect = page.rect
    clip = fitz.Rect(
        rect.x0 + nb[0] * rect.width,
        rect.y0 + nb[1] * rect.height,
        rect.x0 + nb[2] * rect.width,
        rect.y0 + nb[3] * rect.height,
    )
    # 过滤退化区域（小于页面宽/高 2%）
    if clip.width < rect.width * 0.02 or clip.height < rect.height * 0.02:
        return None
    pix = page.get_pixmap(matrix=fitz.Matrix(2, 2), clip=clip)
    path = os.path.join(tmp_dir, "fig_%d.png" % index)
    pix.save(path)
    return path


def convert_pdf_to_docx(pdf_bytes, file_name):
    from PIL import Image
    from docx import Document
    from docx.shared import Inches

    fitz, pdf = _open_pdf(pdf_bytes)
    doc = Document()
    total = pdf.page_count
    tmp_dir = tempfile.mkdtemp(prefix="documind_convert_")
    fig_index = 0

    for i in range(total):
        state["convert"] = {"current": i + 1, "total": total, "file": file_name}
        page = pdf.load_page(i)

        # 渲染页面（200dpi 足够覆盖模型 1024 基准）
        pix = page.get_pixmap(matrix=fitz.Matrix(200.0 / 72.0, 200.0 / 72.0))
        img = Image.open(io.BytesIO(pix.tobytes("png"))).convert("RGB")

        raw = run_generate_raw(img, "markdown")
        blocks, _ = parse_blocks(raw, i)

        if not blocks:
            doc.add_paragraph("（本页未识别到内容）")
        for block in blocks:
            category = block["category"]
            content = clean_inline(block["content"])
            if category == "image":
                nb = block["bbox"]
                if nb:
                    fig_path = _crop_figure(fitz, page, nb, tmp_dir, fig_index)
                    fig_index += 1
                    if fig_path:
                        try:
                            doc.add_picture(fig_path, width=Inches(5.2))
                        except Exception:
                            pass
                continue
            if not content:
                continue
            if category == "table":
                _add_markdown_table(doc, content)
            elif category in ("title", "header"):
                doc.add_heading(content, level=1)
            else:
                doc.add_paragraph(content)

        if i < total - 1:
            doc.add_page_break()

    state["convert"] = None
    out = io.BytesIO()
    doc.save(out)
    pdf.close()
    return out.getvalue()


# ---------- HTTP 服务 ----------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[http] " + (fmt % args) + "\n")
        sys.stderr.flush()

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, code, data, content_type, file_name=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if file_name:
            self.send_header(
                "Content-Disposition",
                "attachment; filename*=UTF-8''" + urllib.parse.quote(file_name),
            )
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length > 0 else b""

    def do_GET(self):
        if self.path.startswith("/health"):
            self._send(200, {
                "status": state["status"],
                "model": state["model"],
                "error": state["error"],
                "convert": state["convert"],
            })
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.startswith("/ocr"):
            self._handle_ocr()
        elif self.path.startswith("/convert"):
            self._handle_convert()
        else:
            self._send(404, {"error": "not found"})

    def _handle_ocr(self):
        if state["status"] != "ready":
            self._send(503, {"error": "model not ready: %s" % state["status"]})
            return
        try:
            payload = json.loads(self._read_body().decode("utf-8"))
            image_bytes = base64.b64decode(payload["image"])
            mode = payload.get("mode", "text")
            text, blocks = ocr_image(image_bytes, mode)
            self._send(200, {"text": text, "blocks": blocks})
        except Exception as exc:
            self._send(500, {"error": str(exc)})

    def _handle_convert(self):
        if state["status"] != "ready":
            self._send(503, {"error": "model not ready: %s" % state["status"]})
            return
        try:
            pdf_bytes = self._read_body()
            if not pdf_bytes:
                self._send(400, {"error": "empty body"})
                return
            raw_name = self.headers.get("X-File-Name", "document.pdf")
            file_name = urllib.parse.unquote(raw_name)
            data = convert_pdf_to_docx(pdf_bytes, file_name)
            out_name = os.path.splitext(file_name)[0] + ".docx"
            self._send_bytes(
                200,
                data,
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                out_name,
            )
        except Exception as exc:
            state["convert"] = None
            self._send(500, {"error": str(exc)})


def _load_guard(repo):
    try:
        load_model(repo)
        print("[mlx-server] model ready", flush=True)
    except Exception as exc:
        state["status"] = "failed"
        state["error"] = str(exc)
        sys.stderr.write("[mlx-server] load failed: %s\n" % exc)
        sys.stderr.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--port", type=int, default=8091)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    state["model"] = args.model

    loader = threading.Thread(target=_load_guard, args=(args.model,), daemon=True)
    loader.start()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print("[mlx-server] listening on %s:%d model=%s" % (args.host, args.port, args.model), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
"""#
}
