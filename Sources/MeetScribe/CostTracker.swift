import Foundation

/// OpenAI `gpt-4o-transcribe` のトークン課金を累計するユーティリティ。
/// 料金レートは 2025 年時点のもの。
enum CostTracker {
    // USD per 1 token
    static let textInputRate: Double = 2.50 / 1_000_000   // $2.50 per 1M text input
    static let audioInputRate: Double = 6.00 / 1_000_000  // $6.00 per 1M audio input
    static let outputRate: Double = 10.00 / 1_000_000     // $10.00 per 1M output

    /// 1 transcription event の usage から USD を計算
    static func cost(
        textInputTokens: Int,
        audioInputTokens: Int,
        outputTokens: Int
    ) -> Double {
        return Double(textInputTokens) * textInputRate
            + Double(audioInputTokens) * audioInputRate
            + Double(outputTokens) * outputRate
    }

    /// JSON の usage 辞書から課金を抽出。
    /// 期待スキーマ:
    /// ```
    /// "usage": {
    ///   "input_tokens": 53,
    ///   "input_token_details": { "text_tokens": 1, "audio_tokens": 52 },
    ///   "output_tokens": 31
    /// }
    /// ```
    static func extractCost(from usage: [String: Any]) -> Double {
        let output = usage["output_tokens"] as? Int ?? 0
        let details = usage["input_token_details"] as? [String: Any]
        let text = details?["text_tokens"] as? Int ?? 0
        let audio = details?["audio_tokens"] as? Int ?? 0
        return cost(
            textInputTokens: text,
            audioInputTokens: audio,
            outputTokens: output
        )
    }
}
