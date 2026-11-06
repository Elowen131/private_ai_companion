#!/usr/bin/env bash
# 跑测试的统一入口：先修掉「代理劫持回环」导致 flutter_tester 起不来的问题。
#
# 背景：宿主环境会注入 HTTP_PROXY/HTTPS_PROXY=http://127.0.0.1:xxxx。`flutter test`
# 启动 flutter_tester 后要连 ws://127.0.0.1:<port>/ws 的 VM Service，Dart 的 HTTP
# 客户端按环境变量把这条本机连接也送进代理，代理不认 WebSocket 升级，于是报
#   WebSocketException: Invalid WebSocket upgrade request
# 这不是代码问题，也不是「沙箱不支持测试」。放行回环并清掉代理即可。
#
# 用法：
#   tool/test.sh                 # 全量
#   tool/test.sh test/xxx_test.dart
set -euo pipefail

# Flutter SDK（按本机安装位置覆盖）
FLUTTER_BIN="${FLUTTER_BIN:-/c/tools/flutter/bin}"
if [ -d "$FLUTTER_BIN" ]; then
  export PATH="$PATH:$FLUTTER_BIN"
fi

# 关键：回环不走代理
export NO_PROXY="localhost,127.0.0.1,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

exec flutter test "$@"
