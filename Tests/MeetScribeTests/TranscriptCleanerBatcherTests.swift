import XCTest
@testable import MeetScribeCore

/// テスト内で並行アクセスされるカウンタ/値の受け皿。runBatch モックの呼び出し
/// 回数・引数を actor で直列化して安全に検証するためのヘルパー。
private actor Recorder<T: Sendable> {
    private(set) var callCount = 0
    private(set) var lastArgument: T?

    func record(_ value: T) {
        callCount += 1
        lastArgument = value
    }
}

/// runBatch モック内で「ネットワーク呼び出し中」を模擬してブロックするための
/// 手動ゲート。テストが `open()` するまで `wait()` した側は再開しない。
private actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// バッチサイズの上限クランプ検証用: runBatch に渡されたバッチサイズの最大値と
/// 処理済み総アイテム数を集計する。
private actor SizeRecorder {
    private(set) var maxBatchSize = 0
    private(set) var totalItems = 0

    func record(_ count: Int) {
        maxBatchSize = max(maxBatchSize, count)
        totalItems += count
    }
}

final class TranscriptCleanerBatcherTests: XCTestCase {

    // MARK: - 待ち時間の既定値
    //
    // 2026-08-14 の講義 (cleaner 604回) の実測: **1バッチ平均1.52件**しか溜まらず、
    // batchSize(5) にはまず届かないので**毎回タイマーで発火**していた。つまり
    // 待ち時間がそのまま対訳表示の遅延になる (旧8秒: 確定→最大8秒待ち→LLM 6.0秒→表示で
    // 平均10秒・最悪14秒)。ここを緩めると遅延が戻るので数値ごと固定する。

    func test_defaultMaxWaitSeconds_isThreeSeconds() {
        XCTAssertEqual(TranscriptCleanerBatcher.defaultMaxWaitSeconds, 3)
    }

    /// 旧値(8秒)より短いこと。呼び出し回数は約1.3倍に増えるが、system プロンプトの
    /// キャッシュヒット率が実測83%あるため入力コストの増分は小さい。
    func test_defaultMaxWaitSeconds_isShorterThanPreviousValue() {
        XCTAssertLessThan(TranscriptCleanerBatcher.defaultMaxWaitSeconds, 8)
        XCTAssertGreaterThan(
            TranscriptCleanerBatcher.defaultMaxWaitSeconds, 0,
            "0以下だとバッチ化そのものが無効になる"
        )
    }

    // MARK: - トリガー条件: batchSize件で即flush

    func test_enqueue_belowBatchSize_doesNotFlushYet() async {
        let recorder = Recorder<[TranscriptCleanerBatcher.PendingItem]>()
        // maxWaitSeconds を長くして、時間トリガーで誤って発火しないようにする。
        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, _, _ in
            await recorder.record(items)
            return items.map { ($0.itemId, TranscriptCleaner.Result(cleaned: $0.text, translationJa: nil)) }
        }

        for i in 0..<(TranscriptCleanerBatcher.batchSize - 1) {
            await batcher.enqueue(itemId: "id-\(i)", text: "text \(i)", apiKey: "k", provider: .openAI)
        }
        try? await Task.sleep(for: .milliseconds(100))

        let count = await recorder.callCount
        XCTAssertEqual(count, 0, "batchSize 未満なら runBatch はまだ呼ばれない")
    }

    func test_enqueue_reachingBatchSize_flushesImmediately() async {
        let recorder = Recorder<[TranscriptCleanerBatcher.PendingItem]>()
        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, apiKey, provider in
            await recorder.record(items)
            XCTAssertEqual(apiKey, "k")
            XCTAssertEqual(provider, .openAI)
            return items.map { ($0.itemId, TranscriptCleaner.Result(cleaned: $0.text, translationJa: nil)) }
        }

        for i in 0..<TranscriptCleanerBatcher.batchSize {
            await batcher.enqueue(itemId: "id-\(i)", text: "text \(i)", apiKey: "k", provider: .openAI)
        }
        // enqueue が batchSize 到達時に投げる Task の完了を少し待つ。
        try? await Task.sleep(for: .milliseconds(150))

        let count = await recorder.callCount
        let items = await recorder.lastArgument
        XCTAssertEqual(count, 1, "batchSize 件目で即flushされるべき")
        XCTAssertEqual(items?.count, TranscriptCleanerBatcher.batchSize)
    }

    // MARK: - トリガー条件: 最古の要素から maxWaitSeconds 経過で flush

    func test_enqueue_belowBatchSize_flushesAfterMaxWaitSeconds() async {
        let recorder = Recorder<[TranscriptCleanerBatcher.PendingItem]>()
        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 0.05) { items, _, _ in
            await recorder.record(items)
            return nil
        }

        await batcher.enqueue(itemId: "only", text: "text", apiKey: "k", provider: .openAI)
        var count = await recorder.callCount
        XCTAssertEqual(count, 0, "maxWaitSeconds 経過前はflushされない")

        try? await Task.sleep(for: .milliseconds(200))
        count = await recorder.callCount
        XCTAssertEqual(count, 1, "maxWaitSeconds 経過後は残り1件でもflushされる")
    }

    // MARK: - flushAll (stop() 経路)

    func test_flushAll_flushesPartialQueueImmediately() async {
        let recorder = Recorder<[TranscriptCleanerBatcher.PendingItem]>()
        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, _, _ in
            await recorder.record(items)
            return items.map { ($0.itemId, TranscriptCleaner.Result(cleaned: $0.text, translationJa: nil)) }
        }

        await batcher.enqueue(itemId: "a", text: "text a", apiKey: "k", provider: .openAI)
        await batcher.enqueue(itemId: "b", text: "text b", apiKey: "k", provider: .openAI)

        await batcher.flushAll()

        let count = await recorder.callCount
        let items = await recorder.lastArgument
        XCTAssertEqual(count, 1)
        XCTAssertEqual(items?.count, 2)
    }

    func test_flushAll_onEmptyQueue_doesNotCallRunBatch() async {
        let recorder = Recorder<[TranscriptCleanerBatcher.PendingItem]>()
        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, _, _ in
            await recorder.record(items)
            return nil
        }

        await batcher.flushAll()

        let count = await recorder.callCount
        XCTAssertEqual(count, 0)
    }

    func test_flushAll_cancelsPendingTimedFlush() async {
        // flushAll が先に処理してしまえば、後から発火するはずだった時間トリガーは
        // 空キューに対して何もしない (二重実行にならない)。
        let recorder = Recorder<[TranscriptCleanerBatcher.PendingItem]>()
        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 0.05) { items, _, _ in
            await recorder.record(items)
            return items.map { ($0.itemId, TranscriptCleaner.Result(cleaned: $0.text, translationJa: nil)) }
        }

        await batcher.enqueue(itemId: "a", text: "text a", apiKey: "k", provider: .openAI)
        await batcher.flushAll()

        // maxWaitSeconds 経過を待っても、キューは既に空なので追加のflushは起きない。
        try? await Task.sleep(for: .milliseconds(150))

        let count = await recorder.callCount
        XCTAssertEqual(count, 1, "flushAll後にタイマーが二重発火してはいけない")
    }

    // MARK: - flushAll × in-flight drain のレース (レビュー指摘の回帰テスト)
    //
    // 修正前の実装は drainAndRun() が spawn した Task の完了を追跡していなかった。
    // batchSize到達で先発した drain が「queue.removeAll() → await runBatch (ネットワーク)」
    // の途中 (queueは既に空) で flushAll() が呼ばれると、flushAll は
    // 「queueが空だから何もしない」と即returnし、in-flight の整形結果を待たずに
    // stop() の保存フローへ進んでしまっていた (=会議末尾最大batchSize件が未整形で保存)。

    func test_flushAll_awaitsInFlightDrainTriggeredByBatchSize() async {
        let gate = Gate()
        let itemId = "batcher-race-\(UUID().uuidString)"
        await MainActor.run {
            TranscriptStore.shared.completeItem(itemId: itemId, finalText: "元のテキスト", speaker: .me)
        }

        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, _, _ in
            await gate.wait() // ネットワーク呼び出し中を模擬してブロックし続ける
            return items.map { ($0.itemId, TranscriptCleaner.Result(cleaned: "整形済み", translationJa: nil)) }
        }

        // batchSize件目の enqueue で drainAndRun() が即座に spawn される
        // (= in-flight になり、gate.wait() でブロックされる)。
        for i in 0..<(TranscriptCleanerBatcher.batchSize - 1) {
            await batcher.enqueue(itemId: "filler-\(i)", text: "filler", apiKey: "k", provider: .openAI)
        }
        await batcher.enqueue(itemId: itemId, text: "元のテキスト", apiKey: "k", provider: .openAI)

        // in-flight drain が gate で止まっている間に flushAll を呼ぶ。
        // 修正前はここで queue が既に空なので flushAll が即座に返ってしまう。
        let flushTask = Task { await batcher.flushAll() }

        // drain Task が runBatch (= gate.wait()) に到達するのを少し待ってから解放する。
        try? await Task.sleep(for: .milliseconds(100))
        await gate.open()
        await flushTask.value

        let text = await MainActor.run {
            TranscriptStore.shared.entries.first { $0.id == itemId }?.text
        }
        XCTAssertEqual(text, "整形済み", "flushAllはbatchSize到達で先発した in-flight バッチの完了も待つべき")
    }

    // MARK: - バッチサイズの上限クランプ (レビュー推奨事項)
    //
    // enqueue() から drainAndRun() が spawn した Task が実際に走り出す前に、
    // 別の enqueue() がさらに積むと queue.count が batchSize を超えうる。
    // runDrained() は先頭 batchSize 件だけを切り出すべきで、1回の runBatch 呼び出しが
    // batchSize を超えてはいけない (残りは次の drain が処理し、取りこぼしも無い)。

    func test_concurrentEnqueue_neverExceedsBatchSizePerRunBatchCall() async {
        let sizeRecorder = SizeRecorder()
        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, _, _ in
            await sizeRecorder.record(items.count)
            return items.map { ($0.itemId, TranscriptCleaner.Result(cleaned: $0.text, translationJa: nil)) }
        }

        let totalItems = TranscriptCleanerBatcher.batchSize * 6
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<totalItems {
                group.addTask {
                    await batcher.enqueue(itemId: "id-\(i)", text: "t\(i)", apiKey: "k", provider: .openAI)
                }
            }
        }
        // 並行enqueue完了時点でまだ走っているだろう in-flight drain と、
        // batchSize未満で残っている分をまとめて処理する。
        await batcher.flushAll()

        let maxSize = await sizeRecorder.maxBatchSize
        let total = await sizeRecorder.totalItems
        XCTAssertLessThanOrEqual(maxSize, TranscriptCleanerBatcher.batchSize, "1回のrunBatch呼び出しはbatchSizeを超えてはいけない")
        XCTAssertEqual(total, totalItems, "並行enqueueでも全アイテムが最終的に処理されるべき (取りこぼしなし)")
    }

    // MARK: - discardAll (kill() 経路: 課金なしで破棄)

    func test_discardAll_neverCallsRunBatch() async {
        let recorder = Recorder<[TranscriptCleanerBatcher.PendingItem]>()
        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 0.05) { items, _, _ in
            await recorder.record(items)
            return nil
        }

        await batcher.enqueue(itemId: "a", text: "text a", apiKey: "k", provider: .openAI)
        await batcher.discardAll()

        // 元は0.05秒後にタイマーfireするはずだったが、discardAllでキャンセルされている。
        try? await Task.sleep(for: .milliseconds(150))

        let count = await recorder.callCount
        XCTAssertEqual(count, 0, "discardAll後はLLM呼び出しが一切発生してはいけない (課金防止)")
    }

    // MARK: - パース失敗フォールバック (バッチ全件スキップ、原文維持)

    func test_runBatchReturnsNil_doesNotUpdateTranscriptStore() async {
        let itemId = "batcher-test-\(UUID().uuidString)"
        await MainActor.run {
            TranscriptStore.shared.completeItem(itemId: itemId, finalText: "元のテキスト", speaker: .me)
        }

        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { _, _, _ in
            nil // パース失敗を模擬
        }
        await batcher.enqueue(itemId: itemId, text: "元のテキスト", apiKey: "k", provider: .openAI)
        await batcher.flushAll()

        let text = await MainActor.run {
            TranscriptStore.shared.entries.first { $0.id == itemId }?.text
        }
        XCTAssertEqual(text, "元のテキスト", "パース失敗時は原文を維持する (整形結果を書き込まない)")
    }

    // MARK: - 成功時: TranscriptStore へ反映される

    func test_successfulBatch_updatesTranscriptStoreForEachItem() async {
        let itemId = "batcher-test-\(UUID().uuidString)"
        await MainActor.run {
            TranscriptStore.shared.completeItem(itemId: itemId, finalText: "えーと、今日は会議です", speaker: .me)
        }

        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, _, _ in
            items.map { ($0.itemId, TranscriptCleaner.Result(cleaned: "今日は会議です", translationJa: nil)) }
        }
        await batcher.enqueue(itemId: itemId, text: "えーと、今日は会議です", apiKey: "k", provider: .openAI)
        await batcher.flushAll()

        let text = await MainActor.run {
            TranscriptStore.shared.entries.first { $0.id == itemId }?.text
        }
        XCTAssertEqual(text, "今日は会議です")
    }

    // MARK: - translateOnly: cleaned が nil のとき本文に触れない
    //
    // `cleaned == nil` が「整形結果は無い = 本文を書き換えるな」の合図。
    // ここで updateFinalText を呼ぶと訳と一緒に本文まで書き換わり、
    // 整形なしモードの前提 (原文が STT の出力のまま残る) が壊れる。

    func test_nilCleaned_appliesTranslationWithoutChangingText() async {
        let itemId = "batcher-translate-\(UUID().uuidString)"
        let raw = "In my history, we did that"
        await MainActor.run {
            TranscriptStore.shared.completeItem(itemId: itemId, finalText: raw, speaker: .other)
        }

        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, _, _ in
            items.map {
                ($0.itemId, TranscriptCleaner.Result(cleaned: nil, translationJa: "私の経験では、それをやりました"))
            }
        }
        await batcher.enqueue(itemId: itemId, text: raw, apiKey: "k", provider: .openAI)
        await batcher.flushAll()

        let entry = await MainActor.run {
            TranscriptStore.shared.entries.first { $0.id == itemId }
        }
        XCTAssertEqual(entry?.text, raw, "translateOnly では原文がそのまま残るべき")
        XCTAssertEqual(entry?.translation, "私の経験では、それをやりました")
    }

    /// 既に付いている訳は上書きできる (再整形・遅延到着の後勝ち) が、本文は動かない。
    func test_nilCleaned_doesNotClearExistingTextEvenWithNilTranslation() async {
        let itemId = "batcher-translate-nil-\(UUID().uuidString)"
        await MainActor.run {
            TranscriptStore.shared.completeItem(itemId: itemId, finalText: "今日は会議です", speaker: .me)
        }

        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, _, _ in
            items.map { ($0.itemId, TranscriptCleaner.Result(cleaned: nil, translationJa: nil)) }
        }
        await batcher.enqueue(itemId: itemId, text: "今日は会議です", apiKey: "k", provider: .openAI)
        await batcher.flushAll()

        let entry = await MainActor.run {
            TranscriptStore.shared.entries.first { $0.id == itemId }
        }
        XCTAssertEqual(entry?.text, "今日は会議です")
        XCTAssertNil(entry?.translation)
    }

    /// 同じバッチに整形あり (cleaned) と整形なし (nil) が混ざっても、それぞれ正しく分岐する。
    func test_mixedResults_applyPerItemBranch() async {
        let formatted = "batcher-mixed-formatted-\(UUID().uuidString)"
        let translated = "batcher-mixed-translated-\(UUID().uuidString)"
        await MainActor.run {
            TranscriptStore.shared.completeItem(itemId: formatted, finalText: "えーと、今日は会議です", speaker: .me)
            TranscriptStore.shared.completeItem(itemId: translated, finalText: "Let's start.", speaker: .other)
        }

        let batcher = TranscriptCleanerBatcher(maxWaitSeconds: 60) { items, _, _ in
            items.map { item in
                item.itemId == formatted
                    ? (item.itemId, TranscriptCleaner.Result(cleaned: "今日は会議です", translationJa: nil))
                    : (item.itemId, TranscriptCleaner.Result(cleaned: nil, translationJa: "始めましょう。"))
            }
        }
        await batcher.enqueue(itemId: formatted, text: "えーと、今日は会議です", apiKey: "k", provider: .openAI)
        await batcher.enqueue(itemId: translated, text: "Let's start.", apiKey: "k", provider: .openAI)
        await batcher.flushAll()

        let entries = await MainActor.run {
            (
                TranscriptStore.shared.entries.first { $0.id == formatted },
                TranscriptStore.shared.entries.first { $0.id == translated }
            )
        }
        XCTAssertEqual(entries.0?.text, "今日は会議です")
        XCTAssertEqual(entries.1?.text, "Let's start.", "整形なしの要素は本文が原文のまま")
        XCTAssertEqual(entries.1?.translation, "始めましょう。")
    }
}
