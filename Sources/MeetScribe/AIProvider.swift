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
}
