#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""端到端自检：本地权重加载 -> 文本推理 -> GLB 导出 -> 校验文件头。

用于确认「路线 C」整条链路真的能出模型，而不只是服务能启动。
权重从默认落点 tools/text_to_3d/weights/openai_shap-e/ 读取，完全离线。

用法：
    python tools/text_to_3d/verify_pipeline.py
可选：
    --prompt "a cute cat" --steps 16 --frame-size 64 --out ./verify.glb
"""
import argparse
import io
import os
import tempfile
import time

os.environ.setdefault("MPLBACKEND", "Agg")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

import numpy as np  # noqa: E402
import torch  # noqa: E402
from diffusers import ShapEPipeline  # noqa: E402
from diffusers.utils import export_to_ply  # noqa: E402
import trimesh  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser(description="Shap-E 端到端自检")
    ap.add_argument("--model-dir",
                    default=os.environ.get("LOCAL_MODEL_DIR")
                    or os.path.join(_HERE, "weights", "openai_shap-e"))
    ap.add_argument("--prompt", default="a cute cat")
    ap.add_argument("--steps", type=int, default=16, help="低步数，快速验证")
    ap.add_argument("--frame-size", type=int, default=64, help="低分辨率，快速验证")
    ap.add_argument("--out", default=os.path.join(_HERE, "verify.glb"))
    args = ap.parse_args()

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    dtype = torch.float16 if device.type == "cuda" else torch.float32
    print(f"[verify] device={device} dtype={dtype}", flush=True)
    print(f"[verify] model_dir={args.model_dir}", flush=True)
    if not os.path.exists(os.path.join(args.model_dir, "model_index.json")):
        raise SystemExit(f"[verify] FATAL: no model_index.json in {args.model_dir}")

    t0 = time.time()
    print("[verify] loading pipeline (offline) …", flush=True)
    pipe = ShapEPipeline.from_pretrained(
        args.model_dir,
        torch_dtype=dtype,
        variant="fp16",
        use_safetensors=True,
        local_files_only=True,
    ).to(device)
    print(f"[verify] pipeline loaded in {time.time()-t0:.1f}s", flush=True)

    t1 = time.time()
    print(f"[verify] generating: '{args.prompt}' steps={args.steps} "
          f"frame={args.frame_size} …", flush=True)
    with torch.no_grad():
        out = pipe(
            args.prompt,
            guidance_scale=15.0,
            num_inference_steps=args.steps,
            frame_size=args.frame_size,
            output_type="mesh",
        )
    mesh = out.images[0]
    print(f"[verify] inference done in {time.time()-t1:.1f}s", flush=True)

    with tempfile.NamedTemporaryFile(suffix=".ply", delete=False) as tf:
        ply_path = tf.name
    try:
        export_to_ply(mesh, ply_path)
        tm = trimesh.load(ply_path)
        rot = trimesh.transformations.rotation_matrix(-np.pi / 2, [1, 0, 0])
        tm = tm.apply_transform(rot)
        buf = io.BytesIO()
        tm.export(buf, file_type="glb")
        data = buf.getvalue()
    finally:
        try:
            os.remove(ply_path)
        except OSError:
            pass

    with open(args.out, "wb") as f:
        f.write(data)
    magic_ok = data[:4] == b"glTF"
    print(f"[verify] GLB: {len(data)} bytes  magic={'OK' if magic_ok else 'BAD'}  "
          f"-> {args.out}", flush=True)
    print(f"[verify] TOTAL {time.time()-t0:.1f}s", flush=True)
    if not magic_ok or len(data) < 1024:
        raise SystemExit("[verify] FAILED: GLB looks invalid")
    print("[verify] SUCCESS — text -> 3D pipeline works end-to-end.", flush=True)


if __name__ == "__main__":
    main()
