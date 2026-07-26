# プライバシーについて

最終更新: 2026-07-26

MeetScribe（以下「本アプリ」）がデータをどう扱うかを説明します。

## 要点

- **開発者はあなたのデータを一切受け取りません。** 本アプリに開発者が運営するサーバーはありません。
- 音声とテキストは、**あなた自身が設定したAPIキー**で、あなたのMacから OpenAI または xAI へ直接送信されます。
- 議事録はあなたが指定したフォルダにのみ保存されます。
- 利用統計・クラッシュレポート・アクセス解析の類は**一切収集していません**。

## 外部に送信されるデータ

本アプリは、会議で選択したAIプロバイダー（OpenAI または xAI）に対して以下を送信します。送信はすべて、あなたがKeychainに登録したAPIキーを使い、あなたのMacから直接行われます。

| 送信されるもの | 送信先 | タイミング |
|---|---|---|
| マイクの音声 | 選択中のプロバイダー | 録音中（マイクをミュートしている間は送信しません） |
| Macが再生している音声（通話相手の声を含む） | 同上 | 録音中（システム音声をミュートしている間は送信しません） |
| 確定した文字起こしテキスト | 同上 | 整形・対訳のため、確定するたびに |
| 直近の文字起こしテキスト | 同上 | 「Catchup」要約ボタンを押したとき |
| 会議全体の文字起こし（最大6,000字） | 同上 | 「全体像」の自動更新時（録音中、定期的に） |
| 会議冒頭の文字起こし（最大3,000字） | 同上 | 録音停止時、議事録タイトルの生成のため |

送信先での取り扱い（学習利用の有無、保存期間など）は各社のポリシーに従います。

- [OpenAI のプライバシーポリシー](https://openai.com/policies/privacy-policy/)
- [xAI のプライバシーポリシー](https://x.ai/legal/privacy-policy)

## Macの中に保存されるもの

| 保存されるもの | 場所 | 削除方法 |
|---|---|---|
| 議事録（Markdown） | あなたが設定したフォルダ | Finderで削除 |
| 保存に失敗した議事録の退避先 | `~/Library/Application Support/MeetScribe/rescue/` | Finderで削除 |
| APIキー | macOSキーチェーン（サービス名 `com.meetscribe.app`） | 下記のコマンド、または「キーチェーンアクセス」アプリ |
| 動作ログ | `~/Library/Logs/MeetScribe/` | Finderで削除 |
| 設定（保存先・言語・文字サイズなど） | UserDefaults | 下記のコマンド |

**動作ログに会議の内容は記録されません。** 接続状態やエラー、処理した文字数などの動作情報のみを記録し、ファイルが5MBを超えると1世代だけ残して古いものから削除されます。

## 録音についてのお願い

会議の録音・文字起こしを行うことを参加者に伝える責任は、本アプリの利用者にあります。録音が禁止されている場面や、参加者の同意が得られない場面では使用しないでください。

## アンインストール

```bash
# アプリ本体
rm -rf "/Applications/MeetScribe.app"

# APIキー（登録しているプロバイダーの分だけ実行）
security delete-generic-password -s "com.meetscribe.app" -a "openai-api-key"
security delete-generic-password -s "com.meetscribe.app" -a "xai-api-key"

# 設定
defaults delete com.meetscribe.app

# ログと退避データ
rm -rf ~/Library/Logs/MeetScribe
rm -rf ~/Library/Application\ Support/MeetScribe
```

議事録ファイルは、あなたが指定したフォルダにそのまま残ります。必要に応じて手動で削除してください。

## お問い合わせ

不明な点は [GitHub Issues](https://github.com/yuyuyupoke/meetscribe/issues) からご連絡ください。
