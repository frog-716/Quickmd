#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH="$PWD/Quickmd.app"
BUNDLE_ID="com.quickmd.app"
MODE="${1:-start}"

stop_running_app() {
  if [[ -d "$APP_PATH" ]]; then
    /usr/bin/osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" \
      >/dev/null 2>&1 || true
  fi

  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! /usr/bin/pgrep -x Quickmd >/dev/null 2>&1; then
      return 0
    fi
    /bin/sleep 0.1
  done

  echo "Quickmd 还在运行，停止后再试。" >&2
  return 1
}

if [[ "$MODE" == "stop" ]]; then
  stop_running_app
  echo "Quickmd 已停止。"
  exit 0
fi

if [[ "$MODE" == "start" ]]; then
  if (( $# > 0 )); then shift; fi
elif [[ "$MODE" != --* ]]; then
  echo "用法：./dev.sh [--show-now 等调试参数] | stop" >&2
  exit 2
fi

stop_running_app
./build.sh
/usr/bin/open -n -a "$APP_PATH" --args --dev "$@"
echo "开发模式已构建并启动。改完代码后再运行 ./dev.sh 即可同步更新。"
