import XCTest
@testable import MeetScribeCore

/// 最大録音時間キャップの設定解決と発火条件を固定する。
///
/// なぜ必要か (2026-08-11 監査 Q3): 唯一の課金ガードだった10分無音 auto-stop は
/// 実績42セッション中 0回しか発火していない (閾値がノイズゲート前の生レベルを見ており、
/// 講義室の環境音でリセットされ続ける)。停止忘れで課金が発散するのを止める歯止めなので、
/// 「上書き手段が生きている」「早発火しない」「停止後に発火しない」を固定する。
final class SessionLengthLimitPolicyTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        // 実ユーザーの設定を汚さない専用スイート
        UserDefaults(suiteName: "meetscribe-session-cap-tests-\(UUID().uuidString)")!
    }

    // MARK: - 既定値

    /// 既定は3時間。60分だった間に**2日連続で講義が切られて議事録が2分割された**
    /// (2026-08-12 14:32→15:32 で60分到達、2026-08-13 08:58→09:58 も同様)。
    /// 61分の講義は珍しくなく、実績最長は81分なので180分まで引き上げた。
    func test_default_isThreeHours() {
        XCTAssertEqual(
            SessionLengthLimitPolicy.resolveSeconds(environment: [:], defaults: makeDefaults()),
            180 * 60,
            "既定のキャップは3時間 (60分は実績61分の講義を切ってしまった)"
        )
    }

    /// キャップは実績の最長セッション (81分) を必ず超えていなければならない。
    /// ここを下回る値に戻すと、また講義が途中で切られて議事録が分割される。
    func test_default_exceedsLongestObservedSession() {
        let longestObservedMinutes: Double = 81  // 2026-07-08
        XCTAssertGreaterThan(SessionLengthLimitPolicy.defaultMinutes, longestObservedMinutes)
    }

    // MARK: - 上書き手段

    func test_environmentOverride() {
        let seconds = SessionLengthLimitPolicy.resolveSeconds(
            environment: [SessionLengthLimitPolicy.environmentKey: "180"],
            defaults: makeDefaults()
        )
        XCTAssertEqual(seconds, 180 * 60)
    }

    /// GUI (Finder/Dock/`open`) 起動はシェルの環境を継承しないので、
    /// UserDefaults 併設が無いと長いワークショップ用の逃げ道が実質使えない。
    func test_userDefaultsOverride_isHonored() {
        let defaults = makeDefaults()
        defaults.set(240, forKey: SessionLengthLimitPolicy.userDefaultsKey)
        XCTAssertEqual(
            SessionLengthLimitPolicy.resolveSeconds(environment: [:], defaults: defaults),
            240 * 60
        )
    }

    func test_userDefaultsOverride_acceptsStringValue() {
        let defaults = makeDefaults()
        defaults.set("90", forKey: SessionLengthLimitPolicy.userDefaultsKey)
        XCTAssertEqual(
            SessionLengthLimitPolicy.resolveSeconds(environment: [:], defaults: defaults),
            90 * 60
        )
    }

    func test_environmentWins_overUserDefaults() {
        let defaults = makeDefaults()
        defaults.set(240, forKey: SessionLengthLimitPolicy.userDefaultsKey)
        XCTAssertEqual(
            SessionLengthLimitPolicy.resolveSeconds(
                environment: [SessionLengthLimitPolicy.environmentKey: "120"],
                defaults: defaults
            ),
            120 * 60,
            "恒久設定を書き換えずに1回だけ試せるよう環境変数を上に置く"
        )
    }

    // MARK: - 壊れた値・極端な値

    func test_garbageValue_fallsBackToDefault() {
        for raw in ["", "  ", "abc", "60min", "nan"] {
            XCTAssertEqual(
                SessionLengthLimitPolicy.resolveSeconds(
                    environment: [SessionLengthLimitPolicy.environmentKey: raw],
                    defaults: makeDefaults()
                ),
                SessionLengthLimitPolicy.defaultMinutes * 60,
                "壊れた値 '\(raw)' で挙動が変わってはいけない"
            )
        }
    }

    /// `0` は「無効化」の意図で書かれるが、下限クランプで数分の録音になると事故なので
    /// 既定値へ落とす (課金ガードは常に残す)。
    func test_zeroOrTooSmall_fallsBackToDefault() {
        for raw in ["0", "-30", "1"] {
            XCTAssertEqual(
                SessionLengthLimitPolicy.resolveSeconds(
                    environment: [SessionLengthLimitPolicy.environmentKey: raw],
                    defaults: makeDefaults()
                ),
                SessionLengthLimitPolicy.defaultMinutes * 60,
                "'\(raw)' で録音が即終了してはいけない"
            )
        }
    }

    func test_hugeValue_isClampedToUpperBound() {
        XCTAssertEqual(
            SessionLengthLimitPolicy.resolveSeconds(
                environment: [SessionLengthLimitPolicy.environmentKey: "99999"],
                defaults: makeDefaults()
            ),
            SessionLengthLimitPolicy.allowedMinutesRange.upperBound * 60
        )
    }

    func test_unexpectedDefaultsType_isIgnored() {
        let defaults = makeDefaults()
        defaults.set([1, 2, 3], forKey: SessionLengthLimitPolicy.userDefaultsKey)
        XCTAssertEqual(
            SessionLengthLimitPolicy.resolveSeconds(environment: [:], defaults: defaults),
            SessionLengthLimitPolicy.defaultMinutes * 60
        )
    }
}

@MainActor
final class SessionLengthLimiterTests: XCTestCase {

    func test_firesWhenLimitReached() {
        let called = expectation(description: "onLimitReached")
        let limiter = SessionLengthLimiter(
            limitSeconds: 0.2,
            pollIntervalSeconds: 0.1,
            onLimitReached: { called.fulfill() }
        )
        limiter.start()
        wait(for: [called], timeout: 3.0)
        limiter.stop()
    }

    func test_doesNotFireBeforeLimit() {
        let called = expectation(description: "onLimitReached")
        called.isInverted = true
        let limiter = SessionLengthLimiter(
            limitSeconds: 60,
            pollIntervalSeconds: 0.1,
            onLimitReached: { called.fulfill() }
        )
        limiter.start()
        wait(for: [called], timeout: 0.6)
        limiter.stop()
    }

    /// 経過時間は tick の回数ではなく `startedAt` からの実時間差で見る。
    /// これでスリープ復帰後にキャップ未到達で誤発火せず、到達済みなら確実に停止する。
    func test_usesElapsedWallClockFromStart() {
        let called = expectation(description: "onLimitReached")
        let limiter = SessionLengthLimiter(
            limitSeconds: 60,
            pollIntervalSeconds: 0.1,
            onLimitReached: { called.fulfill() }
        )
        limiter.start(from: Date().addingTimeInterval(-3600))
        wait(for: [called], timeout: 3.0)
        limiter.stop()
    }

    /// 停止後に Timer が残ると、保存フロー中や次セッションで誤って stop() が走る。
    func test_stop_preventsCallback() {
        let called = expectation(description: "onLimitReached")
        called.isInverted = true
        let limiter = SessionLengthLimiter(
            limitSeconds: 0.05,
            pollIntervalSeconds: 0.05,
            onLimitReached: { called.fulfill() }
        )
        limiter.start()
        limiter.stop()
        wait(for: [called], timeout: 0.6)
    }

    func test_firesOnlyOnce() {
        let called = expectation(description: "onLimitReached")
        called.expectedFulfillmentCount = 1
        called.assertForOverFulfill = true
        let limiter = SessionLengthLimiter(
            limitSeconds: 0.1,
            pollIntervalSeconds: 0.05,
            onLimitReached: { called.fulfill() }
        )
        limiter.start()
        wait(for: [called], timeout: 3.0)
        // 発火後も Timer が生きていると 2回目が来る (assertForOverFulfill で検知)
        let settled = expectation(description: "settle")
        settled.isInverted = true
        wait(for: [settled], timeout: 0.4)
        limiter.stop()
    }

    func test_doubleStart_replacesTimer() {
        let limiter = SessionLengthLimiter(
            limitSeconds: 60,
            pollIntervalSeconds: 0.1,
            onLimitReached: {}
        )
        limiter.start()
        limiter.start()
        limiter.stop()
    }
}
