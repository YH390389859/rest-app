#!/bin/bash
# 生成一张长期有效的自签名代码签名证书，用来签 Rest.app。
#
# 为什么需要这一步：
#   ad-hoc 签名（codesign -s -）没有身份，TCC 只能按 cdhash 记住授权。
#   每次重新编译 cdhash 都变，于是「辅助功能 / 自动化」授权反复失效，
#   列表里还会堆出一串「Rest 23-30-19-781」这种带时间戳的条目。
#   换成固定证书后，TCC 按「bundle id + 证书指纹」识别，重装 / 升级都不掉权限。
#
# 为什么用独立钥匙串：
#   证书导进登录钥匙串后，codesign 每次要私钥都会被访问控制拦一下（弹窗），
#   脚本和 CI 都会卡死。单独建一个钥匙串、显式 --keychain 指过去，
#   再用 set-key-partition-list 放行 codesign，就能完全静默签名。
#
# 用法：
#   tools/make-signing-cert.sh           # 生成证书 + 独立钥匙串（幂等）
#   tools/make-signing-cert.sh --force   # 已存在也重新生成
#
# 产出：
#   ~/Library/Keychains/rest-signing.keychain-db   本地签名用的钥匙串
#   certs/rest-signing.p12                         私钥 + 证书，存进 GitHub secret
#   证书名：Rest Self Signed（build.sh 和 CI 都按这个名字找身份）

set -euo pipefail
cd "$(dirname "$0")/.."

CN="Rest Self Signed"
DAYS="${DAYS:-3650}" # 10 年
# 本地便利密码：保护的东西就是 certs/ 里那份 p12（同一把私钥），不是额外的秘密
SIGN_PASS="${SIGN_PASS:-rest-signing}"
OUT_DIR="certs"
OUT_P12="$OUT_DIR/rest-signing.p12"
KEYCHAIN="$HOME/Library/Keychains/rest-signing.keychain-db"

if [ "${1:-}" != "--force" ] && [ -f "$KEYCHAIN" ] \
  && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CN"; then
  echo "==> 签名身份已就绪：$CN"
  security find-certificate -c "$CN" -p "$KEYCHAIN" | openssl x509 -noout -subject -dates | sed 's/^/    /'
  [ -f "$OUT_P12" ] || echo "    !! certs/rest-signing.p12 不见了，要重新导出请加 --force"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"

# codeSigning 的 EKU 必须带，否则 codesign 认不出这是签名身份
cat > "$WORK/openssl.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = ext

[dn]
CN = Rest Self Signed
O  = Rest
C  = CN

[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> 生成自签名证书（有效期 $DAYS 天）"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days "$DAYS" \
  -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

echo "==> 导出 certs/rest-signing.p12"
rm -f "$OUT_P12"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$CN" -out "$OUT_P12" -passout "pass:$SIGN_PASS" 2>/dev/null
chmod 600 "$OUT_P12"

echo "==> 建独立钥匙串 $KEYCHAIN"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
rm -f "$KEYCHAIN"
security create-keychain -p "$SIGN_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN" # 不自动上锁，省掉每次解锁
security unlock-keychain -p "$SIGN_PASS" "$KEYCHAIN"
security import "$OUT_P12" -k "$KEYCHAIN" -P "$SIGN_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# 关键：不加这条，codesign 取私钥会弹「是否允许」
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$SIGN_PASS" "$KEYCHAIN" >/dev/null

# 自检：真拿这张证书签一个空壳二进制，确认全程无弹窗
printf 'int main(void){return 0;}\n' > "$WORK/t.c"
clang -o "$WORK/t" "$WORK/t.c"
echo "==> 自检签名"
if perl -e 'alarm 25; exec @ARGV' codesign --force --keychain "$KEYCHAIN" --sign "$CN" "$WORK/t" 2>"$WORK/err"; then
  codesign -dv --verbose=2 "$WORK/t" 2>&1 | grep -E "^(Identifier|Authority)" | sed 's/^/    /'
  echo "    ✅ 无需人工授权"
else
  echo "    ⚠️ 自检失败："
  sed 's/^/       /' "$WORK/err"
fi

cat <<EOF

==> 完成。接下来：

  1) 本机构建会自动用这张证书（build.sh 会找到 rest-signing.keychain-db）：
       ./build.sh release --install

  2) 让 GitHub Actions 也用它签名，把 p12 存成两个 secret：
       base64 -i $OUT_P12 | pbcopy          → secret 名：SIGNING_P12
       secret 名：SIGNING_P12_PASS = $SIGN_PASS

  3) 私钥只在这台机器和仓库 secret 里，certs/ 已被 .gitignore 忽略。
     证书到期：$(date -v+${DAYS}d +%Y-%m-%d 2>/dev/null || echo "$DAYS 天后")
EOF
