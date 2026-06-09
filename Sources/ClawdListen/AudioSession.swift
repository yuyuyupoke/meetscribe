import AVFoundation
import Foundation

/// キャプチャ経路が渡す音声フレームの共通表現。
enum AudioFrame {
    case pcm(AVAudioPCMBuffer)
    case sample(CMSampleBuffer)
}

/// 1ストリーム分の音声処理パイプライン。
/// PCM 変換 → OpenAI WebSocket への送信を行う。
/// `client` は再接続時に差し替える可能性があるので var + lock 保護。
private final class TranscriptionPipeline: @unchecked Sendable {
    private let clientLock = NSLock()
    private var _client: TranscriptionClient
    private var converter: PCMConverter?

    init(client: TranscriptionClient) {
        self._client = client
    }

    func replaceClient(_ newClient: TranscriptionClient) {
        clientLock.lock(); defer { clientLock.unlock() }
        _client = newClient
    }

    func process(_ frame: AudioFrame) {
        let pcm: Data?
        switch frame {
        case .pcm(let buffer):
            if converter == nil {
                converter = PCMConverter(sourceFormat: buffer.format)
            }
            pcm = converter?.convert(buffer)
        case .sample(let sampleBuffer):
            pcm = PCMConverter.convert(sampleBuffer, using: &converter)
        }
        guard let data = pcm else { return }
        clientLock.lock()
        let target = _client
        clientLock.unlock()
        target.sendAudio(data)
    }
}

/// マイクとシステム音の2ストリームを統合制御。
/// - start(): 録音開始 → WebSocket 接続 → 無音検知タイマー起動
/// - stop():  正常停止 → 文字起こしを Markdown に保存 (タイトル生成 claude)
/// - kill():  緊急停止 → 保存せず、バッファもクリア
@MainActor
final class AudioSession {
    static let shared = AudioSession()

    private let microphone = MicrophoneCapture()
    private let systemAudio = SystemAudioCapture()

    private var micClient: TranscriptionClient?
    private var sysClient: TranscriptionClient?
    private var micPipeline: TranscriptionPipeline?
    private var sysPipeline: TranscriptionPipeline?
    private var silenceDetector: SilenceDetector?

    /// 再接続中の Task。多重再接続を防ぐためストリームごとに 1 本だけ保持。
    private var micReconnectTask: Task<Void, Never>?
    private var sysReconnectTask: Task<Void, Never>?

    private init() {}

    // MARK: - 自動再接続

    /// バックオフ秒数（指数）。OpenAI Realtime API は ~30-60分でセッション強制終了するため、
    /// 切断検知時にここに従って再接続を試みる。`maxAttempts` 回失敗で諦める。
    /// 合計約63秒粘る (Wi-Fi 切替や VPN 再接続の想定)
    private static let reconnectBackoffSeconds: [TimeInterval] = [1, 2, 4, 8, 16, 16, 16]
    private static let maxReconnectAttempts: Int = 7

    /// 再接続フローが lastError に書く文言の接頭辞。
    /// 成功時にこの接頭辞のメッセージだけ消すことで、他の (文字起こし失敗等) を壊さない。
    private static let reconnectErrorPrefix = "[再接続]"

    // MARK: - Start

    func start() async {
        DebugLog.log("[ClawdListen] AudioSession.start()")
        AppState.shared.captureStatus = .starting
        AppState.shared.lastError = nil
        AppState.shared.lastSavedURL = nil
        TranscriptStore.shared.clear()

        guard let apiKey = KeychainStore.read(), !apiKey.isEmpty else {
            AppState.shared.captureStatus = .error("API Keyが未設定")
            AppState.shared.lastError = "OpenAI API Keyを設定してください"
            return
        }

        let micClient = TranscriptionClient(apiKey: apiKey, speaker: .me)
        let sysClient = TranscriptionClient(apiKey: apiKey, speaker: .other)
        do {
            async let micConnect: Void = micClient.connect()
            async let sysConnect: Void = sysClient.connect()
            try await micConnect
            try await sysConnect
        } catch {
            AppState.shared.lastError = "OpenAI接続失敗: \(error.localizedDescription)"
            AppState.shared.captureStatus = .error(error.localizedDescription)
            micClient.disconnect()
            sysClient.disconnect()
            return
        }
        self.micClient = micClient
        self.sysClient = sysClient

        let micPipeline = TranscriptionPipeline(client: micClient)
        let sysPipeline = TranscriptionPipeline(client: sysClient)
        self.micPipeline = micPipeline
        self.sysPipeline = sysPipeline

        // 予期せぬ切断を検知したら自動再接続にハンドオフ。
        wireUnexpectedClose(client: micClient, speaker: .me)
        wireUnexpectedClose(client: sysClient, speaker: .other)

        do {
            try microphone.start { [micPipeline] buffer, _ in
                micPipeline.process(.pcm(buffer))
            }
        } catch {
            AppState.shared.lastError = "マイク起動失敗: \(error.localizedDescription)"
            AppState.shared.captureStatus = .error(error.localizedDescription)
            tearDown()
            return
        }

        do {
            try await systemAudio.start { [sysPipeline] sampleBuffer in
                sysPipeline.process(.sample(sampleBuffer))
            }
        } catch {
            AppState.shared.lastError = "システム音起動失敗: \(error.localizedDescription)"
            AppState.shared.captureStatus = .error(error.localizedDescription)
            tearDown()
            return
        }

        // 会議開始時刻をマーク + 無音検知タイマー起動 (10分)
        AppState.shared.meetingStartedAt = Date()
        let detector = SilenceDetector(timeoutMinutes: 10.0) { [weak self] in
            DebugLog.log("[ClawdListen] silence timeout → auto-stop")
            Task { await self?.stop() }
        }
        detector.start()
        silenceDetector = detector

        AppState.shared.captureStatus = .running
    }

    // MARK: - Stop (正常終了: 議事録を保存)

    func stop() async {
        DebugLog.log("[ClawdListen] AudioSession.stop() - with save")
        AppState.shared.captureStatus = .stopping

        let startedAt = AppState.shared.meetingStartedAt
        let endedAt = Date()
        microphone.stop()
        await systemAudio.stop()
        silenceDetector?.stop()
        silenceDetector = nil
        tearDown()
        AppState.shared.captureStatus = .idle

        // 発話が無ければ保存しない
        let meetingEntries = TranscriptStore.shared.meetingEntries
        guard let startedAt = startedAt, !meetingEntries.isEmpty else {
            DebugLog.log("[ClawdListen] empty transcript → skip save")
            AppState.shared.meetingStartedAt = nil
            return
        }

        await runSaveFlow(startedAt: startedAt, endedAt: endedAt, meetingEntries: meetingEntries)
        AppState.shared.meetingStartedAt = nil
    }

    // MARK: - Kill (緊急停止: 保存しない)

    func kill() async {
        DebugLog.log("[ClawdListen] AudioSession.kill() - no save")
        AppState.shared.captureStatus = .stopping
        microphone.stop()
        await systemAudio.stop()
        silenceDetector?.stop()
        silenceDetector = nil
        tearDown()
        TranscriptStore.shared.clear()
        AppState.shared.captureStatus = .idle
        AppState.shared.meetingStartedAt = nil
        AppState.shared.lastSavedURL = nil
    }

    // MARK: - 保存フロー

    private func runSaveFlow(
        startedAt: Date,
        endedAt: Date,
        meetingEntries: [TranscriptEntry]
    ) async {
        AppState.shared.isSavingMeeting = true
        defer { AppState.shared.isSavingMeeting = false }

        // 1. タイトル生成 (Claude sonnet ~15秒)
        let transcriptText = TranscriptStore.shared.meetingTranscriptText
        let title = await MeetingTitleGenerator.generate(from: transcriptText)
        DebugLog.log("[ClawdListen] generated title: \(title)")

        // 2. レコード組み立て + 保存
        let record = MeetingRecord(
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            meetingEntries: meetingEntries,
            qaEntries: TranscriptStore.shared.qaEntries,
            totalCostUSD: AppState.shared.totalCostUSD,
            model: "gpt-4o-transcribe"
        )
        do {
            let url = try TranscriptExporter.save(record, to: AppState.shared.meetingsSaveDirectoryURL)
            AppState.shared.lastSavedURL = url
            DebugLog.log("[ClawdListen] saved to: \(url.path)")
        } catch {
            AppState.shared.lastError = "議事録保存失敗: \(error.localizedDescription)"
            DebugLog.log("[ClawdListen] save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - リソース解放

    private func tearDown() {
        micReconnectTask?.cancel()
        sysReconnectTask?.cancel()
        micReconnectTask = nil
        sysReconnectTask = nil
        micClient?.disconnect()
        sysClient?.disconnect()
        micClient = nil
        sysClient = nil
        micPipeline = nil
        sysPipeline = nil
        AppState.shared.reconnectingStreams = []
    }

    // MARK: - 自動再接続実装

    /// Client に onUnexpectedClose ハンドラを取り付ける (ロック保護経由)。
    /// `wired` 後に切断検知すると `reconnect(speaker:)` が走る。
    private func wireUnexpectedClose(client: TranscriptionClient, speaker: SpeakerLabel) {
        client.setOnUnexpectedClose { [weak self] in
            // コールバックは MainActor 外スレッドから呼ばれる可能性があるので跳ばす。
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.startReconnect(speaker: speaker)
            }
        }
    }

    /// 指定ストリームの再接続 Task を起動 (既に走っているなら何もしない)。
    private func startReconnect(speaker: SpeakerLabel) {
        // 録音中でなければ再接続しない (stop / kill 後の遅延発火対策)
        guard AppState.shared.isRunning else { return }

        switch speaker {
        case .me:
            guard micReconnectTask == nil else { return }
            micReconnectTask = Task { [weak self] in
                await self?.runReconnectLoop(speaker: .me)
                await MainActor.run { self?.micReconnectTask = nil }
            }
        case .other:
            guard sysReconnectTask == nil else { return }
            sysReconnectTask = Task { [weak self] in
                await self?.runReconnectLoop(speaker: .other)
                await MainActor.run { self?.sysReconnectTask = nil }
            }
        default:
            return
        }
    }

    /// 指数バックオフで再接続を試みる。成功したら pipeline.client を差し替え、
    /// 失敗継続したらユーザーに通知して諦める。
    private func runReconnectLoop(speaker: SpeakerLabel) async {
        AppState.shared.reconnectingStreams.insert(speaker)
        setReconnectError("\(Self.reconnectErrorPrefix) [\(speaker.displayName)] 接続切れ、再接続中…")
        DebugLog.log("[ClawdListen] reconnect start for \(speaker.rawValue)")

        guard let apiKey = KeychainStore.read(), !apiKey.isEmpty else {
            setReconnectError("\(Self.reconnectErrorPrefix) [\(speaker.displayName)] 再接続失敗: APIキー未設定")
            AppState.shared.reconnectingStreams.remove(speaker)
            return
        }

        for attempt in 0..<Self.maxReconnectAttempts {
            // バックオフ前に cancel / 停止チェック (ユーザーが stop/kill 押した時の即応性)
            if Task.isCancelled || !AppState.shared.isRunning { break }
            let delay = Self.reconnectBackoffSeconds[
                min(attempt, Self.reconnectBackoffSeconds.count - 1)
            ]
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled || !AppState.shared.isRunning { break }

            let newClient = TranscriptionClient(apiKey: apiKey, speaker: speaker)
            do {
                try await newClient.connect()
                // connect 中に stop/kill が来ていたらゾンビ client を残さず破棄して終了
                if Task.isCancelled || !AppState.shared.isRunning {
                    newClient.disconnect()
                    DebugLog.log("[ClawdListen] reconnect cancelled after connect for \(speaker.rawValue)")
                    return
                }
                // 成功: pipeline を差し替えて、新コールバックも取り付ける
                wireUnexpectedClose(client: newClient, speaker: speaker)
                switch speaker {
                case .me:
                    micClient?.disconnect()
                    micClient = newClient
                    micPipeline?.replaceClient(newClient)
                case .other:
                    sysClient?.disconnect()
                    sysClient = newClient
                    sysPipeline?.replaceClient(newClient)
                default:
                    newClient.disconnect()
                    return
                }
                AppState.shared.reconnectingStreams.remove(speaker)
                clearReconnectErrorIfMine()
                DebugLog.log("[ClawdListen] reconnect succeeded for \(speaker.rawValue) (attempt \(attempt + 1))")
                return
            } catch {
                DebugLog.log("[ClawdListen] reconnect attempt \(attempt + 1) failed for \(speaker.rawValue): \(error.localizedDescription)")
                newClient.disconnect()
                setReconnectError("\(Self.reconnectErrorPrefix) [\(speaker.displayName)] 再接続失敗 (\(attempt + 1)/\(Self.maxReconnectAttempts)): \(error.localizedDescription)")
            }
        }

        AppState.shared.reconnectingStreams.remove(speaker)
        setReconnectError("\(Self.reconnectErrorPrefix) [\(speaker.displayName)] 再接続を諦めました。録音は継続しますが、文字起こしは止まります。")
        DebugLog.log("[ClawdListen] reconnect gave up for \(speaker.rawValue)")
    }

    /// 再接続関連のエラーメッセージだけを更新する (他種のエラーを上書きしない方針を保ちつつ、
    /// 再接続中の最新状況は反映する)。
    private func setReconnectError(_ message: String) {
        AppState.shared.lastError = message
    }

    /// 再接続成功時の lastError クリア。自分が立てた `[再接続]` 接頭辞のメッセージのみ消す。
    /// 他種のエラー (文字起こし失敗、API エラー等) は維持する。
    private func clearReconnectErrorIfMine() {
        if AppState.shared.lastError?.hasPrefix(Self.reconnectErrorPrefix) == true {
            AppState.shared.lastError = nil
        }
    }
}
