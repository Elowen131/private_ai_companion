#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在「能联网的机器」上把 openai/shap-e 权重下载到本地目录（断点续传）。

用途：本项目路线 C 的推理机（server.py / generate.py）支持从本地目录加载权重
（设置环境变量 LOCAL_MODEL_DIR 指向本脚本的输出目录即可完全离线运行）。

本脚本应在「能正常访问 huggingface.co 或 hf-mirror.com 的机器」上运行——
例如你开了 VPN 的电脑。它不依赖本项目 venv，只要有 Python + huggingface_hub：

    pip install -U "huggingface_hub[cli]"

用法：
    python download_weights.py --local-dir ./openai_shap-e
    # 若 huggingface.co 直连不通，用镜像（默认就是 hf-mirror.com）：
    python download_weights.py --local-dir ./openai_shap-e --endpoint https://hf-mirror.com
"""
import argparse
import os

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "0")

from huggingface_hub import snapshot_download  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description="下载 Shap-E 权重到本地目录")
    ap.add_argument("--local-dir", required=True,
                    help="输出目录，例如 ./openai_shap-e")
    ap.add_argument("--repo", default="openai/shap-e")
    ap.add_argument(
        "--endpoint",
        default=os.environ.get("HF_ENDPOINT", "https://hf-mirror.com"),
        help="HF 镜像，默认 hf-mirror.com；若直连 huggingface.co 通可改为之。",
    )
    args = ap.parse_args()
    os.environ["HF_ENDPOINT"] = args.endpoint

    print(f"[download] endpoint={args.endpoint} repo={args.repo} -> {args.local_dir}")
    path = snapshot_download(
        repo_id=args.repo,
        local_dir=args.local_dir,
        local_dir_use_symlinks=False,
    )
    print(f"[download] done -> {path}")
    print("[download] 之后在本项目设置 LOCAL_MODEL_DIR 指向该目录即可离线加载。")


if __name__ == "__main__":
    main()
