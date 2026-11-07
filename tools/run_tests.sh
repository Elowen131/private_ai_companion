#!/usr/bin/env bash
# 本地测试运行器 —— 为后续测试提效。
#
# 背景：本工程 44 个测试用例里，有 12 个依赖端侧 LLM 底座 llamadart 的原生资产
# （通过 app/di.dart → local_llm_provider.dart 间接引入）。CI（GitHub ubuntu）可联网
# 拉取该原生库，但本地开发机常因代理拦截其下载而 `flutter test` 整批失败。本脚本默认
# 跑「纯 Dart / 不依赖原生资产」的用例，让本地能稳定跑通回归；需要时再用 `all` 跑全量。
#
# 用法：
#   ./tools/run_tests.sh                 # 跑全部「纯」用例（默认）
#   ./tools/run_tests.sh --coverage      # 纯用例 + 生成覆盖率（lcov 在 coverage/lcov.info）
#   ./tools/run_tests.sh test/foo_test.dart   # 跑指定文件（可多个）
#   ./tools/run_tests.sh all             # 跑全部用例（含 llamadart 耦合，需能拉原生资产）
#
# 退出码透传 flutter test，便于接入 pre-commit / CI。

set -euo pipefail
cd "$(dirname "$0")/.."

# flutter 不一定在 PATH（尤其非交互式子 shell）。优先级：环境变量 FLUTTER_BIN
# > 常见本地安装路径兜底 > 最后才回退到裸 flutter。
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  for p in /c/tools/flutter/bin/flutter \
           "$HOME/flutter/bin/flutter" \
           /opt/flutter/bin/flutter \
           "$LOCALAPPDATA/flutter/bin/flutter"; do
    if [ -x "$p" ]; then FLUTTER_BIN="$p"; break; fi
  done
fi

# 这 12 个用例间接引入 llamadart 原生资产，本地大概率跑不了，默认排除。
EXCLUDE=(
  test/appearance_test.dart
  test/avatar_studio_page_test.dart
  test/frontend_hardening_test.dart
  test/group_chat_layout_test.dart
  test/performance_budget_test.dart
  test/quick_key_test.dart
  test/topic_browser_test.dart
  test/topic_sheet_race_test.dart
  test/ui_preview_test.dart
  test/ux_flow_test.dart
  test/ux_navigation_test.dart
  test/world_ui_smoke_test.dart
)

COVERAGE=""
MODE="pure"
FILES=()
for a in "$@"; do
  case "$a" in
    --coverage) COVERAGE="--coverage" ;;
    all) MODE="all" ;;
    *.dart) FILES+=("$a") ;;
    *) echo "忽略未知参数: $a" ;;
  esac
done

run_flutter() {
  echo ">>> $FLUTTER_BIN test $*"
  "$FLUTTER_BIN" test $COVERAGE "$@"
}

if [ "$MODE" = "all" ]; then
  echo "== 全量模式：含 llamadart 耦合用例，需能联网拉取原生资产 =="
  if [ ${#FILES[@]} -gt 0 ]; then
    run_flutter "${FILES[@]}"
  else
    run_flutter
  fi
  exit $?
fi

if [ ${#FILES[@]} -gt 0 ]; then
  echo "== 指定文件模式 =="
  run_flutter $COVERAGE "${FILES[@]}"
  exit $?
fi

# 纯模式：收集 test/*_test.dart 减去 EXCLUDE 列表。
mapfile -t ALL < <(find test -maxdepth 1 -name '*_test.dart' | sort)
PICK=()
for f in "${ALL[@]}"; do
  skip=0
  for e in "${EXCLUDE[@]}"; do
    [ "$f" = "$e" ] && skip=1 && break
  done
  [ "$skip" -eq 0 ] && PICK+=("$f")
done

echo "== 纯模式：跑 ${#PICK[@]} 个用例（排除 ${#EXCLUDE[@]} 个 llamadart 耦合） =="
run_flutter $COVERAGE "${PICK[@]}"
