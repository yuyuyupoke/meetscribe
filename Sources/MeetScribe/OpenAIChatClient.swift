import Foundation

/// OpenAI互換 chat/completions の共通クライアント。
/// 整形・対訳 (TranscriptCleaner)、Catchup要約、全体像生成が共用する。
/// コストは呼び出しごとに計算して返す (AppState への計上は呼び出し側)。
enum OpenAIChatClient {
    /// 既存テスト・呼び出しとの互換用OpenAIデフォルト値。
    static let model = "gpt-4.1-mini"

    // USD per token (2026-07 時点の gpt-4.1-mini 料金: $0.40/M in, $1.60/M out)
    static let inputRate: Double = 0.40 / 1_000_000
    static let outputRate: Double = 1.60 / 1_000_000

    /// 1回の補完リクエスト。失敗 (HTTPエラー・タイムアウト・パース不能) は text=nil。
    /// - Parameter forceJSON: true なら response_format=json_object を指定
    /// - Parameter cacheKey: プロンプトキャッシュ用の用途別キー (`PromptCacheKey`)。
    ///   xAI では `x-grok-conv-id` ヘッダーとして送り、同一キーのリクエストを同じ
    ///   サーバーへ寄せてキャッシュヒット率を上げる。送信内容・モデル・パラメータは
    ///   一切変わらないので応答品質には影響しない。
    /// - Parameter reasoningEffort: `reasoning_effort` に送る値。既定は
    ///   `ReasoningEffortPolicy.current` (= `none`)。`nil` はパラメータを付けない。
    /// - Parameter usageLabel: usage 内訳ログに出す用途ラベル (例: `"overview"`)。
    ///   どの用途がコストを食っているかを実数で切り分けるためだけに使い、
    ///   リクエスト内容には一切影響しない。
    static func complete(
        system: String,
        user: String,
        apiKey: String,
        provider: AIProvider = .openAI,
        timeout: TimeInterval = 20,
        forceJSON: Bool = false,
        cacheKey: String? = nil,
        reasoningEffort: String? = ReasoningEffortPolicy.current,
        usageLabel: String = "chat"
    ) async -> (text: String?, costUSD: Double) {
        guard let request = makeRequest(
            system: system,
            user: user,
            apiKey: apiKey,
            provider: provider,
            timeout: timeout,
            forceJSON: forceJSON,
            cacheKey: cacheKey,
            reasoningEffort: reasoningEffort
        ) else {
            return (nil, 0)
        }

        // 失敗ログに用途とパラメータを添える。`reasoning_effort` を送り始めた直後は
        // 「どの用途のどのパラメータで 400 になったか」が分からないと切り分け不能になる
        // (整形・要約は失敗しても原文を維持して静かに続くため、ログしか手掛かりがない)。
        // 出すのは検証済みラベル・プロバイダー定義値・ホワイトリスト済み effort のみで、
        // 本文やレスポンス body は含めない。
        let failureContext = "label=\(sanitizedUsageLabel(usageLabel))"
            + " provider=\(provider.rawValue) model=\(provider.chatModel)"
            + " effort=\(sanitizedEffort(provider.supportsReasoningEffort ? reasoningEffort : nil))"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                DebugLog.log("[chat-client] HTTP \(status) \(failureContext)")
                return (nil, 0)
            }
            // 用途ごとのトークン内訳を残す。2026-08-10 のコスト分析は
            // 「Overview が総額の約40%」を回数×単価の推定で出すしかなく精度が低かったため、
            // 次からは実数で切り分けられるようにする。**本文は一切書かない** (トークン数のみ)。
            if let usage = usageObject(from: data) {
                DebugLog.log(usageLogLine(
                    usage: usage,
                    provider: provider,
                    label: usageLabel,
                    effort: provider.supportsReasoningEffort ? reasoningEffort : nil
                ))
            }
            return parseResponse(data, provider: provider)
        } catch {
            DebugLog.log("[chat-client] request failed: \(error.localizedDescription) \(failureContext)")
            return (nil, 0)
        }
    }

    /// リクエストを組み立てる純関数 (ヘッダー付与の検証をテストから行えるよう分離)。
    /// body のシリアライズに失敗した場合のみ nil。
    static func makeRequest(
        system: String,
        user: String,
        apiKey: String,
        provider: AIProvider,
        timeout: TimeInterval = 20,
        forceJSON: Bool = false,
        cacheKey: String? = nil,
        reasoningEffort: String? = ReasoningEffortPolicy.current
    ) -> URLRequest? {
        var request = URLRequest(url: provider.chatEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cacheKey, provider.usesGrokConversationHeader {
            request.setValue(cacheKey, forHTTPHeaderField: "x-grok-conv-id")
        }

        var body: [String: Any] = [
            "model": provider.chatModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if forceJSON {
            body["response_format"] = ["type": "json_object"]
        }
        // 非推論モデル (gpt-4.1-mini) はこのパラメータを知らず、送ると 400 で
        // リクエストが丸ごと落ちる = 整形・要約が全滅する。対応プロバイダーのみに限定する。
        if let reasoningEffort, provider.supportsReasoningEffort {
            body["reasoning_effort"] = reasoningEffort
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        request.httpBody = bodyData
        return request
    }

    /// chat/completions レスポンスから (本文, コストUSD) を抽出する純関数。
    static func parseResponse(
        _ data: Data,
        provider: AIProvider = .openAI
    ) -> (text: String?, costUSD: Double) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, 0)
        }
        var cost = 0.0
        if let usage = obj["usage"] as? [String: Any] {
            cost = usageCost(usage, provider: provider)
        }
        let choices = obj["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        // モデルが混ぜる特殊トークンを剥がしてから返す。ここを通せば
        // cleaner / overview / catchup / title の4経路すべてが同時に守られる。
        let content = (message?["content"] as? String)
            .map(sanitizeModelText)
        return (content, cost)
    }

    // MARK: - モデル応答のサニタイズ

    /// 応答テキストからモデルの特殊トークンを除去する。
    ///
    /// **なぜ必要か (2026-08-13 に実APIで再現・原因確定)**
    /// grok-4.3 は `response_format: json_object` を指定しても、応答の末尾に
    /// `<|eos|>` を**生テキストとして**吐くことがある:
    /// ```
    /// {"items": [{"id": "s1", "cleaned": "...", "translation_ja": "..."}]}<|eos|>
    /// ```
    /// JSON本体は完全に閉じているのに `JSONSerialization` が
    /// `Extra data: line 1 column 282` で落ち、**課金済みの応答を丸ごと捨てていた**。
    /// 本番ログでは cleaner 呼び出しの 5〜17% がこれで失敗し、対訳が欠落していた。
    ///
    /// 誤診しやすい点 (実測で潰した仮説):
    /// - `finish_reason` は `stop` → truncate ではない
    /// - 失敗群の `completion_tokens` (58〜180) は成功群 (0〜276) と同じ分布
    ///   → `max_tokens` 到達でもない
    /// - 入力の引用符が原因という仮説は再現実験で棄却
    ///   (引用符ありで成功2/3、引用符なしで失敗2/5)
    ///
    /// **入れていない対策とその理由**: 「最初の `{` から最後の `}` を切り出す」等の
    /// 投機的なJSON抽出は入れない。観測された失敗形はすべて「JSON本体は完全 +
    /// 末尾に特殊トークン」であり、本文に `}` を含む応答で誤動作するリスクだけが増える。
    /// markdown コードフェンスの除去も、実際には一度も観測されていないので入れない
    /// (必要になれば `TranscriptCleaner` の失敗診断ログが形を教えてくれる)。
    static func sanitizeModelText(_ raw: String) -> String {
        guard raw.contains("<|") else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = ""
        var rest = Substring(raw)
        while let open = rest.range(of: "<|") {
            result += rest[rest.startIndex..<open.lowerBound]
            let afterOpen = open.upperBound
            if let close = rest[afterOpen...].range(of: "|>"),
               isSpecialTokenName(rest[afterOpen..<close.lowerBound]) {
                // 特殊トークンとして丸ごと捨てる
                rest = rest[close.upperBound...]
                continue
            }
            // トークンの形をしていない `<|` は本文の一部として残す
            // (発話に "use <| as a pipe" のような表現が来ても壊さない)
            result += "<|"
            rest = rest[afterOpen...]
        }
        result += rest
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<|` と `|>` に挟まれた文字列が特殊トークン名として妥当か。
    /// ASCII の英数字・`_`・`-` のみ、1〜32文字に限る。これを緩めると
    /// 発話本文に現れた `<|` … `|>` が本文ごと食われる。
    private static func isSpecialTokenName(_ name: Substring) -> Bool {
        guard !name.isEmpty, name.count <= 32 else { return false }
        return name.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-")
        }
    }

    /// 1 USD 相当の tick 数。xAI は請求額を整数 tick で返す (docs.x.ai/developers/cost-tracking)。
    static let usdTicksPerDollar: Double = 10_000_000_000

    /// usage オブジェクトから実コストを求める。
    ///
    /// xAI は `cost_in_usd_ticks` に **全割引適用後の実請求額** を返すため、これがあれば
    /// 常にそれを使う。プロンプトキャッシュ割引・推論トークン・サーバー側ツール利用まで
    /// 含んだ確定値なので、単価表の更新漏れやトークン内訳の解釈ミスの影響を受けない。
    ///
    /// 実額を返さない API (OpenAI) はトークン単価から計算する。その際:
    /// - `prompt_tokens` はキャッシュ済みトークンを**含む**総数なので、キャッシュ分は
    ///   割引単価に振り替える (総数×標準単価だと過大計算になる)
    /// - 推論トークンは xAI では `completion_tokens` と別カウントなので加算する。
    ///   OpenAI は `completion_tokens` に含む仕様なので加算しない (二重計上を防ぐ)
    static func usageCost(_ usage: [String: Any], provider: AIProvider) -> Double {
        let input = promptTokens(usage)
        let cached = cachedTokens(usage)
        // ticks を使う経路 (= xAI = ヘッダーを送る唯一のプロバイダー) でも
        // ヒット率を確認できるよう、コスト算出方法に関わらずログを出す。
        if cached > 0 {
            DebugLog.log("[chat-client] prompt cache hit: \(cached)/\(input) tokens")
        }

        // 実請求額が返っていればそれが最も正確。
        if let billed = billedCostUSD(usage) {
            return billed
        }
        return tokenBasedCostUSD(usage, provider: provider)
    }

    /// 単価表からコストを計算する (実請求額が無い API 用)。ログ副作用を持たない。
    static func tokenBasedCostUSD(_ usage: [String: Any], provider: AIProvider) -> Double {
        let input = promptTokens(usage)
        let cached = cachedTokens(usage)
        let completion = completionTokens(usage)
        let reasoning = reasoningTokens(usage)
        let billedOutput: Int = provider.reasoningTokensExcludedFromCompletion
            ? completion + reasoning
            : completion
        let uncached: Int = input - cached
        let inputCost: Double = Double(uncached) * provider.chatInputRate
        let cachedCost: Double = Double(cached) * provider.chatCachedInputRate
        let outputCost: Double = Double(billedOutput) * provider.chatOutputRate
        return inputCost + cachedCost + outputCost
    }

    // MARK: - トークン内訳の取り出し (想定外の値でコストとログが壊れないようクランプ)

    static func promptTokens(_ usage: [String: Any]) -> Int {
        max(usage["prompt_tokens"] as? Int ?? 0, 0)
    }

    /// キャッシュヒット数。負数・`prompt_tokens` 超過という想定外の値は丸める。
    static func cachedTokens(_ usage: [String: Any]) -> Int {
        let details = usage["prompt_tokens_details"] as? [String: Any]
        let raw: Int = details?["cached_tokens"] as? Int ?? 0
        return min(max(raw, 0), promptTokens(usage))
    }

    static func completionTokens(_ usage: [String: Any]) -> Int {
        max(usage["completion_tokens"] as? Int ?? 0, 0)
    }

    static func reasoningTokens(_ usage: [String: Any]) -> Int {
        let details = usage["completion_tokens_details"] as? [String: Any]
        return max(details?["reasoning_tokens"] as? Int ?? 0, 0)
    }

    /// `cost_in_usd_ticks` に入っている**実請求額** (USD)。無ければ nil。
    /// 0 は「無料」と「値の欠損」を区別できないため権威扱いせず nil を返し、
    /// 呼び出し側をトークン単価計算にフォールバックさせる。
    static func billedCostUSD(_ usage: [String: Any]) -> Double? {
        if let ticks = usage["cost_in_usd_ticks"] as? Double, ticks > 0 {
            return ticks / usdTicksPerDollar
        }
        if let ticks = usage["cost_in_usd_ticks"] as? Int, ticks > 0 {
            return Double(ticks) / usdTicksPerDollar
        }
        return nil
    }

    // MARK: - usage 内訳ログ

    /// レスポンス JSON から `usage` オブジェクトだけを取り出す。
    static func usageObject(from data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["usage"] as? [String: Any]
    }

    /// usage 内訳のログ1行を組み立てる純関数。
    ///
    /// **出力に発話本文・プロンプト・APIキーが混ざってはならない**ため、
    /// 出力する値は「整数として取り出したトークン数」「プロバイダー定義のモデル名」
    /// 「ホワイトリスト済みの effort」「検証済みラベル」だけに限定している。
    /// usage に未知のキー (本文が入り込んだフィールド等) があっても素通りしない。
    /// - Parameter effort: 実際に送った `reasoning_effort`。`nil` は未指定 (= `default` 表記)。
    static func usageLogLine(
        usage: [String: Any],
        provider: AIProvider,
        label: String,
        effort: String?
    ) -> String {
        let prompt = promptTokens(usage)
        let cached = cachedTokens(usage)
        let completion = completionTokens(usage)
        let reasoning = reasoningTokens(usage)

        // 実請求額があればそれ、無ければ単価計算値。どちらを出したかを src= で明示する
        // (推定値を実測値と誤読すると次のコスト分析がまた推定ベースになるため)。
        // `usageCost` ではなく `tokenBasedCostUSD` を呼ぶのは、キャッシュヒットログが
        // 1レスポンスにつき二重に出るのを避けるため (この関数は副作用を持たない)。
        let billed = billedCostUSD(usage)
        let cost = billed ?? tokenBasedCostUSD(usage, provider: provider)
        let source = billed == nil ? "calc" : "ticks"

        return "[usage] label=\(sanitizedUsageLabel(label))"
            + " model=\(provider.chatModel)"
            + " effort=\(sanitizedEffort(effort))"
            + " prompt=\(prompt) cached=\(cached)"
            + " completion=\(completion) reasoning=\(reasoning)"
            + " cost=\(String(format: "%.8f", cost)) src=\(source)"
    }

    /// usage ログに出しうる用途ラベル。ここに載っていない文字列はログに書かない。
    static let knownUsageLabels: Set<String> = [
        "chat",             // 用途指定なしの呼び出し (既定)
        "cleaner-single",   // TranscriptCleaner.clean
        "cleaner-batch",    // TranscriptCleaner.cleanBatch (`-件数` が付く)
        "catchup",          // CopilotController.runCatchup
        "overview",         // CopilotController.updateOverviewIfNeeded
        "title"             // MeetingTitleGenerator.generate
    ]

    /// ログに出して安全なラベルか検証する。
    ///
    /// ラベルは呼び出し側が渡す固定文字列だけを想定しているが、万一プロンプトや
    /// 発話本文・APIキーが渡された場合にログへ流出させないよう、**既知ラベルの
    /// ホワイトリストに完全一致しないものは丸ごと捨てる**。
    /// 「使える文字だけ残す」方式にしないのは、部分的な除去では本文が読める形で
    /// 残ってしまう (空白を削るだけでは文が読める・`sk-proj-…` は素通りする) ため。
    /// 唯一の例外はバッチ件数のサフィックス (`cleaner-batch-8` のような ASCII数字5桁以内)。
    static func sanitizedUsageLabel(_ label: String) -> String {
        if knownUsageLabels.contains(label) { return label }
        if let separator = label.lastIndex(of: "-") {
            let base = String(label[label.startIndex..<separator])
            let suffix = label[label.index(after: separator)...]
            if knownUsageLabels.contains(base),
               !suffix.isEmpty,
               suffix.count <= 5,
               suffix.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return label
            }
        }
        return "invalid-label"
    }

    /// ログに出す effort 表記。`ReasoningEffortPolicy` のホワイトリスト外は出さない。
    static func sanitizedEffort(_ effort: String?) -> String {
        guard let effort else { return "default" }
        return ReasoningEffortPolicy.allowed.contains(effort) ? effort : "unknown"
    }
}
