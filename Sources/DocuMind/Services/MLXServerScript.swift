import Foundation

/// 内嵌的 Python 推理服务脚本 v3（mlx-vlm 封装，纯 OCR 推理，仅监听 127.0.0.1）。
/// 运行时由 MLXServerManager 写入 ~/Library/Application Support/DocuMind/mlx/mlx_server.py 并执行。
///
/// v3 变更：版面引擎已移到 Swift 侧（Services/Layout/），sidecar 只做推理。
/// /ocr 返回 {text, blocks:[{category,bbox,content,page}]}，bbox 归一化到 0-1。
enum MLXServerScript {

    static let source = #"""
#!/usr/bin/env python3
# DocuMind 本地 OCR 推理服务 v3（mlx-vlm，仅监听 127.0.0.1）
import argparse
import base64
import io
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = {"status": "loading", "model": None, "error": None}
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

    def do_GET(self):
        if self.path.startswith("/health"):
            self._send(200, {
                "status": state["status"],
                "model": state["model"],
                "error": state["error"],
            })
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.startswith("/ocr"):
            self._send(404, {"error": "not found"})
            return
        if state["status"] != "ready":
            self._send(503, {"error": "model not ready: %s" % state["status"]})
            return
        try:
            from PIL import Image
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            image_bytes = base64.b64decode(payload["image"])
            mode = payload.get("mode", "text")
            img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
            raw = run_generate_raw(img, mode)
            blocks, plain = parse_blocks(raw, 0)
            self._send(200, {"text": clean_inline(plain), "blocks": blocks})
        except Exception as exc:
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
