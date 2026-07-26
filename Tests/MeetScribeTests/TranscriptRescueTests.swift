import XCTest
@testable import MeetScribeCore

/// 議事録を失わないための保存まわり。
/// - 同名ファイルの上書き防止（タイトル生成が失敗すると `会議_HH-mm` が固定名になり、
///   同じ分に2件保存すると先の議事録が黙って消えていた）
/// - 保存先に書けなかったときの退避保存
final class TranscriptRescueTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meetscribe-rescue-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 上書き防止

    func test_availableURL_noCollision_returnsOriginalName() {
        let url = TranscriptExporter.availableURL(in: tempDir, filename: "会議.md")
        XCTAssertEqual(url.lastPathComponent, "会議.md")
    }

    func test_availableURL_collision_appendsSuffix() throws {
        let first = tempDir.appendingPathComponent("会議.md")
        try "one".write(to: first, atomically: true, encoding: .utf8)

        let second = TranscriptExporter.availableURL(in: tempDir, filename: "会議.md")
        XCTAssertEqual(second.lastPathComponent, "会議-2.md")
    }

    func test_availableURL_multipleCollisions_incrementsSuffix() throws {
        for name in ["会議.md", "会議-2.md", "会議-3.md"] {
            try "x".write(
                to: tempDir.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        let url = TranscriptExporter.availableURL(in: tempDir, filename: "会議.md")
        XCTAssertEqual(url.lastPathComponent, "会議-4.md")
    }

    /// 実際の save が既存ファイルを潰さないこと（回帰テスト）。
    func test_save_twiceWithSameTitle_doesNotOverwrite() throws {
        let record = makeRecord(title: "同じタイトル")

        let first = try TranscriptExporter.save(record, to: tempDir)
        let second = try TranscriptExporter.save(record, to: tempDir)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: - 退避先

    func test_rescueDirectory_isInsideApplicationSupport() {
        let path = TranscriptExporter.rescueDirectory.path
        XCTAssertTrue(
            path.hasSuffix("Library/Application Support/MeetScribe/rescue"),
            "退避先が想定外: \(path)"
        )
    }

    /// 保存先未設定でも save はエラーを投げ、退避側で拾えること。
    func test_save_withoutDirectory_throws() {
        let record = makeRecord(title: "保存先なし")
        XCTAssertThrowsError(try TranscriptExporter.save(record, to: nil))
    }

    // MARK: - Helper

    private func makeRecord(title: String) -> MeetingRecord {
        MeetingRecord(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            title: title,
            meetingEntries: [
                TranscriptEntry(
                    id: "e1",
                    speaker: .me,
                    text: "テスト発話",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                    isFinal: true
                )
            ],
            overview: nil,
            catchupCards: [],
            totalCostUSD: 0,
            model: "test-model",
            provider: .xAI,
            assistantModel: "test-chat"
        )
    }
}
