#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""弱网专用：并行分块 + 断点续传下载 Shap-E 权重到本地目录。

适用场景：huggingface.co 直连不通、hf-mirror 的小文件 API 通道被限速，
但 LFS 大文件 CDN（cas-bridge.xethub.hf.co）可用且支持 HTTP Range。
单连接约 200 KB/s，16 连接并行可叠加到 ~800 KB/s。

用法：
    python fetch_weights.py --local-dir ./weights/openai_shap-e
可选：
    --endpoint https://hf-mirror.com   # 换镜像源
    --workers 16                       # 并行连接数
    --chunk-size 4                     # 每块 MB
    --with-fp32-renderer               # 额外下载 shap_e_renderer 的 fp32 .bin（905MB，通常不需要）

特性：
- 每个分块单独落盘为 .part，中断后重跑会跳过已完成块（真·断点续传）；
- 小文件直接整文件下载；
- 失败自动重试（指数退避），全部块完成后才合并，避免半成品；
- 只用 Python 标准库，无额外依赖。
"""
import argparse
import os
import sys
import threading
import time
import urllib.request

REPO = "openai/shap-e"

# 运行 diffusers 0.43 ShapEPipeline(variant="fp16", use_safetensors=True)
# 所需的最小文件集。shap_e_renderer 的 fp16 权重由 renderer 的复制而来
# （两者是同一 ShapERenderer 的两个副本，fp16 大小恰为 fp32 的一半）。
FILES = {
    "model_index.json": 458,
    "prior/config.json": 489,
    "prior/diffusion_pytorch_model.fp16.safetensors": 631435880,
    "renderer/config.json": 496,
    "renderer/diffusion_pytorch_model.fp16.safetensors": 452597858,
    "scheduler/scheduler_config.json": 276,
    "shap_e_renderer/config.json": 551,
    "text_encoder/config.json": 626,
    "text_encoder/model.fp16.safetensors": 247324608,
    "tokenizer/merges.txt": 524619,
    "tokenizer/special_tokens_map.json": 472,
    "tokenizer/tokenizer_config.json": 737,
    "tokenizer/vocab.json": 1059962,
    "README.md": 3899,
    ".gitattributes": 1477,
}

# 仅当确实需要 fp32 渲染器时才加（--with-fp32-renderer）
OPTIONAL_FP32 = {
    "shap_e_renderer/diffusion_pytorch_model.bin": 905233202,
}

_print_lock = threading.Lock()
_state = {"bytes": 0, "chunks": 0, "total": 0}
_t0 = time.time()


def log(msg):
    with _print_lock:
        print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _progress(nbytes, chunk=False):
    with _print_lock:
        _state["bytes"] += nbytes
        if chunk:
            _state["chunks"] += 1
        done = _state["bytes"]
        total = _state["total"]
        elapsed = max(time.time() - _t0, 1e-6)
        pct = 100.0 * done / total if total else 0
        speed = done / elapsed / 1024
        print(
            f"\r  {done/1024/1024:.1f}/{total/1024/1024:.1f} MB "
            f"({pct:.1f}%)  {speed:.0f} KB/s  chunks={_state['chunks']}   ",
            end="", flush=True,
        )


def _url(name, endpoint):
    return f"{endpoint.rstrip('/')}/{REPO}/resolve/main/{name}"


def _get(url, headers, timeout=150):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def fetch_small(name, size, dest, endpoint, retries):
    if os.path.exists(dest) and os.path.getsize(dest) == size:
        _progress(size)
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    last = None
    for attempt in range(retries):
        try:
            data = _get(_url(name, endpoint), {"User-Agent": "Mozilla/5.0"}, 90)
            if size and len(data) != size:
                raise ValueError(f"{name}: expected {size} bytes, got {len(data)}")
            tmp = dest + ".tmp"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, dest)
            _progress(len(data))
            return
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1 + attempt)
    raise RuntimeError(f"failed small file {name}: {last}")


def fetch_chunk(args_tuple):
    name, idx, start, end, part_dir, endpoint, retries = args_tuple
    part = os.path.join(part_dir, f"{idx:05d}.part")
    want = end - start + 1
    if os.path.exists(part) and os.path.getsize(part) == want:
        return
    os.makedirs(part_dir, exist_ok=True)
    headers = {
        "Range": f"bytes={start}-{end}",
        "User-Agent": "Mozilla/5.0",
    }
    last = None
    for attempt in range(retries):
        try:
            data = _get(_url(name, endpoint), headers, 150)
            if len(data) != want:
                raise ValueError(
                    f"{name} chunk {idx}: expected {want} bytes, got {len(data)}"
                )
            tmp = part + ".tmp"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, part)
            _progress(want, chunk=True)
            return
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1 + attempt)
    raise RuntimeError(f"FAILED chunk {name} #{idx}: {last}")


def fetch_big(name, size, dest, endpoint, chunk_mb, workers, retries):
    # 已完成则跳过
    if os.path.exists(dest) and os.path.getsize(dest) == size:
        log(f"OK (already) {name} ({size/1024/1024:.0f} MB)")
        _progress(size)
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    safe = name.replace("/", "__")
    part_dir = os.path.join(os.path.dirname(dest), ".parts", safe)
    chunk = chunk_mb * 1024 * 1024
    tasks = []
    idx = 0
    pos = 0
    while pos < size:
        end = min(pos + chunk - 1, size - 1)
        tasks.append((name, idx, pos, end, part_dir, endpoint, retries))
        idx += 1
        pos = end + 1
    log(f"start {name}: {size/1024/1024:.0f} MB -> {len(tasks)} chunks")
    from concurrent.futures import ThreadPoolExecutor, as_completed
    errors = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(fetch_chunk, t) for t in tasks]
        for fu in as_completed(futs):
            try:
                fu.result()
            except Exception as e:  # noqa: BLE001
                errors.append(str(e))
                log(f"  !! {e}")
    if errors:
        raise RuntimeError(f"{len(errors)} chunks failed for {name}; re-run to resume")
    # 合并
    log(f"merging {name} …")
    tmp = dest + ".merging"
    with open(tmp, "wb") as out:
        for i in range(len(tasks)):
            p = os.path.join(part_dir, f"{i:05d}.part")
            with open(p, "rb") as f:
                out.write(f.read())
    if os.path.getsize(tmp) != size:
        raise RuntimeError(f"{name}: merged size mismatch")
    os.replace(tmp, dest)
    # 清理分块
    try:
        for i in range(len(tasks)):
            os.remove(os.path.join(part_dir, f"{i:05d}.part"))
        os.rmdir(part_dir)
    except OSError:
        pass
    log(f"OK {name} ({size/1024/1024:.0f} MB)")


def main():
    ap = argparse.ArgumentParser(description="并行分块下载 Shap-E 权重（弱网友好）")
    ap.add_argument("--local-dir", required=True)
    ap.add_argument("--endpoint", default=os.environ.get("HF_ENDPOINT", "https://hf-mirror.com"))
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--chunk-size", type=int, default=4, help="每块 MB")
    ap.add_argument("--retries", type=int, default=6)
    ap.add_argument("--with-fp32-renderer", action="store_true")
    args = ap.parse_args()

    files = dict(FILES)
    if args.with_fp32_renderer:
        files.update(OPTIONAL_FP32)

    _state["total"] = sum(files.values())
    os.makedirs(args.local_dir, exist_ok=True)
    log(f"endpoint={args.endpoint}")
    log(f"dest={args.local_dir}")
    log(f"files={len(files)}  total={_state['total']/1024/1024/1024:.2f} GB  "
        f"workers={args.workers}  chunk={args.chunk_size}MB")

    # 小文件先下（config / tokenizer），保证管线配置齐全
    small = [(n, s) for n, s in files.items() if s <= 8 * 1024 * 1024]
    big = [(n, s) for n, s in files.items() if s > 8 * 1024 * 1024]
    for name, size in small:
        dest = os.path.join(args.local_dir, *name.split("/"))
        try:
            fetch_small(name, size, dest, args.endpoint, args.retries)
        except Exception as e:  # noqa: BLE001
            log(f"  !! small file failed: {e}")
    print(flush=True)
    log(f"small files done ({len(small)}); starting {len(big)} big files")

    # 大文件串行启动、每个内部并行分块（避免多个大文件同时抢连接）
    for name, size in big:
        dest = os.path.join(args.local_dir, *name.split("/"))
        fetch_big(name, size, dest, args.endpoint,
                  args.chunk_size, args.workers, args.retries)
        print(flush=True)

    elapsed = time.time() - _t0
    log(f"ALL DONE in {elapsed/60:.1f} min -> {args.local_dir}")

    # 把 renderer 的 fp16 复制给 shap_e_renderer（同一 ShapERenderer，省 863MB 下载）
    src = os.path.join(args.local_dir, "renderer", "diffusion_pytorch_model.fp16.safetensors")
    dst = os.path.join(args.local_dir, "shap_e_renderer", "diffusion_pytorch_model.fp16.safetensors")
    if os.path.exists(src) and not os.path.exists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        import shutil
        shutil.copyfile(src, dst)
        log("copied renderer fp16 -> shap_e_renderer fp16 (same ShapERenderer)")

    # 完整性校验
    missing = []
    for name, size in files.items():
        p = os.path.join(args.local_dir, *name.split("/"))
        if not os.path.exists(p) or os.path.getsize(p) != size:
            missing.append(name)
    if missing:
        log(f"MISSING/MISMATCH: {missing}")
        sys.exit(1)
    log("integrity check passed: all files present with expected sizes")


if __name__ == "__main__":
    main()
