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

# 图标：缺了就现场生成（生成脚本只依赖系统框架）
if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> 生成 AppIcon.icns"
  swiftc -O tools/make-icon.swift -o /tmp/rest-make-icon
  /tmp/rest-make-icon Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# 本地自签名，确保 TCC（辅助功能/自动化）能稳定记住授权
codesign --force --sign - --identifier com.yanghui.rest "$APP" >/dev/null 2>&1 || \
  echo "!! codesign 失败（可忽略，仅影响权限记忆）"

echo "==> 完成: $APP"
