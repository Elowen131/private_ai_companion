#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 shap_e_renderer 的 fp32 .bin 转成完整的 fp16 safetensors。

为什么需要：
  diffusers 0.43 的 ShapEPipeline 实际加载的是 `shap_e_renderer` 组件。
  该组件的 fp32 权重 `diffusion_pytorch_model.bin` 里含有 marching cubes
  的查找表 `mesh_decoder.cases` / `mesh_decoder.masks`，而仓库里另一个
  `renderer/` 的 fp16 权重**不含这两项**。若直接用 renderer 的 fp16 顶替，
  decode_to_mesh 会得到空纹理列表并抛
  `ValueError: torch.cat(): expected a non-empty list of Tensors`。

本脚本从 .bin 读取完整 state_dict，浮点权重转 fp16、整数/布尔查找表保持
原 dtype，保存为 `diffusion_pytorch_model.fp16.safetensors`，使
`ShapEPipeline.from_pretrained(..., variant="fp16", use_safetensors=True)`
能加载完整权重，同时体积/内存约为 fp32 的一半。

用法：
    python tools/text_to_3d/convert_renderer.py
可选：--model-dir /path/to/openai_shap-e
"""
import argparse
import os

import torch
from safetensors.torch import save_file

_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(_HERE, "weights", "openai_shap-e")


def main():
    ap = argparse.ArgumentParser(description="fp32 .bin -> 完整 fp16 safetensors")
    ap.add_argument("--model-dir",
                    default=os.environ.get("LOCAL_MODEL_DIR") or DEFAULT_DIR)
    args = ap.parse_args()

    sub = os.path.join(args.model_dir, "shap_e_renderer")
    src = os.path.join(sub, "diffusion_pytorch_model.bin")
    dst = os.path.join(sub, "diffusion_pytorch_model.fp16.safetensors")
    if not os.path.exists(src):
        raise SystemExit(f"[convert] FATAL: not found {src}")

    print(f"[convert] loading {src} ({os.path.getsize(src)/1024/1024:.0f} MB) …",
          flush=True)
    try:
        sd = torch.load(src, map_location="cpu", weights_only=True)
    except Exception:  # 旧版 pickle state_dict
        sd = torch.load(src, map_location="cpu", weights_only=False)

    out = {}
    for k, v in sd.items():
        if not isinstance(v, torch.Tensor):
            continue  # 跳过 _metadata 等非张量项
        if v.is_floating_point():
            out[k] = v.to(torch.float16).contiguous()
        else:
            out[k] = v.contiguous()

    print(f"[convert] tensors={len(out)}", flush=True)
    for key in ("mesh_decoder.cases", "mesh_decoder.masks"):
        if key not in out:
            raise SystemExit(f"[convert] FATAL: missing {key} in checkpoint")
        print(f"[convert]   {key}: {tuple(out[key].shape)} {out[key].dtype}",
              flush=True)

    save_file(out, dst)
    print(f"[convert] wrote {dst} ({os.path.getsize(dst)/1024/1024:.0f} MB)",
          flush=True)
    print("[convert] SUCCESS — 现在可用 variant='fp16' 加载完整渲染器。",
          flush=True)


if __name__ == "__main__":
    main()
