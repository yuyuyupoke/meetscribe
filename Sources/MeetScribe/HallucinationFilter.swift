import Foundation

/// Whisper系モデルが環境ノイズを誤認識する定型フレーズをフィルタリング。
/// 単独completedアイテムとして出現した場合のみブロック（文脈中の使用は許可）。
enum HallucinationFilter {

    /// 既知のハルシネーションパターン。
    /// gpt-4o-transcribe (Whisper由来) が無音〜低レベルノイズに対して
    /// 出力しやすい日本語定型フレーズ。
    private static let knownPatterns: Set<String> = [
        // 挨拶・感謝系
        "ありがとうございます",
        "ありがとうございました",
        "ご視聴ありがとうございました",
        "ご覧いただきありがとうございます",
        "ご視聴ありがとうございます",
        // 相槌系
        "はい",
        "そうですね",
        "うん",
        "ええ",
        // 挨拶・締め系
        "お疲れ様でした",
        "お疲れ様です",
        "よろしくお願いします",
        "よろしくお願いいたします",
        // その他頻出
        "おはようございます",
        "こんにちは",
        "こんばんは",
        "失礼します",
        "以上です",
    ]

    /// 句読点・記号のみで構成されるテキストにマッチ。
    private static let punctuationOnlyPattern = try! NSRegularExpression(
        pattern: #"^[\s。、．，！？!?,.\-…・　]+$"#
    )

    /// 同一フレーズ (1〜50文字) が4回以上連続するパターン。
    /// Whisper系は無音・低SNR区間で「十十一二十十二…」「Information Technology,
    /// Information Technology, …」のような周期反復を生成する。
    private static let repetitionPattern = try! NSRegularExpression(
        pattern: #"(.{1,50}?)\1{3,}"#,
        options: [.dotMatchesLineSeparators]
    )

    /// 反復部分がテキスト全体に占める割合の下限。実発話に混ざる強調反復
    /// (「いやいやいやいや、それは違う」等) を誤って落とさないための境界。
    private static let repetitionCoverageThreshold = 0.6

    /// 反復判定を行う最小テキスト長 (UTF-16単位)。2文字フレーズ×4回=8文字から。
    private static let repetitionMinLength = 8

    /// テキストがハルシネーション定型文に該当するか判定する。
    ///
    /// - Parameter text: completedイベントの文字起こしテキスト
    /// - Returns: フィルター（破棄）すべきなら `true`
    static func shouldFilter(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty { return true }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if punctuationOnlyPattern.firstMatch(in: trimmed, range: range) != nil {
            return true
        }

        if knownPatterns.contains(trimmed) { return true }

        return isRepetitionHallucination(trimmed)
    }

    /// フレーズ反復ハルシネーションかを判定する。
    /// 空白ゆらぎで周期がずれないよう空白を除去してから、反復マッチの合計長が
    /// 全体の `repetitionCoverageThreshold` 以上を占める場合にハルシネーションとみなす。
    static func isRepetitionHallucination(_ text: String) -> Bool {
        let normalized = String(text.filter { !$0.isWhitespace })
        let ns = normalized as NSString
        guard ns.length >= repetitionMinLength else { return false }

        let range = NSRange(location: 0, length: ns.length)
        let matches = repetitionPattern.matches(in: normalized, range: range)
        guard !matches.isEmpty else { return false }

        let repeatedLength = matches.reduce(0) { $0 + $1.range.length }
        return Double(repeatedLength) >= Double(ns.length) * repetitionCoverageThreshold
    }
}
