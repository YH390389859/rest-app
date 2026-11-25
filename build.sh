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

# 可选：./build.sh release --install
# 装到「应用程序」再运行。TCC 的辅助功能授权是按路径 + 签名记的，从 build/ 直接跑
# 每次重新编译都会失效，装到固定位置后只需要重新勾选，不会再多出一条「Rest」。
if [ "${2:-}" = "--install" ]; then
  DEST="/Applications/Rest.app"
  echo "==> 安装到 $DEST"
  osascript -e 'tell application "Rest" to quit' >/dev/null 2>&1 || true
  pkill -x Rest >/dev/null 2>&1 || true
  sleep 0.5
  # 只覆盖确认是同一个应用的目标，避免误删同名目录
  if [ -d "$DEST" ]; then
    BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || echo "")
    if [ "$BID" = "com.yanghui.rest" ]; then
      rm -rf "$DEST"
    else
      echo "!! $DEST 已存在且不是 com.yanghui.rest，停止安装"; exit 1
    fi
  fi
  cp -R "$APP" "$DEST"
  codesign --force --sign - --identifier com.yanghui.rest "$DEST" >/dev/null 2>&1 || true
  open "$DEST"
  echo "==> 已启动 $DEST"
fi
