import XCTest
@testable import MeetScribeCore

final class TranscriptCleanerTests: XCTestCase {

    // MARK: - shouldClean

    func test_shouldClean_shortText_false() {
        XCTAssertFalse(TranscriptCleaner.shouldClean("はい"))
        XCTAssertFalse(TranscriptCleaner.shouldClean("OK"))
        XCTAssertFalse(TranscriptCleaner.shouldClean("  そう  "))
        XCTAssertFalse(TranscriptCleaner.shouldClean(""))
    }

    func test_shouldClean_normalSegment_true() {
        XCTAssertTrue(TranscriptCleaner.shouldClean("えーと、今日はあの、会議の日程について話します"))
        XCTAssertTrue(TranscriptCleaner.shouldClean("So um, today we will discuss the schedule"))
    }

    // MARK: - parseCleanResult (JSON応答のパース / formatAndTranslate = 従来動作)

    func test_parseCleanResult_japanese_noTranslation() {
        let json = #"{"cleaned": "今日は会議です", "translation_ja": null}"#
        let result = TranscriptCleaner.parseCleanResult(json, mode: .formatAndTranslate)

        XCTAssertEqual(result?.cleaned, "今日は会議です")
        XCTAssertNil(result?.translationJa)
    }

    func test_parseCleanResult_english_withTranslation() {
        let json = #"{"cleaned": "Let's start the meeting.", "translation_ja": "会議を始めましょう。"}"#
        let result = TranscriptCleaner.parseCleanResult(json, mode: .formatAndTranslate)

        XCTAssertEqual(result?.cleaned, "Let's start the meeting.")
        XCTAssertEqual(result?.translationJa, "会議を始めましょう。")
    }

    func test_parseCleanResult_emptyTranslation_treatedAsNil() {
        let json = #"{"cleaned": "text here", "translation_ja": "  "}"#
        let result = TranscriptCleaner.parseCleanResult(json, mode: .formatAndTranslate)

        XCTAssertEqual(result?.cleaned, "text here")
        XCTAssertNil(result?.translationJa)
    }

    func test_parseCleanResult_emptyCleaned_returnsNil() {
        XCTAssertNil(TranscriptCleaner.parseCleanResult(
            #"{"cleaned": "", "translation_ja": null}"#, mode: .formatAndTranslate
        ))
    }

    func test_parseCleanResult_malformed_returnsNil() {
        XCTAssertNil(TranscriptCleaner.parseCleanResult("not json", mode: .formatAndTranslate))
        XCTAssertNil(TranscriptCleaner.parseCleanResult(#"{"other": 1}"#, mode: .formatAndTranslate))
        XCTAssertNil(TranscriptCleaner.parseCleanResult("not json", mode: .translateOnly))
    }

    // MARK: - parseCleanResult (translateOnly)

    func test_parseCleanResult_translateOnly_takesTranslationAndLeavesCleanedNil() {
        let result = TranscriptCleaner.parseCleanResult(
            #"{"translation_ja": "会議を始めましょう。"}"#, mode: .translateOnly
        )

        XCTAssertEqual(result?.translationJa, "会議を始めましょう。")
        XCTAssertNil(result?.cleaned, "本文を書き換える材料を持ってはいけない")
    }

    /// 訳が無ければ反映するものが無い (日本語原文)。
    func test_parseCleanResult_translateOnly_nullTranslation_returnsNil() {
        XCTAssertNil(TranscriptCleaner.parseCleanResult(
            #"{"translation_ja": null}"#, mode: .translateOnly
        ))
    }

    /// プロンプトで求めていない `cleaned` が返ってきても、本文の書き換えには使わない。
    func test_parseCleanResult_translateOnly_ignoresUnrequestedCleaned() {
        let result = TranscriptCleaner.parseCleanResult(
            #"{"cleaned": "In my experience", "translation_ja": "私の経験では"}"#,
            mode: .translateOnly
        )

        XCTAssertNil(result?.cleaned, "translateOnly で原文改変の材料を通してはいけない")
        XCTAssertEqual(result?.translationJa, "私の経験では")
    }

    // MARK: - parseBatchResult (バッチ応答のパース / formatAndTranslate = 従来動作)

    func test_parseBatchResult_multipleItems_parsesAll() {
        let json = #"""
        {"items": [
            {"id": "a", "cleaned": "今日は会議です", "translation_ja": null},
            {"id": "b", "cleaned": "Let's start.", "translation_ja": "始めましょう。"}
        ]}
        """#
        let result = TranscriptCleaner.parseBatchResult(json, mode: .formatAndTranslate)

        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].itemId, "a")
        XCTAssertEqual(result?[0].result.cleaned, "今日は会議です")
        XCTAssertNil(result?[0].result.translationJa)
        XCTAssertEqual(result?[1].itemId, "b")
        XCTAssertEqual(result?[1].result.cleaned, "Let's start.")
        XCTAssertEqual(result?[1].result.translationJa, "始めましょう。")
    }

    func test_parseBatchResult_topLevelMalformed_returnsNil() {
        for mode in CleanerMode.allCases {
            XCTAssertNil(TranscriptCleaner.parseBatchResult("not json", mode: mode))
            XCTAssertNil(TranscriptCleaner.parseBatchResult(#"{"other": 1}"#, mode: mode))
        }
    }

    func test_parseBatchResult_oneItemMalformed_skipsOnlyThatItem() {
        let json = #"""
        {"items": [
            {"id": "a", "cleaned": "正常なテキスト", "translation_ja": null},
            {"id": "b", "cleaned": "", "translation_ja": null},
            {"missing_id": true}
        ]}
        """#
        let result = TranscriptCleaner.parseBatchResult(json, mode: .formatAndTranslate)

        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.itemId, "a")
    }

    func test_parseBatchResult_emptyItemsArray_returnsEmptyNotNil() {
        for mode in CleanerMode.allCases {
            XCTAssertEqual(TranscriptCleaner.parseBatchResult(#"{"items": []}"#, mode: mode)?.count, 0)
        }
    }

    // MARK: - parseBatchResult (translateOnly)
    //
    // translateOnly の応答には `cleaned` が無い。本文には触れず訳だけ反映するため、
    // `cleaned` は nil で返ってこなければならない (nil が「本文を書き換えない」の合図)。

    func test_parseBatchResult_translateOnly_parsesTranslationOnlyResponse() {
        let json = #"""
        {"items": [
            {"id": "a", "translation_ja": "始めましょう。"},
            {"id": "b", "translation_ja": "次のスライドです。"}
        ]}
        """#
        let result = TranscriptCleaner.parseBatchResult(json, mode: .translateOnly)

        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].itemId, "a")
        XCTAssertEqual(result?[0].result.translationJa, "始めましょう。")
        XCTAssertNil(result?[0].result.cleaned)
        XCTAssertEqual(result?[1].result.translationJa, "次のスライドです。")
        XCTAssertNil(result?[1].result.cleaned)
    }

    /// 日本語原文 (translation_ja が null) は反映するものが無いので結果に含めない。
    func test_parseBatchResult_translateOnly_skipsItemsWithoutTranslation() {
        let json = #"""
        {"items": [
            {"id": "ja", "translation_ja": null},
            {"id": "blank", "translation_ja": "   "},
            {"id": "en", "translation_ja": "始めましょう。"}
        ]}
        """#
        let result = TranscriptCleaner.parseBatchResult(json, mode: .translateOnly)

        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.itemId, "en")
    }

    /// 求めていない `cleaned` が混ざっても本文書き換えには使わない
    /// (整形なしの狙いは "In my history" → "In my experience" 型の原文改変を防ぐこと)。
    func test_parseBatchResult_translateOnly_ignoresUnrequestedCleaned() {
        let json = #"""
        {"items": [{"id": "a", "cleaned": "In my experience", "translation_ja": "私の経験では"}]}
        """#
        let result = TranscriptCleaner.parseBatchResult(json, mode: .translateOnly)

        XCTAssertEqual(result?.count, 1)
        XCTAssertNil(result?.first?.result.cleaned)
        XCTAssertEqual(result?.first?.result.translationJa, "私の経験では")
    }

    /// 逆に formatAndTranslate は `cleaned` が無い応答を採用しない (本文が消える事故を防ぐ)。
    func test_parseBatchResult_formatAndTranslate_skipsItemsWithoutCleaned() {
        let json = #"{"items": [{"id": "a", "translation_ja": "始めましょう。"}]}"#
        XCTAssertEqual(
            TranscriptCleaner.parseBatchResult(json, mode: .formatAndTranslate)?.count,
            0
        )
    }

    // MARK: - diagnosticShape (パース失敗の診断)
    //
    // 目的は「なぜ size=1 のバッチ応答が 5〜17% パースできないのか」を確定させること。
    // **本文を1文字も漏らさない**ことが前提条件なので、そこを重点的に固定する。

    func test_diagnosticShape_singularItemsObject_isIdentifiable() {
        // 有力候補その1: items が配列でなく単数のオブジェクトで返る
        let shape = TranscriptCleaner.diagnosticShape(of: #"{"items": {"id": "a", "cleaned": "text"}}"#)
        XCTAssertTrue(shape.contains("top-level=object(1)"), shape)
        XCTAssertTrue(shape.contains("items=object(2)"), shape)
        XCTAssertTrue(shape.contains("cleaned=string(4 chars)"), shape)
    }

    func test_diagnosticShape_renamedKey_isIdentifiable() {
        // 有力候補その2: キー名が変わる
        let shape = TranscriptCleaner.diagnosticShape(of: #"{"segments": [{"id": "a"}]}"#)
        XCTAssertTrue(shape.contains("segments=array(1)"), shape)
    }

    func test_diagnosticShape_flatArray_isIdentifiable() {
        let shape = TranscriptCleaner.diagnosticShape(of: #"[{"id": "a", "cleaned": "text"}]"#)
        XCTAssertTrue(shape.contains("top-level=array(1) of object(2)"), shape)
    }

    func test_diagnosticShape_unparsable_reportsBytesOnly() {
        let shape = TranscriptCleaner.diagnosticShape(of: "Sorry, I cannot help with that")
        XCTAssertTrue(shape.hasPrefix("top-level=unparsable"), shape)
        XCTAssertFalse(shape.contains("Sorry"), shape)
        XCTAssertTrue(shape.contains("bytes"), shape)
    }

    func test_diagnosticShape_manyKeys_isBounded() {
        var obj: [String: Any] = [:]
        for i in 0..<20 { obj["k\(i)"] = i }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let shape = TranscriptCleaner.diagnosticShape(of: String(decoding: data, as: UTF8.self))

        XCTAssertTrue(
            shape.contains("+\(20 - TranscriptCleaner.maxDiagnosticKeys) more"),
            shape
        )
        XCTAssertLessThan(shape.count, 400, "診断ログが長すぎる: \(shape)")
    }

    /// **本文の流出ゼロ。** キー名・ネスト・配列・トップレベル文字列など、
    /// モデルが本文をどこに入れて返しても値が出ないことを固定する
    /// (ログは平文で長期間残るため、値の出力は議事録の意図しない二重保存になる)。
    func test_diagnosticShape_neverLeaksTranscriptContent() {
        let japanese = "本日の会議では新製品の価格を1200円に決定しました"
        let english = "we decided the price today"
        let payloads = [
            #"{"items": [{"id": "a", "cleaned": "\#(japanese)"}]}"#,
            #"{"\#(japanese)": 1}"#,
            #"{"\#(english)": {"cleaned": "\#(japanese)"}}"#,
            #"["\#(japanese)", "\#(english)"]"#,
            #"{"items": {"deep": {"deeper": {"cleaned": "\#(japanese)"}}}}"#,
            #""\#(japanese)""#,
            japanese
        ]

        for payload in payloads {
            let shape = TranscriptCleaner.diagnosticShape(of: payload)
            XCTAssertFalse(shape.contains(japanese), "本文が漏れた: \(shape)")
            XCTAssertFalse(shape.contains(english), "本文が漏れた: \(shape)")
            // 断片も出さない
            XCTAssertFalse(shape.contains("価格"), "本文の断片が漏れた: \(shape)")
            XCTAssertFalse(shape.contains("decided"), "本文の断片が漏れた: \(shape)")
            XCTAssertFalse(shape.contains("1200"), "本文の断片が漏れた: \(shape)")
        }
    }

    func test_sanitizedKey_keepsIdentifiersRedactsEverythingElse() {
        // スキーマのキー名 (これが分かれば原因が特定できる)
        XCTAssertEqual(TranscriptCleaner.sanitizedKey("items"), "items")
        XCTAssertEqual(TranscriptCleaner.sanitizedKey("translation_ja"), "translation_ja")
        XCTAssertEqual(TranscriptCleaner.sanitizedKey("item-1.id"), "item-1.id")
        // 本文になり得るもの: 日本語・空白入り・長すぎる・空
        XCTAssertEqual(TranscriptCleaner.sanitizedKey("えー、今日は"), "<redacted:6 chars>")
        XCTAssertEqual(TranscriptCleaner.sanitizedKey("two words"), "<redacted:9 chars>")
        XCTAssertEqual(
            TranscriptCleaner.sanitizedKey(String(repeating: "a", count: 25)),
            "<redacted:25 chars>"
        )
        XCTAssertEqual(TranscriptCleaner.sanitizedKey(""), "<redacted:0 chars>")
        XCTAssertEqual(TranscriptCleaner.sanitizedKey("Hello, world!"), "<redacted:13 chars>")
    }
}

final class OpenAIChatClientTests: XCTestCase {

    private func makeResponse(content: String, promptTokens: Int, completionTokens: Int) -> Data {
        let obj: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": content]]
            ],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func test_parseResponse_extractsContentAndCost() {
        let data = makeResponse(content: " 今日は会議です \n", promptTokens: 100, completionTokens: 50)
        let result = OpenAIChatClient.parseResponse(data)

        XCTAssertEqual(result.text, "今日は会議です")
        let expected = 100.0 * OpenAIChatClient.inputRate + 50.0 * OpenAIChatClient.outputRate
        XCTAssertEqual(result.costUSD, expected, accuracy: 1e-12)
    }

    func test_parseResponse_malformedData_returnsNilAndZero() {
        let result = OpenAIChatClient.parseResponse(Data("not json".utf8))
        XCTAssertNil(result.text)
        XCTAssertEqual(result.costUSD, 0)
    }

    func test_parseResponse_missingChoices_returnsNilButCost() {
        let obj: [String: Any] = ["usage": ["prompt_tokens": 10, "completion_tokens": 0]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let result = OpenAIChatClient.parseResponse(data)

        XCTAssertNil(result.text)
        XCTAssertEqual(result.costUSD, 10.0 * OpenAIChatClient.inputRate, accuracy: 1e-12)
    }

    func test_rates_matchDocumentedPricing() {
        XCTAssertEqual(OpenAIChatClient.inputRate, 0.40 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(OpenAIChatClient.outputRate, 1.60 / 1_000_000, accuracy: 1e-15)
    }

    func test_parseResponse_xAI_usesGrokRates() {
        let data = makeResponse(content: "ok", promptTokens: 100, completionTokens: 50)
        let result = OpenAIChatClient.parseResponse(data, provider: .xAI)
        let expected = 100.0 * AIProvider.xAI.chatInputRate
            + 50.0 * AIProvider.xAI.chatOutputRate

        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(result.costUSD, expected, accuracy: 1e-12)
    }

    // MARK: - タイムアウト
    //
    // 2026-08-14 の講義中に実測: cleaner 85件中1件 (1.2%) が20秒でタイムアウトし、
    // **そのバッチ3件ぶんの対訳が丸ごと落ちた**。1件の失敗が複数セグメントに波及するため、
    // 単発より長く取る。値を戻すと同じ取りこぼしが再発するので数値ごと固定する。

    func test_timeouts_areLongEnoughForObservedLatency() {
        XCTAssertEqual(TranscriptCleaner.batchTimeoutSeconds, 40)
        XCTAssertEqual(TranscriptCleaner.singleTimeoutSeconds, 30)
    }

    /// バッチは件数ぶん出力が長くなるので、単発より短くしてはいけない。
    func test_batchTimeout_isNotShorterThanSingle() {
        XCTAssertGreaterThanOrEqual(
            TranscriptCleaner.batchTimeoutSeconds,
            TranscriptCleaner.singleTimeoutSeconds
        )
    }

    /// タイムアウトに張り付いた in-flight バッチがあると停止が延びる
    /// (`flushAll` が完了を待つ)。`waitForSaveCompletion` の90秒上限に収まること。
    func test_batchTimeout_fitsWithinSaveCompletionBudget() {
        XCTAssertLessThan(TranscriptCleaner.batchTimeoutSeconds, 90)
    }

    /// 旧値 (単発15秒 / バッチ20秒) より延ばしたことを固定する。
    func test_timeouts_exceedPreviousValues() {
        XCTAssertGreaterThan(TranscriptCleaner.singleTimeoutSeconds, 15)
        XCTAssertGreaterThan(TranscriptCleaner.batchTimeoutSeconds, 20)
    }
}
