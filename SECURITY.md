# セキュリティポリシー

## 脆弱性の報告

セキュリティ脆弱性は、公開Issueではなく GitHub の
[private vulnerability reporting](https://github.com/yuyuyupoke/meetscribe/security/advisories/new)
を通じて報告してください。

72時間以内に初回応答します。修正リリースまでは公開を控えてください。

## 注意事項

- OpenAI/xAI APIキーはプロバイダー別アカウントとしてmacOS Keychain（`com.meetscribe.app`サービス）に保存されます。
- 文字起こし用の音声と整形・翻訳・Copilot用のテキストは、設定画面で選択したOpenAIまたはxAIのAPIへ送信されます。組織の承認なしに機密会議で使用しないでください。
- Q&A クエリは Claude Code CLI サブプロセス経由でローカル実行されます。
