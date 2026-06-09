#!/usr/bin/env bash
# Clawd Listen v2 - Build script
# Swift PackageをビルドしてmacOS .appバンドルにパッケージングする
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
APP_NAME="Clawd Listen"
BUNDLE_ID="com.clawdlisten.app"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$PROJECT_DIR/dist/${APP_NAME}.app"
CONFIG="${1:-release}"

echo "==> Cleaning previous build output"
rm -rf "$PROJECT_DIR/dist"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "==> Building Swift package ($CONFIG)"
swift build -c "$CONFIG" --arch arm64

BINARY="$BUILD_DIR/arm64-apple-macosx/$CONFIG/ClawdListen"
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Assembling .app bundle at $APP_DIR"
cp "$BINARY" "$APP_DIR/Contents/MacOS/ClawdListen"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

shopt -s nullglob
for resource in "$PROJECT_DIR/Resources/"*; do
    name="$(basename "$resource")"
    if [[ "$name" == "Info.plist" ]]; then
        continue
    fi
    cp -R "$resource" "$APP_DIR/Contents/Resources/$name"
    echo "    resource: $name copied"
done
shopt -u nullglob

echo "==> Signing"
ENTITLEMENTS="$PROJECT_DIR/Resources/ClawdListen.entitlements"
# 自己署名証明書 (Clawd Listen Dev) があればそのSHA1で署名。
# find-identity ではなく find-certificate で探す (自己署名は codesigning policy で
# valid として出てこないが、SHA1 指定なら codesign は使える)。
SIGN_ID="-"
CERT_SHA1=$(security find-certificate -c "Clawd Listen Dev" -Z login.keychain 2>/dev/null \
    | awk '/SHA-1 hash:/ {print $3}' | head -1)
if [[ -n "$CERT_SHA1" ]]; then
    # 実際に codesign で使えるか試してから採用する
    TEST_FILE=$(mktemp)
    echo "test" > "$TEST_FILE"
    if codesign --force --sign "$CERT_SHA1" "$TEST_FILE" >/dev/null 2>&1; then
        SIGN_ID="$CERT_SHA1"
        echo "    using self-signed 'Clawd Listen Dev' ($CERT_SHA1)"
    else
        echo "    cert found but codesign failed; falling back to ad-hoc"
        echo "    (scripts/setup-signing.sh を再実行してください)"
    fi
    rm -f "$TEST_FILE"
else
    echo "    using ad-hoc (TCC不安定; scripts/setup-signing.sh 実行推奨)"
fi
codesign --force --deep --sign "$SIGN_ID" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_DIR"

echo ""
echo "✅ Build complete"
echo "   $APP_DIR"
echo ""
echo "起動: open \"$APP_DIR\""
