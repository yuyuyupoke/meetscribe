import Foundation

/// MeetScribe が会議単位で使用するAIプロバイダー。
/// 録音開始時に選択値を固定し、文字起こし・整形・翻訳・Copilotを同じ
/// プロバイダーへルーティングする。
enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI = "openai"
    case xAI = "xai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .xAI: return "xAI (Grok)"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .xAI: return "xAI"
        }
    }

    var keychainAccount: String {
        switch self {
        case .openAI: return "openai-api-key"
        case .xAI: return "xai-api-key"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .openAI: return "sk-proj-..."
        case .xAI: return "xai-..."
        }
    }

    var transcriptionModel: String {
        switch self {
        case .openAI: return "gpt-realtime-whisper"
        // xAI STTは現時点でモデルIDを公開していないため、人間可読の公式名称を記録する。
        case .xAI: return "Grok Speech to Text"
        }
    }

    var chatModel: String {
        switch self {
        case .openAI: return "gpt-4.1-mini"
        case .xAI: return "grok-4.3"
        }
    }

    /// 各Streaming STTへ送るPCM16 monoのサンプルレート。
    var transcriptionSampleRate: Double {
        switch self {
        case .openAI: return 24_000
        case .xAI: return 16_000
        }
    }

    var chatEndpoint: URL {
        switch self {
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .xAI:
            return URL(string: "https://api.x.ai/v1/chat/completions")!
        }
    }

    /// USD per token。2026-07時点の各モデル標準料金。
    var chatInputRate: Double {
        switch self {
        case .openAI: return 0.40 / 1_000_000
        case .xAI: return 1.25 / 1_000_000
        }
    }

    var chatOutputRate: Double {
        switch self {
        case .openAI: return 1.60 / 1_000_000
        case .xAI: return 2.50 / 1_000_000
        }
    }

    /// プロンプトキャッシュにヒットした入力トークンの単価。両プロバイダーとも
    /// キャッシュは自動適用で、レスポンスの `usage.prompt_tokens_details.cached_tokens`
    /// に再利用されたトークン数が返る (`prompt_tokens` はこれを含む総数)。
    /// gpt-4.1-mini: $0.10/M (75%オフ) / grok-4.3: $0.20/M (84%オフ)。
    ///
    /// 注: OpenAI のキャッシュ発動条件は「共通プレフィックス1024トークン以上」で、
    /// 本アプリの system プロンプトは4種すべて ~250-400トークン・user 側は毎回変わる
    /// ため、**OpenAI 経路では実際には `cached_tokens` は 0 のまま**になる見込み。
    /// 将来プロンプトが伸びた場合に自動で効くよう式としては保持している。
    var chatCachedInputRate: Double {
        switch self {
        case .openAI: return 0.10 / 1_000_000
        case .xAI: return 0.20 / 1_000_000
        }
    }

    /// 推論トークン (`completion_tokens_details.reasoning_tokens`) が
    /// `completion_tokens` に**含まれない**か。
    /// - xAI (grok-4.3): 別カウント (`total = prompt + completion + reasoning` を実測確認)
    ///   → 課金出力は completion + reasoning
    /// - OpenAI: `completion_tokens` に含む仕様 → 加算すると二重計上になる
    var reasoningTokensExcludedFromCompletion: Bool {
        switch self {
        case .openAI: return false
        case .xAI: return true
        }
    }

    /// xAI の `x-grok-conv-id` ヘッダーを送るか。同一IDのリクエストを同じサーバーへ
    /// ルーティングさせてキャッシュヒット率を上げる公式推奨の最適化 (docs.x.ai)。
    /// OpenAI は同種のヘッダーを持たず、キャッシュは自動 + プレフィックス一致のみで効く。
    var usesGrokConversationHeader: Bool {
        switch self {
        case .openAI: return false
        case .xAI: return true
        }
    }

    /// `reasoning_effort` を受け付けるか。
    /// grok-4.3 は推論モデルで `none`/`low`/`high` を取る。gpt-4.1-mini は非推論モデルで
    /// このパラメータを持たないため、送るとリクエストが弾かれる。
    var supportsReasoningEffort: Bool {
        switch self {
        case .openAI: return false
        case .xAI: return true
        }
    }
}

/// チャット呼び出しの `reasoning_effort` を決めるポリシー。
///
/// **既定は `none`（推論トークンを出さない）**。2026-08-10 に英語講義の
/// 実データで A/B した結果、整形・対訳・要約のいずれも推論なしが最良だった:
/// - コスト: Cleaner 1バッチ $0.0043 → $0.0023 (**-47%**)、Overview 1回 $0.0040 → $0.0023 (**-42%**)
/// - 整形品質: 英語講義の音声には `um`/`uh` がほぼ無く (xAI STT が書き起こし時点で落とす)
///   整形の仕事が元々少ない。推論を効かせると逆に "In my history" → "In my experience"、
///   "introduction" → "introductory" のような**原文の書き換え**が出た。`none` は全件原文維持
/// - 全体像品質: 推論ありは直近6,000字に引っ張られて purpose を上書きしてしまうが、
///   `none` は前回の purpose を正しく継承し agenda を累積した
///
/// 注意: 2026-07-25 の調査では**日本語会議**でフィラー除去が機能しなくなる劣化を実測している
/// (「めっちゃいいですねめっちゃいいですね」の重複が残る等)。日本語主体の会議で整形が
/// 物足りない場合は従来動作に戻せる:
/// - GUI (Finder/Dock) 起動でも効く恒久設定:
///   `defaults write com.meetscribe.app reasoningEffort default`
/// - その場限りの切り替え (ターミナルから起動する場合のみ):
///   `MEETSCRIBE_REASONING_EFFORT=default open -a MeetScribe` ではなく
///   `MEETSCRIBE_REASONING_EFFORT=default /Applications/MeetScribe.app/Contents/MacOS/MeetScribe`
enum ReasoningEffortPolicy {
    static let environmentKey = "MEETSCRIBE_REASONING_EFFORT"

    /// GUI 起動時のロールバック手段。**環境変数だけでは不十分**なため併設している:
    /// Finder/Dock/`open` から起動したアプリはシェルの環境を継承しないので、
    /// `MEETSCRIBE_REASONING_EFFORT` は普段の使い方では届かない。
    static let userDefaultsKey = "reasoningEffort"

    /// 環境変数も UserDefaults も無いときに使う値。
    static let defaultEffort = "none"

    /// xAI が受け付ける値 + 「送らない」を意味する `default`。
    /// 未知の文字列で API に弾かれると整形・要約が丸ごと失敗するため、
    /// ホワイトリスト外は無視する。
    static let allowed: Set<String> = ["none", "low", "high", "default"]

    /// 実際に送る値。`nil` は「パラメータを付けない」(= プロバイダー既定の推論量)。
    ///
    /// 優先順位は 環境変数 → UserDefaults → 既定値。環境変数を上に置くのは、
    /// 恒久設定 (UserDefaults) を書き換えずに1回だけ挙動を確かめられるようにするため。
    /// ホワイトリスト外・空文字は「指定なし」と見なして次の候補へ落ちる。
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults? = .standard
    ) -> String? {
        let candidate = normalized(environment[environmentKey])
            ?? normalized(defaults?.string(forKey: userDefaultsKey))
            ?? defaultEffort
        return candidate == "default" ? nil : candidate
    }

    /// 入力を正規化し、ホワイトリストに載っている値だけを返す (それ以外は nil)。
    private static func normalized(_ raw: String?) -> String? {
        guard let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !value.isEmpty,
            allowed.contains(value)
        else {
            return nil
        }
        return value
    }

    /// 実際に送る値。**呼び出しのたびに解決する** (`static let` にしない)。
    ///
    /// `static let` だと「その起動で最初に LLM を呼んだ瞬間」に凍結され、
    /// 常駐アプリでは `defaults write com.meetscribe.app reasoningEffort default` を
    /// 打っても既に録音済みの起動では反映されない (しかも再現しない挙動になる)。
    /// 詳細な理由は `CleanerModePolicy.current` のコメントを参照。
    static var current: String? { resolve() }
}

/// プロンプトキャッシュのヒット率を上げるための、用途ごとに安定したキー。
///
/// xAI は同一 `x-grok-conv-id` のリクエストを同じサーバーへ寄せるため、
/// 「同じ system プロンプトを使う呼び出し」を同じキーで固定すると、その
/// サーバー上のキャッシュが温まり続けてヒットしやすくなる。用途を混ぜると
/// プレフィックスが違うリクエストが同じサーバーに集まるだけで利点がないので、
/// system プロンプトの単位 = キーの単位にする。
///
/// 会議をまたいで同じ値を使う (会議IDを混ぜない) のは意図的で、キャッシュTTL内なら
/// 次の会議の初回呼び出しでもヒットしうる。一方でインストール単位のサフィックスは
/// 付ける: キャッシュはアカウント単位なので他ユーザーと同じIDを共有しても得が無く、
/// ルーティングが一箇所に偏るだけだから。会議内容やユーザー識別情報は一切含めない。
enum PromptCacheKey {
    private static let installIDKey = "promptCacheInstallID"

    /// インストールごとに一度だけ生成して永続化するサフィックス (8桁hex)。
    static let installID: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: installIDKey), !existing.isEmpty {
            return existing
        }
        let generated = String(UUID().uuidString.prefix(8)).lowercased()
        defaults.set(generated, forKey: installIDKey)
        return generated
    }()

    /// 文字起こしセグメントの整形・対訳 (バッチ)
    static var cleanerBatch: String { "meetscribe-cleaner-batch-\(installID)" }
    /// 文字起こしセグメントの整形・対訳 (単発)
    static var cleanerSingle: String { "meetscribe-cleaner-single-\(installID)" }
    /// Catchup 要約
    static var catchup: String { "meetscribe-catchup-\(installID)" }
    /// 会議の全体像の自動更新
    static var overview: String { "meetscribe-overview-\(installID)" }
    /// 議事録タイトルの生成
    static var title: String { "meetscribe-title-\(installID)" }
}
