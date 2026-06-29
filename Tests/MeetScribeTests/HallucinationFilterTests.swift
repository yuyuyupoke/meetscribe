import XCTest
@testable import MeetScribeCore

final class HallucinationFilterTests: XCTestCase {

    // MARK: - Known hallucination patterns

    func test_shouldFilter_arigatou_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("ありがとうございます"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("ありがとうございました"))
    }

    func test_shouldFilter_goshichou_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("ご視聴ありがとうございました"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("ご覧いただきありがとうございます"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("ご視聴ありがとうございます"))
    }

    func test_shouldFilter_hai_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("はい"))
    }

    func test_shouldFilter_soudesune_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("そうですね"))
    }

    func test_shouldFilter_otsukaresama_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("お疲れ様でした"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("お疲れ様です"))
    }

    func test_shouldFilter_yoroshiku_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("よろしくお願いします"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("よろしくお願いいたします"))
    }

    func test_shouldFilter_greetings_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("おはようございます"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("こんにちは"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("こんばんは"))
    }

    func test_shouldFilter_other_patterns_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("失礼します"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("以上です"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("うん"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("ええ"))
    }

    // MARK: - Empty / whitespace / punctuation

    func test_shouldFilter_emptyString_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter(""))
    }

    func test_shouldFilter_whitespaceOnly_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("   "))
        XCTAssertTrue(HallucinationFilter.shouldFilter("\t\n"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("　")) // full-width space
    }

    func test_shouldFilter_punctuationOnly_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("。"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("、"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("..."))
        XCTAssertTrue(HallucinationFilter.shouldFilter("！？"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("，．"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("・"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("…"))
    }

    // MARK: - Normal text (should NOT be filtered)

    func test_shouldFilter_normalSentence_returnsFalse() {
        XCTAssertFalse(HallucinationFilter.shouldFilter("今日の会議について説明します"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("次のスライドに移ります"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("この問題の解決策を考えましょう"))
    }

    func test_shouldFilter_patternInLongerText_returnsFalse() {
        XCTAssertFalse(HallucinationFilter.shouldFilter("ありがとうございます、次は資料の確認です"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("はい、分かりました"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("そうですね、でも別の方法もあります"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("お疲れ様です、今日の議題は三点あります"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("よろしくお願いします。本日は"))
    }

    func test_shouldFilter_shortButNotPattern_returnsFalse() {
        XCTAssertFalse(HallucinationFilter.shouldFilter("いいえ"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("なるほど"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("了解"))
    }

    // MARK: - Whitespace trimming

    func test_shouldFilter_patternWithSurroundingWhitespace_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("  ありがとうございます  "))
        XCTAssertTrue(HallucinationFilter.shouldFilter("\nはい\n"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("　そうですね　"))
    }

    // MARK: - Edge cases

    func test_shouldFilter_singleCharacters_returnsFalse() {
        XCTAssertFalse(HallucinationFilter.shouldFilter("あ"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("A"))
    }

    func test_shouldFilter_numbers_returnsFalse() {
        XCTAssertFalse(HallucinationFilter.shouldFilter("123"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("2024年"))
    }
}
