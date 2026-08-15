import Foundation

/// `TranscriptCleaner` へのセグメント単位の呼び出しをまとめてバッチ化するキュー。
///
/// 従来は確定セグメントごとに1回LLM呼び出し (57分会議で712回、system prompt
/// 337トークンを毎回再送) していた。ここでは確定セグメントをキューに溜め、
/// 「`batchSize` 件溜まる」か「最古の要素が `maxWaitSeconds` 秒経過」の
/// どちらか早い方でまとめて1回のLLM呼び出しにする。
///
/// セッション (録音) を通して1インスタンスの利用を想定 (`.shared`)。
/// mic/sys 2本の `TranscriptionClient` から並行して `enqueue` されるが、
/// actor によって直列化されるためキュー操作自体はロック不要。
actor TranscriptCleanerBatcher {
    static let shared = TranscriptCleanerBatcher()

    struct PendingItem: Sendable {
        let itemId: String
        let text: String
    }

    /// バッチ整形の実行部。本番は `TranscriptCleaner.cleanBatch` を呼ぶが、
    /// テストではネットワークを叩かずに差し替えられるようにする。
    typealias BatchRunner = @Sendable ([PendingItem], String, AIProvider) async -> [(itemId: String, result: TranscriptCleaner.Result)]?

    static let batchSize = 5

    /// 最古の要素をどれだけ待たせてよいか。
    ///
    /// **8秒から3秒に短縮した (2026-08-15)**。待ち時間が対訳表示の遅延の主因だった:
    /// 2026-08-14 の講義 (cleaner 604回) では**1バッチ平均1.52件**しか溜まっておらず、
    /// `batchSize`(5) にはまず届かず**毎回8秒タイマーで発火**していた。つまり
    /// 実質「確定 → 最大8秒 (平均4秒) 待ち → LLM 6.0秒 → 表示」で、
    /// 平均10秒・最悪14秒かかっていた。
    ///
    /// 3秒にすると呼び出し回数は約1.3倍に増えるが、入力コストの増分は小さい:
    /// system プロンプトは毎回ほぼ同じでキャッシュヒット率が実測83%あり、
    /// 増えるのは主にキャッシュ済みトークンの再送分だから。
    static let defaultMaxWaitSeconds: TimeInterval = 3

    private let runBatch: BatchRunner
    private let maxWaitSeconds: TimeInterval

    private var queue: [PendingItem] = []
    private var flushTask: Task<Void, Never>?
    /// `drainAndRun()` が spawn した実行中の drain Task。`flushAll()` はこれを
    /// 待たないと、batchSize到達等で既に発火済みの in-flight バッチの完了を
    /// 待たずに返ってしまう (会議末尾の直前セグメントが未整形のまま保存される)。
    private var inFlightDrains: [Task<Void, Never>] = []
    private var apiKey: String?
    private var provider: AIProvider?

    init(
        maxWaitSeconds: TimeInterval = TranscriptCleanerBatcher.defaultMaxWaitSeconds,
        runBatch: @escaping BatchRunner = { items, apiKey, provider in
            await TranscriptCleaner.cleanBatch(
                items.map { ($0.itemId, $0.text) },
                apiKey: apiKey,
                provider: provider
            )
        }
    ) {
        self.maxWaitSeconds = maxWaitSeconds
        self.runBatch = runBatch
    }

    /// 整形対象のセグメントをキューに追加する。
    /// `batchSize` 件溜まったら即座にflushし、そうでなければ最古の要素から
    /// `maxWaitSeconds` 秒後にflushするタイマーを (未設定なら) 張る。
    func enqueue(itemId: String, text: String, apiKey: String, provider: AIProvider) {
        self.apiKey = apiKey
        self.provider = provider
        queue.append(PendingItem(itemId: itemId, text: text))

        if queue.count >= Self.batchSize {
            flushTask?.cancel()
            flushTask = nil
            drainAndRun()
            return
        }

        guard flushTask == nil else { return }
        flushTask = Task { [weak self, maxWaitSeconds] in
            try? await Task.sleep(for: .seconds(maxWaitSeconds))
            guard !Task.isCancelled else { return }
            await self?.timedFlush()
        }
    }

    private func timedFlush() {
        flushTask = nil
        guard !queue.isEmpty else { return }
        drainAndRun()
    }

    /// セッション停止時に呼ぶ。残キューを必ずLLM呼び出しにかけて反映し、かつ
    /// 既に発火済み (batchSize到達 or タイマー) の in-flight drain の完了も待つ。
    /// in-flight を待たないと、直前の runDrained() が既に queue を空にした後に
    /// flushAll() が「空だから何もしない」と早期return してしまい、その
    /// in-flight バッチの整形結果が保存フローに反映される前に stop() が
    /// 進んでしまう (=直前最大 batchSize件が未整形のまま保存される)。
    func flushAll() async {
        flushTask?.cancel()
        flushTask = nil
        await runDrained()

        let pending = inFlightDrains
        inFlightDrains.removeAll()
        for task in pending {
            await task.value
        }
    }

    /// 緊急停止 (kill) 用。結果を保存する見込みが無いので、LLM呼び出しをせず
    /// キューを捨てる (不要な課金を避ける)。in-flight (既にLLMへ投げてしまった)
    /// 分もキャンセルする (URLSessionのasync APIはTaskキャンセルを伝播するので
    /// 実際のリクエストも中断される。無駄な課金と、次セッションのTranscriptStoreへの
    /// 誤反映を避ける)。
    func discardAll() {
        flushTask?.cancel()
        flushTask = nil
        queue.removeAll()
        for task in inFlightDrains {
            task.cancel()
        }
        inFlightDrains.removeAll()
    }

    // MARK: - Internal

    private func drainAndRun() {
        let task = Task { await self.runDrained() }
        inFlightDrains.append(task)
    }

    private func runDrained() async {
        guard !queue.isEmpty, let apiKey, let provider else { return }
        // spawn時点ではなく実行時点の queue を見るため、drainAndRun() 呼び出しから
        // このTaskが実際に走り出すまでの間に他の enqueue() が積んだ分もここに
        // 含まれ得る (actor直列化はあるがTaskスケジューリングの前後関係は保証されない)。
        // batchSize を超えないよう先頭から切り出し、残りは queue に置いたままにする
        // (残りは次の drainAndRun / タイマー / flushAll が処理する)。
        let batch = Array(queue.prefix(Self.batchSize))
        queue.removeFirst(batch.count)

        guard let results = await runBatch(batch, apiKey, provider) else {
            // バッチ全件スキップ。呼び出し元 (TranscriptionClient) が既に表示した
            // 原文がそのまま残る (= このバッチのセグメントは対訳が付かない)。
            //
            // **原因は "failed to parse" と決めつけない。** タイムアウト / HTTPエラー /
            // JSONパース失敗のどれでも nil になる。2026-08-14 にここを
            // 「パース失敗」と読んだせいで、実際はタイムアウトだった事象を
            // 誤診しかけた。内訳は `TranscriptCleaner` 側が直前の行に出す。
            DebugLog.log("[cleaner-batch] batch of \(batch.count) not applied, keeping raw text")
            return
        }
        for entry in results {
            await MainActor.run {
                if let cleaned = entry.result.cleaned {
                    TranscriptStore.shared.updateFinalText(
                        itemId: entry.itemId,
                        text: cleaned,
                        translation: entry.result.translationJa
                    )
                } else {
                    // 整形結果が無い (`translateOnly`) → **本文には触れず訳だけ反映**する。
                    // 整形されない代わりに、STT が出した原文が LLM に書き換えられない。
                    TranscriptStore.shared.updateTranslation(
                        itemId: entry.itemId,
                        translation: entry.result.translationJa
                    )
                }
            }
        }
    }
}
