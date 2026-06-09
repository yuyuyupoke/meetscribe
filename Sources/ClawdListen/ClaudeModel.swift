import Foundation

/// claude -p の --model に渡すモデル識別子 + UI 表示名。
enum ClaudeModel: String, CaseIterable, Sendable, Identifiable {
    case opus
    case sonnet
    case haiku

    var id: String { rawValue }

    /// claude CLI の --model フラグに渡す短縮名。
    var cliArgument: String {
        switch self {
        case .opus: return "opus"
        case .sonnet: return "sonnet"
        case .haiku: return "haiku"
        }
    }

    var displayName: String {
        switch self {
        case .opus: return "Opus 4.7"
        case .sonnet: return "Sonnet 4.6"
        case .haiku: return "Haiku 4.5"
        }
    }

    /// 選択の目安
    var subtitle: String {
        switch self {
        case .opus: return "最強・遅め"
        case .sonnet: return "バランス"
        case .haiku: return "高速・軽量"
        }
    }
}
