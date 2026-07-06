# トラブルシューティング

## アプリを開けません — 開発元が未確認

アドホック署名により初回起動時に Gatekeeper が作動する。DMG内の `install.command` をダブルクリックすれば自動で解消するが、それでも開けない場合は手動で以下を実行する。

```bash
xattr -cr "/Applications/MeetScribe.app"
```

その後、アプリを右クリックして **開く** を選択。

## "The Realtime Beta API is no longer supported" エラーが出る

OpenAI Realtime API Beta エンドポイントは廃止済み。最新リリースに更新せよ。

## "claude CLI not found" エラーが出る

会議タイトルの自動生成には Claude Code が `$PATH` 上で利用可能な状態でインストールされている必要がある（無くてもクラッシュせず、タイムスタンプ名で保存される）。

```bash
which claude
```

インストール: [docs.claude.com/en/docs/claude-code/quickstart](https://docs.claude.com/en/docs/claude-code/quickstart)

## VU メーターは動くが文字起こしされない

クォータ枯渇、またはサーバー側 VAD により無音と判定されている可能性がある。

- 使用量を確認: [platform.openai.com/usage](https://platform.openai.com/usage)
- もう少し大きな声で話す、またはマイクに近づく
- システム設定 → サウンドで入力デバイスを確認

## マイクが相手側の音声を拾う（二重ラベルのトランスクリプト）

Voice Processing で抑制されるはずだが、一部の Bluetooth ヘッドセットではエコー経路が長すぎて回避できない場合がある。

- 可能であれば有線ヘッドホンを使用する
- 出力音量を下げる。AEC は中程度の音量で最も効果的に動作する

## 証明書セットアップで openssl の -legacy 関連エラーが出る

`-legacy` は OpenSSL 3.x のオプションで、LibreSSL（macOS 標準）や OpenSSL 1.x には存在しない。

- `scripts/setup-signing.sh` は `openssl pkcs12 -help` の出力を見て対応時のみ `-legacy` を付与するため、通常は再実行するだけで解消する
- それでも失敗する場合は `openssl version` を確認し、`brew install openssl@3` で OpenSSL 3.x を導入、`PATH` を通してから再実行する

## 全設定をリセットする

```bash
defaults delete com.meetscribe.app
launchctl bootout "gui/$(id -u)/com.meetscribe.agent" 2>/dev/null
```

アプリを再起動し、API キーとフォルダを再入力する。
