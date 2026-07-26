import XCTest
@testable import MeetScribeCore

/// 議事録タイトルの後処理。
/// BYOK 化でチャットモデルの生出力を直接扱うようになったため、
/// 指示に従わない応答（引用符・接頭辞・改行・長すぎる出力）を確実に落とす。
final class MeetingTitleGeneratorTests: XCTestCase {

    func test_cleanUp_trimsWhitespaceAndNewlines() {
        XCTAssertEqual(MeetingTitleGenerator.cleanUp("  営業戦略の検討  \n"), "営業戦略の検討")
    }

    func test_cleanUp_collapsesInternalNewlines() {
        XCTAssertEqual(MeetingTitleGenerator.cleanUp("営業戦略\nの検討"), "営業戦略 の検討")
    }

    func test_cleanUp_stripsQuotes() {
        XCTAssertEqual(MeetingTitleGenerator.cleanUp("\"営業戦略の検討\""), "営業戦略の検討")
        XCTAssertEqual(MeetingTitleGenerator.cleanUp("「営業戦略の検討」"), "営業戦略の検討")
        XCTAssertEqual(MeetingTitleGenerator.cleanUp("『営業戦略の検討』"), "営業戦略の検討")
    }

    func test_cleanUp_stripsLabelPrefixes() {
        XCTAssertEqual(MeetingTitleGenerator.cleanUp("タイトル: 営業戦略の検討"), "営業戦略の検討")
        XCTAssertEqual(MeetingTitleGenerator.cleanUp("タイトル：営業戦略の検討"), "営業戦略の検討")
        XCTAssertEqual(MeetingTitleGenerator.cleanUp("会議タイトル: 営業戦略の検討"), "営業戦略の検討")
        XCTAssertEqual(MeetingTitleGenerator.cleanUp("# 営業戦略の検討"), "営業戦略の検討")
    }

    /// ファイル名に使われるため、長すぎる応答は必ず切り詰める。
    func test_cleanUp_truncatesTo30Characters() {
        let long = String(repeating: "あ", count: 100)
        XCTAssertEqual(MeetingTitleGenerator.cleanUp(long).count, 30)
    }

    func test_cleanUp_emptyInput_returnsEmpty() {
        // 呼び出し側は空文字を fallbackTitle に振り替える
        XCTAssertTrue(MeetingTitleGenerator.cleanUp("   \n  ").isEmpty)
    }

    // MARK: - 生成の前提条件

    /// APIキーが無いときはネットワークに触れずフォールバックすること。
    func test_generate_withoutAPIKey_returnsFallback() async {
        let title = await MeetingTitleGenerator.generate(
            from: String(repeating: "会議の内容です。", count: 10),
            apiKey: nil,
            provider: .xAI
        )
        XCTAssertTrue(title.hasPrefix("会議_"), "フォールバック名でない: \(title)")
    }

    /// 短すぎる文字起こしは生成を試みない（課金を避ける）。
    func test_generate_withTooShortTranscript_returnsFallback() async {
        let title = await MeetingTitleGenerator.generate(
            from: "短い",
            apiKey: "dummy-key",
            provider: .xAI
        )
        XCTAssertTrue(title.hasPrefix("会議_"), "フォールバック名でない: \(title)")
    }
}
