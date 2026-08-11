import Foundation

/// 確定した文字起こしセグメントを選択中プロバイダーで「整形 + 対訳」するクリーナー。
/// - 整形: フィラー (「えー」「あの」"um" 等) の除去と言い直しの統合のみ。内容・言語は変えない
/// - 対訳: 原文が日本語以外のとき、日本語訳を同時生成する (追加API呼び出しなし)
/// 失敗時は nil を返し、呼び出し側は原文を維持する。
enum TranscriptCleaner {

    struct Result: Equatable, Sendable {
        let cleaned: String
        /// 原文が日本語以外の場合のみ。日本語原文なら nil
        let translationJa: String?
    }

    private static let systemPrompt = """
    あなたは会議・講義の文字起こし整形担当。入力された文字起こしセグメント1つを処理し、JSONで返す。

    整形ルール:
    - フィラー（「えー」「あー」「あの」「その」「なんか」、"um"、"uh"、"you know" 等）を除去
    - 言い間違い・言い直しは、最終的に言いたかった内容に統合
    - 明らかな誤変換・誤認識は文脈から自然に修正
    - 意味・情報・言語は変えない。要約しない。内容を追加しない
    - 修正の必要がなければ入力をそのまま cleaned に入れる

    対訳ルール:
    - 原文が日本語以外（英語等）の場合のみ、整形後テキストの自然な日本語訳を translation_ja に入れる
    - 原文が日本語なら translation_ja は null

    出力形式 (JSONのみ):
    {"cleaned": "整形後テキスト", "translation_ja": "日本語訳 または null"}
    """

    /// 整形に回すべきか。ごく短いセグメントは整形の価値がなく、
    /// LLM が過剰修正するリスクの方が高いので除外する。
    static func shouldClean(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
    }

    /// セグメントを整形・対訳して返す。API エラー・タイムアウト・空応答は nil。
    /// 消費トークンのコストは AppState.totalCostUSD に加算する。
    static func clean(
        _ text: String,
        apiKey: String,
        provider: AIProvider = .openAI
    ) async -> Result? {
        let (content, costUSD) = await OpenAIChatClient.complete(
            system: systemPrompt,
            user: text,
            apiKey: apiKey,
            provider: provider,
            timeout: 15,
            forceJSON: true,
            cacheKey: PromptCacheKey.cleanerSingle,
            usageLabel: "cleaner-single"
        )
        if costUSD > 0 {
            await MainActor.run { AppState.shared.addCost(costUSD) }
        }
        guard let content else { return nil }
        return parseCleanResult(content)
    }

    /// LLM の JSON 応答をパースする純関数。cleaned が空・形式不正なら nil。
    static func parseCleanResult(_ content: String) -> Result? {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cleaned = (obj["cleaned"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        let translation = (obj["translation_ja"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            cleaned: cleaned,
            translationJa: (translation?.isEmpty ?? true) ? nil : translation
        )
    }

    // MARK: - バッチ整形 (コスト削減: セグメント毎の呼び出しをまとめる)

    private static let batchSystemPrompt = """
    あなたは会議・講義の文字起こし整形担当。入力は文字起こしセグメントの配列(JSON)。
    各要素を独立に処理し、入力と同じ件数・同じ id で結果をJSONで返す。

    整形ルール (各セグメントに適用):
    - フィラー（「えー」「あー」「あの」「その」「なんか」、"um"、"uh"、"you know" 等）を除去
    - 言い間違い・言い直しは、最終的に言いたかった内容に統合
    - 明らかな誤変換・誤認識は文脈から自然に修正
    - 意味・情報・言語は変えない。要約しない。内容を追加しない
    - 修正の必要がなければ入力をそのまま cleaned に入れる
    - 他のセグメントの内容を混ぜない (各セグメントは独立)

    対訳ルール:
    - 原文が日本語以外（英語等）の場合のみ、整形後テキストの自然な日本語訳を translation_ja に入れる
    - 原文が日本語なら translation_ja は null

    入力形式:
    {"items": [{"id": "セグメントのid", "text": "文字起こしテキスト"}, ...]}

    出力形式 (JSONのみ、他のテキストは含めない):
    {"items": [{"id": "入力と同じid", "cleaned": "整形後テキスト", "translation_ja": "日本語訳 または null"}, ...]}
    """

    /// 確定セグメントをまとめて1回のLLM呼び出しで整形・対訳する。
    /// system prompt の再送コストを セグメント数 → 1回 に削減する狙い。
    /// 応答全体のパースに失敗した場合は nil を返し、呼び出し側はバッチ全件を
    /// 原文のまま維持する (単体 `clean` の失敗時と同じフォールバック方針)。
    static func cleanBatch(
        _ items: [(itemId: String, text: String)],
        apiKey: String,
        provider: AIProvider = .openAI
    ) async -> [(itemId: String, result: Result)]? {
        guard !items.isEmpty else { return [] }
        let payload: [String: Any] = [
            "items": items.map { ["id": $0.itemId, "text": $0.text] }
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload),
              let userContent = String(data: bodyData, encoding: .utf8) else {
            return nil
        }

        let (content, costUSD) = await OpenAIChatClient.complete(
            system: batchSystemPrompt,
            user: userContent,
            apiKey: apiKey,
            provider: provider,
            timeout: 20,
            forceJSON: true,
            cacheKey: PromptCacheKey.cleanerBatch,
            // バッチ件数までログに残す。1回あたりの単価だけでは「何件を1回に
            // まとめられているか」が分からず、バッチ化の効き具合を測れないため。
            usageLabel: "cleaner-batch-\(items.count)"
        )
        if costUSD > 0 {
            await MainActor.run { AppState.shared.addCost(costUSD) }
        }
        guard let content else { return nil }
        return parseBatchResult(content)
    }

    /// バッチ応答の JSON をパースする純関数。
    /// トップレベルが壊れている ("items" が無い等) 場合のみ nil (= バッチ全件スキップ)。
    /// 個々の要素が壊れている場合はその要素だけ無視する (他要素は活かす)。
    static func parseBatchResult(_ content: String) -> [(itemId: String, result: Result)]? {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = obj["items"] as? [[String: Any]] else {
            return nil
        }
        var results: [(itemId: String, result: Result)] = []
        for raw in rawItems {
            guard let itemId = raw["id"] as? String,
                  let cleaned = (raw["cleaned"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !cleaned.isEmpty else {
                continue
            }
            let translation = (raw["translation_ja"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append((
                itemId: itemId,
                result: Result(
                    cleaned: cleaned,
                    translationJa: (translation?.isEmpty ?? true) ? nil : translation
                )
            ))
        }
        return results
    }
}
