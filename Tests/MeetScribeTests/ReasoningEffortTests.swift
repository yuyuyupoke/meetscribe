import XCTest
@testable import MeetScribeCore

/// `reasoning_effort` の決定ロジックと usage 内訳ログ。
///
/// 2026-08-10 にテキサスの英語講義の実データで A/B した結果、`none` (推論なし) が
/// コスト -42〜-47% かつ品質同等以上だったため既定にした。ここで固定したいのは:
/// - 既定が `none` であること (回帰でコストが2倍に戻るのを防ぐ)
/// - 環境変数で必ず戻せること (2026-07-25 の日本語会議ではフィラー除去が劣化した実測がある)
/// - 非推論モデル (gpt-4.1-mini) には**絶対に送らない**こと (400 で整形が丸ごと落ちる)
/// - usage ログに発話本文が混ざらないこと (2026-07-25 の平文ログ流出の再発防止)
final class ReasoningEffortTests: XCTestCase {

    private let key = ReasoningEffortPolicy.environmentKey

    /// 環境変数だけを見る解決 (テスト実行マシンに
    /// `defaults write com.meetscribe.app reasoningEffort …` が入っていても結果が変わらないように、
    /// UserDefaults を明示的に切って呼ぶ)。
    private func resolveIgnoringUserDefaults(environment: [String: String]) -> String? {
        ReasoningEffortPolicy.resolve(environment: environment, defaults: nil)
    }

    /// テスト専用の UserDefaults ドメイン。`.standard` を汚さない。
    private func makeScratchDefaults(
        _ value: String?,
        function: String = #function
    ) -> UserDefaults {
        let suite = "com.meetscribe.tests.\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let value {
            defaults.set(value, forKey: ReasoningEffortPolicy.userDefaultsKey)
        }
        // teardown へは Sendable な suite 名だけを渡す (UserDefaults インスタンスを
        // クロージャに送ると Swift 6 の strict concurrency で data race 判定になる)。
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    // MARK: - ポリシー定義

    func test_defaultEffort_isNone() {
        // 実測で最良だった値。ここを緩めるとコストが約2倍に戻る
        XCTAssertEqual(ReasoningEffortPolicy.defaultEffort, "none")
        XCTAssertEqual(ReasoningEffortPolicy.environmentKey, "MEETSCRIBE_REASONING_EFFORT")
    }

    func test_allowed_containsProviderValuesAndDefaultEscape() {
        XCTAssertEqual(ReasoningEffortPolicy.allowed, ["none", "low", "high", "default"])
    }

    // MARK: - resolve

    func test_resolve_withoutEnvironment_returnsNone() {
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[:]), "none")
    }

    func test_resolve_default_meansOmitParameter() {
        // "default" = パラメータを付けない = プロバイダー既定の推論量に戻す非常口
        XCTAssertNil(resolveIgnoringUserDefaults(environment:[key: "default"]))
    }

    func test_resolve_explicitValues_arePassedThrough() {
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "low"]), "low")
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "high"]), "high")
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "none"]), "none")
    }

    func test_resolve_isCaseInsensitive() {
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "LOW"]), "low")
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "High"]), "high")
        XCTAssertNil(resolveIgnoringUserDefaults(environment:[key: "DEFAULT"]))
    }

    func test_resolve_trimsSurroundingWhitespace() {
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "  low  "]), "low")
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "\tnone\n"]), "none")
    }

    func test_resolve_unknownValue_fallsBackToDefault() {
        // 未知の値を API に送ると整形・要約が丸ごと失敗するため、必ず既定へ落とす
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "medium"]), "none")
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "maximum"]), "none")
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "1"]), "none")
    }

    func test_resolve_emptyOrWhitespaceValue_fallsBackToDefault() {
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: ""]), "none")
        XCTAssertEqual(resolveIgnoringUserDefaults(environment:[key: "   "]), "none")
    }

    // MARK: - UserDefaults 経路 (GUI起動時の唯一のロールバック手段)

    /// Finder/Dock/`open` から起動したアプリはシェルの環境変数を継承しないため、
    /// 環境変数だけだと**実際の使い方では従来動作に戻せない**。UserDefaults が必須。
    func test_userDefaultsKey_isStable() {
        // `defaults write com.meetscribe.app reasoningEffort default` が手順として成立すること
        XCTAssertEqual(ReasoningEffortPolicy.userDefaultsKey, "reasoningEffort")
    }

    func test_resolve_userDefaults_providesRollbackWithoutEnvironment() {
        let defaults = makeScratchDefaults("default")
        XCTAssertNil(ReasoningEffortPolicy.resolve(environment: [:], defaults: defaults))
    }

    func test_resolve_userDefaults_explicitValueIsUsed() {
        let defaults = makeScratchDefaults("low")
        XCTAssertEqual(ReasoningEffortPolicy.resolve(environment: [:], defaults: defaults), "low")
    }

    /// 恒久設定 (UserDefaults) を書き換えずに1回だけ試せるよう、環境変数を上に置く。
    func test_resolve_environmentWinsOverUserDefaults() {
        let defaults = makeScratchDefaults("default")
        XCTAssertEqual(
            ReasoningEffortPolicy.resolve(environment: [key: "low"], defaults: defaults),
            "low"
        )
    }

    func test_resolve_userDefaults_unknownValue_fallsBackToDefaultEffort() {
        let defaults = makeScratchDefaults("medium")
        XCTAssertEqual(ReasoningEffortPolicy.resolve(environment: [:], defaults: defaults), "none")
    }

    /// 環境変数がホワイトリスト外なら「指定なし」と見なして UserDefaults に落ちる。
    func test_resolve_invalidEnvironment_fallsThroughToUserDefaults() {
        let defaults = makeScratchDefaults("default")
        XCTAssertNil(ReasoningEffortPolicy.resolve(environment: [key: "medium"], defaults: defaults))
    }

    func test_resolve_emptyUserDefaults_returnsDefaultEffort() {
        let defaults = makeScratchDefaults(nil)
        XCTAssertEqual(ReasoningEffortPolicy.resolve(environment: [:], defaults: defaults), "none")
    }

    func test_resolve_nilDefaults_doesNotCrash() {
        XCTAssertEqual(ReasoningEffortPolicy.resolve(environment: [:], defaults: nil), "none")
    }

    // MARK: - リクエスト本文への反映

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_makeRequest_xAI_includesReasoningEffort() throws {
        let request = OpenAIChatClient.makeRequest(
            system: "s", user: "u", apiKey: "k",
            provider: .xAI, reasoningEffort: "none"
        )
        XCTAssertEqual(try body(request)["reasoning_effort"] as? String, "none")
    }

    func test_makeRequest_openAI_neverIncludesReasoningEffort() throws {
        // gpt-4.1-mini は非推論モデル。送ると 400 で整形が丸ごと落ちる
        for effort in ["none", "low", "high"] {
            let request = OpenAIChatClient.makeRequest(
                system: "s", user: "u", apiKey: "k",
                provider: .openAI, reasoningEffort: effort
            )
            XCTAssertNil(try body(request)["reasoning_effort"],
                         "OpenAI 経路に reasoning_effort=\(effort) が漏れている")
        }
        XCTAssertFalse(AIProvider.openAI.supportsReasoningEffort)
        XCTAssertTrue(AIProvider.xAI.supportsReasoningEffort)
    }

    func test_makeRequest_nilEffort_omitsParameter() throws {
        let request = OpenAIChatClient.makeRequest(
            system: "s", user: "u", apiKey: "k",
            provider: .xAI, reasoningEffort: nil
        )
        XCTAssertNil(try body(request)["reasoning_effort"])
    }

    /// 引数省略時はポリシーの解決値がそのまま入る (既定 = プロセス環境に従う)。
    func test_makeRequest_defaultArgument_followsPolicy() throws {
        let request = OpenAIChatClient.makeRequest(
            system: "s", user: "u", apiKey: "k", provider: .xAI
        )
        let actual = try body(request)["reasoning_effort"] as? String
        XCTAssertEqual(actual, ReasoningEffortPolicy.current)
    }

    /// `reasoning_effort` 以外の本文 (モデル・messages・temperature・response_format) と
    /// キャッシュキーのヘッダーが、パラメータ有無で変わらないこと。
    func test_makeRequest_otherBodyFieldsAndHeaders_unchanged() throws {
        let withEffort = OpenAIChatClient.makeRequest(
            system: "sys", user: "usr", apiKey: "k",
            provider: .xAI, forceJSON: true,
            cacheKey: PromptCacheKey.overview, reasoningEffort: "low"
        )
        let withoutEffort = OpenAIChatClient.makeRequest(
            system: "sys", user: "usr", apiKey: "k",
            provider: .xAI, forceJSON: true,
            cacheKey: PromptCacheKey.overview, reasoningEffort: nil
        )

        var a = try body(withEffort)
        let b = try body(withoutEffort)
        XCTAssertEqual(a["reasoning_effort"] as? String, "low")
        a.removeValue(forKey: "reasoning_effort")
        // JSON のキー順は非決定的なのでバイト列ではなく構造で比較する
        XCTAssertEqual(a as NSDictionary, b as NSDictionary)

        XCTAssertEqual(
            withEffort?.value(forHTTPHeaderField: "x-grok-conv-id"),
            PromptCacheKey.overview
        )
        XCTAssertEqual(
            withEffort?.value(forHTTPHeaderField: "Authorization"),
            withoutEffort?.value(forHTTPHeaderField: "Authorization")
        )
    }

    // MARK: - usage 内訳ログ

    /// 2026-07-25 に実 API から観測した usage 形状。
    private func sampleUsage(withTicks: Bool) -> [String: Any] {
        var usage: [String: Any] = [
            "prompt_tokens": 547,
            "completion_tokens": 33,
            "total_tokens": 908,
            "prompt_tokens_details": ["cached_tokens": 512],
            "completion_tokens_details": ["reasoning_tokens": 274]
        ]
        if withTicks {
            usage["cost_in_usd_ticks"] = 9_136_500
        }
        return usage
    }

    func test_usageLogLine_containsLabelModelEffortAndTokenBreakdown() {
        let line = OpenAIChatClient.usageLogLine(
            usage: sampleUsage(withTicks: true),
            provider: .xAI,
            label: "cleaner-batch-8",
            effort: "none"
        )
        XCTAssertTrue(line.hasPrefix("[usage] "), line)
        XCTAssertTrue(line.contains("label=cleaner-batch-8"), line)
        XCTAssertTrue(line.contains("model=grok-4.3"), line)
        XCTAssertTrue(line.contains("effort=none"), line)
        XCTAssertTrue(line.contains("prompt=547"), line)
        XCTAssertTrue(line.contains("cached=512"), line)
        XCTAssertTrue(line.contains("completion=33"), line)
        XCTAssertTrue(line.contains("reasoning=274"), line)
        // 1行で完結する (ログの1レコード = 1呼び出し)
        XCTAssertFalse(line.contains("\n"), line)
    }

    func test_usageLogLine_prefersActualBilledTicks() {
        let line = OpenAIChatClient.usageLogLine(
            usage: sampleUsage(withTicks: true),
            provider: .xAI, label: "overview", effort: "none"
        )
        // 9,136,500 ticks / 10^10 = $0.00091365 (実請求額)
        XCTAssertTrue(line.contains("cost=0.00091365"), line)
        XCTAssertTrue(line.contains("src=ticks"), line)
    }

    func test_usageLogLine_withoutTicks_usesCalculatedCostAndMarksIt() {
        let usage = sampleUsage(withTicks: false)
        let line = OpenAIChatClient.usageLogLine(
            usage: usage, provider: .xAI, label: "overview", effort: "none"
        )
        let expected = String(
            format: "%.8f",
            OpenAIChatClient.tokenBasedCostUSD(usage, provider: .xAI)
        )
        XCTAssertTrue(line.contains("cost=\(expected)"), line)
        XCTAssertTrue(line.contains("src=calc"), line)
    }

    func test_usageLogLine_effortRendering() {
        let usage = sampleUsage(withTicks: true)
        // nil = パラメータ未指定 → "default" と表記 (プロバイダー既定で走ったことが分かる)
        XCTAssertTrue(
            OpenAIChatClient.usageLogLine(usage: usage, provider: .xAI, label: "title", effort: nil)
                .contains("effort=default")
        )
        // ホワイトリスト外は値を出さない (ログに任意文字列を書かせない)
        XCTAssertTrue(
            OpenAIChatClient.usageLogLine(
                usage: usage, provider: .xAI, label: "title", effort: "秘密の発話内容"
            ).contains("effort=unknown")
        )
    }

    func test_usageLogLine_openAI_showsOwnModelName() {
        let line = OpenAIChatClient.usageLogLine(
            usage: sampleUsage(withTicks: false),
            provider: .openAI, label: "cleaner-single", effort: nil
        )
        XCTAssertTrue(line.contains("model=gpt-4.1-mini"), line)
        XCTAssertTrue(line.contains("effort=default"), line)
    }

    // MARK: - 秘密漏洩の回帰テスト

    /// ログは平文で長期間残るため、**発話本文・プロンプト・APIキーが1文字も混ざってはいけない**。
    /// usage に本文らしいフィールドが入っていても、ラベルに本文が渡されても、
    /// 出力はトークン数・モデル名・effort・検証済みラベルだけであることを固定する。
    func test_usageLogLine_neverLeaksSpeechOrSecrets() {
        let secrets = [
            "来期の役員報酬を3000万に上げる件",
            "This is the confidential salary discussion",
            "sk-proj-abcdef0123456789",
            "xai-abcdef0123456789"
        ]
        var usage = sampleUsage(withTicks: true)
        // API が (あるいは将来の実装が) 本文入りのフィールドを usage に混ぜてきても素通りさせない
        usage["content"] = secrets[0]
        usage["text"] = secrets[1]
        usage["api_key"] = secrets[2]
        usage["messages"] = [["role": "user", "content": secrets[0]]]
        usage["prompt_tokens_details"] = ["cached_tokens": 512, "raw_text": secrets[1]]

        for label in secrets + ["Cleaner Batch: 来期の役員報酬", ""] {
            let line = OpenAIChatClient.usageLogLine(
                usage: usage, provider: .xAI, label: label, effort: secrets[0]
            )
            for secret in secrets {
                XCTAssertFalse(line.contains(secret), "秘密が漏れている: \(line)")
            }
            // 断片も残さない (空白除去のような部分加工では読める形で残ってしまう)
            for fragment in ["役員報酬", "salary", "confidential", "sk-proj", "xai-a"] {
                XCTAssertFalse(line.contains(fragment), "断片が漏れている: \(line)")
            }
            XCTAssertTrue(line.contains("label=invalid-label"), line)
            XCTAssertTrue(line.contains("prompt=547"), line)
        }
    }

    func test_sanitizedUsageLabel_acceptsCallSiteLabels() {
        // 実際に呼び出し側が渡すラベルは全部そのまま通ること
        for label in [
            "chat", "cleaner-single", "cleaner-batch-12", "catchup", "overview", "title"
        ] {
            XCTAssertEqual(OpenAIChatClient.sanitizedUsageLabel(label), label)
        }
    }

    func test_sanitizedUsageLabel_rejectsAnythingElse() {
        for label in [
            "", "-", "Overview", "with space", "日本語", "unknown-label",
            // 小文字英数とハイフンだけで構成される「一見安全な」文字列も、
            // 既知ラベルでなければ捨てる (APIキーがこの形をしている)
            "sk-proj-abcdef0123456789", "xai-abcdef0123456789",
            "cleaner-batch-abc", "cleaner-batch-123456",
            "quote\"inside", "new\nline", String(repeating: "a", count: 49)
        ] {
            XCTAssertEqual(OpenAIChatClient.sanitizedUsageLabel(label), "invalid-label",
                           "ラベル '\(label)' が素通りしている")
        }
    }

    // MARK: - usage の取り出し

    func test_usageObject_extractsUsageOnly() throws {
        let json = """
        {"choices":[{"message":{"content":"秘密の本文"}}],
         "usage":{"prompt_tokens":10,"completion_tokens":2}}
        """
        let usage = try XCTUnwrap(OpenAIChatClient.usageObject(from: Data(json.utf8)))
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 10)
        XCTAssertNil(usage["choices"])
    }

    func test_usageObject_missingOrBrokenJSON_returnsNil() {
        XCTAssertNil(OpenAIChatClient.usageObject(from: Data("not json".utf8)))
        XCTAssertNil(OpenAIChatClient.usageObject(from: Data(#"{"choices":[]}"#.utf8)))
    }
}
