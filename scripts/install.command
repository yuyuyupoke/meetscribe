#!/usr/bin/env bash
# MeetScribe インストーラー
#
# DMGのルートに同梱されている MeetScribe.app を /Applications にコピーし、
# ad-hoc署名によるGatekeeperのquarantine属性を除去してから起動する。
# Finderでこのファイルをダブルクリックすると Terminal が自動起動して実行される。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="MeetScribe.app"
SRC_APP="$SCRIPT_DIR/$APP_NAME"
DEST_APP="/Applications/$APP_NAME"

echo ""
echo "==================================="
echo " MeetScribe セットアップ"
echo "==================================="
echo ""

if [[ ! -d "$SRC_APP" ]]; then
    echo "エラー: $SRC_APP が見つかりません。"
    echo "このファイルをDMGのルートに置いたまま実行してください。"
    read -n 1 -s -r -p "何かキーを押すと終了します..."
    echo ""
    exit 1
fi

if [[ -d "$DEST_APP" ]]; then
    echo "既に /Applications に MeetScribe があります。"
    read -r -p "上書きしますか？ (y/N): " ANSWER
    case "$ANSWER" in
        [yY]*) echo "→ 上書きします" ;;
        *)
            echo "→ キャンセルしました"
            read -n 1 -s -r -p "何かキーを押すと終了します..."
            echo ""
            exit 0
            ;;
    esac
    rm -rf "$DEST_APP"
fi

echo "[1/3] /Applications にコピー中..."
cp -R "$SRC_APP" "$DEST_APP"

echo "[2/3] セキュリティ属性を解除中..."
xattr -cr "$DEST_APP"

echo "[3/3] MeetScribe を起動します..."
open "$DEST_APP"

echo ""
echo "セットアップ完了！MeetScribeが起動します"
echo ""
read -n 1 -s -r -p "このウィンドウを閉じてOKです。何かキーを押すと終了します..."
echo ""
