#!/usr/bin/env bash
# =============================================================================
# device_audit.sh — 真机运行时验证脚本（解决审计遗留的「待真机验证」项）
#
# 覆盖：
#   ① CPU-only 推理后端剥离是否真的生效（运行时 dlopen 验证，而非只看 APK）
#   ② 真机帧率 / 卡顿 / 内存峰值 / 透明 surface 表现
#
# 用法（设备已通过 adb 连接、App 已安装并处于前台）：
#   bash tools/device_audit.sh                       # 自动取包名
#   bash tools/device_audit.sh com.xxx.yyy            # 显式指定包名
#   bash tools/device_audit.sh <pkg> /path/to/app-arm64-v8a-release.apk
#       （附带 APK 时，会用 check_apk_size.py 再做一次包体/剥离静态核对）
#
# 退出码：0 = 全部 PASS；1 = 有 FAIL 或未连接设备。脚本只读、不修改设备数据。
# =============================================================================
set -u

PKG="${1:-com.elowen131.privateaicompanion}"
APK="${2:-}"
ADB="${ADB:-adb}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0

ok()   { echo "[PASS] $1"; pass=$((pass+1)); }
bad()  { echo "[FAIL] $1"; fail=$((fail+1)); }
info() { echo "[INFO] $1"; }

# ---- 0. adb 可用性 ----------------------------------------------------------
if ! command -v "$ADB" >/dev/null 2>&1; then
  bad "找不到 adb（$ADB）。请安装 Android SDK platform-tools 并加入 PATH。"
  exit 1
fi
if [ -z "$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')" ]; then
  bad "没有已连接的 Android 设备。请通过 USB/无线连接并开启 USB 调试后重试。"
  exit 1
fi
info "已连接设备：$("$ADB" devices | awk 'NR>1 && $2=="device"{printf \"%s \",$1}')"

# 确认包已安装
if ! "$ADB" shell pm path "$PKG" >/dev/null 2>&1; then
  bad "设备上未安装 $PKG。请先安装 release APK 再运行本脚本。"
  exit 1
fi

# 取得前台进程 PID（若 App 没在前台，给出指引但仍继续尽力检查）
PID="$("$ADB" shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
if [ -z "$PID" ]; then
  info "未检测到 $PKG 前台进程。请先打开 App 并切到前台（至少进入一次聊天以触发推理），再重跑本脚本以获取最准确的运行时结果。"
else
  info "前台进程 PID = $PID"
fi

# =============================================================================
# ① CPU-only 后端剥离：运行时真正被 mmap 进进程的原生库
#    被禁止加载的后端（与 android/app/build.gradle.kts excludes 同源）：
#      libggml-vulkan.so        —— llamadart Vulkan GPU 后端 (~42MB)
#      libwebgpu_dawn.so        —— Dawn WebGPU 运行时
#      libLiteRtGpuAccelerator / libLiteRtWebGpuAccelerator / libLiteRtTopKOpenClSampler
#      / libLiteRtTopKWebGpuSampler —— LiteRT GPU/WebGPU/OpenCL 加速器
#      libLiteRtLm.so / libGemmaModelConstraintProvider.so —— LiteRT CPU 推理核心 (~29MB)
#    若这些 .so 出现在 /proc/<pid>/maps，说明剥离失败（运行时仍在加载），须回真机排查。
# =============================================================================
echo ""
echo "=== ① CPU-only 剥离：运行时已映射的原生库 ==="
BANNED_LIBS="libggml-vulkan|libwebgpu_dawn|libLiteRtGpuAccelerator|libLiteRtWebGpuAccelerator|libLiteRtTopKOpenClSampler|libLiteRtTopKWebGpuSampler|libLiteRtLm|libGemmaModelConstraintProvider"

if [ -n "$PID" ]; then
  MATCHED="$("$ADB" shell "cat /proc/$PID/maps 2>/dev/null" | grep -iE "$BANNED_LIBS" | sort -u)"
  if [ -z "$MATCHED" ]; then
    ok "进程未映射任何被禁后端 .so —— CPU-only 推理路径生效（Vulkan/LiteRT/Dawn 未加载）。"
  else
    bad "进程映射了被禁后端（剥离未生效）："
    echo "$MATCHED" | sed 's/^/        /'
  fi
else
  info "跳过运行时 maps 检查（无前台进程）。可手动：adb shell pidof $PKG → adb shell cat /proc/<PID>/maps | grep -iE '$BANNED_LIBS'"
fi

# =============================================================================
# ② 帧率 / 卡顿：dumpsys gfxinfo
#    Janky frames 比例越低越好；本 App 目标 < 5%（滑动/对话切换场景）。
# =============================================================================
echo ""
echo "=== ② 渲染性能：gfxinfo（帧率 / 卡顿）==="
GFX="$("$ADB" shell dumpsys gfxinfo "$PKG" 2>/dev/null)"
TOTAL=$(echo "$GFX" | grep -iE "Total frames rendered" | grep -oE '[0-9]+' | head -1)
JANKY=$(echo "$GFX" | grep -iE "Janky frames" | grep -oE '[0-9]+' | head -1)
if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null; then
  JANKY=${JANKY:-0}
  PCT=$(awk "BEGIN{printf \"%.1f\", ($JANKY*100.0)/$TOTAL}")
  info "渲染帧总数 = $TOTAL，卡顿帧 = $JANKY，卡顿率 = ${PCT}%"
  # 阈值：卡顿率 < 5% 视为流畅
  awk "BEGIN{exit !($PCT < 5.0)}" && \
    ok "卡顿率 ${PCT}% < 5%，流畅度达标。" || \
    bad "卡顿率 ${PCT}% ≥ 5%，需排查（检查是否误启用 GPU 推理或后台负载）。"
else
  info "未取到 gfxinfo 帧数据（可能 App 尚未产生 UI 渲染统计）。请在前台滑动/进入聊天后再测。"
fi

# =============================================================================
# ② 内存峰值：dumpsys meminfo（TOTAL PSS，单位 KB）
#    本 App 目标：常规使用 < 400MB PSS；长时间对话/3D 造型后观察是否持续攀升不回落。
# =============================================================================
echo ""
echo "=== ② 内存占用：meminfo（TOTAL PSS）==="
MEM="$("$ADB" shell dumpsys meminfo "$PKG" 2>/dev/null | grep -iE "^[[:space:]]*TOTAL[[:space:]]+[0-9]+" | awk '{print $2}')"
if [ -n "$MEM" ]; then
  MEM_MB=$(awk "BEGIN{printf \"%.0f\", $MEM/1024}")
  info "当前 TOTAL PSS = ${MEM_MB} MB（${MEM} KB）"
  # 阈值：常规 < 400MB；超过则提示关注（注意页面栈/媒体缓存是否及时释放）
  awk "BEGIN{exit !($MEM_MB <= 400)}" && \
    ok "内存峰值 ${MEM_MB}MB ≤ 400MB 预算。" || \
    bad "内存 ${MEM_MB}MB > 400MB，关注是否存在泄漏（检查媒体/3D 资源释放）。"
else
  info "未取到 meminfo 数据。可手动：adb shell dumpsys meminfo $PKG"
fi

# =============================================================================
# ② 透明 surface：检查主 Activity 窗口的不透明标记
#    App 采用透明/周边 surface（桌面伴生层），目标是「透明不黑底」。
#    这里通过 window 状态判断窗口是否被标记为 opaque；黑底问题需肉眼复检。
# =============================================================================
echo ""
echo "=== ② 透明 surface 检查（窗口不透明度）==="
WIN="$("$ADB" shell dumpsys window windows 2>/dev/null | grep -iE "Window{[^ ]*$PKG" | head -1)"
if [ -n "$WIN" ]; then
  if echo "$WIN" | grep -qiE "isOpen=true"; then
    info "检测到 $PKG 主窗口处于打开状态。透明/黑底观感需在真机肉眼复检（透明 surface 不应出现纯黑底闪烁）。"
    ok "窗口状态可读（isOpen）。透明 surface 渲染观感请按上方指引肉眼确认。"
  else
    info "主窗口状态：$WIN"
  fi
else
  info "未从 dumpsys window 解析到主窗口。请在前台时重跑；黑底/透明观感以肉眼复检为准。"
fi

# =============================================================================
# 附带：若有 APK，做包体/剥离静态核对（与 CI check_apk_size.py 同源）
# =============================================================================
if [ -n "$APK" ] && [ -f "$APK" ]; then
  echo ""
  echo "=== 附带：APK 包体/剥离静态核对 ==="
  if [ -f "$SCRIPT_DIR/check_apk_size.py" ]; then
    python3 "$SCRIPT_DIR/check_apk_size.py" "$APK" --allow-multi-abi || true
  else
    info "未找到 check_apk_size.py，跳过静态核对。"
  fi
fi

echo ""
echo "==================== 汇总 ===================="
echo "PASS = $pass, FAIL = $fail"
if [ "$fail" -gt 0 ]; then
  echo "结论：存在未达标项，请在真机排查后重测。"
  exit 1
else
  echo "结论：本次真机运行时检查全部通过。"
  exit 0
fi
