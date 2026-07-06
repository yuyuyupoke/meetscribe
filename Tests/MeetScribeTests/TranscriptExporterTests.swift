import XCTest
@testable import MeetScribeCore

final class TranscriptExporterTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetScribeTests-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    private func makeRecord(
        title: String = "Test Meeting",
        startedAt: Date = Date(timeIntervalSince1970: 1719500000),
        endedAt: Date = Date(timeIntervalSince1970: 1719503600),
        meetingEntries: [TranscriptEntry] = [],
        overview: MeetingOverview? = nil,
        catchupCards: [CatchupCard] = [],
        cost: Double = 0.0042
    ) -> MeetingRecord {
        MeetingRecord(
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            meetingEntries: meetingEntries,
            overview: overview,
            catchupCards: catchupCards,
            totalCostUSD: cost,
            model: "gpt-4o-transcribe"
        )
    }

    // MARK: - render

    func test_render_containsFrontMatter() {
        let record = makeRecord()
        let content = TranscriptExporter.render(record: record)

        XCTAssertTrue(content.hasPrefix("---\n"))
        XCTAssertTrue(content.contains("date:"))
        XCTAssertTrue(content.contains("model: gpt-4o-transcribe"))
        XCTAssertTrue(content.contains("cost: $0.0042"))
    }

    func test_render_containsTitle() {
        let record = makeRecord(title: "Weekly Standup")
        let content = TranscriptExporter.render(record: record)
        XCTAssertTrue(content.contains("# Weekly Standup"))
    }

    func test_render_emptyMeeting_showsNoUtteranceMarker() {
        let record = makeRecord(meetingEntries: [])
        let content = TranscriptExporter.render(record: record)
        XCTAssertTrue(content.contains("_(発話なし)_"))
    }

    func test_render_withMeetingEntries_containsSpeakerLabels() {
        let entries = [
            TranscriptEntry(id: "1", speaker: .me, text: "こんにちは", createdAt: Date(), isFinal: true),
            TranscriptEntry(id: "2", speaker: .other, text: "よろしく", createdAt: Date(), isFinal: true)
        ]
        let record = makeRecord(meetingEntries: entries)
        let content = TranscriptExporter.render(record: record)

        XCTAssertTrue(content.contains("**[自分]** こんにちは"))
        XCTAssertTrue(content.contains("**[相手]** よろしく"))
    }

    // MARK: - 対訳・全体像・Catchup

    func test_render_entryWithTranslation_containsQuotedTranslation() {
        let entries = [
            TranscriptEntry(
                id: "1", speaker: .other,
                text: "Let's discuss the roadmap.",
                createdAt: Date(), isFinal: true,
                translation: "ロードマップについて話しましょう。"
            )
        ]
        let record = makeRecord(meetingEntries: entries)
        let content = TranscriptExporter.render(record: record)

        XCTAssertTrue(content.contains("**[相手]** Let's discuss the roadmap."))
        XCTAssertTrue(content.contains("> 訳: ロードマップについて話しましょう。"))
    }

    func test_render_withOverview_containsOverviewSection() {
        let overview = MeetingOverview(
            purpose: "四半期計画の確定",
            agenda: ["前期の振り返り", "予算"],
            currentTopic: "予算配分の議論"
        )
        let record = makeRecord(
            meetingEntries: [TranscriptEntry(id: "1", speaker: .me, text: "test", createdAt: Date(), isFinal: true)],
            overview: overview
        )
        let content = TranscriptExporter.render(record: record)

        XCTAssertTrue(content.contains("## 🧭 全体像"))
        XCTAssertTrue(content.contains("**目的**: 四半期計画の確定"))
        XCTAssertTrue(content.contains("- 前期の振り返り"))
    }

    func test_render_withCatchupCards_sortedOldestFirst_excludingErrorsAndNoSpeech() {
        let cards = [
            CatchupCard(periodLabel: "14:10〜14:15", minutes: 5, text: "後半の要約",
                        createdAt: Date(timeIntervalSince1970: 200)),
            CatchupCard(periodLabel: "14:00〜14:03", minutes: 3, text: "前半の要約",
                        createdAt: Date(timeIntervalSince1970: 100)),
            CatchupCard(periodLabel: "14:20〜14:21", minutes: 1, text: "失敗", isError: true,
                        createdAt: Date(timeIntervalSince1970: 300)),
            CatchupCard(periodLabel: "14:25〜14:26", minutes: 1, text: "この期間の発話はありません",
                        isNoSpeech: true, createdAt: Date(timeIntervalSince1970: 400))
        ]
        let record = makeRecord(
            meetingEntries: [TranscriptEntry(id: "1", speaker: .me, text: "test", createdAt: Date(), isFinal: true)],
            catchupCards: cards
        )
        let content = TranscriptExporter.render(record: record)

        XCTAssertTrue(content.contains("## ⏱ Catchup履歴"))
        XCTAssertFalse(content.contains("失敗"), "エラーカードは保存しない")
        XCTAssertFalse(content.contains("発話はありません"), "発話なしカードは保存しない")
        // 古い順に並ぶ
        let firstIdx = content.range(of: "前半の要約")!.lowerBound
        let secondIdx = content.range(of: "後半の要約")!.lowerBound
        XCTAssertLessThan(firstIdx, secondIdx)
    }

    func test_render_onlyErrorAndNoSpeechCards_omitsCatchupSection() {
        let cards = [
            CatchupCard(periodLabel: "14:20〜14:21", minutes: 1, text: "失敗", isError: true),
            CatchupCard(periodLabel: "14:25〜14:26", minutes: 1, text: "発話なし", isNoSpeech: true)
        ]
        let record = makeRecord(
            meetingEntries: [TranscriptEntry(id: "1", speaker: .me, text: "test", createdAt: Date(), isFinal: true)],
            catchupCards: cards
        )
        let content = TranscriptExporter.render(record: record)
        XCTAssertFalse(content.contains("## ⏱ Catchup履歴"), "保存対象ゼロなら見出しごと省略")
    }

    func test_render_noOverviewNoCatchup_omitsSections() {
        let record = makeRecord(
            meetingEntries: [TranscriptEntry(id: "1", speaker: .me, text: "test", createdAt: Date(), isFinal: true)]
        )
        let content = TranscriptExporter.render(record: record)
        XCTAssertFalse(content.contains("## 🧭 全体像"))
        XCTAssertFalse(content.contains("## ⏱ Catchup履歴"))
    }

    // MARK: - MeetingRecord.durationMinutes

    func test_durationMinutes_oneHour_returns60() {
        let record = makeRecord(
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3600)
        )
        XCTAssertEqual(record.durationMinutes, 60)
    }

    func test_durationMinutes_minimum_returns1() {
        let record = makeRecord(
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(record.durationMinutes, 1, "Duration < 1 min should be clamped to 1")
    }

    // MARK: - makeFilename

    func test_makeFilename_containsDateAndTitle() {
        let record = makeRecord(
            title: "Weekly",
            startedAt: Date(timeIntervalSince1970: 1719500000)
        )
        let filename = TranscriptExporter.makeFilename(for: record)
        XCTAssertTrue(filename.hasSuffix(".md"))
        XCTAssertTrue(filename.contains("Weekly"))
    }

    func test_makeFilename_sanitizesSpecialChars() {
        let record = makeRecord(title: "Meeting: 2024/06/28 <draft>")
        let filename = TranscriptExporter.makeFilename(for: record)
        XCTAssertFalse(filename.contains(":"))
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains("<"))
        XCTAssertFalse(filename.contains(">"))
    }

    func test_makeFilename_emptyTitle_usesUntitled() {
        let record = makeRecord(title: "")
        let filename = TranscriptExporter.makeFilename(for: record)
        XCTAssertTrue(filename.contains("untitled"))
    }

    func test_makeFilename_longTitle_truncated() {
        let longTitle = String(repeating: "あ", count: 100)
        let record = makeRecord(title: longTitle)
        let filename = TranscriptExporter.makeFilename(for: record)
        // Title portion should be ≤ 60 chars
        XCTAssertLessThanOrEqual(filename.count, 100, "Filename with long title should be truncated")
    }

    // MARK: - save

    func test_save_nilDirectory_throwsError() {
        let record = makeRecord()
        XCTAssertThrowsError(try TranscriptExporter.save(record, to: nil)) { error in
            XCTAssertTrue(error is TranscriptExporter.ExportError)
        }
    }

    func test_save_validDirectory_createsFile() throws {
        let entries = [
            TranscriptEntry(id: "1", speaker: .me, text: "hello", createdAt: Date(), isFinal: true)
        ]
        let record = makeRecord(meetingEntries: entries)
        let url = try TranscriptExporter.save(record, to: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("hello"))
    }

    func test_save_returnsFileURL() throws {
        let record = makeRecord()
        let url = try TranscriptExporter.save(record, to: tmpDir)
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".md"))
    }
}
