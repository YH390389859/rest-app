#!/bin/bash
# 编译并打包成可双击运行的 Rest.app
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product Rest --disable-sandbox

BIN=$(swift build -c "$CONFIG" --show-bin-path --disable-sandbox)/Rest
APP="build/Rest.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rest"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 本地自签名，确保 TCC（辅助功能/自动化）能稳定记住授权
codesign --force --sign - --identifier com.yanghui.rest "$APP" >/dev/null 2>&1 || \
  echo "!! codesign 失败（可忽略，仅影响权限记忆）"

echo "==> 完成: $APP"
