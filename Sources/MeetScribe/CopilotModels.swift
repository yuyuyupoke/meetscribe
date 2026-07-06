import Foundation

/// Catchup要約の1カード分。右カラムに新しい順で表示され、議事録にも保存される。
struct CatchupCard: Identifiable, Equatable, Sendable {
    let id: UUID
    /// 対象期間の表示ラベル (例: "14:03〜14:06")
    let periodLabel: String
    /// 対象の分数 (1/3/5/10)
    let minutes: Int
    /// 要約本文 (日本語)。エラー時はエラーメッセージ
    var text: String
    var isError: Bool
    /// 対象期間に発話が無かった (要約は生成していない)。UI には出すが議事録には残さない
    var isNoSpeech: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        periodLabel: String,
        minutes: Int,
        text: String,
        isError: Bool = false,
        isNoSpeech: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.periodLabel = periodLabel
        self.minutes = minutes
        self.text = text
        self.isError = isError
        self.isNoSpeech = isNoSpeech
        self.createdAt = createdAt
    }
}

/// AIが傍聴して自動更新する「会議の全体像」。
struct MeetingOverview: Equatable, Sendable {
    /// この会議/講義の目的 (1文)
    var purpose: String
    /// 議題・トピックの一覧
    var agenda: [String]
    /// 今まさに話していること (1文)
    var currentTopic: String

    /// LLM の JSON 応答からパースする。形式不正なら nil。
    /// 期待スキーマ: {"purpose": "...", "agenda": ["...", ...], "current_topic": "..."}
    static func parse(_ jsonText: String) -> MeetingOverview? {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let purpose = obj["purpose"] as? String,
              let currentTopic = obj["current_topic"] as? String else {
            return nil
        }
        let agenda = (obj["agenda"] as? [String]) ?? []
        let trimmedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPurpose.isEmpty else { return nil }
        return MeetingOverview(
            purpose: trimmedPurpose,
            agenda: agenda.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            currentTopic: currentTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
