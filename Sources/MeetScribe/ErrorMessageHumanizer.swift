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

    /// OpenAI Realtime API の `error` イベント (`error.type` / `error.code`) を
    /// 具体的な日本語メッセージに変換する。WebSocket ハンドシェイクは APIキーが
    /// 無効でも 101 Switching Protocols で成功し、接続直後の最初のメッセージとして
    /// このイベントが届く (`{"type":"error","error":{"type":"invalid_request_error",
    /// "code":"invalid_api_key",...}}`) ため、`error` イベント側で判定する必要がある。
    /// 該当パターンが無ければ OpenAI 側の原文メッセージをそのまま返す。
    static func humanizeAPIError(type: String?, code: String?, message: String) -> String {
        if code == "invalid_api_key" || type == "authentication_error" {
            return "APIキーが正しくない、または権限がありません。設定画面で選択中プロバイダーのキーを確認してください"
        }
        if code == "insufficient_quota" || code == "billing_hard_limit_reached" {
            return "APIの利用上限に達しています。選択中プロバイダーの請求設定を確認してください"
        }
        return message
    }

    private static func humanizeURLError(_ err: URLError) -> String {
        switch err.code {
        case .timedOut:
            return "接続がタイムアウトしました (ネット遅延またはAPI側の応答遅延)"
        case .notConnectedToInternet:
            return "インターネットに接続されていません"
        case .networkConnectionLost:
            return "ネットワーク接続が切れました"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "文字起こしサーバーに到達できません (DNS / ファイアウォール)"
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
