import Foundation

/// マイク tap の到達状況を記録する時計。`MicrophoneCapture` が所有し、
/// `MicrophoneTapWatchdog` の判定材料になる唯一の入力を提供する。
///
/// 潰した事故 (2026-08-11 監査実装のレビュー): 監視材料を「最後の tap 時刻」1本で
/// 持っていたため、2つの穴が空いていた。
///
///   1. **再起動失敗で監視が自己無効化する** — `stop()` が時刻を nil に戻した後
///      `start()` が throw すると nil で固定される。watchdog は nil を
///      「判断材料なし」= 途絶なしと読むので、1秒後の tick が「復帰した」と誤認して
///      再起動枠を戻し `[マイク] 再起動できませんでした` バナーまで消す。以後 nil の
///      ままなので再試行も give-up 警告も永久に来ない = **マイクが無警告で死ぬ**。
///   2. **再起動上限に到達できない** — engine 起動だけで時刻が進むので、「engine は
///      running なのに tap が来ない」状態でも次の tick で枠が 0 に戻り、5秒周期の
///      無限再起動になる。`maxRestartAttempts` の打ち切りと give-up バナーが到達不能。
///
/// なので「経過秒」と「実バッファが届いたか」を**別々に**持つ:
///   * `secondsSinceLastTap(now:)` — 監視起点 (engine 起動 / 起動失敗 / 最後の tap) からの経過秒。
///     起動失敗でも起点を進めるのが要点。nil のままにすると watchdog が黙る。
///   * `hasTapArrived` — 直近の監視起点以降に**実バッファ**が届いたか。再起動枠の
///     リセットとバナー消去はこれが true の時だけ許す。
///
/// tap はキャプチャスレッドから、読み出しは MainActor の watchdog から来るので
/// NSLock + var で保護する (`OSAllocatedUnfairLock` に**関数型を入れると** withLock ごとに
/// reabstraction thunk が連鎖して stop 時にスタックオーバーフローする既知事故があるため、
/// ここでも値型のみを扱う)。NSLock は非再帰なので、ロック下から自分の他メソッドは呼ばない。
///
/// 時刻は `ProcessInfo.systemUptime` を渡す前提 (スリープ中は進まないので、
/// スリープ復帰直後に途絶と誤判定しない)。テストのために now は引数で受ける。
final class MicrophoneTapClock: @unchecked Sendable {
    private let lock = NSLock()

    /// 監視の起点 (engine 起動 / 起動失敗 / 最後の tap 到達)。停止中・未開始は nil。
    private var _originUptime: TimeInterval?

    /// 直近の監視起点以降に実バッファが届いたか。
    private var _tapArrived = false

    /// engine の起動を監視の起点にする。**成功・失敗の両方で呼ぶ。**
    ///
    /// 失敗時も起点を進めるのが要点: nil のまま放置すると watchdog が「判断材料なし」
    /// として黙り、再試行も give-up 警告も来なくなる。ここで起点を進めておけば
    /// 閾値経過で再び途絶と判定され、再起動のはしごが `maxRestartAttempts` まで進む。
    ///
    /// 「1バッファも届かないケース (権限・入力デバイス消失) も閾値経過で検知させる」
    /// という元の意図はそのまま維持しつつ、`hasTapArrived` は false に戻すので
    /// 「起動しただけ」を「tap が戻った」と誤認しない。
    func markMonitoringStart(at uptime: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _originUptime = uptime
        _tapArrived = false
    }

    /// 実バッファの到達。**ここだけが `hasTapArrived` を true にする。**
    func markTapArrived(at uptime: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _originUptime = uptime
        _tapArrived = true
    }

    /// 停止中は「途絶」ではないので監視材料を消す (再起動中の誤発火防止)。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _originUptime = nil
        _tapArrived = false
    }

    /// 監視起点からの経過秒。停止中・未開始は nil。
    func secondsSinceLastTap(now: TimeInterval) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let origin = _originUptime else { return nil }
        return max(0, now - origin)
    }

    /// 直近の監視起点以降に実バッファが届いたか。
    var hasTapArrived: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _tapArrived
    }
}
