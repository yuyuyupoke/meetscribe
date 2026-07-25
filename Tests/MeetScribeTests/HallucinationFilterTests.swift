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

    // MARK: - Repetition hallucination (実議事録で観測されたパターン)

    func test_shouldFilter_repeatedAizuchi_returnsTrue() {
        XCTAssertTrue(HallucinationFilter.shouldFilter("うんうんうんうんうん"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("うん、うん、うん、うん、うん、うん"))
        XCTAssertTrue(HallucinationFilter.shouldFilter("はいはいはいはい"))
    }

    func test_shouldFilter_repeatedEnglishPhrase_returnsTrue() {
        let text = String(repeating: "Information Technology, ", count: 12)
        XCTAssertTrue(HallucinationFilter.shouldFilter(text))
        // 先頭に周期からずれた断片が付いても検出できる
        XCTAssertTrue(HallucinationFilter.shouldFilter("Technology, " + text))
    }

    func test_shouldFilter_repeatedNumberSequence_returnsTrue() {
        // 2026-07-24 の議事録で観測された数字カウントの周期反復
        let cycle = "二十十一二十十二二十十三二十十四二十十五二十十六二十十七二十十八二十十九二十二十"
        XCTAssertTrue(HallucinationFilter.shouldFilter(String(repeating: cycle, count: 8)))
    }

    func test_shouldFilter_emphasisRepetitionInRealSpeech_returnsFalse() {
        // 実発話の強調反復: 反復部分が全体の6割未満なら残す
        XCTAssertFalse(HallucinationFilter.shouldFilter("いやいやいやいや、それは違うでしょ"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("はいはい、わかりました。では次の議題に進みましょう"))
    }

    func test_shouldFilter_shortRepetition_returnsFalse() {
        // 4回未満の反復は自然な発話 (最小長8文字未満も対象外)
        XCTAssertFalse(HallucinationFilter.shouldFilter("うんうんうん"))
        XCTAssertFalse(HallucinationFilter.shouldFilter("そうそう、その件です"))
    }

    func test_isRepetitionHallucination_normalLongSentence_returnsFalse() {
        XCTAssertFalse(HallucinationFilter.isRepetitionHallucination(
            "今日の会議では営業リストの作成方針について三つの観点から議論を行いました"
        ))
    }
}
