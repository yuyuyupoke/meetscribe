# トラブルシューティング

## アプリを開けません — 開発元が未確認

アドホック署名により初回起動時に Gatekeeper が作動する。

```bash
xattr -cr "/Applications/Clawd Listen.app"
```

その後、アプリを右クリックして **開く** を選択。

## "The Realtime Beta API is no longer supported" エラーが出る

OpenAI Realtime API Beta エンドポイントは廃止済み。最新リリースに更新せよ。

## "claude CLI not found" エラーが出る

Q&A 機能には Claude Code が `$PATH` 上で利用可能な状態でインストールされている必要がある。

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

## 全設定をリセットする

```bash
defaults delete com.clawdlisten.app
launchctl bootout "gui/$(id -u)/com.clawdlisten.agent" 2>/dev/null
```

アプリを再起動し、API キーとフォルダを再入力する。
