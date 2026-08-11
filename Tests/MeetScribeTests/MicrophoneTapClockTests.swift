import XCTest
@testable import MeetScribeCore

/// マイク tap 監視の**材料**を固定する。
///
/// 潰した事故 (2026-08-11 監査実装のレビュー): 材料を「最後の tap 時刻」1本で持って
/// いたため、watchdog が2種類の誤読をした。
///   1. engine 再起動が失敗すると時刻が nil で固定され、watchdog は nil を
///      「判断材料なし」= 正常と読んで再起動枠を戻し警告バナーまで消した。以後
///      永久に検知せず、**マイクが無警告で死んで講義の残りが無音になる**。
///   2. engine 起動だけで時刻が進むので「engine は running なのに tap が来ない」
///      状態でも枠が毎回 0 に戻り、再起動上限と give-up バナーに到達できなかった。
///
/// 守る不変条件:
///   * 起動しただけでは「tap が届いた」扱いにしない (`hasTapArrived == false`)
///   * 起動**失敗**でも経過秒は nil にせず進める (監視を黙らせない)
///   * 実バッファ到達だけが `hasTapArrived` を true にする
///   * 停止中は材料を消す (再起動中の誤発火防止)
///
/// 実オーディオは使わない (時計は AVFoundation 非依存に切り出してある)。
final class MicrophoneTapClockTests: XCTestCase {

    // MARK: - 初期状態

    func test_initialState_hasNoMaterial() {
        let clock = MicrophoneTapClock()
        XCTAssertNil(clock.secondsSinceLastTap(now: 100), "未開始は判断材料なし")
        XCTAssertFalse(clock.hasTapArrived)
    }

    // MARK: - engine 起動 (成功)

    /// engine が起動しただけで「tap が届いた」ことにすると、tap が死んだまま
    /// 5秒周期の無限再起動になり打ち切りに到達できない。
    func test_monitoringStart_doesNotCountAsTapArrival() throws {
        let clock = MicrophoneTapClock()
        clock.markMonitoringStart(at: 100)
        XCTAssertFalse(
            clock.hasTapArrived,
            "engine 起動を tap 到達扱いにすると再起動上限に到達できない"
        )
        let elapsed = try XCTUnwrap(clock.secondsSinceLastTap(now: 103))
        XCTAssertEqual(elapsed, 3, accuracy: 0.0001)
    }

    /// 1バッファも届かないケース (権限・入力デバイス消失) を閾値経過で検知させる
    /// ため、起点は engine 起動時刻で進む。
    func test_monitoringStart_agesPastThreshold() {
        let clock = MicrophoneTapClock()
        clock.markMonitoringStart(at: 100)
        XCTAssertTrue(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: clock.secondsSinceLastTap(
                now: 100 + MicrophoneTapWatchdog.stallThresholdSeconds
            ),
            isMuted: false,
            isRunning: true
        ), "engine 起動後1バッファも来なければ閾値経過で検知しないといけない")
    }

    // MARK: - engine 起動 (失敗)

    /// 起動失敗で材料を nil に戻すと watchdog が永久に黙る (再試行も give-up も来ない)。
    /// 失敗時刻を起点に据えることで閾値経過後に再び途絶と判定される。
    func test_failedStart_keepsClockAging_soWatchdogStaysArmed() {
        let clock = MicrophoneTapClock()
        // stop() 相当: 材料を消す
        clock.clear()
        XCTAssertNil(clock.secondsSinceLastTap(now: 100))
        // start() が throw した → 失敗時刻を起点にする
        clock.markMonitoringStart(at: 100)

        XCTAssertNotNil(
            clock.secondsSinceLastTap(now: 101),
            "起動失敗後に nil のままだと watchdog が「判断材料なし」で黙る"
        )
        XCTAssertFalse(clock.hasTapArrived, "起動失敗を復帰扱いにしてはいけない")
        XCTAssertTrue(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: clock.secondsSinceLastTap(
                now: 100 + MicrophoneTapWatchdog.stallThresholdSeconds
            ),
            isMuted: false,
            isRunning: true
        ), "起動失敗後も閾値経過で再試行に進めるべき")
    }

    // MARK: - 実バッファ到達

    func test_tapArrival_isTheOnlyRecoverySignal() throws {
        let clock = MicrophoneTapClock()
        clock.markMonitoringStart(at: 100)
        XCTAssertFalse(clock.hasTapArrived)

        clock.markTapArrived(at: 101)
        XCTAssertTrue(clock.hasTapArrived)
        let elapsed = try XCTUnwrap(clock.secondsSinceLastTap(now: 101.021))
        XCTAssertEqual(elapsed, 0.021, accuracy: 0.0001)
    }

    /// 再起動のたびに「まだ tap が来ていない」状態へ戻す (前回の到達を持ち越さない)。
    func test_monitoringStart_resetsPreviousTapArrival() {
        let clock = MicrophoneTapClock()
        clock.markTapArrived(at: 100)
        XCTAssertTrue(clock.hasTapArrived)

        clock.markMonitoringStart(at: 200)
        XCTAssertFalse(
            clock.hasTapArrived,
            "前セッションの tap 到達を持ち越すと死んだ engine を復帰と誤認する"
        )
    }

    // MARK: - 停止

    func test_clear_removesMaterial() {
        let clock = MicrophoneTapClock()
        clock.markTapArrived(at: 100)
        clock.clear()
        XCTAssertNil(clock.secondsSinceLastTap(now: 200), "停止中は「途絶」ではない")
        XCTAssertFalse(clock.hasTapArrived)
    }

    // MARK: - 時刻の巻き戻り

    /// systemUptime は巻き戻らない前提だが、負の経過秒を返すと閾値比較が壊れるので clamp。
    func test_negativeElapsed_isClampedToZero() {
        let clock = MicrophoneTapClock()
        clock.markTapArrived(at: 100)
        XCTAssertEqual(clock.secondsSinceLastTap(now: 99), 0)
    }
}
