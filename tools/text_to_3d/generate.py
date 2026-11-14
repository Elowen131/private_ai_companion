#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""离线批量生成路线 C 的样例 GLB（供 App 首启 / 无服务演示）。

基于 HuggingFace diffusers 的 ShapEPipeline 在本地把若干固定提示词推理成 GLB，
输出到 ./samples/ 并写 manifest.json。产物会提交进 assets/route_c_samples/，
随包分发，保证手机端无 PC、无网也能演示文生 3D。

用法：
    python tools/text_to_3d/generate.py [--out samples] [--steps 64] [--guidance 15]
"""
import argparse
import json
import os
import tempfile
import threading

# 在中转代理下用 hf-mirror 代替 huggingface.co；回环不走代理；无头 Agg。
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("NO_PROXY", "127.0.0.1,localhost,::1")
os.environ.setdefault("no_proxy", "127.0.0.1,localhost,::1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("MPLBACKEND", "Agg")

import torch  # noqa: E402
from diffusers import ShapEPipeline  # noqa: E402
from diffusers.utils import export_to_ply  # noqa: E402
import trimesh  # noqa: E402
import numpy as np  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))

# (样例 id, 英文提示词) —— 与 lib 侧 route_c_glb_store.dart 的 routeCSamples 对齐。
SAMPLES = [
    ("cat", "a cute cat"),
    ("dog", "a small dog"),
    ("dragon", "a dragon"),
    ("robot", "a robot"),
    ("chair", "a wooden chair"),
    ("flower", "a flower"),
]


def _mesh_to_glb_bytes(mesh) -> bytes:
    with tempfile.NamedTemporaryFile(suffix=".ply", delete=False) as tf:
        ply_path = tf.name
    try:
        export_to_ply(mesh, ply_path)
        tm = trimesh.load(ply_path)
        rot = trimesh.transformations.rotation_matrix(-np.pi / 2, [1, 0, 0])
        tm = tm.apply_transform(rot)
        buf = __import__("io").BytesIO()
        tm.export(buf, file_type="glb")
        return buf.getvalue()
    finally:
        try:
            os.remove(ply_path)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description="离线生成样例 GLB")
    ap.add_argument("--out", default=os.path.join(_HERE, "samples"))
    ap.add_argument("--steps", type=int, default=64)
    ap.add_argument("--guidance", type=float, default=15.0)
    ap.add_argument("--frame-size", type=int, default=256)
    ap.add_argument(
        "--model-dir",
        default=os.environ.get("LOCAL_MODEL_DIR", "").strip(),
        help="本地权重目录（HF 格式）。设置后完全离线加载，不走网络。",
    )
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"[route_c] device = {device}", flush=True)

    # 解析本地权重目录：--model-dir > 环境变量 LOCAL_MODEL_DIR >
    # 默认落点 tools/text_to_3d/weights/openai_shap-e
    model_dir = args.model_dir
    if not (model_dir and os.path.isdir(model_dir)
            and os.path.exists(os.path.join(model_dir, "model_index.json"))):
        default_dir = os.path.join(_HERE, "weights", "openai_shap-e")
        if os.path.isdir(default_dir) and os.path.exists(
            os.path.join(default_dir, "model_index.json")
        ):
            model_dir = default_dir

    if model_dir:
        print(f"[route_c] loading Shap-E from local dir: {model_dir} …", flush=True)
        pipe = ShapEPipeline.from_pretrained(
            model_dir,
            torch_dtype=torch.float16,
            variant="fp16",
            use_safetensors=True,
            local_files_only=True,
        ).to(device)
    else:
        print("[route_c] loading Shap-E (openai/shap-e) …", flush=True)
        pipe = ShapEPipeline.from_pretrained(
            "openai/shap-e",
            torch_dtype=torch.float16,
            variant="fp16",
            use_safetensors=True,
        ).to(device)
    print("[route_c] pipeline ready.", flush=True)

    manifest = []
    for sid, prompt in SAMPLES:
        print(f"[route_c] generating [{sid}] :: {prompt}", flush=True)
        try:
            with torch.no_grad():
                output = pipe(
                    prompt,
                    guidance_scale=args.guidance,
                    num_inference_steps=args.steps,
                    frame_size=args.frame_size,
                    output_type="mesh",
                )
            mesh = output.images[0]
            data = _mesh_to_glb_bytes(mesh)
        except Exception as e:  # noqa: BLE001
            print(f"[route_c]   !! {sid} 生成失败：{e}", flush=True)
            continue
        path = os.path.join(args.out, f"{sid}.glb")
        with open(path, "wb") as f:
            f.write(data)
        manifest.append({"id": sid, "prompt": prompt, "file": f"{sid}.glb"})
        print(
            f"[route_c]   -> {path} ({len(data) / 1024:.0f} KB)",
            flush=True,
        )

    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print(
        f"[route_c] done. {len(manifest)} samples written to {args.out}",
        flush=True,
    )


if __name__ == "__main__":
    main()
