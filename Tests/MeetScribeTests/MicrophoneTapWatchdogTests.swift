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

    /// `nil` = 未開始 / 停止中。判断材料が無いので発火しない。
    /// **engine 起動失敗は nil にならない** (`MicrophoneTapClock` が失敗時刻を起点に
    /// 据えるため) — nil で固定されると監視が永久に黙るので、そこは別途固定する
    /// (`MicrophoneTapClockTests.test_failedStart_keepsClockAging_soWatchdogStaysArmed`)。
    func test_noTapTimestamp_doesNotFire() {
        XCTAssertFalse(MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: nil,
            isMuted: false,
            isRunning: true
        ))
    }

    // MARK: - 再起動枠のリセット条件

    /// 潰した事故: 「途絶していない」だけを復帰の合図にしていたため、再起動失敗の
    /// 1秒後に自分の警告バナーを消し、以後の検知も再試行も永久に止まっていた。
    func test_restartBudget_isNotResetWithoutTapArrival() {
        XCTAssertFalse(MicrophoneTapWatchdog.shouldResetRestartBudget(
            restartCount: 1,
            hasTapArrivedSinceStart: false
        ), "実バッファが届く前に枠を戻すと警告が消えてマイクの死が見えなくなる")
    }

    func test_restartBudget_resetsOnlyAfterTapArrival() {
        XCTAssertTrue(MicrophoneTapWatchdog.shouldResetRestartBudget(
            restartCount: 1,
            hasTapArrivedSinceStart: true
        ), "実際に tap が戻ったら次の事故に備えて枠を戻す")
    }

    func test_restartBudget_nothingToResetAtZero() {
        XCTAssertFalse(MicrophoneTapWatchdog.shouldResetRestartBudget(
            restartCount: 0,
            hasTapArrivedSinceStart: true
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

    // MARK: - 監視ループの通し挙動 (シミュレータ)

    /// 潰した事故: 再起動ごとに枠が 0 に戻るため `maxRestartAttempts` の打ち切りに
    /// 構造的に到達できず、give-up バナーが到達不能コードだった (5〜6秒周期で
    /// VPIO 再構成と installTap をやり直し続ける)。CHANGELOG の
    /// 「再起動は1セッション5回まで、上限後はバナーを残す」が成立していなかった。
    func test_engineRestartsButTapNeverReturns_reachesGiveUpBanner() {
        let sim = MicWatchdogLoopSimulator(outcome: .engineStartsWithoutTap)
        sim.killTap()
        sim.runTicks(120)

        XCTAssertTrue(sim.gaveUp, "tap が戻らないなら有限回で打ち切って警告を残すべき")
        XCTAssertEqual(
            sim.restartAttempts,
            MicrophoneTapWatchdog.maxRestartAttempts,
            "打ち切りまでの再起動回数が上限と一致していない"
        )
        XCTAssertEqual(sim.banner, MicWatchdogLoopSimulator.giveUpBanner)
        XCTAssertFalse(sim.bannerClearedWhileBroken, "壊れている最中にバナーを消してはいけない")
    }

    /// 潰した事故: 再起動が throw すると経過秒が nil で固定され、次の tick が
    /// 「復帰」と誤読して失敗バナーを消し、以後 61分の講義が「録音中」表示のまま
    /// マイク音声ゼロで進んだ (生音声は未永続化なので復元不可)。
    func test_restartKeepsFailing_bannerSurvivesAndRetriesContinue() {
        let sim = MicWatchdogLoopSimulator(outcome: .startThrows)
        sim.killTap()

        // 1回目の再起動が失敗するところまで進める (閾値 + 1 tick)。
        sim.runTicks(Int(MicrophoneTapWatchdog.stallThresholdSeconds) + 1)
        XCTAssertEqual(sim.restartAttempts, 1)
        XCTAssertEqual(
            sim.banner,
            MicWatchdogLoopSimulator.failureBanner,
            "失敗の1秒後に自分のバナーを消すと異常が一切見えなくなる"
        )

        // その後も再試行が続き、上限で give-up バナーに着地する。
        sim.runTicks(120)
        XCTAssertTrue(sim.gaveUp, "起動失敗が続く場合も打ち切り警告に到達すべき")
        XCTAssertEqual(sim.restartAttempts, MicrophoneTapWatchdog.maxRestartAttempts)
        XCTAssertEqual(sim.banner, MicWatchdogLoopSimulator.giveUpBanner)
        XCTAssertFalse(sim.bannerClearedWhileBroken)
    }

    /// 正常系: 実バッファが戻ったら枠を戻して自分のバナーだけ消す (再起動は1回で済む)。
    func test_tapReturnsAfterRestart_resetsBudgetAndClearsBanner() {
        let sim = MicWatchdogLoopSimulator(outcome: .recovers)
        sim.killTap()
        sim.runTicks(120)

        XCTAssertEqual(sim.restartAttempts, 1, "復帰したのに再起動を繰り返してはいけない")
        XCTAssertEqual(sim.restartCount, 0, "復帰したら次の事故に備えて枠を戻す")
        XCTAssertNil(sim.banner, "復帰後にバナーを残すと誤解される")
        XCTAssertFalse(sim.gaveUp)
    }
}

// MARK: - シミュレータ

/// `AudioSession.runMicrophoneWatchdogLoop()` の tick を実オーディオ・実 Task 抜きで
/// 再現する最小シミュレータ。判定は本番と同じ純関数と `MicrophoneTapClock` を通す
/// (再現しているのはループの分岐とバナー/カウンタの操作だけ)。
private final class MicWatchdogLoopSimulator {
    /// 再起動を試みた時に何が起きるか。
    enum RestartOutcome {
        /// engine は起動するが tap は戻らない (ドライバ不調・ch=0 のデバイス等)。
        case engineStartsWithoutTap
        /// `microphone.start()` が throw する (入力デバイス消失)。
        case startThrows
        /// 起動して実バッファも戻る (正常な復帰)。
        case recovers
    }

    static let restartingBanner = "[マイク] マイクを再起動しています"
    static let failureBanner = "[マイク] マイクを再起動できませんでした"
    static let giveUpBanner = "[マイク] 音声が届いていません"
    private static let micPrefix = "[マイク]"

    private let clock = MicrophoneTapClock()
    private let outcome: RestartOutcome
    private var now: TimeInterval = 1_000
    private var tapsFlowing = true
    private var ended = false

    private(set) var restartCount = 0
    private(set) var restartAttempts = 0
    private(set) var banner: String?
    private(set) var gaveUp = false
    /// tap が流れていない (= 壊れている) のにバナーが消えたか。監視の自己無効化の検出器。
    private(set) var bannerClearedWhileBroken = false

    init(outcome: RestartOutcome) {
        self.outcome = outcome
        clock.markMonitoringStart(at: now)
    }

    /// 入力デバイスが外れて tap が途絶する。
    func killTap() { tapsFlowing = false }

    func runTicks(_ count: Int) {
        for _ in 0..<count {
            if ended { return }
            now += MicrophoneTapWatchdog.pollIntervalSeconds
            if tapsFlowing { clock.markTapArrived(at: now) }
            tick()
        }
    }

    private func tick() {
        let stalled = MicrophoneTapWatchdog.isStalled(
            secondsSinceLastTap: clock.secondsSinceLastTap(now: now),
            isMuted: false,
            isRunning: true
        )
        guard stalled else {
            if MicrophoneTapWatchdog.shouldResetRestartBudget(
                restartCount: restartCount,
                hasTapArrivedSinceStart: clock.hasTapArrived
            ) {
                restartCount = 0
                if banner?.hasPrefix(Self.micPrefix) == true { banner = nil }
            }
            if !tapsFlowing, restartAttempts > 0, banner == nil {
                bannerClearedWhileBroken = true
            }
            return
        }
        guard restartCount < MicrophoneTapWatchdog.maxRestartAttempts else {
            banner = Self.giveUpBanner
            gaveUp = true
            ended = true
            return
        }
        restartCount += 1
        restartAttempts += 1
        banner = Self.restartingBanner
        performRestart()
    }

    /// `runMicrophoneRestart()` 相当。`microphone.stop()` が時計を消し、
    /// start の成否に応じて起点を据え直す。
    private func performRestart() {
        clock.clear()
        clock.markMonitoringStart(at: now)
        switch outcome {
        case .engineStartsWithoutTap:
            break
        case .startThrows:
            banner = Self.failureBanner
        case .recovers:
            tapsFlowing = true
        }
    }
}
