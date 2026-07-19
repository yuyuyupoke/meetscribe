import XCTest
@testable import MeetScribeCore

/// TranscriptTextView の差分更新ロジック (TranscriptTextDiff) のユニットテスト。
/// AppKit を経由せず純粋関数として検証できる範囲 (diffOps / remapPosition) をカバーする。
/// renderChunk/buildAttributed/applyDiff は TranscriptTextView (NSViewRepresentable) の
/// static メンバーであり MainActor 分離が推論されるため、クラス全体を MainActor にする。
@MainActor
final class TranscriptTextDiffTests: XCTestCase {

    private func entry(
        _ id: String,
        text: String = "hello",
        isFinal: Bool = true,
        translation: String? = nil,
        speaker: SpeakerLabel = .me
    ) -> TranscriptEntry {
        TranscriptEntry(
            id: id,
            speaker: speaker,
            text: text,
            createdAt: Date(),
            isFinal: isFinal,
            translation: translation
        )
    }

    // MARK: - diffOps: 追記のみ (ストリーミングのホットパス)

    func test_diffOps_appendNewEntry_previousLastBecomesUpdate_newEntryIsInsert() {
        let old = [entry("a"), entry("b")]
        let new = [entry("a"), entry("b"), entry("c")]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )

        // "b" は old では最後 (末尾改行なし) だったが、new では最後ではなくなるため
        // レンダリング結果 (末尾の "\n" の有無) が変わる = update。 "a" は不変のまま keep。
        XCTAssertEqual(ops, [
            .keep(oldIndex: 0, newIndex: 0),
            .update(oldIndex: 1, newIndex: 1),
            .insert(newIndex: 2)
        ])
    }

    func test_diffOps_appendDeltaToLastEntry_onlyLastEntryUpdates() {
        let old = [entry("a"), entry("b", text: "Hel")]
        let new = [entry("a"), entry("b", text: "Hello")]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )

        XCTAssertEqual(ops, [
            .keep(oldIndex: 0, newIndex: 0),
            .update(oldIndex: 1, newIndex: 1)
        ])
    }

    func test_diffOps_noChange_allKeep() {
        let entries = [entry("a"), entry("b")]

        let ops = TranscriptTextDiff.diffOps(
            old: entries, new: entries, oldShowTranslations: true, newShowTranslations: true
        )

        XCTAssertEqual(ops, [
            .keep(oldIndex: 0, newIndex: 0),
            .keep(oldIndex: 1, newIndex: 1)
        ])
    }

    // MARK: - diffOps: 削除 (removeItem)

    func test_diffOps_removeMiddleEntry_producesDelete() {
        let old = [entry("a"), entry("b"), entry("c")]
        let new = [entry("a"), entry("c")]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )

        // c は old でも new でも「最後の要素」のまま (isLast 変化なし) なので keep でよい。
        XCTAssertEqual(ops, [
            .keep(oldIndex: 0, newIndex: 0),
            .delete(oldIndex: 1),
            .keep(oldIndex: 2, newIndex: 1)
        ])
    }

    func test_diffOps_removeLastEntry_previousBecomesLast() {
        let old = [entry("a"), entry("b"), entry("c")]
        let new = [entry("a"), entry("b")]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )

        XCTAssertEqual(ops, [
            .keep(oldIndex: 0, newIndex: 0),
            .update(oldIndex: 1, newIndex: 1), // b が新たに最後になる (末尾改行が消える)
            .delete(oldIndex: 2)
        ])
    }

    func test_diffOps_clearAll_producesAllDeletes() {
        let old = [entry("a"), entry("b")]
        let new: [TranscriptEntry] = []

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )

        XCTAssertEqual(ops, [.delete(oldIndex: 0), .delete(oldIndex: 1)])
    }

    // MARK: - diffOps: 内容変化の検出

    func test_diffOps_translationAdded_producesUpdate() {
        let old = [entry("a", translation: nil)]
        let new = [entry("a", translation: "hi")]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )

        XCTAssertEqual(ops, [.update(oldIndex: 0, newIndex: 0)])
    }

    func test_diffOps_translationHiddenByToggle_withNoTranslationText_staysKeep() {
        // showTranslations が変わっても、そのエントリに翻訳が無ければ見た目は変わらない
        let entries = [entry("a", translation: nil)]

        let ops = TranscriptTextDiff.diffOps(
            old: entries, new: entries, oldShowTranslations: true, newShowTranslations: false
        )

        XCTAssertEqual(ops, [.keep(oldIndex: 0, newIndex: 0)])
    }

    func test_diffOps_translationToggleOff_withTranslationText_producesUpdate() {
        let entries = [entry("a", translation: "hi")]

        let ops = TranscriptTextDiff.diffOps(
            old: entries, new: entries, oldShowTranslations: true, newShowTranslations: false
        )

        XCTAssertEqual(ops, [.update(oldIndex: 0, newIndex: 0)])
    }

    func test_diffOps_isFinalFlips_producesUpdate() {
        let old = [entry("a", isFinal: false)]
        let new = [entry("a", isFinal: true)]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )

        XCTAssertEqual(ops, [.update(oldIndex: 0, newIndex: 0)])
    }

    // MARK: - diffOps: フォールバック検知

    func test_diffOps_reorderDetected_returnsNil() {
        let old = [entry("a"), entry("b")]
        let new = [entry("b"), entry("a")]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )

        XCTAssertNil(ops)
    }

    func test_diffOps_duplicateID_returnsNil() {
        let old = [entry("a")]
        let new = [entry("a"), entry("a")]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )

        XCTAssertNil(ops)
    }

    // MARK: - remapPosition

    func test_remapPosition_noEdits_unchanged() {
        XCTAssertEqual(TranscriptTextDiff.remapPosition(10, through: []), 10)
    }

    func test_remapPosition_editAfterPosition_unaffected() {
        let edits = [TranscriptTextDiff.TextEdit(oldRange: NSRange(location: 20, length: 5), newLength: 10)]
        XCTAssertEqual(TranscriptTextDiff.remapPosition(10, through: edits), 10)
    }

    func test_remapPosition_editBeforePosition_shiftsByDelta() {
        // 位置10より前の範囲 [0,5) が長さ5→長さ8 (delta +3) に変わった -> 10 は 13 に移動
        let edits = [TranscriptTextDiff.TextEdit(oldRange: NSRange(location: 0, length: 5), newLength: 8)]
        XCTAssertEqual(TranscriptTextDiff.remapPosition(10, through: edits), 13)
    }

    func test_remapPosition_editShrinksBeforePosition_shiftsNegative() {
        let edits = [TranscriptTextDiff.TextEdit(oldRange: NSRange(location: 0, length: 10), newLength: 4)]
        XCTAssertEqual(TranscriptTextDiff.remapPosition(20, through: edits), 14)
    }

    func test_remapPosition_positionInsideEditedRange_clampsToEditStart() {
        // 位置12 は編集範囲 [10,20) の内側 -> 編集開始位置 (post-edit) にクランプ
        let edits = [TranscriptTextDiff.TextEdit(oldRange: NSRange(location: 10, length: 10), newLength: 3)]
        XCTAssertEqual(TranscriptTextDiff.remapPosition(12, through: edits), 10)
    }

    func test_remapPosition_multipleEditsBeforePosition_accumulateDelta() {
        let edits = [
            TranscriptTextDiff.TextEdit(oldRange: NSRange(location: 0, length: 5), newLength: 8),   // +3
            TranscriptTextDiff.TextEdit(oldRange: NSRange(location: 10, length: 2), newLength: 0)    // -2
        ]
        // 位置20 は両方の編集より後方 -> +3-2 = +1
        XCTAssertEqual(TranscriptTextDiff.remapPosition(20, through: edits), 21)
    }

    func test_remapPosition_insertAtPosition_shiftsPositionAfterInsertedText() {
        // 挿入 (oldRange length 0) がちょうど position の位置で起きた場合、
        // 「position の直前に挿入された」とみなして後方にずらす
        // (oldEnd(=location) <= position の分岐に入るため)
        let edits = [TranscriptTextDiff.TextEdit(oldRange: NSRange(location: 10, length: 0), newLength: 5)]
        XCTAssertEqual(TranscriptTextDiff.remapPosition(10, through: edits), 15)
    }

    // MARK: - renderChunk / buildAttributed: 見た目の regression ガード

    func test_buildAttributed_basicTwoEntries_matchesExpectedPlainText() {
        let entries = [
            entry("a", text: "Hello", speaker: .me),
            entry("b", text: "World", speaker: .other)
        ]

        let attributed = TranscriptTextView.buildAttributed(entries: entries, showTranslations: true)

        XCTAssertEqual(attributed.string, "[自分] Hello\n[相手] World")
    }

    func test_buildAttributed_withTranslation_includesTranslationLine() {
        let entries = [entry("a", text: "Hello", translation: "こんにちは")]

        let attributed = TranscriptTextView.buildAttributed(entries: entries, showTranslations: true)

        XCTAssertEqual(attributed.string, "[自分] Hello\n└ こんにちは")
    }

    func test_buildAttributed_translationHiddenByToggle_omitsTranslationLine() {
        let entries = [entry("a", text: "Hello", translation: "こんにちは")]

        let attributed = TranscriptTextView.buildAttributed(entries: entries, showTranslations: false)

        XCTAssertEqual(attributed.string, "[自分] Hello")
    }

    func test_renderChunk_isLastFalse_appendsTrailingNewline() {
        let chunk = TranscriptTextView.renderChunk(
            entry: entry("a", text: "Hi"), showTranslations: true, isLast: false
        )
        XCTAssertEqual(chunk.string, "[自分] Hi\n")
    }

    func test_renderChunk_isLastTrue_omitsTrailingNewline() {
        let chunk = TranscriptTextView.renderChunk(
            entry: entry("a", text: "Hi"), showTranslations: true, isLast: true
        )
        XCTAssertEqual(chunk.string, "[自分] Hi")
    }

    // MARK: - applyDiff: textStorage への実適用結果の検証

    func test_applyDiff_appendEntry_resultMatchesFullRebuild() {
        let old = [entry("a", text: "Hello")]
        let new = [entry("a", text: "Hello"), entry("b", text: "World", speaker: .other)]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )!

        let storage = NSTextStorage(attributedString: TranscriptTextView.buildAttributed(
            entries: old, showTranslations: true
        ))
        _ = TranscriptTextView.applyDiff(
            ops, old: old, new: new,
            oldShowTranslations: true, newShowTranslations: true,
            textStorage: storage
        )

        let expected = TranscriptTextView.buildAttributed(entries: new, showTranslations: true)
        XCTAssertEqual(storage.string, expected.string)
    }

    func test_applyDiff_updateMiddleEntry_selectionAfterEditRemapsCorrectly() {
        let old = [entry("a", text: "Hi"), entry("b", text: "short"), entry("c", text: "tail")]
        let new = [entry("a", text: "Hi"), entry("b", text: "much longer text"), entry("c", text: "tail")]

        let ops = TranscriptTextDiff.diffOps(
            old: old, new: new, oldShowTranslations: true, newShowTranslations: true
        )!
        let storage = NSTextStorage(attributedString: TranscriptTextView.buildAttributed(
            entries: old, showTranslations: true
        ))
        let edits = TranscriptTextView.applyDiff(
            ops, old: old, new: new,
            oldShowTranslations: true, newShowTranslations: true,
            textStorage: storage
        )

        // "tail" (old の末尾 "c" エントリ本文) の開始位置を求め、編集後も同じ文字列を指すか検証
        let oldFull = TranscriptTextView.buildAttributed(entries: old, showTranslations: true).string
        let oldTailStart = (oldFull as NSString).range(of: "tail").location

        let remapped = TranscriptTextDiff.remapPosition(oldTailStart, through: edits)

        let newFull = storage.string as NSString
        XCTAssertEqual(newFull.substring(with: NSRange(location: remapped, length: 4)), "tail")
    }
}
