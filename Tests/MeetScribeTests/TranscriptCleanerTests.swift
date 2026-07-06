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
}
