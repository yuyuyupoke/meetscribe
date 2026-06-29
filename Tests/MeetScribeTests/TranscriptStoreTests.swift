import XCTest
@testable import MeetScribeCore

@MainActor
final class TranscriptStoreTests: XCTestCase {

    var store: TranscriptStore!

    override func setUp() {
        super.setUp()
        store = TranscriptStore.shared
        store.clear()
    }

    override func tearDown() {
        store.clear()
        store = nil
        super.tearDown()
    }

    // MARK: - appendDelta

    func test_appendDelta_newItem_createsEntry() {
        store.appendDelta("Hello", itemId: "item-1", speaker: .me)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].id, "item-1")
        XCTAssertEqual(store.entries[0].text, "Hello")
        XCTAssertEqual(store.entries[0].speaker, .me)
        XCTAssertFalse(store.entries[0].isFinal)
    }

    func test_appendDelta_existingItem_appendsText() {
        store.appendDelta("Hel", itemId: "item-1", speaker: .me)
        store.appendDelta("lo", itemId: "item-1", speaker: .me)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "Hello")
    }

    func test_appendDelta_differentItems_createsSeparateEntries() {
        store.appendDelta("こんにちは", itemId: "item-1", speaker: .me)
        store.appendDelta("はい", itemId: "item-2", speaker: .other)

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries[0].speaker, .me)
        XCTAssertEqual(store.entries[1].speaker, .other)
    }

    // MARK: - completeItem

    func test_completeItem_existingItem_overwritesText() {
        store.appendDelta("partial", itemId: "item-1", speaker: .me)
        store.completeItem(itemId: "item-1", finalText: "complete text", speaker: .me)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "complete text")
        XCTAssertTrue(store.entries[0].isFinal)
    }

    func test_completeItem_nonExistingItem_createsNewEntry() {
        store.completeItem(itemId: "item-new", finalText: "brand new", speaker: .other)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].id, "item-new")
        XCTAssertEqual(store.entries[0].text, "brand new")
        XCTAssertTrue(store.entries[0].isFinal)
    }

    func test_completeItem_setsIsFinalTrue() {
        store.appendDelta("delta", itemId: "item-1", speaker: .me)
        XCTAssertFalse(store.entries[0].isFinal)

        store.completeItem(itemId: "item-1", finalText: "final", speaker: .me)
        XCTAssertTrue(store.entries[0].isFinal)
    }

    // MARK: - meetingEntries / qaEntries filters

    func test_meetingEntries_onlyMeAndOther() {
        store.appendDelta("me", itemId: "1", speaker: .me)
        store.appendDelta("other", itemId: "2", speaker: .other)
        store.addUserQuery("question")
        let _ = store.startClaudeAnswer()

        XCTAssertEqual(store.meetingEntries.count, 2)
        XCTAssertTrue(store.meetingEntries.allSatisfy { $0.speaker == .me || $0.speaker == .other })
    }

    func test_qaEntries_onlyUserAndClaude() {
        store.appendDelta("me", itemId: "1", speaker: .me)
        store.addUserQuery("question")
        let answerId = store.startClaudeAnswer()
        store.appendToAnswer(itemId: answerId, chunk: "answer")

        XCTAssertEqual(store.qaEntries.count, 2)
        XCTAssertTrue(store.qaEntries.allSatisfy { $0.speaker == .user || $0.speaker == .claude })
    }

    // MARK: - clear

    func test_clear_removesAllEntries() {
        store.appendDelta("a", itemId: "1", speaker: .me)
        store.appendDelta("b", itemId: "2", speaker: .other)
        store.addUserQuery("q")
        XCTAssertFalse(store.entries.isEmpty)

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Q&A operations

    func test_addUserQuery_createsEntryWithCorrectSpeaker() {
        let id = store.addUserQuery("What is this?")

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(id.hasPrefix("qa-user-"))
        XCTAssertEqual(store.entries[0].speaker, .user)
        XCTAssertEqual(store.entries[0].text, "What is this?")
        XCTAssertTrue(store.entries[0].isFinal)
    }

    func test_startClaudeAnswer_createsEmptyEntry() {
        let id = store.startClaudeAnswer()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(id.hasPrefix("qa-claude-"))
        XCTAssertEqual(store.entries[0].speaker, .claude)
        XCTAssertEqual(store.entries[0].text, "")
        XCTAssertFalse(store.entries[0].isFinal)
    }

    func test_appendToAnswer_appendsChunks() {
        let id = store.startClaudeAnswer()
        store.appendToAnswer(itemId: id, chunk: "Hello ")
        store.appendToAnswer(itemId: id, chunk: "world")

        XCTAssertEqual(store.entries[0].text, "Hello world")
    }

    func test_finalizeAnswer_setsIsFinal() {
        let id = store.startClaudeAnswer()
        store.appendToAnswer(itemId: id, chunk: "done")
        XCTAssertFalse(store.entries[0].isFinal)

        store.finalizeAnswer(itemId: id)
        XCTAssertTrue(store.entries[0].isFinal)
    }

    // MARK: - meetingTranscriptText

    func test_meetingTranscriptText_formatsCorrectly() {
        store.completeItem(itemId: "1", finalText: "こんにちは", speaker: .me)
        store.completeItem(itemId: "2", finalText: "よろしく", speaker: .other)

        let text = store.meetingTranscriptText
        XCTAssertTrue(text.contains("[自分] こんにちは"))
        XCTAssertTrue(text.contains("[相手] よろしく"))
    }

    func test_meetingTranscriptText_excludesQA() {
        store.completeItem(itemId: "1", finalText: "hello", speaker: .me)
        store.addUserQuery("question")

        let text = store.meetingTranscriptText
        XCTAssertTrue(text.contains("hello"))
        XCTAssertFalse(text.contains("question"))
    }

    // MARK: - Edge cases

    func test_appendToAnswer_nonexistentId_doesNothing() {
        store.appendToAnswer(itemId: "nonexistent", chunk: "text")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_finalizeAnswer_nonexistentId_doesNothing() {
        store.finalizeAnswer(itemId: "nonexistent")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_appendDelta_emptyString_appendsEmpty() {
        store.appendDelta("", itemId: "1", speaker: .me)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "")
    }
}
