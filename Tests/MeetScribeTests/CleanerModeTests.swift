import XCTest
@testable import MeetScribeCore

/// クリーナーのモード決定ロジックと、モードごとの system プロンプト。
///
/// 2026-08-14 の実測 (cleaner 604回) で、対訳表示の遅延は「バッチ待ち + LLM応答」で
/// 平均10秒・最悪14秒だった。整形をやめると出力 84 → 48 トークン、中央値
/// 1.59s → 1.24s、単価 -29% になる。英語講義では整形の仕事がほぼ無い
/// (2026-08-11 に `um`/`uh` が入力サンプルに1つも無いことを実測) ので既定を
/// `translateOnly` にした。ここで固定したいのは:
/// - 既定が `translateOnly` であること (回帰で遅い方に戻るのを防ぐ)
/// - 日本語会議向けに**必ず従来動作へ戻せる**こと (2026-07-25 に整形の効果を実測済み)
/// - GUI 起動でも戻せること (UserDefaults 経路が唯一の手段)
/// - `translateOnly` のプロンプトに整形の指示が混ざっていないこと
final class CleanerModeTests: XCTestCase {

    private let key = CleanerModePolicy.environmentKey

    /// 環境変数だけを見る解決 (テスト実行マシンに
    /// `defaults write com.meetscribe.app cleanerMode …` が入っていても結果が変わらないように、
    /// UserDefaults を明示的に切って呼ぶ)。
    private func resolveIgnoringUserDefaults(environment: [String: String]) -> CleanerMode {
        CleanerModePolicy.resolve(environment: environment, defaults: nil)
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
            defaults.set(value, forKey: CleanerModePolicy.userDefaultsKey)
        }
        // teardown へは Sendable な suite 名だけを渡す (UserDefaults インスタンスを
        // クロージャに送ると Swift 6 の strict concurrency で data race 判定になる)。
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    // MARK: - ポリシー定義

    func test_defaultMode_isTranslateOnly() {
        XCTAssertEqual(CleanerModePolicy.defaultMode, .translateOnly)
        XCTAssertEqual(CleanerModePolicy.environmentKey, "MEETSCRIBE_CLEANER_MODE")
    }

    /// 手順書に書く値。ここが変わると `defaults write` の手順が通らなくなる。
    func test_rawValues_areStable() {
        XCTAssertEqual(CleanerMode.translateOnly.rawValue, "translate-only")
        XCTAssertEqual(CleanerMode.formatAndTranslate.rawValue, "format-translate")
        XCTAssertEqual(CleanerModePolicy.allowed, ["translate-only", "format-translate"])
    }

    // MARK: - resolve

    func test_resolve_withoutAnySetting_returnsTranslateOnly() {
        XCTAssertEqual(resolveIgnoringUserDefaults(environment: [:]), .translateOnly)
    }

    func test_resolve_environment_selectsMode() {
        XCTAssertEqual(
            resolveIgnoringUserDefaults(environment: [key: "format-translate"]),
            .formatAndTranslate
        )
        XCTAssertEqual(
            resolveIgnoringUserDefaults(environment: [key: "translate-only"]),
            .translateOnly
        )
    }

    func test_resolve_isCaseInsensitiveAndTrimsWhitespace() {
        XCTAssertEqual(
            resolveIgnoringUserDefaults(environment: [key: "  FORMAT-TRANSLATE  "]),
            .formatAndTranslate
        )
        XCTAssertEqual(
            resolveIgnoringUserDefaults(environment: [key: "\tTranslate-Only\n"]),
            .translateOnly
        )
    }

    func test_resolve_unknownValue_fallsBackToDefault() {
        // 綴り間違いで整形も対訳も止まるより、既定で動き続けるほうが被害が小さい
        for raw in ["format", "translate", "formatAndTranslate", "off", "1", "", "   "] {
            XCTAssertEqual(
                resolveIgnoringUserDefaults(environment: [key: raw]),
                .translateOnly,
                "不正値 '\(raw)' が既定へ落ちていない"
            )
        }
    }

    // MARK: - UserDefaults 経路 (GUI起動時の唯一のロールバック手段)

    /// Finder/Dock/`open` から起動したアプリはシェルの環境変数を継承しないため、
    /// 環境変数だけだと**実際の使い方では従来動作に戻せない**。UserDefaults が必須。
    func test_userDefaultsKey_isStable() {
        // `defaults write com.meetscribe.app cleanerMode format-translate` が手順として成立すること
        XCTAssertEqual(CleanerModePolicy.userDefaultsKey, "cleanerMode")
    }

    func test_resolve_userDefaults_providesRollbackWithoutEnvironment() {
        let defaults = makeScratchDefaults("format-translate")
        XCTAssertEqual(
            CleanerModePolicy.resolve(environment: [:], defaults: defaults),
            .formatAndTranslate
        )
    }

    /// 恒久設定 (UserDefaults) を書き換えずに1回だけ試せるよう、環境変数を上に置く。
    func test_resolve_environmentWinsOverUserDefaults() {
        let defaults = makeScratchDefaults("format-translate")
        XCTAssertEqual(
            CleanerModePolicy.resolve(environment: [key: "translate-only"], defaults: defaults),
            .translateOnly
        )
    }

    /// 環境変数が不正なら「指定なし」と見なして UserDefaults に落ちる。
    func test_resolve_invalidEnvironment_fallsThroughToUserDefaults() {
        let defaults = makeScratchDefaults("format-translate")
        XCTAssertEqual(
            CleanerModePolicy.resolve(environment: [key: "nonsense"], defaults: defaults),
            .formatAndTranslate
        )
    }

    func test_resolve_userDefaults_unknownValue_fallsBackToDefault() {
        let defaults = makeScratchDefaults("nonsense")
        XCTAssertEqual(
            CleanerModePolicy.resolve(environment: [:], defaults: defaults),
            .translateOnly
        )
    }

    func test_resolve_emptyUserDefaults_returnsDefaultMode() {
        let defaults = makeScratchDefaults(nil)
        XCTAssertEqual(CleanerModePolicy.resolve(environment: [:], defaults: defaults), .translateOnly)
    }

    func test_resolve_nilDefaults_doesNotCrash() {
        XCTAssertEqual(CleanerModePolicy.resolve(environment: [:], defaults: nil), .translateOnly)
    }

    // MARK: - プロンプト
    //
    // translateOnly の狙いは「出力を減らして速くする」ことと「原文を改変させない」ことの
    // 両方。整形の指示が1行でも残っていると、モデルは cleaned を作ろうとして出力が伸び、
    // 原文改変 ("In my history" → "In my experience") のリスクも戻ってくる。

    private let formattingInstructions = [
        "整形", "フィラー", "言い間違い", "言い直し", "誤変換", "cleaned", "um"
    ]

    func test_translateOnlyPrompts_containNoFormattingInstructions() {
        for prompt in [
            TranscriptCleaner.systemPrompt(for: .translateOnly),
            TranscriptCleaner.batchSystemPrompt(for: .translateOnly)
        ] {
            for instruction in formattingInstructions {
                XCTAssertFalse(
                    prompt.contains(instruction),
                    "translateOnly のプロンプトに整形の指示 '\(instruction)' が残っている: \(prompt)"
                )
            }
            XCTAssertTrue(prompt.contains("translation_ja"), prompt)
        }
    }

    /// 出力スキーマは `translation_ja` だけ (`cleaned` を要求しない)。
    func test_translateOnlyPrompts_requestTranslationOnlySchema() {
        XCTAssertTrue(
            TranscriptCleaner.systemPrompt(for: .translateOnly)
                .contains(#"{"translation_ja": "日本語訳 または null"}"#)
        )
        XCTAssertTrue(
            TranscriptCleaner.batchSystemPrompt(for: .translateOnly)
                .contains(#"{"items": [{"id": "入力と同じid", "translation_ja": "日本語訳 または null"}, ...]}"#)
        )
    }

    /// 従来モードは整形ルールを持ったまま (日本語会議のフィラー除去はここが担う)。
    func test_formatAndTranslatePrompts_keepFormattingInstructions() {
        for prompt in [
            TranscriptCleaner.systemPrompt(for: .formatAndTranslate),
            TranscriptCleaner.batchSystemPrompt(for: .formatAndTranslate)
        ] {
            XCTAssertTrue(prompt.contains("整形ルール"), prompt)
            XCTAssertTrue(prompt.contains("フィラー"), prompt)
            XCTAssertTrue(prompt.contains("cleaned"), prompt)
        }
    }

    /// 短いほど入力トークンが減り、キャッシュも効きやすい。
    func test_translateOnlyPrompts_areShorterThanFormatAndTranslate() {
        XCTAssertLessThan(
            TranscriptCleaner.systemPrompt(for: .translateOnly).count,
            TranscriptCleaner.systemPrompt(for: .formatAndTranslate).count
        )
        XCTAssertLessThan(
            TranscriptCleaner.batchSystemPrompt(for: .translateOnly).count,
            TranscriptCleaner.batchSystemPrompt(for: .formatAndTranslate).count
        )
    }

    /// バッチ側は「各セグメント独立」「同じ id で返す」を落とさない
    /// (混ざると別セグメントの訳が付く / 反映先を見失う)。
    func test_batchTranslateOnlyPrompt_keepsPerItemContract() {
        let prompt = TranscriptCleaner.batchSystemPrompt(for: .translateOnly)
        XCTAssertTrue(prompt.contains("同じ id"), prompt)
        XCTAssertTrue(prompt.contains("各セグメントは独立"), prompt)
    }
}
