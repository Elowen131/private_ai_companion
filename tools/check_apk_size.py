#!/usr/bin/env python3
"""release APK 包体预算门禁（docs/performance-architecture.md §5.1 M1~M4）。

为什么需要它：
  Android 的 shrinkResources 只裁剪 res/，裁剪不到 flutter_assets 与 lib/*.so。
  一个误加的目录声明、一个新引入的原生插件、或一次把 GGUF/GLB 复制进 assets
  的操作，都会让交付包悄悄变大而 CI 仍然全绿。这里把「模型不进包」「单 ABI
  分包」「flutter_assets 预算」变成可失败的硬断言。

用法：
  python3 tools/check_apk_size.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
  python3 tools/check_apk_size.py <全 ABI APK> --allow-multi-abi   # 仅本地诊断

只读，不修改任何文件；失败时退出码 1。
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import sys
import zipfile

MB = 1024 * 1024

# 与文档 §5.1 的 M1/M2/M4 对齐。基线为排除 Vulkan 后端后的实测值：
# arm64 单 ABI 未压缩 ≈ 85MB、APK ≈ 83MB（llamadart 0.17.5 的 CPU 后端 + Flutter/App/
# SQLCipher 等）。预算留 15~20MB 余量容忍原生库版本微调，同时仍能拦住：模型误入包、
# 新增大型 .so（≥20MB）、Vulkan 后端回归（≈42MB）、多 ABI 回潮。
MAX_UNCOMPRESSED_MB = 105.0
MAX_FLUTTER_ASSETS_MB = 1.0
MAX_APK_FILE_MB = 100.0
EXPECTED_ABI = "arm64-v8a"

# 明确属于模型 / 权重：任何大小都不允许出现在 assets/。
MODEL_SUFFIXES = (
    ".glb", ".gltf", ".vrm", ".obj", ".fbx", ".blend", ".stl",
    ".gguf", ".ggml", ".safetensors", ".onnx", ".pt", ".pth", ".tflite",
)
# 通用容器后缀：Flutter 自己会生成 AssetManifest.bin 这类小清单，
# 因此只有超过 1MB 才判定为「误把模型/压缩包打进包」。
GENERIC_SUFFIXES = (".bin", ".zip", ".7z", ".tar", ".gz", ".dat")
GENERIC_MIN_BYTES = 1 * MB

# 用户资产目录。flutter_assets 根下的 AssetManifest / FontManifest / NOTICES.Z
# 等是 Flutter 工具链自动生成，不参与模型判定。
USER_ASSET_PREFIX = "assets/flutter_assets/assets/"


def classify(name: str) -> str:
    if name.startswith("lib/"):
        parts = name.split("/")
        return f"lib/{parts[1]}" if len(parts) > 1 else "lib/?"
    if name.endswith(".dex"):
        return "classes.dex"
    if name.startswith("assets/flutter_assets/"):
        return "flutter_assets"
    if name.startswith("res/"):
        return "res"
    if name.startswith("assets/"):
        return "other assets"
    return "other"


def main() -> int:
    ap = argparse.ArgumentParser(description="release APK 包体预算门禁")
    ap.add_argument("apk", type=pathlib.Path)
    ap.add_argument(
        "--allow-multi-abi",
        action="store_true",
        help="本地诊断用：允许检查全 ABI 旧产物（CI 必须单 ABI）",
    )
    args = ap.parse_args()

    if not args.apk.is_file():
        print(f"[size] FAIL: 找不到 APK：{args.apk}")
        return 1

    with zipfile.ZipFile(args.apk) as z:
        infos = z.infolist()

    groups: collections.Counter[str] = collections.Counter()
    abis: set[str] = set()
    bad_assets: list[str] = []
    so_entries: list[tuple[str, int]] = []
    for i in infos:
        groups[classify(i.filename)] += i.file_size
        if i.filename.startswith("lib/"):
            parts = i.filename.split("/")
            if len(parts) > 1 and parts[1] not in ("?", ""):
                abis.add(parts[1])
            if i.filename.endswith(".so"):
                so_entries.append((i.filename, i.file_size))
        low = i.filename.lower()
        if not low.startswith(USER_ASSET_PREFIX):
            continue
        if low.endswith(MODEL_SUFFIXES):
            bad_assets.append(i.filename)
        elif low.endswith(GENERIC_SUFFIXES) and i.file_size > GENERIC_MIN_BYTES:
            bad_assets.append(f"{i.filename} ({i.file_size / MB:.1f} MB)")

    total = sum(groups.values())
    flutter_assets = groups.get("flutter_assets", 0)
    apk_mb = args.apk.stat().st_size / MB

    print(f"[size] APK: {args.apk}")
    print(f"[size] 压缩后文件: {apk_mb:.2f} MB / 未压缩总计: {total / MB:.2f} MB")
    for k, v in groups.most_common():
        print(f"[size]   {v / MB:9.2f} MB  {k}")
    print(f"[size] ABI: {', '.join(sorted(abis)) or '(none)'}")
    print("[size] top native libs:")
    for name, sz in sorted(so_entries, key=lambda x: -x[1])[:12]:
        print(f"[size]   {sz / MB:9.2f} MB  {name}")

    failures: list[str] = []
    if total / MB > MAX_UNCOMPRESSED_MB:
        failures.append(
            f"未压缩总体积 {total / MB:.2f} MB > 预算 {MAX_UNCOMPRESSED_MB:.0f} MB（M1）"
        )
    if flutter_assets / MB > MAX_FLUTTER_ASSETS_MB:
        failures.append(
            f"flutter_assets {flutter_assets / MB:.2f} MB > 预算 "
            f"{MAX_FLUTTER_ASSETS_MB:.0f} MB（M2，检查 pubspec.yaml 是否误用目录声明）"
        )
    if apk_mb > MAX_APK_FILE_MB:
        failures.append(
            f"APK 文件 {apk_mb:.2f} MB > 预算 {MAX_APK_FILE_MB:.0f} MB"
        )
    if not args.allow_multi_abi and abis != {EXPECTED_ABI}:
        failures.append(
            f"APK 应只含 {EXPECTED_ABI}，实际 {sorted(abis)}；"
            "检查 --split-per-abi --target-platform android-arm64 是否被改掉（B6）"
        )
    if bad_assets:
        failures.append(
            "assets/ 内出现模型/权重/压缩包，违反「模型按需下载不进包」（PRD 11.3）："
            + ", ".join(bad_assets[:8])
            + (" …" if len(bad_assets) > 8 else "")
        )
    if any(n.endswith("libggml-vulkan.so") for n, _ in so_entries):
        failures.append(
            "lib/ 内出现 libggml-vulkan.so（约 42MB 的 Vulkan GPU 后端）；"
            "本 App 端侧推理固定 gpuLayers=0（CPU-only，见 lib/core/llm/local_llm_provider.dart），"
            "该后端永不加载，应从 android/app/build.gradle.kts 的 packaging jniLibs excludes 排除；"
            "如需启用 GPU 推理须同步设置 nGpuLayers>0 并在真机验证"
        )

    if failures:
        print("[size] FAIL:")
        for f in failures:
            print(f"[size]   - {f}")
        return 1
    print("[size] PASS: 包体预算全部达标")
    return 0


if __name__ == "__main__":
    sys.exit(main())
