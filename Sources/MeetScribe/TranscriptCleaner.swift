import Foundation

/// 確定した文字起こしセグメントを選択中プロバイダーで後処理するクリーナー。
///
/// モードは `CleanerMode` で切り替える (既定は `translateOnly`):
/// - `translateOnly`: 日本語訳だけを生成する。本文は STT の出力のまま
/// - `formatAndTranslate`: 整形 (フィラー除去・言い直しの統合) もしてから対訳を付ける
///
/// 失敗時は nil を返し、呼び出し側は原文を維持する。
enum TranscriptCleaner {

    struct Result: Equatable, Sendable {
        /// 整形後テキスト。`translateOnly` では **nil** (= 本文を書き換えない)。
        let cleaned: String?
        /// 原文が日本語以外の場合のみ。日本語原文なら nil
        let translationJa: String?
    }

    private static let formatAndTranslateSystemPrompt = """
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

    /// `translateOnly` の system プロンプト (単発)。
    /// 整形ルールを載せない。仕事を減らすほど出力トークンが減って応答が速くなり
    /// (実測 84 → 48 トークン、中央値 1.59s → 1.24s)、プロンプトが短いぶん
    /// キャッシュも効きやすい。
    private static let translateOnlySystemPrompt = """
    あなたは会議・講義の文字起こしの翻訳担当。入力された文字起こしセグメント1つを処理し、JSONで返す。

    翻訳ルール:
    - 原文が日本語以外（英語等）の場合、原文の自然な日本語訳を translation_ja に入れる
    - 原文が日本語なら translation_ja は null
    - 要約しない。内容を追加しない

    出力形式 (JSONのみ):
    {"translation_ja": "日本語訳 または null"}
    """

    /// 単発呼び出しの system プロンプト。
    static func systemPrompt(for mode: CleanerMode) -> String {
        switch mode {
        case .translateOnly: return translateOnlySystemPrompt
        case .formatAndTranslate: return formatAndTranslateSystemPrompt
        }
    }

    /// クリーナー (整形・対訳) に回すべきか。ごく短いセグメントは得るものが少なく、
    /// LLM が過剰修正するリスクの方が高いので除外する。
    static func shouldClean(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
    }

    // MARK: - タイムアウト
    //
    // 2026-08-14 の講義中に実測: cleaner 呼び出し85件中1件 (1.2%) が20秒で
    // タイムアウトし、**そのバッチ3件ぶんの対訳が丸ごと落ちた**
    // (`cleanBatch` が nil を返すと呼び出し側はバッチ全件を原文のまま維持する)。
    // 応答は通常数秒で返るので、20秒はネットワークの一時的な詰まりを吸収しきれていない。
    //
    // 延ばしても後続バッチは待たされない: `TranscriptCleanerBatcher` は各バッチを
    // 独立した Task で走らせ、actor の reentrancy で `await` 中に次のバッチが進む。
    // ただし**停止時は in-flight バッチの完了を待つ**ので (`flushAll`)、
    // タイムアウトに張り付いた1件があると停止が最大この秒数だけ延びる。
    // それでも `waitForSaveCompletion` の90秒上限に収まる。

    /// バッチ整形のタイムアウト。件数が多いほど出力が長くなるのでこちらを長めに取る。
    static let batchTimeoutSeconds: TimeInterval = 40
    /// 単発整形のタイムアウト。
    static let singleTimeoutSeconds: TimeInterval = 30

    /// セグメントを後処理して返す。API エラー・タイムアウト・空応答は nil。
    /// 消費トークンのコストは AppState.totalCostUSD に加算する。
    static func clean(
        _ text: String,
        apiKey: String,
        provider: AIProvider = .openAI,
        mode: CleanerMode = CleanerModePolicy.current
    ) async -> Result? {
        let (content, costUSD) = await OpenAIChatClient.complete(
            system: systemPrompt(for: mode),
            user: text,
            apiKey: apiKey,
            provider: provider,
            timeout: singleTimeoutSeconds,
            forceJSON: true,
            cacheKey: PromptCacheKey.cleanerSingle,
            usageLabel: "cleaner-single"
        )
        if costUSD > 0 {
            await MainActor.run { AppState.shared.addCost(costUSD) }
        }
        guard let content else {
            DebugLog.log("[cleaner] single: no response (HTTP error or timeout)")
            return nil
        }
        return parseCleanResult(content, mode: mode)
    }

    /// LLM の JSON 応答をパースする純関数。反映できる内容が無ければ nil。
    ///
    /// モードで受け取り方が変わる:
    /// - `formatAndTranslate`: `cleaned` が空・形式不正なら nil (従来どおり)
    /// - `translateOnly`: `cleaned` は**読まない** (モデルが勝手に返してきても
    ///   本文の書き換えには使わない)。訳が無ければ反映するものが無いので nil
    static func parseCleanResult(_ content: String, mode: CleanerMode) -> Result? {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let translation = nonEmpty(obj["translation_ja"])

        switch mode {
        case .translateOnly:
            guard let translation else { return nil }
            return Result(cleaned: nil, translationJa: translation)
        case .formatAndTranslate:
            guard let cleaned = nonEmpty(obj["cleaned"]) else { return nil }
            return Result(cleaned: cleaned, translationJa: translation)
        }
    }

    /// JSON の値を「トリム済みで空でない文字列」に落とす (それ以外は nil)。
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - バッチ処理 (コスト削減: セグメント毎の呼び出しをまとめる)

    private static let batchFormatAndTranslatePrompt = """
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

    /// `translateOnly` の system プロンプト (バッチ)。整形ルールは載せない。
    private static let batchTranslateOnlyPrompt = """
    あなたは会議・講義の文字起こしの翻訳担当。入力は文字起こしセグメントの配列(JSON)。
    各要素を独立に翻訳し、入力と同じ件数・同じ id で結果をJSONで返す。

    翻訳ルール:
    - 原文が日本語以外（英語等）の場合、原文の自然な日本語訳を translation_ja に入れる
    - 原文が日本語なら translation_ja は null
    - 要約しない。内容を追加しない
    - 他のセグメントの内容を混ぜない (各セグメントは独立)

    入力形式:
    {"items": [{"id": "セグメントのid", "text": "文字起こしテキスト"}, ...]}

    出力形式 (JSONのみ、他のテキストは含めない):
    {"items": [{"id": "入力と同じid", "translation_ja": "日本語訳 または null"}, ...]}
    """

    /// バッチ呼び出しの system プロンプト。
    static func batchSystemPrompt(for mode: CleanerMode) -> String {
        switch mode {
        case .translateOnly: return batchTranslateOnlyPrompt
        case .formatAndTranslate: return batchFormatAndTranslatePrompt
        }
    }

    /// 確定セグメントをまとめて1回のLLM呼び出しで処理する。
    /// system prompt の再送コストを セグメント数 → 1回 に削減する狙い。
    /// 応答全体のパースに失敗した場合は nil を返し、呼び出し側はバッチ全件を
    /// 原文のまま維持する (単体 `clean` の失敗時と同じフォールバック方針)。
    static func cleanBatch(
        _ items: [(itemId: String, text: String)],
        apiKey: String,
        provider: AIProvider = .openAI,
        mode: CleanerMode = CleanerModePolicy.current
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
            system: batchSystemPrompt(for: mode),
            user: userContent,
            apiKey: apiKey,
            provider: provider,
            timeout: batchTimeoutSeconds,
            forceJSON: true,
            cacheKey: PromptCacheKey.cleanerBatch,
            // バッチ件数までログに残す。1回あたりの単価だけでは「何件を1回に
            // まとめられているか」が分からず、バッチ化の効き具合を測れないため。
            usageLabel: "cleaner-batch-\(items.count)"
        )
        if costUSD > 0 {
            await MainActor.run { AppState.shared.addCost(costUSD) }
        }
        guard let content else {
            // **パース失敗と区別する。** 2026-08-14 に「診断ログが0件だから
            // `<|eos|>` は直った」と読んだ直後に、実際はタイムアウトで
            // 同じバッチが落ちていたことが分かった。呼び出し側のログは
            // どちらも「バッチ全件スキップ」に見えるため、原因はここで分ける。
            DebugLog.log("[cleaner] batch of \(items.count): no response (HTTP error or timeout)")
            return nil
        }
        return parseBatchResult(content, mode: mode)
    }

    /// バッチ応答の JSON をパースする純関数。
    /// トップレベルが壊れている ("items" が無い等) 場合のみ nil (= バッチ全件スキップ)。
    /// 個々の要素が壊れている場合はその要素だけ無視する (他要素は活かす)。
    ///
    /// `translateOnly` では `cleaned` を**読まない**: プロンプトで求めていないので
    /// 通常は返ってこないが、返ってきても本文の書き換えには使わない
    /// ("In my history" → "In my experience" 型の原文改変を構造的に防ぐ)。
    /// 訳が無い要素 (= 日本語原文) は反映するものが無いので結果に含めない。
    static func parseBatchResult(
        _ content: String,
        mode: CleanerMode
    ) -> [(itemId: String, result: Result)]? {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = obj["items"] as? [[String: Any]] else {
            // 課金済みの応答を丸ごと捨てている経路。原因が未確定なので推測で
            // フォールバックは書かず、まず**形だけ**を残して確定させる (下記参照)。
            DebugLog.log("[cleaner] batch parse failed: \(diagnosticShape(of: content))")
            return nil
        }
        var results: [(itemId: String, result: Result)] = []
        for raw in rawItems {
            guard let itemId = raw["id"] as? String else { continue }
            let translation = nonEmpty(raw["translation_ja"])

            switch mode {
            case .translateOnly:
                guard let translation else { continue }
                results.append((itemId, Result(cleaned: nil, translationJa: translation)))
            case .formatAndTranslate:
                guard let cleaned = nonEmpty(raw["cleaned"]) else { continue }
                results.append((itemId, Result(cleaned: cleaned, translationJa: translation)))
            }
        }
        return results
    }

    // MARK: - パース失敗の診断
    //
    // 2026-08-11 の監査で、size=1 のバッチ応答が実測 5.2〜17.3% パースできておらず、
    // 課金済みの応答を丸ごと捨てていることが分かった。影響は金額 ($0.003〜0.010/講義)
    // より品質側で、1講義あたり約22セグメント (9.3%) の日本語対訳が欠落している。
    //
    // **フォールバックは書かない。** トークン算術 (失敗群の completion 残差) が
    // 「フラット形で返っている」仮説を 4.6〜7.4σ で否定しており、有力候補は
    // `{"items": {...}}` の単数崩れ or キー名の変化。推測でパッチを当てると
    // 「直したのに何も変わらない」になるので、まず形を観測して確定させる。
    //
    // **本文は絶対に出さない。** ログは平文で長期間残り、値を出せば議事録の
    // 意図しない二重保存になる (2026-07-25 に修正済みの事故)。出すのは
    // 「トップレベルの種別 / キー名 / 値の型 / 要素数・文字数」だけ。

    /// 診断ログに載せるキーの最大数 (壊れた応答が巨大でもログを溢れさせない)。
    static let maxDiagnosticKeys = 8
    /// 原文のまま出してよいキー名の最大長。
    static let maxDiagnosticKeyLength = 24

    /// パースできなかった応答の**形**を1行で表す (値は一切含めない)。
    static func diagnosticShape(of content: String) -> String {
        let byteCount = content.utf8.count
        guard let data = content.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return "top-level=unparsable (\(byteCount) bytes)"
        }
        return "top-level=\(shapeDescription(root)) (\(byteCount) bytes)"
    }

    /// JSON 値の形。文字列は長さだけ、配列・辞書は要素数と (浅い範囲で) 中身の形。
    private static func shapeDescription(_ value: Any, depth: Int = 0) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            return "string(\(string.count) chars)"
        case let array as [Any]:
            // 先頭要素の形だけ見る (フラット配列で返ってきた場合の判別に効く)。
            guard depth < 1, let first = array.first else { return "array(\(array.count))" }
            return "array(\(array.count)) of \(shapeDescription(first, depth: depth + 1))"
        case let dict as [String: Any]:
            return "object(\(dict.count))\(keyShapes(dict, depth: depth))"
        case is NSNumber:
            return "number"
        default:
            return "unknown"
        }
    }

    /// 辞書のキー名と値の型の一覧 (深さと件数で有界)。
    private static func keyShapes(_ dict: [String: Any], depth: Int) -> String {
        guard depth < 2 else { return "" }
        let keys = dict.keys.sorted()
        let shown = keys.prefix(maxDiagnosticKeys)
        let parts = shown.map { key in
            "\(sanitizedKey(key))=\(shapeDescription(dict[key] ?? NSNull(), depth: depth + 1))"
        }
        let more = keys.count > shown.count ? ", +\(keys.count - shown.count) more" : ""
        return " [\(parts.joined(separator: ", "))\(more)]"
    }

    /// キー名をログに出してよい形に落とす。
    ///
    /// 知りたいのはスキーマのキー名 (`items` / `cleaned` / `translation_ja` …) であって
    /// 発話本文ではない。モデルが本文をキーにして返す可能性があるので、
    /// **識別子の形 (ASCII 英数と `_ - .` のみ、24文字以内) に完全一致するものだけ**
    /// 原文で出し、それ以外は文字数だけの `<redacted:N chars>` にする。
    /// 実際の発話は空白・日本語・句読点を含むので必ず redacted 側に落ちる。
    static func sanitizedKey(_ key: String) -> String {
        let isIdentifierLike = !key.isEmpty
            && key.count <= maxDiagnosticKeyLength
            && key.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x61 && scalar.value <= 0x7A)      // a-z
                    || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                    || (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                    || scalar == "_" || scalar == "-" || scalar == "."
            }
        return isIdentifierLike ? key : "<redacted:\(key.count) chars>"
    }
}
