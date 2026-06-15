# セキュリティポリシー

## 脆弱性の報告

セキュリティ脆弱性は、公開Issueではなく GitHub の
[private vulnerability reporting](https://github.com/yuyuyupoke/clawd-listen/security/advisories/new)
を通じて報告してください。

72時間以内に初回応答します。修正リリースまでは公開を控えてください。

## 注意事項

- OpenAI API キーは macOS Keychain (`com.clawdlisten.app` サービス) に保存されます。
- 文字起こし用の音声は OpenAI Realtime API に送信されます。組織の承認なしに機密会議で使用しないでください。
- Q&A クエリは Claude Code CLI サブプロセス経由でローカル実行されます。
