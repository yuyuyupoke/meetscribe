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

    func test_replacePartial_existingItem_replacesInsteadOfAppending() {
        store.replacePartial("Hello", itemId: "xai-1", speaker: .me)
        store.replacePartial("Hello world", itemId: "xai-1", speaker: .me)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "Hello world")
        XCTAssertFalse(store.entries[0].isFinal)
    }

    func test_replacePartial_doesNotOverwriteFinalItem() {
        store.completeItem(itemId: "xai-1", finalText: "final", speaker: .me)
        store.replacePartial("late partial", itemId: "xai-1", speaker: .me)
        XCTAssertEqual(store.entries[0].text, "final")
    }

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

    // MARK: - updateFinalText (GPT-4.1 mini 整形反映)

    func test_updateFinalText_replacesTextKeepingFinal() {
        store.completeItem(itemId: "item-1", finalText: "えーと、今日はあの、会議です", speaker: .me)
        store.updateFinalText(itemId: "item-1", text: "今日は会議です")

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "今日は会議です")
        XCTAssertTrue(store.entries[0].isFinal)
    }

    func test_updateFinalText_nonexistentId_doesNothing() {
        store.updateFinalText(itemId: "ghost", text: "text")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_updateFinalText_withTranslation_setsTranslation() {
        store.completeItem(itemId: "item-1", finalText: "Let's start.", speaker: .other)
        store.updateFinalText(itemId: "item-1", text: "Let's start.", translation: "始めましょう。")

        XCTAssertEqual(store.entries[0].text, "Let's start.")
        XCTAssertEqual(store.entries[0].translation, "始めましょう。")
    }

    func test_updateFinalText_withoutTranslation_clearsTranslation() {
        store.completeItem(itemId: "item-1", finalText: "こんにちは", speaker: .me)
        store.updateFinalText(itemId: "item-1", text: "こんにちは", translation: nil)

        XCTAssertNil(store.entries[0].translation)
    }

    // MARK: - updateTranslation (translateOnly クリーナーの反映経路)
    //
    // 整形しないモードでは**本文が STT の出力のまま残る**のが正しい挙動。
    // ここで本文に触れてしまうと「整形しない代わりに原文が改変されない」という
    // モードの前提そのものが壊れる。

    func test_updateTranslation_setsTranslationWithoutTouchingText() {
        store.completeItem(itemId: "item-1", finalText: "In my history, we did that", speaker: .other)
        store.updateTranslation(itemId: "item-1", translation: "私の経験では、それをやりました")

        XCTAssertEqual(
            store.entries[0].text,
            "In my history, we did that",
            "translateOnly では本文を書き換えてはいけない"
        )
        XCTAssertEqual(store.entries[0].translation, "私の経験では、それをやりました")
        XCTAssertTrue(store.entries[0].isFinal)
    }

    func test_updateTranslation_nonexistentId_doesNothing() {
        // kill/clear 後に遅れて届いたバッチ結果で落ちない・復活させない
        store.updateTranslation(itemId: "ghost", translation: "訳")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_updateTranslation_doesNotAffectOtherEntries() {
        store.completeItem(itemId: "item-1", finalText: "first", speaker: .me)
        store.completeItem(itemId: "item-2", finalText: "second", speaker: .other)
        store.updateTranslation(itemId: "item-2", translation: "2番目")

        XCTAssertEqual(store.entries[0].text, "first")
        XCTAssertNil(store.entries[0].translation)
        XCTAssertEqual(store.entries[1].text, "second")
        XCTAssertEqual(store.entries[1].translation, "2番目")
    }

    func test_updateTranslation_nilTranslation_keepsText() {
        store.completeItem(itemId: "item-1", finalText: "こんにちは", speaker: .me)
        store.updateTranslation(itemId: "item-1", translation: nil)

        XCTAssertEqual(store.entries[0].text, "こんにちは")
        XCTAssertNil(store.entries[0].translation)
    }

    func test_removeItem_removesMatchingPartial() {
        store.replacePartial("hallucination", itemId: "xai-1", speaker: .other)
        store.removeItem(itemId: "xai-1")
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - meetingEntries filter

    func test_meetingEntries_onlyMeAndOther() {
        store.appendDelta("me", itemId: "1", speaker: .me)
        store.appendDelta("other", itemId: "2", speaker: .other)

        XCTAssertEqual(store.meetingEntries.count, 2)
        XCTAssertTrue(store.meetingEntries.allSatisfy { $0.speaker == .me || $0.speaker == .other })
    }

    // MARK: - clear

    func test_clear_removesAllEntries() {
        store.appendDelta("a", itemId: "1", speaker: .me)
        store.appendDelta("b", itemId: "2", speaker: .other)
        XCTAssertFalse(store.entries.isEmpty)

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - meetingTranscriptText

    func test_meetingTranscriptText_formatsCorrectly() {
        store.completeItem(itemId: "1", finalText: "こんにちは", speaker: .me)
        store.completeItem(itemId: "2", finalText: "よろしく", speaker: .other)

        let text = store.meetingTranscriptText
        XCTAssertTrue(text.contains("[自分] こんにちは"))
        XCTAssertTrue(text.contains("[相手] よろしく"))
    }

    // MARK: - Edge cases

    func test_appendDelta_emptyString_appendsEmpty() {
        store.appendDelta("", itemId: "1", speaker: .me)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "")
    }
}
