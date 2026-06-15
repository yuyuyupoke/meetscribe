import Foundation

/// 会議の文字起こしから短いタイトルを自動生成する。
/// claude -p --model sonnet で15文字以内のタイトルを取得する。
enum MeetingTitleGenerator {
    /// 生成する。失敗したらタイムスタンプベースのフォールバックを返す。
    static func generate(from transcript: String) async -> String {
        // 空 or 短すぎる場合はフォールバック
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else {
            return fallbackTitle()
        }

        let prompt = buildPrompt(transcript: trimmed)
        do {
            let client = try ClaudeQAClient()
            let raw = try await client.invokeRaw(prompt: prompt, model: .sonnet)
            let title = cleanUp(raw)
            return title.isEmpty ? fallbackTitle() : title
        } catch {
            DebugLog.log("[title] generation failed: \(error.localizedDescription)")
            return fallbackTitle()
        }
    }

    // MARK: -

    private static func buildPrompt(transcript: String) -> String {
        """
        以下は会議のリアルタイム文字起こしです。
        この会議にふさわしい簡潔なタイトルを日本語で1つだけ出力してください。

        ルール:
        - 全角で15文字以内
        - 会議の主題を表す名詞句
        - 余分な説明、句読点、引用符は付けない
        - タイトルの文字列だけを返す (改行なし)

        <transcript>
        \(transcript.prefix(3000))
        </transcript>
        """
    }

    private static func cleanUp(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "「", with: "")
            .replacingOccurrences(of: "」", with: "")
            .replacingOccurrences(of: "『", with: "")
            .replacingOccurrences(of: "』", with: "")
        // 先頭に「タイトル:」などが付いたら削除
        var result = trimmed
        for prefix in ["タイトル:", "タイトル：", "会議タイトル:", "会議タイトル：", "# "] {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return String(result.prefix(30))
    }

    private static func fallbackTitle() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH-mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        return "会議_\(df.string(from: Date()))"
    }
}
