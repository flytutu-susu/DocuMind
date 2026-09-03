import Foundation

/// 内嵌的 Python 推理服务脚本（mlx-vlm 封装）。
/// 运行时由 MLXServerManager 写入 ~/Library/Application Support/DocuMind/mlx/mlx_server.py 并执行。
///
/// 设计要点（依据 baidu/Unlimited-OCR 模型卡与 mlx-vlm 社区实践）：
/// - 模型在后台线程加载，/health 随时可查询（loading / ready / failed）
/// - 推理全局串行（MLX 非线程安全）
/// - 输出清理：剥离 <|det|> 定位标记、Ġ/Ċ 分词伪影
enum MLXServerScript {

    static let source = #"""
#!/usr/bin/env python3
# DocuMind 本地 OCR 推理服务（mlx-vlm 封装，仅监听 127.0.0.1）
import argparse
import base64
import io
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = {"status": "loading", "model": None, "error": None}
model = None
processor = None
model_config = None
gen_lock = threading.Lock()

DET_RE = re.compile(r'<\|det\|>([^<\s]+)(?:\s*\[[^\]]*\])?\s*<\|/det\|>(.*)')

PROMPTS = {
    "text": "Free OCR.",
    "markdown": "<|grounding|>Convert the document to markdown.",
}


def clean_text(raw):
    # 分词伪影（SentencePiece 风格标记）
    text = str(raw).replace("Ġ", " ").replace("Ċ", "\n")
    # 剥离 <|det|>type [bbox]<|/det|> 标记，保留文字
    out_lines = []
    for line in text.splitlines():
        stripped = line.strip()
        m = DET_RE.match(stripped)
        if m:
            category, content = m.group(1).strip(), m.group(2).strip()
            if category == "image":
                continue
            out_lines.append(content)
        else:
            out_lines.append(line)
    text = "\n".join(out_lines)
    for tok in ("<|det|>", "<|/det|>", "<|grounding|>", "<image>",
                "<|endoftext|>", "</s>", "<s>"):
        text = text.replace(tok, "")
    return text.strip()


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


def run_generate(image_bytes, mode):
    from mlx_vlm import generate
    try:
        from mlx_vlm.prompt_utils import apply_chat_template
    except Exception:
        apply_chat_template = None
    from PIL import Image

    img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    prompt_text = PROMPTS.get(mode, PROMPTS["text"])

    prompt = None
    if apply_chat_template is not None and model_config is not None:
        try:
            prompt = apply_chat_template(processor, model_config, prompt_text, num_images=1)
        except Exception:
            prompt = None
    if prompt is None:
        # mlx-vlm 要求 prompt 中显式包含 <image> 占位符
        prompt = "<image>" + prompt_text

    with gen_lock:
        out = generate(
            model, processor,
            prompt=prompt,
            image=img,
            max_tokens=8192,
            temperature=0.0,
            repetition_penalty=1.05,
            verbose=False,
        )
    return clean_text(getattr(out, "text", out))


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
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            image_bytes = base64.b64decode(payload["image"])
            mode = payload.get("mode", "text")
            text = run_generate(image_bytes, mode)
            self._send(200, {"text": text})
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
