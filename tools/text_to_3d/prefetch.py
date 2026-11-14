#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""预拉取并缓存 Shap-E 权重（fp16，来自 hf-mirror），可断点续传。

由 setup.ps1 的 -DownloadWeights 调用；也可单独运行：
    .venv/Scripts/python.exe prefetch.py
"""
import os

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("NO_PROXY", "127.0.0.1,localhost,::1")
os.environ.setdefault("no_proxy", "127.0.0.1,localhost,::1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

import torch
from diffusers import ShapEPipeline


def main():
    print("[route_c] downloading / caching Shap-E weights (fp16) …", flush=True)
    ShapEPipeline.from_pretrained(
        "openai/shap-e",
        torch_dtype=torch.float16,
        variant="fp16",
        use_safetensors=True,
    )
    print("[route_c] weights ready.", flush=True)


if __name__ == "__main__":
    main()
