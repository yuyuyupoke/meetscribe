#!/usr/bin/env bash
# MeetScribe 配布パッケージ作成スクリプト
#
# 使い方:
#   ./distribute.sh 1.0.0
#
# 出力 (dist/ 配下):
#   - MeetScribe-<VERSION>.dmg   ハードリンク含むDMG (推奨配布形式)
#   - MeetScribe-<VERSION>.zip   ditto -c -k で署名属性保持
#   - SHA256SUMS.txt               チェックサム
#
# 次のステップ:
#   gh release create v<VERSION> dist/MeetScribe-<VERSION>.dmg dist/MeetScribe-<VERSION>.zip dist/SHA256SUMS.txt
set -euo pipefail

VERSION="${1:?Usage: ./distribute.sh <version>  (例: ./distribute.sh 1.0.0)}"

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
APP_NAME="MeetScribe"
APP_DIR="$PROJECT_DIR/dist/${APP_NAME}.app"
ARTIFACTS_DIR="$PROJECT_DIR/dist"

echo "==> [1/5] release ビルド"
./build.sh release >/dev/null
if [[ ! -d "$APP_DIR" ]]; then
    echo "ERROR: $APP_DIR が生成されませんでした" >&2
    exit 1
fi

echo "==> [2/5] 署名の整合性を検証"
codesign --verify --deep --strict "$APP_DIR" || {
    echo "ERROR: 署名検証に失敗しました。setup-signing.sh を実行してください" >&2
    exit 1
}

# ad-hoc 署名のまま配布すると、環境によっては「壊れているため開けません」になり
# ユーザー側に復旧手段がない。build.sh は証明書が無いと黙って ad-hoc に落ちるため、
# 配布物を作る前にここで止める。
if codesign -dvv "$APP_DIR" 2>&1 | grep -q "Signature=adhoc"; then
    echo "ERROR: ad-hoc 署名のままです。./scripts/setup-signing.sh を実行してから再ビルドしてください" >&2
    exit 1
fi

# 配布物にデバッガアタッチ許可が残っていないことを確認する
# (メモリ上の API キーや会議音声を他プロセスから読めてしまう)
if codesign -d --entitlements - "$APP_DIR" 2>/dev/null | grep -q "get-task-allow"; then
    echo "ERROR: get-task-allow entitlement が残っています。Resources/MeetScribe.entitlements を確認してください" >&2
    exit 1
fi

echo "==> [3/5] DMG 作成 (Applications へドラッグする標準レイアウト)"
# install.command による xattr 剥がしは廃止した。
# DMG 経由で配布されるとスクリプト自体も quarantine を継承してブロックされるうえ、
# macOS 15 以降は Ctrl+クリックでの Gatekeeper 回避も廃止されている。
# 初回起動の許可手順は README に記載する。
DMG_PATH="$ARTIFACTS_DIR/MeetScribe-$VERSION.dmg"
rm -f "$DMG_PATH"
DMG_STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT
cp -R "$APP_DIR" "$DMG_STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
echo "    → $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

echo "==> [4/5] ZIP 作成 (ditto で署名属性を保持)"
ZIP_PATH="$ARTIFACTS_DIR/MeetScribe-$VERSION.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
echo "    → $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"

echo "==> [5/5] SHA256 チェックサム"
SUMS_PATH="$ARTIFACTS_DIR/SHA256SUMS.txt"
(cd "$ARTIFACTS_DIR" && shasum -a 256 "MeetScribe-$VERSION.dmg" "MeetScribe-$VERSION.zip") > "$SUMS_PATH"
cat "$SUMS_PATH"

echo ""
echo "✅ 配布パッケージ作成完了"
echo ""
echo "次のステップ (GitHub Release 作成):"
echo "  gh release create v$VERSION \\"
echo "    --title \"MeetScribe $VERSION\" \\"
echo "    --notes-file CHANGELOG.md \\"
echo "    \"$DMG_PATH\" \\"
echo "    \"$ZIP_PATH\" \\"
echo "    \"$SUMS_PATH\""
