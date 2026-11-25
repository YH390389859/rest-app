#!/bin/bash
# 把 Rest.app 打成拖拽安装的 DMG。
# 用法：tools/make-dmg.sh build/Rest.app [输出目录]
# 产出：<输出目录>/Rest-<版本>.dmg（卷里是 Rest.app + 一个指向 /Applications 的快捷方式）
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?用法: make-dmg.sh <Rest.app> [输出目录]}"
OUT_DIR="${2:-dist}"
[ -d "$APP" ] || { echo "!! 找不到 $APP"; exit 1; }

NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Contents/Info.plist" 2>/dev/null || basename "$APP" .app)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)
[ -n "$NAME" ] || NAME="Rest"

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/${NAME}-${VERSION}.dmg"

# 暂存目录做在输出目录旁边，避免跨卷复制丢 xattr / 签名
STAGE=$(mktemp -d "${OUT_DIR}/.dmg-stage.XXXXXX")
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# ditto 比 cp -R 更能保住扩展属性和资源分支，签名里的 CDHash 才不会变
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
# UDZO = zlib 压缩的只读镜像，双击挂载即可拖进「应用程序」
hdiutil create \
  -volname "$NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov -quiet \
  "$OUT"

# 顺手校验一下镜像能读
hdiutil verify -quiet "$OUT"
echo "==> DMG: $OUT ($(du -h "$OUT" | cut -f1))"
