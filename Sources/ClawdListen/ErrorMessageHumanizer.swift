import Foundation

/// 受信エラー / API エラーの文言をユーザーが読んで分かる日本語に正規化する。
/// 元のシステムメッセージ (e.g. "The operation couldn't be completed.
/// (NSURLErrorDomain error -1001.)") はデバッグ向けに DebugLog 側に残し、
/// UI 表示はこちらの humanize() を経由させる。
enum ErrorMessageHumanizer {

    static func humanize(_ error: Error) -> String {
        if let urlErr = error as? URLError {
            return humanizeURLError(urlErr)
        }
        if let txErr = error as? TranscriptionClientError {
            return txErr.errorDescription ?? "通信エラー"
        }
        // フォールバック: ローカライズドメッセージから NSURLErrorDomain などの
        // 機械的接頭辞を取り除く
        let raw = error.localizedDescription
        return raw
            .replacingOccurrences(of: "The operation couldn’t be completed.", with: "")
            .replacingOccurrences(of: "The operation couldn't be completed.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OpenAI Realtime API の `error` イベントの error.type を見て、
    /// 自動再接続で復旧する見込みがあるかを返す。
    /// セッション切れ・サーバー側内部エラー・レート制限は再接続価値あり、
    /// 認証/権限/不正パラメータは再接続しても無駄なので false。
    static func isRecoverableAPIErrorType(_ type: String?) -> Bool {
        guard let type else { return false }
        let recoverable: Set<String> = [
            "server_error",
            "session_expired",
            "rate_limit_exceeded",
            "internal_error",
            "timeout"
        ]
        return recoverable.contains(type)
    }

    private static func humanizeURLError(_ err: URLError) -> String {
        switch err.code {
        case .timedOut:
            return "接続がタイムアウトしました (ネット遅延 or OpenAI側の応答遅延)"
        case .notConnectedToInternet:
            return "インターネットに接続されていません"
        case .networkConnectionLost:
            return "ネットワーク接続が切れました"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "OpenAI サーバーに到達できません (DNS / ファイアウォール)"
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return "APIキー認証エラー"
        case .badServerResponse:
            return "サーバー応答が不正"
        case .cancelled:
            return "通信がキャンセルされました"
        default:
            return "通信エラー (code \(err.code.rawValue))"
        }
    }
}
