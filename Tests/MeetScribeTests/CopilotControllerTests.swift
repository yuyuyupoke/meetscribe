import XCTest
@testable import MeetScribeCore

/// CopilotController の純関数ヘルパーと MeetingOverview パースのテスト。
@MainActor
final class CopilotControllerTests: XCTestCase {

    private func entry(
        _ id: String,
        text: String = "text",
        secondsAgo: TimeInterval,
        isFinal: Bool = true,
        now: Date
    ) -> TranscriptEntry {
        TranscriptEntry(
            id: id,
            speaker: .me,
            text: text,
            createdAt: now.addingTimeInterval(-secondsAgo),
            isFinal: isFinal
        )
    }

    // MARK: - entriesInWindow (直近N分の抽出)

    func test_entriesInWindow_includesOnlyRecentFinalEntries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            entry("old", secondsAgo: 400, now: now),          // 6分40秒前 → 対象外
            entry("recent", secondsAgo: 100, now: now),       // 1分40秒前 → 対象
            entry("pending", secondsAgo: 50, isFinal: false, now: now), // 未確定 → 対象外
            entry("empty", text: "", secondsAgo: 30, now: now)          // 空 → 対象外
        ]
        let result = CopilotController.entriesInWindow(entries, minutes: 3, now: now)
        XCTAssertEqual(result.map(\.id), ["recent"])
    }

    func test_entriesInWindow_boundaryExactlyOnCutoff_included() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [entry("edge", secondsAgo: 180, now: now)]
        let result = CopilotController.entriesInWindow(entries, minutes: 3, now: now)
        XCTAssertEqual(result.count, 1)
    }

    func test_entriesInWindow_empty_returnsEmpty() {
        XCTAssertTrue(CopilotController.entriesInWindow([], minutes: 5).isEmpty)
    }

    // MARK: - periodLabel

    func test_periodLabel_format() {
        let from = Date(timeIntervalSince1970: 0)
        let to = from.addingTimeInterval(180)
        let label = CopilotController.periodLabel(from: from, to: to)
        // タイムゾーン依存を避け、形式のみ検証 (HH:mm〜HH:mm)
        let pattern = #"^\d{2}:\d{2}〜\d{2}:\d{2}$"#
        XCTAssertNotNil(label.range(of: pattern, options: .regularExpression), "got: \(label)")
    }

    // MARK: - transcriptText

    func test_transcriptText_includesSpeakerLabels() {
        let now = Date()
        let entries = [
            TranscriptEntry(id: "1", speaker: .me, text: "こんにちは", createdAt: now, isFinal: true),
            TranscriptEntry(id: "2", speaker: .other, text: "hi", createdAt: now, isFinal: true)
        ]
        let text = CopilotController.transcriptText(entries)
        XCTAssertEqual(text, "[自分] こんにちは\n[相手] hi")
    }

    // MARK: - 全体像の自動更新トリガー閾値

    /// 2026-08-10 の実測 (61分の英語講義で総額 $0.8197、うち Overview が40%超) を受けて
    /// 緩めた値。ここを戻すと Overview のLLM呼び出しが倍に増えるため、数値ごと固定する。
    func test_overviewTriggerThresholds_matchCostMeasurement() {
        XCTAssertEqual(CopilotController.monitorInterval, 60)
        XCTAssertEqual(CopilotController.updateCharThreshold, 5_000)
        XCTAssertEqual(CopilotController.updateTimeThreshold, 300)
        XCTAssertEqual(CopilotController.minCharsForTimeUpdate, 400)
        // 初回表示の速さ (体感) に直結する値なので、コスト削減の対象にしない
        XCTAssertEqual(CopilotController.minCharsForFirstOverview, 300)
    }

    /// 時間トリガーは監視周期より長くないと「毎周期発火」になり閾値が意味を失う。
    func test_timeThreshold_isLongerThanMonitorInterval() {
        XCTAssertGreaterThan(
            CopilotController.updateTimeThreshold,
            CopilotController.monitorInterval
        )
    }

    /// **LLM に渡す窓は発火間隔より広くなければならない。**
    /// 窓 (`overviewContextChars`) が新規発話量 (`updateCharThreshold`) を下回ると、
    /// 更新の合間に流れた発話が一度も全体像に反映されないまま窓の外へ出てしまう。
    /// 閾値を 2,400→5,000 に緩めた時点で余裕が 2.5倍→1.2倍まで縮んでいたため 8,000 に広げた。
    func test_overviewContextWindow_isWiderThanCharThreshold() {
        XCTAssertGreaterThan(
            CopilotController.overviewContextChars,
            CopilotController.updateCharThreshold
        )
        // 取りこぼしの実害を避けるため 1.5倍以上の余裕を要求する
        XCTAssertGreaterThanOrEqual(
            Double(CopilotController.overviewContextChars),
            Double(CopilotController.updateCharThreshold) * 1.5
        )
        XCTAssertEqual(CopilotController.overviewContextChars, 8_000)
    }

    /// 初回の全体像が出るまでは従来の30秒周期を維持する
    /// (60秒にすると「傍聴中…」が最大60秒残って体感が悪い。初回は1会議1回でコストに響かない)。
    func test_firstOverviewMonitorInterval_isFasterThanSteadyState() {
        XCTAssertEqual(CopilotController.firstOverviewMonitorInterval, 30)
        XCTAssertLessThan(
            CopilotController.firstOverviewMonitorInterval,
            CopilotController.monitorInterval
        )
    }

    // MARK: - 発火判定の振る舞い (OverviewUpdateTrigger)
    //
    // 閾値の定数ミラーだけでは「呼び出し側が状態を前進させ忘れている」欠陥を
    // 一切捕まえられない (2026-08-11 監査 C3: パース失敗時に状態を据え置くと
    // 監視周期ごとに再試行し続け、61分で7回のはずが約60回になる)。
    // ここでは監視ループを模した発火回数そのものを固定する。

    /// 監視ループを模して「何周期目に発火したか」を返す。
    /// - Parameters:
    ///   - charsPerTick: 1周期あたりに増える文字起こしの文字数
    ///   - parseSucceeds: 応答のパースが成功するか
    ///   - advanceOnFailure: 失敗時にも状態を前進させるか (false = C3 修正前の挙動)
    ///   - startsWithOverview: 初回の全体像がすでに出ている状態から始めるか
    private func simulateOverviewFires(
        tickInterval: TimeInterval,
        ticks: Int,
        charsPerTick: Int,
        parseSucceeds: Bool,
        advanceOnFailure: Bool = true,
        startsWithOverview: Bool
    ) -> [Int] {
        var trigger = OverviewUpdateTrigger()
        var hasOverview = startsWithOverview
        var textLength = 0
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var fires: [Int] = []

        for tick in 0..<ticks {
            now = now.addingTimeInterval(tickInterval)
            textLength += charsPerTick
            guard trigger.shouldUpdate(
                textLength: textLength,
                hasOverview: hasOverview,
                now: now
            ) else { continue }
            fires.append(tick)
            if parseSucceeds {
                hasOverview = true
                trigger.recordAttempt(textLength: textLength, now: now)
            } else if advanceOnFailure {
                trigger.recordAttempt(textLength: textLength, now: now)
            }
        }
        return fires
    }

    /// **パースが失敗し続けても発火回数は成功時のカデンスと同じ。**
    /// 61分 (60秒周期) / 発話 300字/分 という実測レンジで、失敗ループが
    /// 監視周期ごとの再試行に化けないことを固定する。
    func test_overviewTrigger_repeatedFailures_keepSuccessCadence() {
        let onSuccess = simulateOverviewFires(
            tickInterval: 60, ticks: 61, charsPerTick: 300,
            parseSucceeds: true, startsWithOverview: true
        )
        let onFailure = simulateOverviewFires(
            tickInterval: 60, ticks: 61, charsPerTick: 300,
            parseSucceeds: false, startsWithOverview: true
        )
        let beforeC3Fix = simulateOverviewFires(
            tickInterval: 60, ticks: 61, charsPerTick: 300,
            parseSucceeds: false, advanceOnFailure: false, startsWithOverview: true
        )

        XCTAssertEqual(onFailure, onSuccess, "失敗時の発火は成功時と同じカデンスでなければならない")
        // 61分講義での実測は約7回。カデンスの上限を余裕込みで固定する
        XCTAssertLessThanOrEqual(onFailure.count, 14, "発火が多すぎる: \(onFailure)")
        // 修正前の挙動 (状態を据え置く) は毎周期発火に化ける
        XCTAssertGreaterThan(beforeC3Fix.count, onFailure.count * 3, "回帰ガードが効いていない")
    }

    /// 初回の全体像が出る前の失敗も有界。かつ**初回試行のタイミングは変えない**
    /// (「傍聴中…」の解消が遅くなると体感が悪い)。
    func test_overviewTrigger_firstOverviewFailures_areBoundedWithoutDelayingFirstTry() {
        let fixed = simulateOverviewFires(
            tickInterval: 30, ticks: 122, charsPerTick: 150,
            parseSucceeds: false, startsWithOverview: false
        )
        let beforeC3Fix = simulateOverviewFires(
            tickInterval: 30, ticks: 122, charsPerTick: 150,
            parseSucceeds: false, advanceOnFailure: false, startsWithOverview: false
        )

        XCTAssertEqual(fixed.first, beforeC3Fix.first, "初回試行のタイミングを遅らせてはいけない")
        // 速い再試行は maxFastFirstAttempts 回まで。その後は通常カデンスに落ちる
        XCTAssertLessThanOrEqual(fixed.count, 20, "初回失敗ループが発散している: \(fixed.count)")
        XCTAssertGreaterThan(beforeC3Fix.count, 100, "修正前は毎周期発火していたはず")
    }

    /// 初回は最低文字数だけで発火する (体感優先の速い初回表示)。
    func test_overviewTrigger_firstFire_atMinCharsForFirstOverview() {
        let trigger = OverviewUpdateTrigger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(trigger.shouldUpdate(
            textLength: CopilotController.minCharsForFirstOverview - 1,
            hasOverview: false, now: now
        ))
        XCTAssertTrue(trigger.shouldUpdate(
            textLength: CopilotController.minCharsForFirstOverview,
            hasOverview: false, now: now
        ))
    }

    /// 試行を記録したら直後の周期では発火せず、文字数/経過時間の各トリガーで復帰する。
    func test_overviewTrigger_recordAttempt_suppressesImmediateRefire() {
        var trigger = OverviewUpdateTrigger()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(trigger.shouldUpdate(textLength: 1_000, hasOverview: false, now: t0))
        trigger.recordAttempt(textLength: 1_000, now: t0)

        // 60秒後・新規100字 → どちらのトリガーも満たさない
        XCTAssertFalse(trigger.shouldUpdate(
            textLength: 1_100, hasOverview: true, now: t0.addingTimeInterval(60)
        ))
        // 5分経過 & 新規400字 → 時間トリガー
        XCTAssertTrue(trigger.shouldUpdate(
            textLength: 1_400, hasOverview: true, now: t0.addingTimeInterval(300)
        ))
        // 新規5,000字 → 経過時間に関係なく文字数トリガー
        XCTAssertTrue(trigger.shouldUpdate(
            textLength: 6_000, hasOverview: true, now: t0.addingTimeInterval(10)
        ))
    }
}

final class MeetingOverviewTests: XCTestCase {

    func test_parse_validJSON() {
        let json = #"{"purpose": "計画確定", "agenda": ["振り返り", "予算"], "current_topic": "予算の議論"}"#
        let overview = MeetingOverview.parse(json)

        XCTAssertEqual(overview?.purpose, "計画確定")
        XCTAssertEqual(overview?.agenda, ["振り返り", "予算"])
        XCTAssertEqual(overview?.currentTopic, "予算の議論")
    }

    func test_parse_missingAgenda_defaultsEmpty() {
        let json = #"{"purpose": "テスト", "current_topic": "x"}"#
        let overview = MeetingOverview.parse(json)
        XCTAssertEqual(overview?.agenda, [])
    }

    func test_parse_emptyPurpose_returnsNil() {
        XCTAssertNil(MeetingOverview.parse(#"{"purpose": "  ", "agenda": [], "current_topic": "x"}"#))
    }

    func test_parse_malformed_returnsNil() {
        XCTAssertNil(MeetingOverview.parse("not json"))
        XCTAssertNil(MeetingOverview.parse(#"{"agenda": []}"#))
    }

    func test_parse_filtersEmptyAgendaItems() {
        let json = #"{"purpose": "p", "agenda": ["a", "  ", "b"], "current_topic": "c"}"#
        XCTAssertEqual(MeetingOverview.parse(json)?.agenda, ["a", "b"])
    }
}
