#!/usr/bin/env bash
# MeetScribe v2 用の自己署名コード署名証明書をセットアップ
# 一度だけ実行すれば、以降のリビルドでTCC権限が安定する
set -euo pipefail

CERT_NAME="MeetScribe Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK_DIR="$(mktemp -d)"
trap "rm -rf $WORK_DIR" EXIT

# 既存のidentityチェック
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✅ 既に '$CERT_NAME' identity が有効です"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

# 古い証明書があれば削除（秘密鍵紐付け失敗等の残骸）
echo "==> Cleaning up stale entries"
security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" 2>/dev/null || true

echo "==> Generating fresh self-signed certificate"
cd "$WORK_DIR"

cat > openssl.cnf << 'CONF'
[req]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_req

[req_distinguished_name]
CN = MeetScribe Dev

[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CONF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 3650 -nodes -config openssl.cnf 2>/dev/null

openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 \
    -name "$CERT_NAME" -passout pass:changeit -legacy

echo "==> Importing identity to login keychain"
security import identity.p12 -k "$KEYCHAIN" \
    -P changeit \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -A 2>&1 | tail -3

echo ""
echo "==> Partition list を設定します"
echo "macOS のログインパスワードを入力してください (codesign がキーチェーンにアクセスするため):"
read -rs LOGIN_PASSWORD
echo

security set-key-partition-list -S "apple-tool:,apple:,codesign:" \
    -s -k "$LOGIN_PASSWORD" "$KEYCHAIN" 2>&1 | tail -3

echo ""
echo "==> Verifying"
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✅ Identity が有効です"
    security find-identity -v -p codesigning | grep "$CERT_NAME"

    # 署名テスト
    echo ""
    echo "==> Signature test"
    TEST_FILE="$WORK_DIR/test_signing"
    echo "test" > "$TEST_FILE"
    if codesign --force --sign "$CERT_NAME" "$TEST_FILE" 2>&1; then
        echo "✅ コード署名動作確認OK"
        echo ""
        echo "🎉 セットアップ完了！"
        echo "   次のビルドから自動で '$CERT_NAME' を使います"
        echo "   $ ./build.sh debug"
    else
        echo "⚠️  署名テスト失敗"
    fi
else
    echo "❌ Identity が作成されませんでした"
    echo ""
    echo "Keychain Access.app で手動で秘密鍵のアクセス制御を設定してください:"
    echo "  1. Keychain Access を開く"
    echo "  2. login keychain → 鍵 (カテゴリ) → 'MeetScribe Dev' の秘密鍵"
    echo "  3. 右クリック → 情報を見る → アクセス制御タブ"
    echo "  4. '常にアクセスを許可' に設定"
    exit 1
fi
