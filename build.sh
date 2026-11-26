#!/bin/bash
# 编译并打包成可双击运行的 Rest.app
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
INSTALL=0
MAKE_DMG=0
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --install)     INSTALL=1 ;;
    --dmg)         MAKE_DMG=1 ;;
    *) echo "!! 未知参数: $arg"; exit 1 ;;
  esac
done

# UNIVERSAL=1 时编出 arm64 + x86_64 的通用二进制（CI 里用；本机构建不必加，慢一倍）
ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "==> 通用二进制（arm64 + x86_64）"
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product Rest --disable-sandbox ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN=$(swift build -c "$CONFIG" --show-bin-path --disable-sandbox ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})/Rest
APP="build/Rest.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rest"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# VERSION=v1.2.3 时把版本号写进 Info.plist（CI 打 tag 用）
if [ -n "${VERSION:-}" ]; then
  PLAIN="${VERSION#v}"
  echo "==> 版本号 $PLAIN"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PLAIN" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PLAIN" "$APP/Contents/Info.plist"
fi

# 图标：缺了就现场生成（生成脚本只依赖系统框架）
if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> 生成 AppIcon.icns"
  swiftc -O tools/make-icon.swift -o /tmp/rest-make-icon
  /tmp/rest-make-icon Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- 代码签名 ---
# 有固定证书就用它签：TCC 按「bundle id + 证书指纹」记授权，重装/升级都不掉权限。
# 没有证书才退回 ad-hoc——那样每次重新编译 cdhash 都变，授权会反复失效。
LOCAL_KEYCHAIN="$HOME/Library/Keychains/rest-signing.keychain-db"
SIGN_ID="${CODESIGN_IDENTITY:-}"
SIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-}"

if [ -z "$SIGN_ID" ] && [ -f "$LOCAL_KEYCHAIN" ] \
  && security find-identity -p codesigning "$LOCAL_KEYCHAIN" 2>/dev/null | grep -q "Rest Self Signed"; then
  # 本地：证书在我们的独立钥匙串里，必须显式 --keychain，否则会去登录钥匙串里找不到/被拦
  SIGN_ID="Rest Self Signed"
  SIGN_KEYCHAIN="$LOCAL_KEYCHAIN"
fi
if [ -z "$SIGN_ID" ] \
  && security find-identity -p codesigning 2>/dev/null | grep -q "Rest Self Signed"; then
  # CI：临时钥匙串已经加进搜索列表，不用指定路径
  SIGN_ID="Rest Self Signed"
fi

sign_app() {
  local target="$1"
  local kc_args=()
  if [ -n "$SIGN_KEYCHAIN" ]; then
    kc_args=(--keychain "$SIGN_KEYCHAIN")
  fi
  if [ -n "$SIGN_ID" ]; then
    # 不要加 --options runtime：hardened runtime 会禁止 App 发 Apple Event，
    # 而暂停播放正是靠 osascript 发出去的。runtime 只有公证才需要。
    if codesign --force --identifier com.yanghui.rest \
      --sign "$SIGN_ID" ${kc_args[@]+"${kc_args[@]}"} "$target" 2>/dev/null; then
      return 0
    fi
    echo "!! 用「$SIGN_ID」签名失败，退回 ad-hoc"
    SIGN_ID=""
  fi
  codesign --force --sign - --identifier com.yanghui.rest "$target" >/dev/null 2>&1 || \
    echo "!! codesign 失败（可忽略，仅影响权限记忆）"
}

if [ -n "$SIGN_ID" ]; then
  echo "==> 签名身份: $SIGN_ID"
else
  echo "==> 签名身份: ad-hoc（跑 tools/make-signing-cert.sh 可换成固定证书）"
fi
sign_app "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature)" | sed 's/^/    /' || true

echo "==> 完成: $APP"

# 可选：./build.sh release --dmg
# 打包成 dist/Rest-<版本>.dmg，双击挂载后把 Rest 拖进「应用程序」
if [ "$MAKE_DMG" = "1" ]; then
  bash tools/make-dmg.sh "$APP" dist
fi

# 可选：./build.sh release --install
# 装到「应用程序」再运行。TCC 的辅助功能授权是按路径 + 签名记的，从 build/ 直接跑
# 每次重新编译都会失效，装到固定位置后只需要重新勾选，不会再多出一条「Rest」。
if [ "$INSTALL" = "1" ]; then
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
  # ditto 比 cp -R 更能保住 xattr，签名不会因为复制而损坏
  ditto "$APP" "$DEST"
  sign_app "$DEST"
  open "$DEST"
  echo "==> 已启动 $DEST"
fi
