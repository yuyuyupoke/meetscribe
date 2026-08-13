import Foundation

/// ヘッダーに出す「録音の開始時刻」と「経過時間」の文字列化。
///
/// View から切り離した純関数にしてあるのは、日付をまたぐ・1時間を超える・
/// 時刻がずれるといった境界をテストで固定するため (実機の時計を待てない)。
enum SessionClockFormatter {
    /// 待機中に出すプレースホルダ。録音の有無でヘッダーの高さが変わらないよう、
    /// 非録音時も同じ桁数の文字列を出す。
    static let idleElapsed = "--:--"
    static let idleStartTime = "--:--:--"

    /// 経過時間。`MM:SS` 形式で、60分を超えたら分が3桁になる (例: `75:04`)。
    /// 時:分:秒にしないのは、講義1コマの長さを一目で比べたいから
    /// (「62分」より「62:10」の方が直感的で、キャップ180分との距離も分かる)。
    static func elapsed(from startedAt: Date, to now: Date) -> String {
        // 時計の巻き戻し (NTP補正・スリープ復帰) で負にならないよう下限0で丸める
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }

    /// 開始時刻。`HH:MM:SS` の24時間表記。
    /// ロケール依存の午前/午後表記を避けるため `en_US_POSIX` で固定する
    /// (議事録の `startedAt` と読み比べたときにズレて見えないように)。
    static func startTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
