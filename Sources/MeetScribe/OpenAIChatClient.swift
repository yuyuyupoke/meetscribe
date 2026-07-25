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
    static func complete(
        system: String,
        user: String,
        apiKey: String,
        provider: AIProvider = .openAI,
        timeout: TimeInterval = 20,
        forceJSON: Bool = false,
        cacheKey: String? = nil
    ) async -> (text: String?, costUSD: Double) {
        guard let request = makeRequest(
            system: system,
            user: user,
            apiKey: apiKey,
            provider: provider,
            timeout: timeout,
            forceJSON: forceJSON,
            cacheKey: cacheKey
        ) else {
            return (nil, 0)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                DebugLog.log("[chat-client] HTTP \(status)")
                return (nil, 0)
            }
            return parseResponse(data, provider: provider)
        } catch {
            DebugLog.log("[chat-client] request failed: \(error.localizedDescription)")
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
        cacheKey: String? = nil
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
        let content = (message?["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (content, cost)
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
        let input: Int = max(usage["prompt_tokens"] as? Int ?? 0, 0)
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let rawCached: Int = promptDetails?["cached_tokens"] as? Int ?? 0
        // 想定外の値 (負数・prompt_tokens 超過) でコストが壊れないようクランプする
        let cached: Int = min(max(rawCached, 0), input)
        // ticks を使う経路 (= xAI = ヘッダーを送る唯一のプロバイダー) でも
        // ヒット率を確認できるよう、コスト算出方法に関わらずログを出す。
        if cached > 0 {
            DebugLog.log("[chat-client] prompt cache hit: \(cached)/\(input) tokens")
        }

        // 実請求額が返っていればそれが最も正確。0 は「無料」と「値の欠損」を
        // 区別できないため権威扱いせず、トークン計算にフォールバックする。
        if let ticks = usage["cost_in_usd_ticks"] as? Double, ticks > 0 {
            return ticks / usdTicksPerDollar
        }
        if let ticks = usage["cost_in_usd_ticks"] as? Int, ticks > 0 {
            return Double(ticks) / usdTicksPerDollar
        }

        let completion: Int = max(usage["completion_tokens"] as? Int ?? 0, 0)
        let completionDetails = usage["completion_tokens_details"] as? [String: Any]
        let reasoning: Int = max(completionDetails?["reasoning_tokens"] as? Int ?? 0, 0)
        let billedOutput: Int = provider.reasoningTokensExcludedFromCompletion
            ? completion + reasoning
            : completion
        let uncached: Int = input - cached
        let inputCost: Double = Double(uncached) * provider.chatInputRate
        let cachedCost: Double = Double(cached) * provider.chatCachedInputRate
        let outputCost: Double = Double(billedOutput) * provider.chatOutputRate
        return inputCost + cachedCost + outputCost
    }
}
