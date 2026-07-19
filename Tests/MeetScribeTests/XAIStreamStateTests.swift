import XCTest
@testable import MeetScribeCore

/// XAIStreamState の「1発話=1エントリ」正規化ロジックの検証。
/// 重複文字起こしバグの根本原因 (チャンク確定と発話確定が別エントリになる) が
/// 再発しないことを保証する。
final class XAIStreamStateTests: XCTestCase {

    private func makeIdFactory() -> (id: () -> String, calls: () -> Int) {
        var count = 0
        return (
            id: {
                count += 1
                return "item-\(count)"
            },
            calls: { count }
        )
    }

    // (a) 1チャンク発話で1エントリのみ確定する
    func test_singleChunkUtterance_producesOneFinalizeAction() {
        var state = XAIStreamState()
        let factory = makeIdFactory()

        // interim
        let interim = state.handlePartial(text: "hel", isFinal: false, speechFinal: nil, makeItemId: factory.id)
        XCTAssertEqual(interim, .updateDisplay(itemId: "item-1", text: "hel"))

        // 発話確定 (チャンク確定を経ずに直接 speech_final が来るケース)
        let final = state.handlePartial(text: "hello world.", isFinal: true, speechFinal: true, makeItemId: factory.id)
        XCTAssertEqual(final, .finalize(itemId: "item-1", text: "hello world."))
        XCTAssertEqual(factory.calls(), 1, "同一発話内でitem IDが複数回生成されてはいけない")

        // 確定後は次のpendingが残っていない
        XCTAssertNil(state.takePending())
    }

    // (b) 複数チャンク発話で縫い合わせ全文が1エントリだけ確定する
    func test_multiChunkUtterance_finalizesOnlyOnceWithStitchedText() {
        var state = XAIStreamState()
        let factory = makeIdFactory()

        // チャンク1: interim → チャンク確定 (speech_final=false)
        _ = state.handlePartial(text: "hello", isFinal: false, speechFinal: nil, makeItemId: factory.id)
        let chunk1Final = state.handlePartial(text: "hello world", isFinal: true, speechFinal: false, makeItemId: factory.id)
        // チャンク確定は表示更新のみで、確定(finalize)ではない → 重複防止の核心
        XCTAssertEqual(chunk1Final, .updateDisplay(itemId: "item-1", text: "hello world"))

        // チャンク2: interim → 発話確定 (speech_final=true, 縫い合わせ全文)
        let interim2 = state.handlePartial(text: "how", isFinal: false, speechFinal: nil, makeItemId: factory.id)
        XCTAssertEqual(interim2, .updateDisplay(itemId: "item-1", text: "hello worldhow"))

        let speechFinal = state.handlePartial(
            text: "Hello world, how are you?",
            isFinal: true,
            speechFinal: true,
            makeItemId: factory.id
        )
        XCTAssertEqual(speechFinal, .finalize(itemId: "item-1", text: "Hello world, how are you?"))
        XCTAssertEqual(factory.calls(), 1, "発話全体を通してitem IDは1つだけ")
    }

    // (c) done時にpendingの発話が1回だけ確定する (finalizedText + 最後のinterim)
    func test_takePending_stitchesFinalizedAndLastInterim() {
        var state = XAIStreamState()
        let factory = makeIdFactory()

        _ = state.handlePartial(text: "hello world", isFinal: true, speechFinal: false, makeItemId: factory.id)
        _ = state.handlePartial(text: "how are", isFinal: false, speechFinal: nil, makeItemId: factory.id)

        let pending = state.takePending()
        XCTAssertEqual(pending?.itemId, "item-1")
        XCTAssertEqual(pending?.text, "hello worldhow are")

        // 1回取り出したら状態はリセットされ、2回目はnil
        XCTAssertNil(state.takePending())
    }

    func test_takePending_emptyState_returnsNil() {
        var state = XAIStreamState()
        XCTAssertNil(state.takePending())
    }

    func test_takePending_onlyFinalizedText_noTrailingInterim() {
        var state = XAIStreamState()
        let factory = makeIdFactory()
        _ = state.handlePartial(text: "hello", isFinal: true, speechFinal: false, makeItemId: factory.id)

        let pending = state.takePending()
        XCTAssertEqual(pending?.text, "hello")
    }

    // (d) speech_finalキー欠落時 (nil) は is_final=true をそのまま発話確定として扱う
    // フォールバック
    func test_missingSpeechFinalKey_fallsBackToIsFinalAsUtteranceEnd() {
        var state = XAIStreamState()
        let factory = makeIdFactory()

        let action = state.handlePartial(text: "hello world", isFinal: true, speechFinal: nil, makeItemId: factory.id)
        XCTAssertEqual(action, .finalize(itemId: "item-1", text: "hello world"))
        // 確定済みなので内部状態もリセットされている
        XCTAssertNil(state.takePending())
    }

    // (e) 再接続後のID衝突なし: makeItemId が呼ばれるのは新しい発話の開始時のみで、
    // クロージャの実装 (呼び出し元でインスタンス固有タグを埋め込む) に一意性を委譲できる
    func test_newUtteranceAfterFinalize_requestsFreshItemId() {
        var state = XAIStreamState()
        var generated: [String] = []
        let makeId: () -> String = {
            let id = "item-\(generated.count + 1)"
            generated.append(id)
            return id
        }

        _ = state.handlePartial(text: "first", isFinal: true, speechFinal: true, makeItemId: makeId)
        _ = state.handlePartial(text: "second", isFinal: true, speechFinal: true, makeItemId: makeId)

        XCTAssertEqual(generated, ["item-1", "item-2"], "発話ごとに新しいitem IDがリクエストされる")
    }

    // interim中は同じitem IDが使い続けられる (アイテムが分裂しない)
    func test_interimEvents_reuseSameItemId() {
        var state = XAIStreamState()
        let factory = makeIdFactory()

        _ = state.handlePartial(text: "a", isFinal: false, speechFinal: nil, makeItemId: factory.id)
        _ = state.handlePartial(text: "ab", isFinal: false, speechFinal: nil, makeItemId: factory.id)
        _ = state.handlePartial(text: "abc", isFinal: false, speechFinal: nil, makeItemId: factory.id)

        XCTAssertEqual(factory.calls(), 1)
    }

    // MARK: - 強制確定 (施策C: 長発話の強制確定)

    // (f) 発話開始から15秒経過したチャンク確定時点で強制確定される
    func test_forceFinalize_triggersAfterElapsedSeconds() {
        var state = XAIStreamState()
        let factory = makeIdFactory()
        let start = Date(timeIntervalSince1970: 1_000_000)

        // 発話開始 (interimで開始時刻が記録される)
        _ = state.handlePartial(text: "long lecture", isFinal: false, speechFinal: nil, now: start, makeItemId: factory.id)

        // 16秒後のチャンク確定 (チャンクのtextは自己完結しており前のinterimには連結しない。
        // 文字数は閾値未満だが経過時間が15秒を超える) → 強制確定がトリガーされる
        let action = state.handlePartial(
            text: "long lecture continues",
            isFinal: true,
            speechFinal: false,
            now: start.addingTimeInterval(16),
            makeItemId: factory.id
        )
        XCTAssertEqual(action, .finalize(itemId: "item-1", text: "long lecture continues"))
    }

    // (g) 累積150文字を超えたチャンク確定時点で強制確定される
    func test_forceFinalize_triggersAfterCharCountExceeded() {
        var state = XAIStreamState()
        let factory = makeIdFactory()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let longText = String(repeating: "a", count: 151)

        let action = state.handlePartial(
            text: longText,
            isFinal: true,
            speechFinal: false,
            now: start,
            makeItemId: factory.id
        )
        XCTAssertEqual(action, .finalize(itemId: "item-1", text: longText))
    }

    // (h) 時間・文字数いずれの閾値も超えなければ強制確定されない (従来動作維持)
    func test_forceFinalize_doesNotTriggerBeforeThresholds() {
        var state = XAIStreamState()
        let factory = makeIdFactory()
        let start = Date(timeIntervalSince1970: 1_000_000)

        _ = state.handlePartial(text: "short", isFinal: false, speechFinal: nil, now: start, makeItemId: factory.id)
        let action = state.handlePartial(
            text: "short chunk",
            isFinal: true,
            speechFinal: false,
            now: start.addingTimeInterval(5),
            makeItemId: factory.id
        )
        XCTAssertEqual(action, .updateDisplay(itemId: "item-1", text: "short chunk"))
    }

    // (i) 【最重要】強制確定後にspeech_final(発話全体の縫い合わせ全文)が届いても
    // 強制確定済み部分と重複しない: チャンク3つ→強制確定→チャンク2つ→speech_final
    // → エントリ2つ、内容重複なし
    func test_forceFinalize_followedBySpeechFinal_doesNotDuplicateContent() {
        var state = XAIStreamState()
        let factory = makeIdFactory()
        let start = Date(timeIntervalSince1970: 1_000_000)

        // チャンク1〜3 (3つ目で累積文字数が150を超え強制確定がトリガーされる)
        _ = state.handlePartial(text: "c1", isFinal: false, speechFinal: nil, now: start, makeItemId: factory.id)
        _ = state.handlePartial(
            text: String(repeating: "x", count: 60), isFinal: true, speechFinal: false, now: start, makeItemId: factory.id
        )
        _ = state.handlePartial(
            text: String(repeating: "y", count: 60), isFinal: true, speechFinal: false, now: start, makeItemId: factory.id
        )
        let forced = state.handlePartial(
            text: String(repeating: "z", count: 60), isFinal: true, speechFinal: false, now: start, makeItemId: factory.id
        )

        guard case .finalize(let firstId, let firstText) = forced else {
            return XCTFail("累積180文字 > 150文字のため強制確定が発生するはず")
        }
        XCTAssertEqual(firstId, "item-1")
        XCTAssertEqual(firstText.count, 180)

        // 強制確定後: チャンク2つ (新エントリ item-2 として蓄積される)
        _ = state.handlePartial(text: "c4", isFinal: true, speechFinal: false, now: start, makeItemId: factory.id)
        _ = state.handlePartial(text: "c5", isFinal: true, speechFinal: false, now: start, makeItemId: factory.id)
        XCTAssertEqual(factory.calls(), 2, "強制確定後は新しいitem IDがリクエストされる")

        // speech_final: サーバーは発話全体 (強制確定済み部分含む) を縫い合わせた全文を送ってくる
        let fullStitch = firstText + "c4c5"
        let finalAction = state.handlePartial(
            text: fullStitch, isFinal: true, speechFinal: true, now: start, makeItemId: factory.id
        )

        XCTAssertEqual(
            finalAction, .finalize(itemId: "item-2", text: "c4c5"),
            "強制確定済み部分(item-1)と重複せず、強制確定後の累積分だけがitem-2として確定する"
        )
    }

    // (j) 強制確定なしで完結する発話は従来通り speech_final の縫い合わせ全文をそのまま使う
    func test_noForceFinalize_speechFinalUsesServerStitchedTextAsIs() {
        var state = XAIStreamState()
        let factory = makeIdFactory()
        let start = Date(timeIntervalSince1970: 1_000_000)

        _ = state.handlePartial(text: "hi", isFinal: true, speechFinal: false, now: start, makeItemId: factory.id)
        let action = state.handlePartial(
            text: "Hi there, how are you?",
            isFinal: true,
            speechFinal: true,
            now: start.addingTimeInterval(1),
            makeItemId: factory.id
        )
        XCTAssertEqual(action, .finalize(itemId: "item-1", text: "Hi there, how are you?"))
    }
}
