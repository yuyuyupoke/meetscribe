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
        qaEntries: [TranscriptEntry] = [],
        cost: Double = 0.0042
    ) -> MeetingRecord {
        MeetingRecord(
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            meetingEntries: meetingEntries,
            qaEntries: qaEntries,
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

    func test_render_withQAEntries_containsQASection() {
        let qa = [
            TranscriptEntry(id: "q1", speaker: .user, text: "What happened?", createdAt: Date(), isFinal: true),
            TranscriptEntry(id: "a1", speaker: .claude, text: "The meeting discussed...", createdAt: Date(), isFinal: true)
        ]
        let record = makeRecord(
            meetingEntries: [TranscriptEntry(id: "1", speaker: .me, text: "test", createdAt: Date(), isFinal: true)],
            qaEntries: qa
        )
        let content = TranscriptExporter.render(record: record)

        XCTAssertTrue(content.contains("## 💬 Q&A"))
        XCTAssertTrue(content.contains("### Q: What happened?"))
        XCTAssertTrue(content.contains("The meeting discussed..."))
    }

    func test_render_noQA_noQASection() {
        let record = makeRecord(
            meetingEntries: [TranscriptEntry(id: "1", speaker: .me, text: "test", createdAt: Date(), isFinal: true)]
        )
        let content = TranscriptExporter.render(record: record)
        XCTAssertFalse(content.contains("## 💬 Q&A"))
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
