import Foundation

/// 話者ラベル。会議音声 (me/other) に加え、Phase 4 で Claude Q&A の
/// ユーザー質問 (.user) と回答 (.claude) も扱う。
enum SpeakerLabel: String, Codable, Sendable {
    case me        // マイク (自分)
    case other     // システム音 (相手)
    case user      // ユーザーが入力した質問
    case claude    // Claude Max の回答

    var displayName: String {
        switch self {
        case .me: return "自分"
        case .other: return "相手"
        case .user: return "質問"
        case .claude: return "Claude"
        }
    }
}

enum TranscriptionClientError: Error, LocalizedError {
    case connectionTimeout
    case sessionNotEstablished

    var errorDescription: String? {
        switch self {
        case .connectionTimeout: return "OpenAI Realtime API 接続タイムアウト"
        case .sessionNotEstablished: return "セッション未確立"
        }
    }
}

/// OpenAI Realtime Transcription API クライアント。ストリーム1本に対して1インスタンス。
///
/// `@unchecked Sendable`: urlSession/webSocket は main actor / audio thread /
/// URLSession delegate queue から触られる。可変状態は必要最小限に絞り、
/// 接続状態と continuation はロックで保護する。
final class TranscriptionClient: NSObject, @unchecked Sendable {
    private let apiKey: String
    private let speaker: SpeakerLabel

    private let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?

    // 接続状態 + 接続完了 continuation を一括でロック保護
    private let stateLock = NSLock()
    private var _isConnected = false
    private var _wasEverConnected = false
    private var _intentionalDisconnect = false
    private var _unexpectedCloseFired = false
    private var _heartbeatTask: Task<Void, Never>?

    /// ハートビート ping 間隔。OpenAI Realtime API は仕様上 WebSocket ping/pong に応答する。
    /// 20秒ごとに ping を送り、10秒以内に pong が返らなければ凍結とみなし切断トリガー。
    private static let heartbeatInterval: TimeInterval = 20
    private static let heartbeatTimeout: TimeInterval = 10
    private var _connectionContinuation: CheckedContinuation<Void, Error>?
    private var deltaCount = 0
    private var sendCount = 0
    private var sendBytes = 0
    private var seenEventTypes: Set<String> = []

    // 予期せぬ切断時に AudioSession へ通知するコールバック。
    // MainActor からの設定、URLSession delegate queue / receive queue からの読み出しが
    // 競合するため stateLock で保護する。外部からは setOnUnexpectedClose 経由で書く。
    private var _onUnexpectedClose: (@Sendable () -> Void)?

    /// 予期せぬ切断時に呼ばれるコールバックを設定する。
    /// `disconnect()` 経由の意図的な切断では発火しない。
    func setOnUnexpectedClose(_ handler: (@Sendable () -> Void)?) {
        stateLock.lock(); defer { stateLock.unlock() }
        _onUnexpectedClose = handler
    }

    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isConnected
    }

    init(apiKey: String, speaker: SpeakerLabel) {
        self.apiKey = apiKey
        self.speaker = speaker
        super.init()
    }

    // MARK: - 接続

    /// WebSocket を開き、`session.created` (旧 `transcription_session.created`)
    /// を受信するまで待つ。タイムアウト10秒。
    /// `OpenAI-Beta: realtime=v1` ヘッダーは 2026年5月の Realtime API GA 移行に
    /// 伴い廃止されており、付与すると `The Realtime Beta API is no longer supported`
    /// と即切断されるため、明示的に送らない。
    func connect() async throws {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: nil
        )
        let ws = session.webSocketTask(with: request)
        self.urlSession = session
        self.webSocket = ws
        ws.resume()
        receiveLoop()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.setConnectionContinuation(cont)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw TranscriptionClientError.connectionTimeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func disconnect() {
        // 意図的な切断を記録しておくことで、delegate didCloseWith 経由で
        // onUnexpectedClose が誤発火するのを防ぐ。コールバックもロック内で捨てる。
        stateLock.lock()
        _intentionalDisconnect = true
        _onUnexpectedClose = nil
        let hb = _heartbeatTask
        _heartbeatTask = nil
        stateLock.unlock()
        hb?.cancel()

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        setConnected(false)
        resumeConnectionContinuation(with: .failure(TranscriptionClientError.sessionNotEstablished))
    }

    // MARK: - ハートビート (WebSocket ping / pong)

    /// `session.created` 受信時に開始される。
    /// 20秒ごとに `sendPing` を送り、10秒以内に pong が返らなければ凍結とみなし
    /// `fireUnexpectedCloseIfNeeded` で自動再接続にハンドオフ。
    /// OpenAI Realtime API は仕様上 ping/pong に応答するが、ネット断や TCP 凍結時に
    /// URLSession の WebSocket は数十分気付かないため、明示的ハートビートで検知を早める。
    private func startHeartbeat() {
        stateLock.lock()
        _heartbeatTask?.cancel()
        let speaker = self.speaker
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                if Task.isCancelled { return }
                guard let self = self, self.isConnected else { return }
                let success = await self.sendPingWithTimeout()
                if !success {
                    DebugLog.log("[\(speaker.rawValue)] heartbeat timeout → triggering reconnect")
                    self.setConnected(false)
                    self.webSocket?.cancel(with: .abnormalClosure, reason: nil)
                    self.fireUnexpectedCloseIfNeeded()
                    return
                }
            }
        }
        _heartbeatTask = task
        stateLock.unlock()
    }

    /// `sendPing` を非同期にラップ。`heartbeatTimeout` 以内に pong が返らなければ false。
    private func sendPingWithTimeout() async -> Bool {
        guard let ws = webSocket else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var resumed = false
            let resumeOnce: (Bool) -> Void = { result in
                lock.lock(); defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    cont.resume(returning: result)
                }
            }
            ws.sendPing { error in
                resumeOnce(error == nil)
            }
            Task {
                try? await Task.sleep(for: .seconds(Self.heartbeatTimeout))
                resumeOnce(false)
            }
        }
    }

    /// 予期せぬ切断 (受信エラー / WebSocket close) が発生したかを判定して
    /// onUnexpectedClose を呼ぶ。一度だけ呼ばれることを保証する。
    /// 専用フラグ `_unexpectedCloseFired` を使い、`_intentionalDisconnect` を
    /// 流用しない (誤解と二次フラグ汚染の防止)。
    ///
    /// 設計判断: 意図的切断時は callback を発火しないが、再利用シナリオが無いため
    /// このメソッドではコールバックを取り出さず、guard 前に早期 return する。
    /// (callback の生死は `disconnect()` が責任を持って nil 化する)
    private func fireUnexpectedCloseIfNeeded() {
        stateLock.lock()
        let intentional = _intentionalDisconnect
        let wasConnected = _wasEverConnected
        let alreadyFired = _unexpectedCloseFired
        stateLock.unlock()

        // 意図的切断・接続未確立・既発火 → 早期return (callbackは温存)
        guard !intentional, wasConnected, !alreadyFired else { return }

        // ここから先で確実に発火する。フラグを立て、callback を atomic に取り出す。
        stateLock.lock()
        _unexpectedCloseFired = true
        let callback = _onUnexpectedClose
        _onUnexpectedClose = nil
        stateLock.unlock()

        callback?()
    }

    // MARK: - 状態ヘルパー (ロック保護)

    private func setConnected(_ value: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        _isConnected = value
    }

    private func setConnectionContinuation(_ cont: CheckedContinuation<Void, Error>) {
        stateLock.lock(); defer { stateLock.unlock() }
        // 既存の continuation がある場合は失効扱い (通常発生しない)
        if let existing = _connectionContinuation {
            existing.resume(throwing: TranscriptionClientError.sessionNotEstablished)
        }
        _connectionContinuation = cont
    }

    /// continuation を取り出して resume する。二重 resume を防ぐため atomic に nil 化。
    private func resumeConnectionContinuation(with result: Result<Void, Error>) {
        stateLock.lock()
        let cont = _connectionContinuation
        _connectionContinuation = nil
        stateLock.unlock()
        switch result {
        case .success:        cont?.resume()
        case .failure(let e): cont?.resume(throwing: e)
        }
    }

    // MARK: - 送信

    /// セッション設定を送信 (言語・モデル・VAD等)。
    /// 2026年5月の Realtime API GA 移行で payload 構造が変わった:
    ///   - イベント名: `session.update` (旧 `transcription_session.update`)
    ///   - 設定は `session.audio.input.*` 配下にネスト
    ///   - format は `{"type":"audio/pcm","rate":24000}` のオブジェクト
    ///   - noise_reduction フィールド名 (旧 input_audio_noise_reduction)
    /// 旧 payload を送ると `unknown parameter 'session.input_audio_format'` 等で
    /// 拒否される。
    private func sendSessionUpdate() {
        let message: [String: Any] = [
            "type": "session.update",
            "session": [
                // GA で必須化: transcription-only セッションであることを明示。
                // 欠けると `Missing required parameter: 'session.type'` で拒否される。
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "transcription": [
                            "model": "gpt-4o-transcribe",
                            "language": "ja",
                            "prompt": ""
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.75,
                            "prefix_padding_ms": 200,
                            "silence_duration_ms": 700
                        ],
                        "noise_reduction": [
                            "type": "far_field"
                        ]
                    ]
                ],
                "include": ["item.input_audio_transcription.logprobs"]
            ]
        ]
        sendJSON(message)
    }

    /// PCM16 (24kHz mono LE) の生バイトを送信。接続確立済みでなければ無視。
    func sendAudio(_ pcm16: Data) {
        guard isConnected, !pcm16.isEmpty else { return }
        let base64 = pcm16.base64EncodedString()
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64
        ]
        sendJSON(message)
        // 送信統計を最初の100チャンクと、以降は1秒(=24,000サンプル=48,000bytes)毎に
        // ログする想定で、500回ごと/100回ごとに残す
        stateLock.lock()
        sendCount += 1
        sendBytes += pcm16.count
        let count = sendCount
        let bytes = sendBytes
        stateLock.unlock()
        if count == 1 || count % 50 == 0 {
            DebugLog.log("[\(speaker.rawValue)] sent #\(count) total=\(bytes)bytes (latest=\(pcm16.count)bytes)")
        }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let ws = webSocket else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            guard let text = String(data: data, encoding: .utf8) else { return }
            let speaker = self.speaker
            ws.send(.string(text)) { error in
                if let error = error {
                    DebugLog.log("[\(speaker.rawValue)] send error: \(error.localizedDescription)")
                }
            }
        } catch {
            DebugLog.log("[\(speaker.rawValue)] json encode error: \(error.localizedDescription)")
        }
    }

    // MARK: - 受信

    private func receiveLoop() {
        guard let ws = webSocket else { return }
        ws.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handle(message: message)
                self.receiveLoop()
            case .failure(let error):
                DebugLog.log("[\(self.speaker.rawValue)] recv error: \(error.localizedDescription)")
                self.resumeConnectionContinuation(with: .failure(error))
                self.setConnected(false)
                // UI 表示用に人間に分かるメッセージへ変換
                let speaker = self.speaker
                let humanMsg = ErrorMessageHumanizer.humanize(error)
                Task { @MainActor in
                    AppState.shared.lastError = "[\(speaker.displayName)] 受信エラー: \(humanMsg)"
                }
                // 自動再接続にハンドオフ。AudioSession 側で UI 表示+再試行する。
                self.fireUnexpectedCloseIfNeeded()
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleJSON(text: text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                handleJSON(text: text)
            }
        @unknown default:
            break
        }
    }

    private func handleJSON(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        // 重要なイベントのみログ。音声イベントやデルタは出さない (ログ肥大化防止)
        switch type {
        case "session.created", "transcription_session.created":
            setConnected(true)
            stateLock.lock()
            _wasEverConnected = true
            stateLock.unlock()
            sendSessionUpdate()
            resumeConnectionContinuation(with: .success(()))
            startHeartbeat()
            DebugLog.log("[\(speaker.rawValue)] session established")

        case "session.updated", "transcription_session.updated":
            DebugLog.log("[\(speaker.rawValue)] session updated")

        case "conversation.item.input_audio_transcription.delta":
            if let delta = obj["delta"] as? String,
               let itemId = obj["item_id"] as? String {
                stateLock.lock()
                deltaCount += 1
                let count = deltaCount
                stateLock.unlock()
                if count == 1 {
                    DebugLog.log("[\(speaker.rawValue)] first delta received: '\(delta)'")
                }
                let speaker = self.speaker
                Task { @MainActor in
                    TranscriptStore.shared.appendDelta(delta, itemId: itemId, speaker: speaker)
                }
            }

        case "conversation.item.input_audio_transcription.failed":
            // 文字起こしエラー: PCM 形式 / 言語 / モデル等の問題で OpenAI 側が拒否
            let err = obj["error"] as? [String: Any]
            let errType = err?["type"] as? String ?? "unknown"
            let errCode = err?["code"] as? String ?? "?"
            let errMsg = err?["message"] as? String ?? "?"
            DebugLog.log("[\(speaker.rawValue)] transcription failed: type=\(errType) code=\(errCode) msg=\(errMsg)")
            let speaker = self.speaker
            Task { @MainActor in
                AppState.shared.lastError = "[\(speaker.displayName)] 文字起こし失敗: \(errMsg)"
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = obj["transcript"] as? String,
               let itemId = obj["item_id"] as? String {
                // ハルシネーション定型文フィルター
                if HallucinationFilter.shouldFilter(transcript) {
                    DebugLog.log("[\(speaker.rawValue)] hallucination filtered: '\(transcript)'")
                    break
                }
                DebugLog.log("[\(speaker.rawValue)] completed: '\(transcript)'")
                let speaker = self.speaker
                Task { @MainActor in
                    TranscriptStore.shared.completeItem(itemId: itemId, finalText: transcript, speaker: speaker)
                }
            }
            // コスト累計
            if let usage = obj["usage"] as? [String: Any] {
                let usd = CostTracker.extractCost(from: usage)
                if usd > 0 {
                    Task { @MainActor in
                        AppState.shared.addCost(usd)
                    }
                }
            }

        case "error":
            let errObj = obj["error"] as? [String: Any]
            let errMsg = errObj?["message"] as? String ?? "unknown"
            let errType = errObj?["type"] as? String
            let recoverable = ErrorMessageHumanizer.isRecoverableAPIErrorType(errType)
            DebugLog.log("[\(speaker.rawValue)] API error type=\(errType ?? "?") recoverable=\(recoverable) msg=\(errMsg)")
            resumeConnectionContinuation(with: .failure(TranscriptionClientError.sessionNotEstablished))
            let speaker = self.speaker
            Task { @MainActor in
                AppState.shared.lastError = "[\(speaker.displayName)] APIエラー: \(errMsg)"
            }
            if recoverable {
                // セッション復旧見込みあり → 切断して再接続フローに乗せる
                setConnected(false)
                webSocket?.cancel(with: .abnormalClosure, reason: nil)
                fireUnexpectedCloseIfNeeded()
            }

        default:
            // 未知/未処理のイベントは初回のみログに残す。
            // event 名が新仕様で変わった場合 (delta/completed の rename 等) を検知するため。
            stateLock.lock()
            let isNew = !seenEventTypes.contains(type)
            if isNew { seenEventTypes.insert(type) }
            stateLock.unlock()
            if isNew {
                DebugLog.log("[\(speaker.rawValue)] unhandled event: \(type)")
            }
        }
    }
}

extension TranscriptionClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DebugLog.log("[\(speaker.rawValue)] WebSocket opened")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DebugLog.log("[\(speaker.rawValue)] WebSocket closed: code=\(closeCode.rawValue)")
        setConnected(false)
        resumeConnectionContinuation(with: .failure(TranscriptionClientError.sessionNotEstablished))
        // Realtime API は ~30-60分でセッション強制終了するので、
        // 意図的切断でなければ自動再接続にハンドオフする。
        fireUnexpectedCloseIfNeeded()
    }
}
