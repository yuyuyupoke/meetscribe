import Foundation

/// 質問送信 → Claude 応答ストリーミング → TranscriptStore 更新までを束ねるコントローラ。
/// UI からは `ask(question:)` を呼ぶだけで完結する。
@MainActor
final class QAController {
    static let shared = QAController()

    private var client: ClaudeQAClient?

    private init() {}

    /// 質問を送信。会議は停止せず継続したまま Claude に問い合わせる。
    func ask(question: String) async {
        // クライアントは起動時に lazy 初期化 (claude CLI 無しなら UI にエラー表示)
        do {
            if client == nil {
                client = try ClaudeQAClient()
            }
        } catch {
            AppState.shared.lastError = "Claude CLI 未検出: \(error.localizedDescription)"
            return
        }
        guard let client = client else { return }

        // ユーザー質問を履歴に追加
        TranscriptStore.shared.addUserQuery(question)
        let answerId = TranscriptStore.shared.startClaudeAnswer()

        AppState.shared.isAsking = true
        AppState.shared.lastError = nil
        let transcript = TranscriptStore.shared.meetingTranscriptText
        let model = AppState.shared.selectedModel
        let knowledgeFolderPath = AppState.shared.knowledgeFolderURL?.path

        defer { AppState.shared.isAsking = false }

        do {
            _ = try await client.ask(
                transcript: transcript,
                question: question,
                model: model,
                knowledgeFolderPath: knowledgeFolderPath
            ) { chunk in
                Task { @MainActor in
                    TranscriptStore.shared.appendToAnswer(itemId: answerId, chunk: chunk)
                }
            }
            TranscriptStore.shared.finalizeAnswer(itemId: answerId)
        } catch {
            TranscriptStore.shared.appendToAnswer(
                itemId: answerId,
                chunk: "\n[エラー] \(error.localizedDescription)"
            )
            TranscriptStore.shared.finalizeAnswer(itemId: answerId)
            AppState.shared.lastError = "Claude 応答失敗: \(error.localizedDescription)"
        }
    }
}
