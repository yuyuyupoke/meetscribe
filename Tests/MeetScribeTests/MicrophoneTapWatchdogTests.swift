import XCTest
@testable import MeetScribeCore

/// マイク tap 途絶の判定を固定する。
///
/// 潰した事故 (2026-08-11 監査 Q2): AVAudioEngine が入力デバイス切替・ヘッドホン
/// 挿抜で停止しても `isRunning` は true、`captureStatus` は `.running`、
/// `lastError` は nil のままで、**講義が無音のまま終わる** (生音声は未永続化なので
/// 復元元ゼロ)。
///
/// 守る不変条件:
///   * 短い途絶 (閾値未満) では engine を再起動しない — 誤発火は音声を刻む
///   * 閾値到達で必ず再起動する
///   * **ミュート中は絶対に発火しない** — 「黙っているだけ」を「壊れた」と誤診しない
///   * 録音中以外は監視しない (停止・保存フロー中の誤発火防止)
///
/// 実オーディオは使わない (判定は純関数に切り出してある)。
final class MicrophoneTapWatchdogTests: XCTestCase {

    // MARK: - 閾値

    func test_belowThreshold_doesNotFire() {
        XCTAssertFalse(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: 4.9,
            isMuted: false,
            isRunning: true
        ), "閾値未満で engine を再起動すると音声を刻む")
    }

    func test_justBelowThreshold_doesNotFire() {
        XCTAssertFalse(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: MicrophoneTapWatchdog.stallThresholdSeconds - 0.001,
            isMuted: false,
            isRunning: true
        ))
    }

    func test_atThreshold_fires() {
        XCTAssertTrue(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: MicrophoneTapWatchdog.stallThresholdSeconds,
            isMuted: false,
            isRunning: true
        ))
    }

    func test_aboveThreshold_fires() {
        XCTAssertTrue(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: 61 * 60,
            isMuted: false,
            isRunning: true
        ), "講義1コマ分 tap が来ていないのに検知しないと議事録が空で終わる")
    }

    func test_customThreshold_isHonored() {
        XCTAssertFalse(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: 9.0,
            isMuted: false,
            isRunning: true,
            threshold: 10
        ))
        XCTAssertTrue(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: 10.0,
            isMuted: false,
            isRunning: true,
            threshold: 10
        ))
    }

    // MARK: - 誤発火の防止

    /// ミュートは tap より下流でフレームを捨てるだけなので tap は届き続けるが、
    /// 上流の記録位置が将来ずれても誤発火しないよう明示的に弾く。
    func test_muted_neverFires() {
        XCTAssertFalse(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: 600,
            isMuted: true,
            isRunning: true
        ), "ミュート中に engine を再起動してはいけない")
    }

    func test_notRunning_neverFires() {
        XCTAssertFalse(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: 600,
            isMuted: false,
            isRunning: false
        ), "停止・保存フロー中に engine を起こし直してはいけない")
    }

    /// `nil` = 未開始 / 停止中 / 再起動直後。判断材料が無いので発火しない。
    func test_noTapTimestamp_doesNotFire() {
        XCTAssertFalse(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: nil,
            isMuted: false,
            isRunning: true
        ))
    }

    // MARK: - 定数の整合

    /// ポーリングが閾値より粗いと検知が最大2倍遅れる (5秒設定で10秒無音になる)。
    func test_pollIntervalIsFinerThanThreshold() {
        XCTAssertLessThan(
            MicrophoneTapWatchdog.pollIntervalSeconds,
            MicrophoneTapWatchdog.stallThresholdSeconds
        )
    }

    /// 再起動は有限回で打ち切る (デバイス消失時の無限リトライ防止)。
    func test_restartAttemptsAreBounded() {
        XCTAssertGreaterThan(MicrophoneTapWatchdog.maxRestartAttempts, 0)
        XCTAssertLessThanOrEqual(MicrophoneTapWatchdog.maxRestartAttempts, 10)
    }
}
