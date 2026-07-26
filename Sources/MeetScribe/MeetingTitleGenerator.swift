import Foundation

/// 会議の文字起こしから短いタイトルを自動生成する。
///
/// 会議で使用中のプロバイダー (OpenAI / xAI) のチャットモデルを使う。
/// 外部CLIには依存しないので、ユーザーが用意したAPIキーだけで完結し、
/// 送信先も文字起こし・整形と同じ1社に閉じる。
enum MeetingTitleGenerator {
    static let systemPrompt = """
        あなたは会議のタイトルを付ける専門家です。
        渡された会議の文字起こしから、ふさわしい簡潔なタイトルを日本語で1つだけ出力してください。

        ルール:
        - 全角で15文字以内
        - 会議の主題を表す名詞句
        - 余分な説明、句読点、引用符は付けない
        - タイトルの文字列だけを返す (改行なし)
        """

    /// 生成する。失敗したらタイムスタンプベースのフォールバックを返す。
    /// - Parameter apiKey: 会議で使用中のプロバイダーのAPIキー。nil ならフォールバック。
    static func generate(
        from transcript: String,
        apiKey: String?,
        provider: AIProvider
    ) async -> String {
        // 空 or 短すぎる場合はフォールバック
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else {
            return fallbackTitle()
        }
        guard let apiKey, !apiKey.isEmpty else {
            DebugLog.log("[title] no API key → fallback title")
            return fallbackTitle()
        }

        let (content, costUSD) = await OpenAIChatClient.complete(
            system: systemPrompt,
            user: String(trimmed.prefix(3000)),
            apiKey: apiKey,
            provider: provider,
            timeout: 20,
            cacheKey: PromptCacheKey.title
        )
        if costUSD > 0 {
            await MainActor.run { AppState.shared.addCost(costUSD) }
        }
        guard let content else {
            DebugLog.log("[title] generation failed → fallback title")
            return fallbackTitle()
        }
        let title = cleanUp(content)
        return title.isEmpty ? fallbackTitle() : title
    }

    // MARK: -

    /// LLM の生出力からタイトルとして使える文字列を取り出す。
    /// 指示に反して引用符・接頭辞・改行を付けてくることがあるため、必ず通す。
    static func cleanUp(_ raw: String) -> String {
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
