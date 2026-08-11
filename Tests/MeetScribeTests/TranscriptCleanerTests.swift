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

    // MARK: - parseCleanResult (JSON応答のパース)

    func test_parseCleanResult_japanese_noTranslation() {
        let json = #"{"cleaned": "今日は会議です", "translation_ja": null}"#
        let result = TranscriptCleaner.parseCleanResult(json)

        XCTAssertEqual(result?.cleaned, "今日は会議です")
        XCTAssertNil(result?.translationJa)
    }

    func test_parseCleanResult_english_withTranslation() {
        let json = #"{"cleaned": "Let's start the meeting.", "translation_ja": "会議を始めましょう。"}"#
        let result = TranscriptCleaner.parseCleanResult(json)

        XCTAssertEqual(result?.cleaned, "Let's start the meeting.")
        XCTAssertEqual(result?.translationJa, "会議を始めましょう。")
    }

    func test_parseCleanResult_emptyTranslation_treatedAsNil() {
        let json = #"{"cleaned": "text here", "translation_ja": "  "}"#
        let result = TranscriptCleaner.parseCleanResult(json)

        XCTAssertEqual(result?.cleaned, "text here")
        XCTAssertNil(result?.translationJa)
    }

    func test_parseCleanResult_emptyCleaned_returnsNil() {
        XCTAssertNil(TranscriptCleaner.parseCleanResult(#"{"cleaned": "", "translation_ja": null}"#))
    }

    func test_parseCleanResult_malformed_returnsNil() {
        XCTAssertNil(TranscriptCleaner.parseCleanResult("not json"))
        XCTAssertNil(TranscriptCleaner.parseCleanResult(#"{"other": 1}"#))
    }

    // MARK: - parseBatchResult (バッチ応答のパース)

    func test_parseBatchResult_multipleItems_parsesAll() {
        let json = #"""
        {"items": [
            {"id": "a", "cleaned": "今日は会議です", "translation_ja": null},
            {"id": "b", "cleaned": "Let's start.", "translation_ja": "始めましょう。"}
        ]}
        """#
        let result = TranscriptCleaner.parseBatchResult(json)

        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0].itemId, "a")
        XCTAssertEqual(result?[0].result.cleaned, "今日は会議です")
        XCTAssertNil(result?[0].result.translationJa)
        XCTAssertEqual(result?[1].itemId, "b")
        XCTAssertEqual(result?[1].result.translationJa, "始めましょう。")
    }

    func test_parseBatchResult_topLevelMalformed_returnsNil() {
        XCTAssertNil(TranscriptCleaner.parseBatchResult("not json"))
        XCTAssertNil(TranscriptCleaner.parseBatchResult(#"{"other": 1}"#))
    }

    func test_parseBatchResult_oneItemMalformed_skipsOnlyThatItem() {
        let json = #"""
        {"items": [
            {"id": "a", "cleaned": "正常なテキスト", "translation_ja": null},
            {"id": "b", "cleaned": "", "translation_ja": null},
            {"missing_id": true}
        ]}
        """#
        let result = TranscriptCleaner.parseBatchResult(json)

        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.itemId, "a")
    }

    func test_parseBatchResult_emptyItemsArray_returnsEmptyNotNil() {
        let result = TranscriptCleaner.parseBatchResult(#"{"items": []}"#)
        XCTAssertEqual(result?.count, 0)
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
}
