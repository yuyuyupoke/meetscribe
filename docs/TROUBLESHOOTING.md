# トラブルシューティング

## アプリを開けません — 開発元が未確認

MeetScribe は Apple の Developer Program に加入していない個人開発アプリのため、公証（notarization）を受けていない。初回起動時のみ macOS がブロックする。

**macOS 15 (Sequoia) 以降**

1. 一度アプリを起動して、ブロックのダイアログを閉じる
2. **システム設定 → プライバシーとセキュリティ** を開く
3. 下にスクロールし「"MeetScribe" は開発元を確認できないため…」の横の **「このまま開く」** をクリック
4. Touch ID またはパスワードで承認する

手順3のボタンは、アプリの起動を試みてから**約1時間だけ**表示される。見当たらない場合は、もう一度アプリを起動してから設定を開き直す。

**macOS 14 (Sonoma) 以前**

`Applications` 内の MeetScribe を右クリック →「開く」でも許可できる（この方法は macOS 15 以降では使えない）。

**それでも開けない場合**

ダウンロード時に付与された検疫属性を手動で外す。

```bash
xattr -cr "/Applications/MeetScribe.app"
open "/Applications/MeetScribe.app"
```

## "The Realtime Beta API is no longer supported" エラーが出る

OpenAI Realtime API Beta エンドポイントは廃止済み。最新リリースに更新せよ。

## 議事録のタイトルが「会議_14-30」のようになる

会議タイトルの自動生成は、選択中の AI プロバイダーの API キーで行われる。API キーが未設定・無効・残高不足の場合や、生成に失敗した場合はタイムスタンプ名で保存される（クラッシュはしない）。フッターの🔑からキーの状態を確認する。

## VU メーターは動くが文字起こしされない

クォータ枯渇、またはサーバー側 VAD により無音と判定されている可能性がある。

- 使用量を確認: [platform.openai.com/usage](https://platform.openai.com/usage)
- もう少し大きな声で話す、またはマイクに近づく
- システム設定 → サウンドで入力デバイスを確認

## マイクが相手側の音声を拾う（二重ラベルのトランスクリプト）

スピーカー再生中の相手の声をマイクが拾い、`[自分]` として二重記録されるケース。

- イヤホン・ヘッドホンを使えば物理的に発生しない（推奨）
- スピーカーを使い続ける場合は `defaults write com.meetscribe.app echoCancellationEnabled -bool true`
  でエコーキャンセル（Voice Processing）を有効化できる。ただし **ON にすると Discord / Zoom 等の
  通話アプリと併用できない**（録音開始の瞬間に通話アプリ側のマイク入力が停止し、相手に声が
  届かなくなる。macOS 側の既知問題でアプリからの回避策はない）。戻すときは
  `defaults write com.meetscribe.app echoCancellationEnabled -bool false`
- 出力音量を下げる。AEC は中程度の音量で最も効果的に動作する

## 録音を開始したら通話アプリ（Discord / Zoom 等）で相手に声が届かなくなった

エコーキャンセル（上記）を手動で ON にしていると発生する。デフォルト OFF のままなら発生しない。
`defaults delete com.meetscribe.app echoCancellationEnabled` でデフォルトに戻せる。
通話アプリ側は入力デバイスを選び直す（または通話に入り直す）と復帰する。

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
