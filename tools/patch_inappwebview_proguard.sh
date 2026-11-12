#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Workaround: flutter_inappwebview_android 1.1.3 (transitive via flutter_3d_controller)
# calls getDefaultProguardFile('proguard-android.txt') in its android/build.gradle.
# Newer AGP (bundled with Flutter 3.47.9, Gradle 9.3.1) HARD-REJECTS that call
# at project-evaluation time, breaking `flutter build apk/aab` (the error fires
# regardless of --obfuscate). This rewrites it to the AGP-recommended
# 'proguard-android-optimize.txt' (safe for release; no behaviour change).
#
# The package lives in pub cache and is re-fetched on a fresh `flutter pub get`,
# so this must run AFTER `flutter pub get` and BEFORE `flutter build apk/aab`.
# Idempotent: only rewrites when the deprecated string is still present.
#
# CI calls this automatically. LOCALLY, run it once after `flutter pub get`:
#   bash tools/patch_inappwebview_proguard.sh
# before `flutter build apk --release ...`.
# ---------------------------------------------------------------------------
set -euo pipefail

patched=0
found=0
roots=()

add_root() {
  # 只接受存在且不重复的目录；空/不存在直接跳过（不硬编码任何用户名）。
  local r="${1:-}"
  [ -n "$r" ] || return 0
  [ -d "$r" ] || return 0
  local existing
  for existing in "${roots[@]:-}"; do
    [ "$existing" = "$r" ] && return 0
  done
  roots+=("$r")
}

add_root "${PUB_CACHE:-}"
add_root "$HOME/.pub-cache"

# Windows（Git Bash / MSYS）：pub 缓存通常在 %LOCALAPPDATA%\Pub\Cache。
# 用 cygpath 转成 POSIX 路径；无 cygpath 时把反斜杠规范化并转换盘符（C:\ -> /c/）。
# 旧版本此处硬编码 /c/Users/<某个用户名>/...，换开发者/换机器即静默失效，故移除。
if [ -n "${LOCALAPPDATA:-}" ]; then
  if command -v cygpath >/dev/null 2>&1; then
    add_root "$(cygpath -u "$LOCALAPPDATA")/Pub/Cache"
  else
    norm=$(printf '%s' "$LOCALAPPDATA" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/\L\1|')
    add_root "$norm/Pub/Cache"
  fi
fi

for root in "${roots[@]:-}"; do
  while IFS= read -r -d '' f; do
    found=$((found + 1))
    if grep -q "proguard-android\.txt" "$f"; then
      sed -i.bak 's/proguard-android\.txt/proguard-android-optimize.txt/g' "$f" && rm -f "$f.bak"
      echo "patched: $f"
      patched=1
    fi
  done < <(find "$root" -type f -path '*flutter_inappwebview_android-*/android/build.gradle' -print0 2>/dev/null)
done

echo "inappwebview proguard patch done (found=$found, patched=$patched)"

if [ "$found" -eq 0 ]; then
  echo "::warning::未在 pub 缓存中找到 flutter_inappwebview_android；若已引入 3D 依赖请先 flutter pub get"
fi

# 兜底校验：若仍残留旧串（sed 失败 / 只读缓存 / 权限问题），明确报错而非静默通过，
# 否则问题会延迟到 Gradle 评估阶段，报难以定位的 AGP 错误。
for root in "${roots[@]:-}"; do
  while IFS= read -r -d '' f; do
    if grep -q "proguard-android\.txt" "$f"; then
      echo "::error::仍存在 proguard-android.txt（改写失败）：$f"
      exit 1
    fi
  done < <(find "$root" -type f -path '*flutter_inappwebview_android-*/android/build.gradle' -print0 2>/dev/null)
done
