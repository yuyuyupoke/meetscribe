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
}
