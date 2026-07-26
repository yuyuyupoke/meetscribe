# セキュリティポリシー

## 脆弱性の報告

セキュリティ脆弱性は、公開Issueではなく GitHub の
[private vulnerability reporting](https://github.com/yuyuyupoke/meetscribe/security/advisories/new)
を通じて報告してください。

72時間以内に初回応答します。修正リリースまでは公開を控えてください。

## 注意事項

- OpenAI/xAI APIキーはプロバイダー別アカウントとしてmacOS Keychain（`com.meetscribe.app`サービス）に保存されます。
- 音声（マイク・システム音声）と、整形・翻訳・Copilot要約・議事録タイトル生成のためのテキストは、設定画面で選択したOpenAIまたはxAIのAPIへ送信されます。組織の承認なしに機密会議で使用しないでください。
- 送信は利用者自身のAPIキーで、利用者のMacから各AIプロバイダーへ直接行われます。開発者が運営するサーバーは存在せず、開発者が会議データを受け取ることはありません。
- 動作ログ（`~/Library/Logs/MeetScribe/`）に会議の発話内容は記録しません。接続状態・エラー・処理文字数などの動作情報のみを記録します。
- 送信されるデータの詳細と削除方法は [PRIVACY.md](PRIVACY.md) を参照してください。
