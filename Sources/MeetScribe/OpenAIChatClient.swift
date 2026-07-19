import Foundation

/// OpenAI互換 chat/completions の共通クライアント。
/// 整形・対訳 (TranscriptCleaner)、Catchup要約、全体像生成が共用する。
/// コストは呼び出しごとに計算して返す (AppState への計上は呼び出し側)。
enum OpenAIChatClient {
    /// 既存テスト・呼び出しとの互換用OpenAIデフォルト値。
    static let model = "gpt-4.1-mini"

    // USD per token (2026-07 時点の gpt-4.1-mini 料金: $0.40/M in, $1.60/M out)
    static let inputRate: Double = 0.40 / 1_000_000
    static let outputRate: Double = 1.60 / 1_000_000

    /// 1回の補完リクエスト。失敗 (HTTPエラー・タイムアウト・パース不能) は text=nil。
    /// - Parameter forceJSON: true なら response_format=json_object を指定
    static func complete(
        system: String,
        user: String,
        apiKey: String,
        provider: AIProvider = .openAI,
        timeout: TimeInterval = 20,
        forceJSON: Bool = false
    ) async -> (text: String?, costUSD: Double) {
        var request = URLRequest(url: provider.chatEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": provider.chatModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if forceJSON {
            body["response_format"] = ["type": "json_object"]
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return (nil, 0)
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                DebugLog.log("[chat-client] HTTP \(status)")
                return (nil, 0)
            }
            return parseResponse(data, provider: provider)
        } catch {
            DebugLog.log("[chat-client] request failed: \(error.localizedDescription)")
            return (nil, 0)
        }
    }

    /// chat/completions レスポンスから (本文, コストUSD) を抽出する純関数。
    static func parseResponse(
        _ data: Data,
        provider: AIProvider = .openAI
    ) -> (text: String?, costUSD: Double) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, 0)
        }
        var cost = 0.0
        if let usage = obj["usage"] as? [String: Any] {
            let input = usage["prompt_tokens"] as? Int ?? 0
            let output = usage["completion_tokens"] as? Int ?? 0
            cost = Double(input) * provider.chatInputRate
                + Double(output) * provider.chatOutputRate
        }
        let choices = obj["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = (message?["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (content, cost)
    }
}
