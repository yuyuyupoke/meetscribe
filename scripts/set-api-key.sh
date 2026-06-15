#!/usr/bin/env bash
# MeetScribe 用の OpenAI API Key を Keychain にセットする
# アプリの KeychainStore.swift と同じ service/account を使う
set -euo pipefail

SERVICE="com.meetscribe.app"
ACCOUNT="openai-api-key"

if [[ $# -gt 0 ]]; then
    # 引数から取得 (シェル履歴に残るので非推奨)
    API_KEY="$1"
else
    # 対話入力 (安全)
    printf "OpenAI API Key: "
    read -rs API_KEY
    printf "\n"
fi

if [[ -z "$API_KEY" ]]; then
    echo "ERROR: empty API key" >&2
    exit 1
fi

security add-generic-password \
    -U \
    -s "$SERVICE" \
    -a "$ACCOUNT" \
    -w "$API_KEY" \
    ~/Library/Keychains/login.keychain-db

echo "✅ API Key saved to Keychain"
echo "   service: $SERVICE"
echo "   account: $ACCOUNT"
