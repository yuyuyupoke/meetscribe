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
    /// Streaming STT API が `error` イベントで返した拒否理由。
    /// WebSocket ハンドシェイク自体は APIキーが無効でも 101 で成功し、
    /// 接続後の最初のメッセージとしてこのイベントが届く。
    case apiError(type: String?, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .connectionTimeout: return "文字起こしAPI 接続タイムアウト"
        case .sessionNotEstablished: return "セッション未確立"
        case .apiError(let type, let code, let message):
            return ErrorMessageHumanizer.humanizeAPIError(type: type, code: code, message: message)
        }
    }
}

/// OpenAI / xAI Streaming STTクライアント。ストリーム1本に対して1インスタンス。
///
/// `@unchecked Sendable`: urlSession/webSocket は main actor / audio thread /
/// URLSession delegate queue から触られる。可変状態は必要最小限に絞り、
/// 接続状態と continuation はロックで保護する。
final class TranscriptionClient: NSObject, @unchecked Sendable {
    private let apiKey: String
    private let speaker: SpeakerLabel
    let provider: AIProvider
    /// 転写言語 (ISO-639-1)。nil = 自動検出 (language パラメータ自体を送らない)。
    private let language: String?

    /// 転写モデル。`gpt-realtime-whisper` はネイティブストリーミング対応で、
    /// VAD なし + 手動 commit により連続発話でも delta が流れ続ける。
    /// 旧 `gpt-4o-transcribe` + server_vad は「無音までターン確定しない = 連続発話で
    /// 文字が一切出ない」問題があったため LecTrace 方式 (VAD無効+定期commit) に移行。
    static let transcriptionModel = "gpt-realtime-whisper"
    var modelName: String { provider.transcriptionModel }
    var sampleRate: Double { provider.transcriptionSampleRate }

    /// 強制 commit の間隔。この周期で必ず転写が確定するので、息継ぎのない
    /// 連続発話 (講義等) でもリアルタイムに文字が出る。
    private static let commitInterval: TimeInterval = 4

    /// commit に必要な最小送信バイト数。API は 100ms 未満のバッファ commit を
    /// 拒否するため、200ms 分 (24kHz * 2byte * 0.2s = 9,600B) を下限にする。
    private static let minCommitBytes = 9_600

    /// 有声判定のピーク振幅閾値 (PCM16、≈ -36 dBFS)。マイク (VPIO ノイズ抑制後) や
    /// 再生なしのシステム音声は無音でも PCM が流れ続けるため、バイト量だけでは
    /// 無音ウィンドウを判別できない。閾値未満しか無いウィンドウは commit せず
    /// clear で捨てて、無音ハルシネーションと課金を防ぐ。控えめ (低め) の値にして
    /// 小声の発話を取りこぼさないことを優先する。
    private static let voicePeakThreshold: Int16 = 500

    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?

    // 接続状態 + 接続完了 continuation を一括でロック保護
    private let stateLock = NSLock()
    private var _isConnected = false
    private var _wasEverConnected = false
    private var _intentionalDisconnect = false
    private var _unexpectedCloseFired = false
    private var _heartbeatTask: Task<Void, Never>?
    private var _commitTask: Task<Void, Never>?
    private var _bytesSinceLastCommit = 0
    private var _voiceSinceLastCommit = false

    /// ハートビート ping 間隔。OpenAI Realtime API は仕様上 WebSocket ping/pong に応答する。
    /// 20秒ごとに ping を送り、10秒以内に pong が返らなければ凍結とみなし切断トリガー。
    private static let heartbeatInterval: TimeInterval = 20
    private static let heartbeatTimeout: TimeInterval = 10
    private var _connectionContinuation: CheckedContinuation<Void, Error>?
    private var _finishContinuation: CheckedContinuation<Void, Never>?
    /// item ID の一意性を保証するためのインスタンス固有タグ。再接続時は新しい
    /// TranscriptionClient インスタンスが作られるため毎回異なる値になり、
    /// TranscriptStore 内に残った旧セッションの item ID と衝突しなくなる。
    private let instanceTag = UUID().uuidString.prefix(8)
    private var _xAIItemSequence = 0
    private var _xAIStreamState = XAIStreamState()
    /// speech_final キーの実地確認 (公式docs+ログの実挙動からの推定のため) を
    /// 初回イベントだけ DebugLog に残すためのフラグ。
    private var _loggedXAISpeechFinalPresence = false
    private var _unbilledXAIAudioBytes = 0
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

    init(
        apiKey: String,
        speaker: SpeakerLabel,
        language: String? = nil,
        provider: AIProvider = .openAI
    ) {
        self.apiKey = apiKey
        self.speaker = speaker
        self.language = language
        self.provider = provider
        super.init()
    }

    // MARK: - 接続

    /// WebSocket を開き、`session.created` (旧 `transcription_session.created`)
    /// を受信するまで待つ。タイムアウト10秒。
    /// `OpenAI-Beta: realtime=v1` ヘッダーは 2026年5月の Realtime API GA 移行に
    /// 伴い廃止されており、付与すると `The Realtime Beta API is no longer supported`
    /// と即切断されるため、明示的に送らない。
    func connect() async throws {
        var request = URLRequest(url: Self.makeEndpoint(provider: provider, language: language))
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

    /// 接続先URL。xAIはURL queryで設定が完結し、setup messageは不要。
    static func makeEndpoint(provider: AIProvider, language: String?) -> URL {
        switch provider {
        case .openAI:
            return URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        case .xAI:
            var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
            var items = [
                URLQueryItem(name: "sample_rate", value: "16000"),
                URLQueryItem(name: "encoding", value: "pcm"),
                URLQueryItem(name: "interim_results", value: "true"),
                // 10msの既定値では短い間でもセグメントが割れすぎるため自然な会話向けに調整。
                URLQueryItem(name: "endpointing", value: "500")
            ]
            if let language {
                items.append(URLQueryItem(name: "language", value: language))
            }
            components.queryItems = items
            return components.url!
        }
    }

    /// xAIはaudio.doneで残りをflushしてから閉じる。OpenAIは従来どおり即時切断。
    func finish() async {
        guard provider == .xAI, isConnected else {
            disconnect()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.setFinishContinuation(continuation)
                    self.sendJSON(["type": "audio.done"])
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                self.resumeFinishContinuation()
            }
            _ = await group.next()
            group.cancelAll()
        }
        disconnect()
    }

    func disconnect() {
        // 意図的な切断を記録しておくことで、delegate didCloseWith 経由で
        // onUnexpectedClose が誤発火するのを防ぐ。コールバックもロック内で捨てる。
        stateLock.lock()
        _intentionalDisconnect = true
        _onUnexpectedClose = nil
        let hb = _heartbeatTask
        _heartbeatTask = nil
        let ct = _commitTask
        _commitTask = nil
        stateLock.unlock()
        hb?.cancel()
        ct?.cancel()

        flushXAICost()
        resumeFinishContinuation()

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

    private func setFinishContinuation(_ continuation: CheckedContinuation<Void, Never>) {
        stateLock.lock()
        let previous = _finishContinuation
        _finishContinuation = continuation
        stateLock.unlock()
        previous?.resume()
    }

    private func resumeFinishContinuation() {
        stateLock.lock()
        let continuation = _finishContinuation
        _finishContinuation = nil
        stateLock.unlock()
        continuation?.resume()
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
        sendJSON(Self.makeSessionUpdatePayload(language: language))
    }

    /// session.update の payload を組み立てる。テスト可能にするため static に分離。
    ///
    /// 設計判断 (LecTrace 方式):
    ///   - `turn_detection: null` で server_vad を無効化。server_vad は「無音が
    ///     silence_duration_ms 続くまで転写が始まらない」ため、連続発話で文字が
    ///     出ない不具合の原因だった。
    ///   - 代わりに `commitInterval` 秒ごとの手動 commit で必ず転写を確定させる。
    ///   - `language` は nil (自動検出) のときキー自体を送らない。
    ///   - `gpt-realtime-whisper` は `prompt` パラメータ非対応
    ///     (`The 'prompt' parameter is not supported for this model.` で拒否される)
    ///     なのでキー自体を送らない。gpt-4o-transcribe 系のみが対応する。
    static func makeSessionUpdatePayload(language: String?) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": transcriptionModel
        ]
        if let language {
            transcription["language"] = language
        }
        return [
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
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                        "noise_reduction": [
                            "type": "far_field"
                        ]
                    ]
                ]
            ]
        ]
    }

    // MARK: - 定期 commit (VAD 無効化に伴う手動ターン確定)

    /// `session.created` 受信時に開始。`commitInterval` ごとに、前回 commit 以降に
    /// 十分な音声 (`minCommitBytes` 以上) を送信していれば `input_audio_buffer.commit`
    /// を送る。commit で転写アイテムが確定し delta/completed が流れてくる。
    /// 無音等で送信量が足りないときは commit を見送り、次周期に持ち越す
    /// (空バッファ commit は API エラーになるため)。
    private func startCommitLoop() {
        stateLock.lock()
        _commitTask?.cancel()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.commitInterval))
                if Task.isCancelled { return }
                guard let self = self, self.isConnected else { return }
                self.commitIfNeeded()
            }
        }
        _commitTask = task
        stateLock.unlock()
    }

    private func commitIfNeeded() {
        stateLock.lock()
        let bytes = _bytesSinceLastCommit
        let hasVoice = _voiceSinceLastCommit
        let enough = bytes >= Self.minCommitBytes
        if enough {
            _bytesSinceLastCommit = 0
            _voiceSinceLastCommit = false
        }
        stateLock.unlock()
        guard enough else { return }  // 送信量不足 → 次周期に持ち越し

        if hasVoice {
            sendJSON(["type": "input_audio_buffer.commit"])
        } else {
            // 有声チャンクが一つも無かったウィンドウは転写せず破棄。
            // commit だと無音ハルシネーション + 課金、放置だとサーバー側バッファに
            // 無音が溜まり続けて次の commit が巨大化するため、明示的に clear する。
            sendJSON(["type": "input_audio_buffer.clear"])
        }
    }

    /// PCM16 (LE) チャンクのピーク振幅。有声判定に使う。
    static func peakAmplitude(_ pcm16: Data) -> Int16 {
        pcm16.withUnsafeBytes { raw -> Int16 in
            let samples = raw.bindMemory(to: Int16.self)
            var peak: Int16 = 0
            for s in samples {
                let v = s == Int16.min ? Int16.max : abs(s)
                if v > peak { peak = v }
            }
            return peak
        }
    }

    /// PCM16 mono LEを送信。OpenAIはbase64 JSON、xAIはraw binary frame。
    func sendAudio(_ pcm16: Data) {
        guard isConnected, !pcm16.isEmpty else { return }
        switch provider {
        case .openAI:
            let message: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": pcm16.base64EncodedString()
            ]
            sendJSON(message)
        case .xAI:
            sendBinary(pcm16)
        }
        let isVoiced = provider == .openAI
            && Self.peakAmplitude(pcm16) >= Self.voicePeakThreshold
        // 送信統計を最初の100チャンクと、以降は1秒(=24,000サンプル=48,000bytes)毎に
        // ログする想定で、500回ごと/100回ごとに残す
        stateLock.lock()
        sendCount += 1
        sendBytes += pcm16.count
        if provider == .openAI { _bytesSinceLastCommit += pcm16.count }
        if isVoiced { _voiceSinceLastCommit = true }
        if provider == .xAI { _unbilledXAIAudioBytes += pcm16.count }
        let billableBytes = takeWholeSecondsOfXAIAudioLocked()
        let count = sendCount
        let bytes = sendBytes
        stateLock.unlock()
        if count == 1 || count % 50 == 0 {
            DebugLog.log("[\(speaker.rawValue)] sent #\(count) total=\(bytes)bytes (latest=\(pcm16.count)bytes)")
        }
        addXAICost(forAudioBytes: billableBytes)
    }

    private func sendBinary(_ data: Data) {
        guard let ws = webSocket else { return }
        let speaker = self.speaker
        ws.send(.data(data)) { error in
            if let error {
                DebugLog.log("[\(speaker.rawValue)] binary send error: \(error.localizedDescription)")
            }
        }
    }

    /// stateLock取得中に呼ぶ。丸1秒分だけ課金計上へ回し、端数は保持する。
    private func takeWholeSecondsOfXAIAudioLocked() -> Int {
        guard provider == .xAI else { return 0 }
        let bytesPerSecond = Int(sampleRate) * MemoryLayout<Int16>.size
        let wholeBytes = (_unbilledXAIAudioBytes / bytesPerSecond) * bytesPerSecond
        _unbilledXAIAudioBytes -= wholeBytes
        return wholeBytes
    }

    private func flushXAICost() {
        guard provider == .xAI else { return }
        stateLock.lock()
        let bytes = _unbilledXAIAudioBytes
        _unbilledXAIAudioBytes = 0
        stateLock.unlock()
        addXAICost(forAudioBytes: bytes)
    }

    private func addXAICost(forAudioBytes bytes: Int) {
        guard bytes > 0 else { return }
        let usd = CostTracker.xAIStreamingCost(
            audioBytes: bytes,
            sampleRate: sampleRate
        )
        Task { @MainActor in AppState.shared.addCost(usd) }
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
                // stop / 再接続時のクライアント差し替えによる意図的切断後は、
                // pending 中の receive が ENOTCONN (ソケットが接続されていません)
                // 等で必ず失敗する。これは正常系なので UI にエラーを出さない
                // (再接続成功後のエラークリアより遅れて届き、赤字が残り続ける原因だった)。
                self.stateLock.lock()
                let intentional = self._intentionalDisconnect
                self.stateLock.unlock()
                if intentional { return }
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

        case "transcript.created":
            // xAIはquery parameterで設定済み。ready後はbinary audioを直接送れる。
            setConnected(true)
            stateLock.lock()
            _wasEverConnected = true
            stateLock.unlock()
            resumeConnectionContinuation(with: .success(()))
            startHeartbeat()
            DebugLog.log("[\(speaker.rawValue)] xAI transcript session established")

        case "session.updated", "transcription_session.updated":
            // commit ループは session.update (turn_detection: null) の反映確定後に
            // 開始する。session.created 直後に始めると、server_vad が有効なままの
            // 一瞬に commit してエラーになるレースがあり、update 拒否時には
            // 4秒周期のエラースパムになるため。
            startCommitLoop()
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
                processFinalTranscript(transcript, itemId: itemId)
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

        case "transcript.partial":
            guard let transcript = obj["text"] as? String else { break }
            let isFinal = obj["is_final"] as? Bool ?? false
            let speechFinal = obj["speech_final"] as? Bool
            logXAISpeechFinalPresenceOnce(obj: obj)
            switch handleXAIPartial(text: transcript, isFinal: isFinal, speechFinal: speechFinal) {
            case .finalize(let itemId, let text):
                processFinalTranscript(text, itemId: itemId)
            case .updateDisplay(let itemId, let text):
                let speaker = self.speaker
                Task { @MainActor in
                    TranscriptStore.shared.replacePartial(
                        text,
                        itemId: itemId,
                        speaker: speaker
                    )
                }
            }

        case "transcript.done":
            // done.textはセッション全文なので再追加しない。確定済みチャンク + 最後の
            // 未確定interimを縫い合わせた、未確定の発話だけ確定する。
            if let pending = takePendingXAIItem(), !pending.text.isEmpty {
                processFinalTranscript(pending.text, itemId: pending.id)
            }
            resumeFinishContinuation()

        case "error":
            let errObj = obj["error"] as? [String: Any]
            let errMsg = errObj?["message"] as? String
                ?? obj["message"] as? String
                ?? "unknown"
            let errType = errObj?["type"] as? String ?? obj["type"] as? String
            let errCode = errObj?["code"] as? String ?? obj["code"] as? String
            // 空バッファ commit の拒否は実害なし (音声は失われない)。
            // send 失敗等でクライアント側カウントと実バッファが稀にずれた場合に
            // 出るだけなので、UI に出さずログだけ残して抜ける。
            if errCode == "input_audio_buffer_commit_empty" {
                DebugLog.log("[\(speaker.rawValue)] benign: commit on empty buffer (skipped)")
                break
            }
            let recoverable = ErrorMessageHumanizer.isRecoverableAPIErrorType(errType)
            DebugLog.log("[\(speaker.rawValue)] API error type=\(errType ?? "?") recoverable=\(recoverable) msg=\(errMsg)")
            let humanMsg = ErrorMessageHumanizer.humanizeAPIError(type: errType, code: errCode, message: errMsg)
            resumeConnectionContinuation(with: .failure(TranscriptionClientError.apiError(type: errType, code: errCode, message: errMsg)))
            let speaker = self.speaker
            Task { @MainActor in
                AppState.shared.lastError = "[\(speaker.displayName)] APIエラー: \(humanMsg)"
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

    /// `XAIStreamState` へ1イベント分の処理を委譲する。stateLock 保持中に
    /// `makeItemId` クロージャを呼ぶため、クロージャ内で stateLock を再取得しない
    /// (NSLock は非再入なのでデッドロックする)。
    private func handleXAIPartial(text: String, isFinal: Bool, speechFinal: Bool?) -> XAIStreamState.Action {
        stateLock.lock(); defer { stateLock.unlock() }
        return _xAIStreamState.handlePartial(text: text, isFinal: isFinal, speechFinal: speechFinal, now: Date()) {
            _xAIItemSequence += 1
            return "xai-\(speaker.rawValue)-\(instanceTag)-\(_xAIItemSequence)"
        }
    }

    private func takePendingXAIItem() -> (id: String, text: String)? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let pending = _xAIStreamState.takePending() else { return nil }
        return (id: pending.itemId, text: pending.text)
    }

    /// speech_final フィールドの実地確認用。公式docs+ログの実挙動からの推定で
    /// 実装しているため、実際のイベントJSONでキーの有無を初回だけログに残す。
    private func logXAISpeechFinalPresenceOnce(obj: [String: Any]) {
        stateLock.lock()
        let shouldLog = !_loggedXAISpeechFinalPresence
        if shouldLog { _loggedXAISpeechFinalPresence = true }
        stateLock.unlock()
        guard shouldLog else { return }
        let hasKey = obj["speech_final"] != nil
        DebugLog.log("[\(speaker.rawValue)] xAI transcript.partial speech_final key present=\(hasKey) value=\(String(describing: obj["speech_final"]))")
    }

    /// 生テキストを先に確定表示し、選択プロバイダーで整形・対訳して後から置換する。
    private func processFinalTranscript(_ transcript: String, itemId: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 空白・改行だけの delta が先行して空エントリを作っている場合があるので、
            // 放置せず削除する (空の「[相手] 」行が UI に残る原因)。
            Task { @MainActor in TranscriptStore.shared.removeItem(itemId: itemId) }
            return
        }
        let speaker = self.speaker
        if HallucinationFilter.shouldFilter(trimmed) {
            DebugLog.log("[\(speaker.rawValue)] hallucination filtered: '\(trimmed)'")
            Task { @MainActor in TranscriptStore.shared.removeItem(itemId: itemId) }
            return
        }
        DebugLog.log("[\(speaker.rawValue)] completed: '\(trimmed)'")
        Task { @MainActor in
            TranscriptStore.shared.completeItem(
                itemId: itemId,
                finalText: trimmed,
                speaker: speaker
            )
        }
        guard TranscriptCleaner.shouldClean(trimmed) else { return }
        let apiKey = self.apiKey
        let provider = self.provider
        // 個別に clean() を呼ぶのではなく、確定セグメントをバッチキューに積む。
        // mic/sys 両ストリームから並行して積まれても TranscriptCleanerBatcher が
        // actor で直列化するので競合はない。
        Task.detached {
            await TranscriptCleanerBatcher.shared.enqueue(
                itemId: itemId,
                text: trimmed,
                apiKey: apiKey,
                provider: provider
            )
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
