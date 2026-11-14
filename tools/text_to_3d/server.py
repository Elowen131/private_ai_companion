#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地文生 3D 服务（路线 C · 零花费 / 全离线推理）。

基于 HuggingFace diffusers 的 ShapEPipeline（模型权重 openai/shap-e），在本地
GPU（无则回退 CPU）上把文本提示词转为 GLB，通过 HTTP 暴露给「私人 AI 陪伴」App。

特性：
- 免费、无需 API key；权重首次从 hf-mirror.com（HF_ENDPOINT）拉取一次后即可离线；
- 提示词哈希缓存，重复提示词秒回；
- 惰性加载管线，避免空闲占显存；
- 设备侧通过 `adb reverse tcp:8765 tcp:8765` 把 127.0.0.1:8765 指向本机。

接口：
- POST /api/gen   body: {"prompt","guidance_scale"(默认15.0),"num_inference_steps"(默认64),
                        "frame_size"(默认256),"seed"}
                   -> 200: GLB 二进制（model/gltf-binary）
- GET  /api/health -> {"ok","gpu","device","model_loaded","cache"}
- GET  /api/samples -> [{"id","prompt","file"}]（离线样例清单）
- GET  /api/sample/<id> -> GLB 二进制（samples/<id>.glb）

启动：
    python tools/text_to_3d/server.py
可选：
    --host 127.0.0.1 --port 8765 --steps 64 --frame-size 256
"""
import argparse
import hashlib
import io
import json
import os
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---- 环境：在中转代理下用 hf-mirror 代替 huggingface.co（权重只拉一次，之后离线）----
# 本机回环不走代理，避免把 127.0.0.1 请求发到代理造成连不上。
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("NO_PROXY", "127.0.0.1,localhost,::1")
os.environ.setdefault("no_proxy", "127.0.0.1,localhost,::1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
# 无头环境：matplotlib 用 Agg 后端，避免 import 时要求显示器。
os.environ.setdefault("MPLBACKEND", "Agg")

# 真正 import torch / diffusers 之前就设好上面这些环境变量。
import torch  # noqa: E402
from diffusers import ShapEPipeline  # noqa: E402
from diffusers.utils import export_to_ply  # noqa: E402
import trimesh  # noqa: E402
import numpy as np  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))
_SAMPLES_DIR = os.path.join(_HERE, "samples")

# 全局模型句柄（惰性加载）。
_MODELS: dict = {}
_MODELS_LOCK = threading.Lock()
_DEVICE = None

# 内存 + 磁盘双缓存：key=sha256(prompt|gs|steps|frame|seed) -> GLB bytes。
_CACHE: dict = {}
_CACHE_LOCK = threading.Lock()
_CACHE_DIR = os.path.join(_HERE, ".glb_cache")
# 生成串行化，避免并发请求同时吃满显存 / 互相拖累。
_GEN_LOCK = threading.Lock()


def ensure_models() -> dict:
    """惰性加载 Shap-E（diffusers 版）管线，线程安全，只加载一次。"""
    global _DEVICE
    with _MODELS_LOCK:
        if "pipe" in _MODELS:
            return _MODELS
        _DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        print(f"[route_c] loading Shap-E (openai/shap-e) on {_DEVICE} …", flush=True)
        # 始终用 fp16 变体，下载体积约为 fp32 的一半；CPU 也能跑（更慢）。
        pipe = ShapEPipeline.from_pretrained(
            "openai/shap-e",
            torch_dtype=torch.float16,
            variant="fp16",
            use_safetensors=True,
        )
        pipe = pipe.to(_DEVICE)
        _MODELS["pipe"] = pipe
        _MODELS["device"] = _DEVICE
        print("[route_c] pipeline ready.", flush=True)
        return _MODELS


def _mesh_to_glb_bytes(mesh) -> bytes:
    """diffusers 的 mesh 对象 -> 旋转 upright -> GLB 字节。

    Shap-E 默认从底部视角输出，绕 X 轴 -90° 使其正立。
    """
    with tempfile.NamedTemporaryFile(suffix=".ply", delete=False) as tf:
        ply_path = tf.name
    try:
        export_to_ply(mesh, ply_path)
        tm = trimesh.load(ply_path)
        rot = trimesh.transformations.rotation_matrix(-np.pi / 2, [1, 0, 0])
        tm = tm.apply_transform(rot)
        buf = io.BytesIO()
        tm.export(buf, file_type="glb")
        return buf.getvalue()
    finally:
        try:
            os.remove(ply_path)
        except OSError:
            pass


def text_to_glb_bytes(
    prompt: str,
    guidance_scale: float = 15.0,
    num_inference_steps: int = 64,
    frame_size: int = 256,
    seed: int = 0,
) -> bytes:
    """把文本提示词推理成 GLB 字节。"""
    m = ensure_models()
    pipe = m["pipe"]
    device = m["device"]
    generator = None
    if seed:
        generator = torch.Generator(device=device).manual_seed(seed)

    with torch.no_grad():
        output = pipe(
            prompt,
            guidance_scale=guidance_scale,
            num_inference_steps=num_inference_steps,
            frame_size=frame_size,
            output_type="mesh",
            generator=generator,
        )
    mesh = output.images[0]
    return _mesh_to_glb_bytes(mesh)


def _cache_path(key: str) -> str:
    return os.path.join(_CACHE_DIR, f"{key}.glb")


def gen_cached(prompt, guidance_scale, num_inference_steps, frame_size, seed) -> bytes:
    key = hashlib.sha256(
        f"{prompt}|{guidance_scale}|{num_inference_steps}|{frame_size}|{seed}".encode(
            "utf-8"
        )
    ).hexdigest()
    with _CACHE_LOCK:
        if key in _CACHE:
            return _CACHE[key]
    # 先看磁盘缓存（跨进程重启复用）。
    cp = _cache_path(key)
    if os.path.exists(cp):
        with open(cp, "rb") as f:
            data = f.read()
        with _CACHE_LOCK:
            _CACHE[key] = data
        return data
    with _GEN_LOCK:
        with _CACHE_LOCK:
            if key in _CACHE:
                return _CACHE[key]
        data = text_to_glb_bytes(
            prompt, guidance_scale, num_inference_steps, frame_size, seed
        )
        os.makedirs(_CACHE_DIR, exist_ok=True)
        with open(cp, "wb") as f:
            f.write(data)
        with _CACHE_LOCK:
            _CACHE[key] = data
    return data


class Handler(BaseHTTPRequestHandler):
    # 关闭默认日志噪音，仅在异常时打印。
    def log_message(self, fmt, *args):  # noqa: A003
        pass

    def _send(self, code, body: bytes, content_type="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path in ("/", "/api/health"):
            return self._health()
        if parsed.path == "/api/samples":
            return self._samples()
        if parsed.path.startswith("/api/sample/"):
            return self._sample(parsed.path.split("/")[-1])
        self._send(404, b'{"error":"not found"}')

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/gen":
            return self._gen()
        self._send(404, b'{"error":"not found"}')

    def _health(self):
        body = json.dumps(
            {
                "ok": True,
                "gpu": torch.cuda.is_available(),
                "device": str(_DEVICE) if _DEVICE is not None else "not loaded",
                "model_loaded": "pipe" in _MODELS,
                "cache": len(_CACHE),
            },
            ensure_ascii=False,
        ).encode("utf-8")
        self._send(200, body)

    def _samples(self):
        manifest = os.path.join(_SAMPLES_DIR, "manifest.json")
        if not os.path.exists(manifest):
            self._send(200, b"[]")
            return
        with open(manifest, "rb") as f:
            self._send(200, f.read())

    def _sample(self, sid: str):
        # 防目录穿越：只允许文件名。
        if not sid or "/" in sid or "\\" in sid or ".." in sid:
            self._send(400, b'{"error":"bad id"}')
            return
        path = os.path.join(_SAMPLES_DIR, f"{sid}.glb")
        if not os.path.exists(path):
            self._send(404, b'{"error":"sample not found"}')
            return
        with open(path, "rb") as f:
            self._send(200, f.read(), content_type="model/gltf-binary")

    def _gen(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw or b"{}")
        except Exception:
            req = {}
        prompt = (req.get("prompt") or "").strip()
        if not prompt:
            self._send(400, json.dumps({"error": "missing prompt"}).encode())
            return
        try:
            gs = float(req.get("guidance_scale", 15.0))
            steps = int(req.get("num_inference_steps", 64))
            frame = int(req.get("frame_size", 256))
            seed = int(req.get("seed", 0))
        except (TypeError, ValueError):
            self._send(400, json.dumps({"error": "bad params"}).encode())
            return
        try:
            data = gen_cached(prompt, gs, steps, frame, seed)
        except Exception as e:  # noqa: BLE001
            msg = json.dumps({"error": f"generation failed: {e}"}).encode()
            self._send(500, msg)
            return
        self._send(200, data, content_type="model/gltf-binary")


def main():
    ap = argparse.ArgumentParser(description="本地文生 3D 服务（Shap-E / diffusers）")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--steps", type=int, default=64)
    ap.add_argument("--frame-size", type=int, default=256)
    args = ap.parse_args()

    print(
        f"[route_c] serving on http://{args.host}:{args.port} "
        f"(GPU={torch.cuda.is_available()})",
        flush=True,
    )
    print(
        "[route_c] 首次运行会下载 Shap-E 权重（fp16 变体，来自 hf-mirror.com），"
        "之后离线可用。",
        flush=True,
    )
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[route_c] shutting down.", flush=True)
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
