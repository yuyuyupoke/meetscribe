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
