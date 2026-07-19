import Foundation

/// OpenAI 文字起こしの課金を累計するユーティリティ。
/// トークン型 usage (gpt-4o-transcribe 系) と duration 型 usage
/// (gpt-realtime-whisper) の両方に対応する。
enum CostTracker {
    // USD per 1 token (gpt-4o-transcribe 系、2025 年時点)
    static let textInputRate: Double = 2.50 / 1_000_000   // $2.50 per 1M text input
    static let audioInputRate: Double = 6.00 / 1_000_000  // $6.00 per 1M audio input
    static let outputRate: Double = 10.00 / 1_000_000     // $10.00 per 1M output

    // USD per second (gpt-realtime-whisper: $0.017/分、2026-07 時点)
    static let realtimeWhisperRatePerSecond: Double = 0.017 / 60

    // xAI Streaming STT: $0.20 / audio hour (2026-07時点)
    static let xAIStreamingRatePerSecond: Double = 0.20 / 3_600

    /// xAIへ送ったPCM16 mono byte数から推定課金を計算する。
    static func xAIStreamingCost(audioBytes: Int, sampleRate: Double) -> Double {
        guard audioBytes > 0, sampleRate > 0 else { return 0 }
        let seconds = Double(audioBytes) / (sampleRate * Double(MemoryLayout<Int16>.size))
        return seconds * xAIStreamingRatePerSecond
    }

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
    /// トークン型スキーマ:
    /// ```
    /// "usage": {
    ///   "type": "tokens",
    ///   "input_tokens": 53,
    ///   "input_token_details": { "text_tokens": 1, "audio_tokens": 52 },
    ///   "output_tokens": 31
    /// }
    /// ```
    /// duration 型スキーマ (whisper 系):
    /// ```
    /// "usage": { "type": "duration", "seconds": 4.2 }
    /// ```
    static func extractCost(from usage: [String: Any]) -> Double {
        if usage["type"] as? String == "duration" {
            let seconds = (usage["seconds"] as? Double)
                ?? (usage["seconds"] as? Int).map(Double.init)
                ?? 0
            return seconds * realtimeWhisperRatePerSecond
        }
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
