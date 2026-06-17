#!/usr/bin/env bash
# MeetScribe をビルドして ~/Applications に配置・再起動する開発用スクリプト。
# ソースを編集したあと、これ一発で最新版が起動する。
#
# 使い方:
#   ./deploy.sh           # release ビルドして配置・起動
#   ./deploy.sh debug     # debug ビルド
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="MeetScribe"

echo "==> ビルド"
./build.sh "${1:-release}" >/dev/null

echo "==> 既存プロセスを停止"
pkill -f "$APP_NAME" 2>/dev/null || true
sleep 1

echo "==> ~/Applications へ配置"
rm -rf "$HOME/Applications/$APP_NAME.app"
cp -R "dist/$APP_NAME.app" "$HOME/Applications/"
xattr -cr "$HOME/Applications/$APP_NAME.app"

echo "==> 起動"
open "$HOME/Applications/$APP_NAME.app"
sleep 1.5
if pgrep -f "$APP_NAME" >/dev/null; then
    echo "✅ 最新版を起動しました (PID: $(pgrep -f "$APP_NAME" | head -1))"
else
    echo "⚠️ 起動を確認できませんでした"
fi
