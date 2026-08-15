import XCTest
@testable import MeetScribeCore

/// モデル応答から特殊トークンを剥がす処理のテスト。
///
/// 2026-08-13 に実APIで確定した欠陥の回帰テスト。grok-4.3 は
/// `response_format: json_object` を指定しても応答末尾に `<|eos|>` を生テキストで吐き、
/// JSON本体が完全なのに `JSONSerialization` が `Extra data` で落ちていた。
/// 本番ログでは cleaner 呼び出しの 5〜17% がこれで失敗し、**課金済みの応答を捨てて
/// 対訳が欠落**していた。cleaner / overview / catchup / title の4経路すべてが
/// `OpenAIChatClient.parseResponse` を通るので、そこで剥がして全経路を守る。
final class ModelTextSanitizationTests: XCTestCase {

    // MARK: - 実測データの回帰テスト

    /// 2026-08-13 に実際に観測した応答の形 (末尾に `<|eos|>`)。
    /// 桁を合わせるため中身は短くしてあるが、構造と混入位置は実物と同じ。
    private let observedCleanerResponse =
        #"{"items": [{"id": "s1", "cleaned": "abc", "translation_ja": "あいう"}]}<|eos|>"#

    func test_observedCleanerResponse_isUnparsableBeforeSanitizing() throws {
        // サニタイズ前は落ちる = これが実際に起きていた失敗
        let data = try XCTUnwrap(observedCleanerResponse.data(using: .utf8))
        XCTAssertNil(
            try? JSONSerialization.jsonObject(with: data),
            "この応答が素通りするなら、そもそも欠陥が再現していない"
        )
        XCTAssertNil(
            TranscriptCleaner.parseBatchResult(observedCleanerResponse, mode: .formatAndTranslate),
            "サニタイズ前は整形結果を取り出せない (= 対訳が欠落していた)"
        )
    }

    func test_observedCleanerResponse_parsesAfterSanitizing() throws {
        let cleaned = OpenAIChatClient.sanitizeModelText(observedCleanerResponse)
        // 観測した応答は formatAndTranslate 期のスキーマ (`cleaned` 入り) なので、
        // そのモードでパースして当時の欠陥を再現・回帰させる。
        let items = try XCTUnwrap(
            TranscriptCleaner.parseBatchResult(cleaned, mode: .formatAndTranslate),
            "サニタイズ後はパースできなければならない"
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.itemId, "s1")
        XCTAssertEqual(items.first?.result.cleaned, "abc")
        XCTAssertEqual(items.first?.result.translationJa, "あいう")
    }

    func test_observedOverviewResponse_parsesAfterSanitizing() throws {
        let raw = #"{"purpose": "目的", "agenda": ["議題1", "議題2"], "current_topic": "現在地"}<|eos|>"#
        XCTAssertNil(MeetingOverview.parse(raw), "サニタイズ前は落ちる")

        let overview = try XCTUnwrap(
            MeetingOverview.parse(OpenAIChatClient.sanitizeModelText(raw))
        )
        XCTAssertEqual(overview.purpose, "目的")
        XCTAssertEqual(overview.agenda, ["議題1", "議題2"])
        XCTAssertEqual(overview.currentTopic, "現在地")
    }

    /// タイトルは JSON ではないので落ちはしないが、`<|eos|>` が
    /// **議事録のファイル名**に混入する経路になっていた。
    func test_titleResponse_dropsSpecialToken() {
        let sanitized = OpenAIChatClient.sanitizeModelText("オフショア入門<|eos|>")
        XCTAssertEqual(sanitized, "オフショア入門")
        XCTAssertEqual(MeetingTitleGenerator.cleanUp(sanitized), "オフショア入門")
        XCTAssertFalse(MeetingTitleGenerator.cleanUp(sanitized).contains("<|"))
    }

    // MARK: - parseResponse への配線 (関数を作って繋ぎ忘れる罠を防ぐ)

    private func responseData(content: String) throws -> Data {
        let payload: [String: Any] = [
            "choices": [["message": ["content": content]]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5]
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    func test_parseResponse_stripsSpecialTokenFromContent() throws {
        let data = try responseData(content: observedCleanerResponse)
        let (text, _) = OpenAIChatClient.parseResponse(data, provider: .xAI)
        let content = try XCTUnwrap(text)
        XCTAssertFalse(content.contains("<|eos|>"), "parseResponse が剥がしていない = 配線漏れ")
        XCTAssertNotNil(TranscriptCleaner.parseBatchResult(content, mode: .formatAndTranslate))
    }

    /// サニタイズはテキストだけの処理で、課金額の計算には触れない。
    func test_parseResponse_costIsUnaffectedBySanitizing() throws {
        let payload: [String: Any] = [
            "choices": [["message": ["content": "text<|eos|>"]]],
            "usage": ["prompt_tokens": 1_000, "completion_tokens": 500, "cost_in_usd_ticks": 12_345]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let (_, cost) = OpenAIChatClient.parseResponse(data, provider: .xAI)
        XCTAssertEqual(cost, 12_345 / OpenAIChatClient.usdTicksPerDollar, accuracy: 1e-12)
    }

    // MARK: - 正常な応答を壊さない (最悪の退行はこれ)

    func test_sanitize_leavesNormalResponsesByteIdentical() {
        let samples = [
            #"{"items": [{"id": "s1", "cleaned": "hello", "translation_ja": null}]}"#,
            #"{"purpose": "p", "agenda": ["a", "b"], "current_topic": "c"}"#,
            "会議タイトル",
            #"{"cleaned": "改行を\n含む\tテキスト"}"#,
            #"{"cleaned": "絵文字 🎉 と \"エスケープ済みの引用符\" を含む"}"#,
            "" // 空文字
        ]
        for s in samples {
            XCTAssertEqual(OpenAIChatClient.sanitizeModelText(s), s, "正常な応答が変化した: \(s)")
        }
    }

    func test_sanitize_trimsSurroundingWhitespaceLikeBefore() {
        // 従来 parseResponse は trim していた。挙動を変えない
        XCTAssertEqual(OpenAIChatClient.sanitizeModelText("  text  "), "text")
        XCTAssertEqual(OpenAIChatClient.sanitizeModelText("\n{\"a\":1}\n"), #"{"a":1}"#)
    }

    // MARK: - 本文中の `<|` を食い潰さない

    /// 発話に `<|` が現れても本文として残す。ここを緩めると
    /// 「トークンの開始に見えるが閉じない」入力で本文が丸ごと消える。
    func test_sanitize_keepsBodyTextThatLooksLikeTokenStart() {
        XCTAssertEqual(
            OpenAIChatClient.sanitizeModelText("use <| as a pipe"),
            "use <| as a pipe"
        )
        XCTAssertEqual(
            OpenAIChatClient.sanitizeModelText("a <| b |> c"),
            "a <| b |> c",
            "空白を含む中身はトークン名として妥当でないので本文扱い"
        )
        XCTAssertEqual(
            OpenAIChatClient.sanitizeModelText("<||>"),
            "<||>",
            "空のトークン名は除去対象にしない"
        )
        // 33文字以上のトークン名は本文扱い (上限を超えたら食わない)
        let longName = String(repeating: "a", count: 33)
        XCTAssertEqual(
            OpenAIChatClient.sanitizeModelText("x<|\(longName)|>y"),
            "x<|\(longName)|>y"
        )
    }

    // MARK: - トークンの位置と個数

    func test_sanitize_removesTokensAnywhereAndRepeatedly() {
        XCTAssertEqual(OpenAIChatClient.sanitizeModelText("<|eos|>tail"), "tail")
        XCTAssertEqual(OpenAIChatClient.sanitizeModelText("head<|eos|>"), "head")
        XCTAssertEqual(OpenAIChatClient.sanitizeModelText("a<|eos|>b<|endoftext|>c"), "abc")
        XCTAssertEqual(OpenAIChatClient.sanitizeModelText("a<|eos|><|eos|>b"), "ab")
        XCTAssertEqual(
            OpenAIChatClient.sanitizeModelText("<|im_start|>x<|im_end|>"),
            "x",
            "アンダースコアを含むトークン名も対象"
        )
        XCTAssertEqual(
            OpenAIChatClient.sanitizeModelText("<|eot-1|>x"),
            "x",
            "ハイフンと数字を含むトークン名も対象"
        )
    }

    func test_sanitize_tokenOnlyResponse_becomesEmpty() {
        XCTAssertEqual(OpenAIChatClient.sanitizeModelText("<|eos|>"), "")
        XCTAssertEqual(OpenAIChatClient.sanitizeModelText("  <|eos|>  "), "")
    }
}
