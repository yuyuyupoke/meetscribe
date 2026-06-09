#!/usr/bin/env bash
# Clawd Listen 配布パッケージ作成スクリプト
#
# 使い方:
#   ./distribute.sh 1.0.0
#
# 出力 (dist/ 配下):
#   - Clawd-Listen-<VERSION>.dmg   ハードリンク含むDMG (推奨配布形式)
#   - Clawd-Listen-<VERSION>.zip   ditto -c -k で署名属性保持
#   - SHA256SUMS.txt               チェックサム
#
# 次のステップ:
#   gh release create v<VERSION> dist/Clawd-Listen-<VERSION>.dmg dist/Clawd-Listen-<VERSION>.zip dist/SHA256SUMS.txt
set -euo pipefail

VERSION="${1:?Usage: ./distribute.sh <version>  (例: ./distribute.sh 1.0.0)}"

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
APP_NAME="Clawd Listen"
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

echo "==> [3/5] DMG 作成"
DMG_PATH="$ARTIFACTS_DIR/Clawd-Listen-$VERSION.dmg"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$APP_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
echo "    → $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

echo "==> [4/5] ZIP 作成 (ditto で署名属性を保持)"
ZIP_PATH="$ARTIFACTS_DIR/Clawd-Listen-$VERSION.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
echo "    → $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"

echo "==> [5/5] SHA256 チェックサム"
SUMS_PATH="$ARTIFACTS_DIR/SHA256SUMS.txt"
(cd "$ARTIFACTS_DIR" && shasum -a 256 "Clawd-Listen-$VERSION.dmg" "Clawd-Listen-$VERSION.zip") > "$SUMS_PATH"
cat "$SUMS_PATH"

echo ""
echo "✅ 配布パッケージ作成完了"
echo ""
echo "次のステップ (GitHub Release 作成):"
echo "  gh release create v$VERSION \\"
echo "    --title \"Clawd Listen $VERSION\" \\"
echo "    --notes-file CHANGELOG.md \\"
echo "    \"$DMG_PATH\" \\"
echo "    \"$ZIP_PATH\" \\"
echo "    \"$SUMS_PATH\""
