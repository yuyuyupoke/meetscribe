import Foundation

/// logprobs（対数確率）に基づいて文字起こし結果の信頼度を評価し、
/// 低信頼度の結果をフィルタリングする。
/// OpenAI Realtime API の completed イベントに含まれる logprobs を解析し、
/// ノイズ由来の誤認識（ハルシネーション）を事後的に除去する。
enum TranscriptionConfidenceFilter {

    struct LogprobEntry: Sendable {
        let token: String
        let logprob: Double
    }

    // MARK: - Parse

    static func parseLogprobs(from jsonArray: [[String: Any]]) -> [LogprobEntry] {
        jsonArray.compactMap { dict in
            guard let token = dict["token"] as? String,
                  let logprob = dict["logprob"] as? Double,
                  logprob.isFinite else { return nil }
            return LogprobEntry(token: token, logprob: logprob)
        }
    }

    // MARK: - Metrics

    static func averageLogprob(_ entries: [LogprobEntry]) -> Double {
        guard !entries.isEmpty else { return 0.0 }
        let sum = entries.reduce(0.0) { $0 + $1.logprob }
        return sum / Double(entries.count)
    }

    // MARK: - Filter

    /// logprobs に基づいてフィルタリングすべきかを判定する。
    /// - `logprobs` が空ならフィルターしない（データなし → 通す）
    /// - 平均 logprob が `threshold` 以下なら true（低信頼 → フィルター）
    /// - トークン数が 1 以下かつ logprob < -0.5 なら true（極短+低信頼）
    static func shouldFilter(
        logprobs: [LogprobEntry],
        threshold: Double = -1.0
    ) -> Bool {
        guard !logprobs.isEmpty else { return false }

        if logprobs.count <= 1 {
            let lp = logprobs[0].logprob
            return lp < -0.5
        }

        return averageLogprob(logprobs) <= threshold
    }

    /// completed イベントの JSON オブジェクトから直接判定する。
    /// `obj["logprobs"]` が `[[String: Any]]` として取得できなければフィルターしない。
    static func shouldFilter(
        from obj: [String: Any],
        threshold: Double = -1.0
    ) -> Bool {
        guard let rawLogprobs = obj["logprobs"] as? [[String: Any]] else {
            return false
        }
        let entries = parseLogprobs(from: rawLogprobs)
        return shouldFilter(logprobs: entries, threshold: threshold)
    }
}
