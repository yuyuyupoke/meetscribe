import Foundation

/// 最大録音時間 (セッション長キャップ) の設定解決。
///
/// なぜ必要か (2026-08-11 監査 Q3): 唯一の課金ガードだった10分無音 auto-stop
/// (`SilenceDetector`) は閾値 0.05 (= -57dBFS) を**ノイズゲート前の生レベル**で
/// 見ているため、講義室の環境音でリセットされ続け、実績42セッション中**0回**しか
/// 発火していない。停止を忘れると録音が無限に伸び、課金が発散する
/// (xAI STT は送信音声秒課金なので2時間で $0.40 超) 上に、環境音の誤認識で
/// 議事録タイトルまで壊れる。
///
/// 判定ソースを「ゲート通過」に変える案は採らない: audio スレッドから MainActor へ
/// 渡す共有状態が増え、既知の UnfairLock 事故と同じ領域に入るため。
/// **経過時間だけを見る単純なキャップ**に留める。
enum SessionLengthLimitPolicy {
    /// その場限りの上書き (ターミナルから直接バイナリを起動した場合のみ効く)。
    static let environmentKey = "MEETSCRIBE_MAX_SESSION_MINUTES"

    /// GUI 起動時の上書き手段。**環境変数だけでは不十分**: Finder/Dock/`open` から
    /// 起動したアプリはシェルの環境を継承しないため。
    /// `defaults write com.meetscribe.app maxSessionMinutes 180`
    static let userDefaultsKey = "maxSessionMinutes"

    /// 既定のキャップ (分)。
    ///
    /// **60分から180分に引き上げた (2026-08-13)**。60分は実害を出した:
    /// ```
    /// 2026-08-12 14:32→15:32 60m  (73KB) ← キャップで切られた
    /// 2026-08-12 15:32→15:34  1m (3.4KB) ← 19秒後に押し直した分
    /// 2026-08-13 08:58→09:58 60m        ← 翌日も同じ
    /// 2026-08-13 09:58→10:00  2m
    /// ```
    /// 2日連続で講義が1時間で切られ、議事録が2分割された。実績を見ると61分の講義は
    /// 珍しくなく (2026-08-10 に2本、08-12 に1本)、最長は81分 (2026-07-08)。
    /// 180分なら実績の全セッションが収まり、停止忘れの課金発散も止められる。
    static let defaultMinutes: Double = 180

    /// 上書き値の許容範囲 (分)。短すぎる値で録音が即終了する事故と、
    /// 実質無効化 (課金ガードの消滅) の両方を防ぐためクランプする。
    static let allowedMinutesRange: ClosedRange<Double> = 5...720

    /// 実際に使うキャップ (秒)。優先順位は 環境変数 → UserDefaults → 既定値。
    /// 数値にならない値・空文字は「指定なし」として次の候補へ落ちる。
    static func resolveSeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults? = .standard
    ) -> TimeInterval {
        let minutes = normalized(environment[environmentKey])
            ?? normalized(storedMinutes(in: defaults))
            ?? defaultMinutes
        return minutes * 60
    }

    /// UserDefaults は数値でも文字列でも書かれうる (`defaults write` は型を選べる)。
    /// 想定外の型 (配列・Data 等) は「指定なし」として扱う。
    private static func storedMinutes(in defaults: UserDefaults?) -> String? {
        guard let raw = defaults?.object(forKey: userDefaultsKey) else { return nil }
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    /// 数値として読めた値だけ採用する。
    /// - 上振れ (> `allowedMinutesRange.upperBound`) は上限へクランプする
    ///   (「とにかく長く」の意図を汲む)
    /// - 下振れ (< `allowedMinutesRange.lowerBound`) は**採用せず既定値へ落とす**。
    ///   `0` を「キャップ無効化」の意図で書いた人が数分で録音を切られるほうが事故なので、
    ///   無効化はできない仕様にして既定値に戻す (課金ガードを常に残す)。
    private static func normalized(_ raw: String?) -> Double? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let minutes = Double(value),
              minutes.isFinite,
              minutes >= allowedMinutesRange.lowerBound else {
            return nil
        }
        return min(minutes, allowedMinutesRange.upperBound)
    }
}

/// 会議開始からの経過時間を監視し、キャップ到達でコールバックを発火する。
///
/// 経過時間は毎回 `startedAt` からの**実時間差**で計算する (tick の回数を数えない)。
/// これで以下が同時に成立する:
///   * スリープ中に Timer が溜まっても、復帰直後の tick が実経過を見るだけなので
///     キャップ未到達なら発火しない (逆に実経過がキャップを超えていれば、
///     録音は既に無音になっているので停止して保存するのが正しい)
///   * Timer のドリフト・遅延では早発火しない
@MainActor
final class SessionLengthLimiter {
    private var timer: Timer?
    private var startedAt: Date?
    private let limitSeconds: TimeInterval
    private let pollIntervalSeconds: TimeInterval
    private let onLimitReached: @MainActor () -> Void

    init(
        limitSeconds: TimeInterval,
        pollIntervalSeconds: TimeInterval = 30,
        onLimitReached: @escaping @MainActor () -> Void
    ) {
        self.limitSeconds = limitSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.onLimitReached = onLimitReached
    }

    func start(from startedAt: Date = Date()) {
        stop()
        self.startedAt = startedAt
        timer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    /// 停止時は必ず呼ぶ (Timer を残すと停止後・次セッションで誤発火する)。
    func stop() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
    }

    private func tick() {
        guard let startedAt else { return }
        guard Date().timeIntervalSince(startedAt) >= limitSeconds else { return }
        DebugLog.log("[session-cap] \(Int(limitSeconds))s reached → auto-stop")
        stop()
        onLimitReached()
    }
}
