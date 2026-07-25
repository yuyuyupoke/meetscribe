import XCTest
@testable import MeetScribeCore

/// プロンプトキャッシュのコスト計算とキー定義。
///
/// OpenAI・xAI とも `usage.prompt_tokens_details.cached_tokens` にヒット数を返し、
/// `prompt_tokens` はキャッシュ分を**含む**総数。素直に総数×標準単価で計算すると
/// 実請求より過大になるため、割引分を差し引く実装をここで固定する。
final class PromptCacheTests: XCTestCase {

    private func makeResponse(
        promptTokens: Int,
        completionTokens: Int,
        cachedTokens: Int?
    ) -> Data {
        var usage: [String: Any] = [
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens
        ]
        if let cachedTokens {
            usage["prompt_tokens_details"] = ["cached_tokens": cachedTokens]
        }
        let obj: [String: Any] = [
            "choices": [["message": ["content": "ok"]]],
            "usage": usage
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - 単価

    func test_cachedInputRates_matchDocumentedPricing() {
        // gpt-4.1-mini: $0.10/M (input $0.40/M の 75%オフ)
        XCTAssertEqual(AIProvider.openAI.chatCachedInputRate, 0.10 / 1_000_000, accuracy: 1e-15)
        // grok-4.3: $0.20/M (input $1.25/M の 84%オフ)
        XCTAssertEqual(AIProvider.xAI.chatCachedInputRate, 0.20 / 1_000_000, accuracy: 1e-15)
    }

    func test_cachedRate_isCheaperThanStandardInput() {
        for provider in AIProvider.allCases {
            XCTAssertLessThan(provider.chatCachedInputRate, provider.chatInputRate)
        }
    }

    // MARK: - コスト計算

    func test_parseResponse_cachedTokens_appliesDiscount() {
        // xAI: 1000 prompt のうち 800 がキャッシュヒット
        let data = makeResponse(promptTokens: 1000, completionTokens: 100, cachedTokens: 800)
        let result = OpenAIChatClient.parseResponse(data, provider: .xAI)

        let expected = 200.0 * AIProvider.xAI.chatInputRate
            + 800.0 * AIProvider.xAI.chatCachedInputRate
            + 100.0 * AIProvider.xAI.chatOutputRate
        XCTAssertEqual(result.costUSD, expected, accuracy: 1e-12)

        // 割引を無視した従来計算より必ず安くなる
        let undiscounted = 1000.0 * AIProvider.xAI.chatInputRate
            + 100.0 * AIProvider.xAI.chatOutputRate
        XCTAssertLessThan(result.costUSD, undiscounted)
    }

    func test_parseResponse_noCacheField_matchesLegacyCalculation() {
        // キャッシュ未ヒット (フィールド自体が無い) 場合は従来と同じ計算
        let data = makeResponse(promptTokens: 100, completionTokens: 50, cachedTokens: nil)
        let result = OpenAIChatClient.parseResponse(data, provider: .openAI)

        let expected = 100.0 * AIProvider.openAI.chatInputRate
            + 50.0 * AIProvider.openAI.chatOutputRate
        XCTAssertEqual(result.costUSD, expected, accuracy: 1e-12)
    }

    func test_parseResponse_zeroCachedTokens_matchesLegacyCalculation() {
        let data = makeResponse(promptTokens: 100, completionTokens: 50, cachedTokens: 0)
        let result = OpenAIChatClient.parseResponse(data, provider: .xAI)

        let expected = 100.0 * AIProvider.xAI.chatInputRate
            + 50.0 * AIProvider.xAI.chatOutputRate
        XCTAssertEqual(result.costUSD, expected, accuracy: 1e-12)
    }

    func test_parseResponse_fullyCached_chargesOnlyCachedRate() {
        let data = makeResponse(promptTokens: 500, completionTokens: 0, cachedTokens: 500)
        let result = OpenAIChatClient.parseResponse(data, provider: .xAI)

        XCTAssertEqual(result.costUSD, 500.0 * AIProvider.xAI.chatCachedInputRate, accuracy: 1e-12)
    }

    func test_parseResponse_cachedExceedingPrompt_clampsToPromptTokens() {
        // API が想定外の値を返してもコストが負にならない
        let data = makeResponse(promptTokens: 100, completionTokens: 0, cachedTokens: 999)
        let result = OpenAIChatClient.parseResponse(data, provider: .xAI)

        XCTAssertEqual(result.costUSD, 100.0 * AIProvider.xAI.chatCachedInputRate, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(result.costUSD, 0)
    }

    func test_parseResponse_negativeCachedTokens_treatedAsZero() {
        let data = makeResponse(promptTokens: 100, completionTokens: 0, cachedTokens: -50)
        let result = OpenAIChatClient.parseResponse(data, provider: .xAI)

        XCTAssertEqual(result.costUSD, 100.0 * AIProvider.xAI.chatInputRate, accuracy: 1e-12)
    }

    // MARK: - キャッシュキー / ヘッダー適用条件

    func test_grokConversationHeader_onlyForXAI() {
        XCTAssertTrue(AIProvider.xAI.usesGrokConversationHeader)
        XCTAssertFalse(AIProvider.openAI.usesGrokConversationHeader)
    }

    // MARK: - xAI の実請求額 (cost_in_usd_ticks)

    /// xAI は全割引適用後の実請求額を tick で返す。1 USD = 10^10 ticks。
    func test_usdTicksPerDollar_matchesDocumentedRate() {
        XCTAssertEqual(OpenAIChatClient.usdTicksPerDollar, 10_000_000_000)
    }

    func test_usageCost_prefersActualBilledTicks() {
        // 2026-07-25 に実APIで観測した値: cached 512/547, completion 33, reasoning 274
        let usage: [String: Any] = [
            "prompt_tokens": 547,
            "completion_tokens": 33,
            "prompt_tokens_details": ["cached_tokens": 512],
            "completion_tokens_details": ["reasoning_tokens": 274],
            "cost_in_usd_ticks": 9_136_500
        ]
        let cost = OpenAIChatClient.usageCost(usage, provider: .xAI)
        XCTAssertEqual(cost, 0.00091365, accuracy: 1e-12)
    }

    /// ticks が無い場合のフォールバックも、実請求額と一致しなければならない。
    /// xAI は推論トークンを completion_tokens と別カウントで返すため、加算しないと
    /// 大幅な過小計算になる (実測サンプルでは 7.5倍 の乖離だった)。
    func test_usageCost_xAIFallback_matchesActualBilling() {
        let samples: [(cached: Int, completion: Int, reasoning: Int, ticks: Int)] = [
            (cached: 512, completion: 33, reasoning: 274, ticks: 9_136_500),
            (cached: 512, completion: 35, reasoning: 610, ticks: 17_586_500),
            (cached: 192, completion: 33, reasoning: 393, ticks: 15_471_500)
        ]
        for s in samples {
            let usage: [String: Any] = [
                "prompt_tokens": 547,
                "completion_tokens": s.completion,
                "prompt_tokens_details": ["cached_tokens": s.cached],
                "completion_tokens_details": ["reasoning_tokens": s.reasoning]
            ]
            let fallback = OpenAIChatClient.usageCost(usage, provider: .xAI)
            let billed = Double(s.ticks) / OpenAIChatClient.usdTicksPerDollar
            XCTAssertEqual(fallback, billed, accuracy: 1e-12,
                           "cached=\(s.cached) reasoning=\(s.reasoning) で実請求と乖離")
        }
    }

    func test_usageCost_openAI_doesNotAddReasoningTokens() {
        // OpenAI は reasoning を completion_tokens に含む仕様なので加算しない
        let usage: [String: Any] = [
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "completion_tokens_details": ["reasoning_tokens": 40]
        ]
        let cost = OpenAIChatClient.usageCost(usage, provider: .openAI)
        let expected = 100.0 * AIProvider.openAI.chatInputRate
            + 50.0 * AIProvider.openAI.chatOutputRate
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
    }

    func test_reasoningTokenAccounting_differsByProvider() {
        XCTAssertTrue(AIProvider.xAI.reasoningTokensExcludedFromCompletion)
        XCTAssertFalse(AIProvider.openAI.reasoningTokensExcludedFromCompletion)
    }

    func test_usageCost_doubleTicks_areAccepted() {
        // JSON 数値が Double として来ても拾えること
        let usage: [String: Any] = ["prompt_tokens": 10, "cost_in_usd_ticks": 9_136_500.0]
        XCTAssertEqual(OpenAIChatClient.usageCost(usage, provider: .xAI), 0.00091365, accuracy: 1e-12)
    }

    func test_usageCost_negativeTicks_fallsBackToTokenCalculation() {
        let usage: [String: Any] = [
            "prompt_tokens": 100,
            "completion_tokens": 0,
            "cost_in_usd_ticks": -1
        ]
        let cost = OpenAIChatClient.usageCost(usage, provider: .xAI)
        XCTAssertEqual(cost, 100.0 * AIProvider.xAI.chatInputRate, accuracy: 1e-12)
    }

    func test_usageCost_zeroTicks_fallsBackToTokenCalculation() {
        // 0 は「無料」と「値の欠損」を区別できないため権威扱いしない
        let usage: [String: Any] = [
            "prompt_tokens": 100,
            "completion_tokens": 10,
            "completion_tokens_details": ["reasoning_tokens": 20],
            "cost_in_usd_ticks": 0
        ]
        let cost = OpenAIChatClient.usageCost(usage, provider: .xAI)
        let expected = 100.0 * AIProvider.xAI.chatInputRate
            + 30.0 * AIProvider.xAI.chatOutputRate
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
    }

    // MARK: - 実レスポンス形状 (フィールド位置の固定)

    /// 2026-07-25 に実 API から受け取ったレスポンスをそのまま流し、
    /// `cost_in_usd_ticks` が `usage` 直下にある前提を固定する。
    /// ここが変わるとエラーにならず静かにフォールバックへ落ちるため、
    /// 形状そのものをテストで守る。
    func test_parseResponse_realXAIResponse_usesBilledTicks() {
        let json = """
        {
          "choices": [{"message": {"role": "assistant", "content": "{\\"items\\":[]}"}}],
          "usage": {
            "prompt_tokens": 547,
            "completion_tokens": 33,
            "total_tokens": 908,
            "prompt_tokens_details": {
              "text_tokens": 547, "audio_tokens": 0, "image_tokens": 0, "cached_tokens": 512
            },
            "completion_tokens_details": {
              "reasoning_tokens": 328, "audio_tokens": 0,
              "accepted_prediction_tokens": 0, "rejected_prediction_tokens": 0
            },
            "num_sources_used": 0,
            "cost_in_usd_ticks": 10486500
          }
        }
        """
        let result = OpenAIChatClient.parseResponse(Data(json.utf8), provider: .xAI)
        XCTAssertEqual(result.text, "{\"items\":[]}")
        XCTAssertEqual(result.costUSD, 0.00104865, accuracy: 1e-12)
    }

    // MARK: - ヘッダー付与

    func test_makeRequest_xAI_setsGrokConversationHeader() {
        let request = OpenAIChatClient.makeRequest(
            system: "s", user: "u", apiKey: "k",
            provider: .xAI, cacheKey: PromptCacheKey.cleanerBatch
        )
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "x-grok-conv-id"),
            PromptCacheKey.cleanerBatch
        )
    }

    func test_makeRequest_openAI_omitsGrokConversationHeader() {
        let request = OpenAIChatClient.makeRequest(
            system: "s", user: "u", apiKey: "k",
            provider: .openAI, cacheKey: PromptCacheKey.cleanerBatch
        )
        XCTAssertNil(request?.value(forHTTPHeaderField: "x-grok-conv-id"))
    }

    func test_makeRequest_withoutCacheKey_omitsHeader() {
        let request = OpenAIChatClient.makeRequest(
            system: "s", user: "u", apiKey: "k", provider: .xAI, cacheKey: nil
        )
        XCTAssertNil(request?.value(forHTTPHeaderField: "x-grok-conv-id"))
    }

    /// ヘッダー追加が本文 (モデル・プロンプト・パラメータ) を変えていないこと。
    /// = 応答品質に影響しないことの担保。
    func test_makeRequest_bodyIdenticalRegardlessOfCacheKey() throws {
        let withKey = OpenAIChatClient.makeRequest(
            system: "sys", user: "usr", apiKey: "k",
            provider: .xAI, forceJSON: true, cacheKey: PromptCacheKey.overview
        )
        let withoutKey = OpenAIChatClient.makeRequest(
            system: "sys", user: "usr", apiKey: "k",
            provider: .xAI, forceJSON: true, cacheKey: nil
        )
        // JSON のキー順は非決定的なのでバイト列ではなく構造で比較する
        let a = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(withKey?.httpBody)
        ) as? NSDictionary
        let b = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(withoutKey?.httpBody)
        ) as? NSDictionary
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func test_installID_isStableAndEmbeddedInKeys() {
        let first = PromptCacheKey.installID
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, PromptCacheKey.installID)
        XCTAssertTrue(PromptCacheKey.cleanerBatch.hasSuffix(first))
    }

    func test_usageCost_openAIWithoutTicks_usesTokenRates() {
        let usage: [String: Any] = [
            "prompt_tokens": 2000,
            "completion_tokens": 100,
            "prompt_tokens_details": ["cached_tokens": 1024]
        ]
        let cost = OpenAIChatClient.usageCost(usage, provider: .openAI)
        let expected = 976.0 * AIProvider.openAI.chatInputRate
            + 1024.0 * AIProvider.openAI.chatCachedInputRate
            + 100.0 * AIProvider.openAI.chatOutputRate
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
    }

    func test_promptCacheKeys_areDistinctPerSystemPrompt() {
        // system プロンプトが違う用途を同じキーにするとサーバーを共有するだけで
        // 利点がないため、用途ごとに別キーであることを固定する
        let keys = [
            PromptCacheKey.cleanerBatch,
            PromptCacheKey.cleanerSingle,
            PromptCacheKey.catchup,
            PromptCacheKey.overview
        ]
        XCTAssertEqual(Set(keys).count, keys.count)
        for key in keys {
            XCTAssertFalse(key.isEmpty)
        }
    }
}
