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

        return knownPatterns.contains(trimmed)
    }
}
