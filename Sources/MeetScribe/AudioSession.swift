import AVFoundation
import Foundation

/// キャプチャ経路が渡す音声フレームの共通表現。
enum AudioFrame {
    case pcm(AVAudioPCMBuffer)
    case sample(CMSampleBuffer)
}

/// 1ストリーム分の音声処理パイプライン。
/// PCM 変換 → 選択プロバイダーのWebSocketへの送信を行う。
/// `client` は再接続時に差し替える可能性があるので var + lock 保護。
private final class TranscriptionPipeline: @unchecked Sendable {
    private let clientLock = NSLock()
    private var _client: TranscriptionClient
    private var converter: PCMConverter?
    private let targetSampleRate: Double

    init(client: TranscriptionClient) {
        self._client = client
        self.targetSampleRate = client.sampleRate
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
                converter = PCMConverter(
                    sourceFormat: buffer.format,
                    targetSampleRate: targetSampleRate
                )
            }
            pcm = converter?.convert(buffer)
        case .sample(let sampleBuffer):
            pcm = PCMConverter.convert(
                sampleBuffer,
                using: &converter,
                targetSampleRate: targetSampleRate
            )
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

    /// クライアント側ノイズフィルタ。環境音・機械音を OpenAI に送る前に除去する。
    private let micPreProcessor = AudioPreProcessor(config: .microphone, label: "mic-pre")
    private let sysPreProcessor = AudioPreProcessor(config: .systemAudio, label: "sys-pre")

    /// 再接続中の Task。多重再接続を防ぐためストリームごとに 1 本だけ保持。
    private var micReconnectTask: Task<Void, Never>?
    private var sysReconnectTask: Task<Void, Never>?

    /// SCStream 復帰中の Task。多重復帰を防ぐため 1 本だけ保持。
    private var sysCaptureRestartTask: Task<Void, Never>?

    /// マイク tap 途絶の監視 Task。録音中のみ生存させ、停止時に必ず cancel する
    /// (Task を残すと停止後に誤発火して engine を起こし直す)。
    private var micWatchdogTask: Task<Void, Never>?

    /// マイク engine 再起動中の Task。多重再起動を防ぐため 1 本だけ保持
    /// (`sysCaptureRestartTask` と同じガード方式)。
    private var micCaptureRestartTask: Task<Void, Never>?

    /// 現セッションで実行したマイク engine 再起動の回数。tap が戻ったら 0 に戻す。
    private var micRestartCount = 0

    /// 現セッションの文字起こし言語。start() 時の設定値を固定し、録音中に
    /// 設定を変えても再接続ストリームだけ言語が変わる不整合を防ぐ
    /// (UI の「次回の録音開始から適用」との一貫性)。
    private var activeLanguage: String?
    private var activeProvider: AIProvider?
    private var activeAPIKey: String?

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
        DebugLog.log("[MeetScribe] AudioSession.start()")
        AppState.shared.captureStatus = .starting
        AppState.shared.lastError = nil
        AppState.shared.lastSavedURL = nil
        AppState.shared.totalCostUSD = 0
        TranscriptStore.shared.clear()
        // singleton (AudioSession) が保持する前処理器は会議間で再利用されるため、
        // passRate 等の統計を会議単位にリセットする (デバッグログの意味を保つため)。
        micPreProcessor.resetStats()
        sysPreProcessor.resetStats()
        // 前回セッションの残キューが新セッションに紛れ込まないよう防御的に破棄する
        // (通常は stop()/kill() で処理済みのはず)。
        await TranscriptCleanerBatcher.shared.discardAll()

        let provider = AppState.shared.selectedProvider
        guard let apiKey = KeychainStore.read(for: provider), !apiKey.isEmpty else {
            AppState.shared.captureStatus = .error("API Keyが未設定")
            AppState.shared.lastError = "\(provider.shortDisplayName) API Keyを設定してください"
            return
        }

        let language = AppState.shared.transcriptionLanguageCode
        self.activeLanguage = language
        self.activeProvider = provider
        self.activeAPIKey = apiKey
        let micClient = TranscriptionClient(
            apiKey: apiKey,
            speaker: .me,
            language: language,
            provider: provider
        )
        let sysClient = TranscriptionClient(
            apiKey: apiKey,
            speaker: .other,
            language: language,
            provider: provider
        )
        do {
            async let micConnect: Void = micClient.connect()
            async let sysConnect: Void = sysClient.connect()
            try await micConnect
            try await sysConnect
        } catch {
            AppState.shared.lastError = "\(provider.shortDisplayName)接続失敗: \(error.localizedDescription)"
            AppState.shared.captureStatus = .error(error.localizedDescription)
            micClient.disconnect()
            sysClient.disconnect()
            activeLanguage = nil
            activeProvider = nil
            activeAPIKey = nil
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

        // SCStream が OS 都合で停止したら (画面ロック・ディスプレイ構成変化・
        // 画面収録権限の再確認等)、まず自動復帰を試みる。会議続行中に即保存終了
        // すると議事録が分断されるため (2026-07-22 リクルート面談で実害)。
        // 復帰しきれなかった時だけ従来どおり stop() 経路で保存終了する。
        // delegate が captureStatus を直接 .error にすると停止ボタンも Kill も
        // 消えてマイクだけ回り続ける詰みになるため、必ず stop() 経路に流す。
        systemAudio.onUnexpectedStop = { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self, AppState.shared.isRunning else { return }
                self.startSystemAudioRestart(reason: reason)
            }
        }

        do {
            try microphone.start(onBuffer: makeMicrophoneHandler(pipeline: micPipeline))
        } catch {
            AppState.shared.lastError = "マイク起動失敗: \(error.localizedDescription)"
            AppState.shared.captureStatus = .error(error.localizedDescription)
            tearDown()
            return
        }

        do {
            try await systemAudio.start(onBuffer: makeSystemAudioHandler(pipeline: sysPipeline))
        } catch {
            AppState.shared.lastError = "システム音起動失敗: \(error.localizedDescription)"
            AppState.shared.captureStatus = .error(error.localizedDescription)
            tearDown()
            return
        }

        // 会議開始時刻をマーク + Copilot (全体像の自動更新) 開始 + 無音検知タイマー起動 (10分)
        AppState.shared.meetingStartedAt = Date()
        CopilotController.shared.startSession(provider: provider, apiKey: apiKey)
        let detector = SilenceDetector(timeoutMinutes: 10.0) { [weak self] in
            DebugLog.log("[MeetScribe] silence timeout → auto-stop")
            Task { await self?.stop() }
        }
        detector.start()
        silenceDetector = detector
        // マイク tap の途絶監視を開始 (AVAudioEngine の無警告死の検知)。
        startMicrophoneWatchdog()

        AppState.shared.captureStatus = .running
    }

    // MARK: - Stop (正常終了: 議事録を保存)

    func stop() async {
        // 再入ガード: stop() の呼び出し元は3系統ある (ユーザー操作 / 無音タイムアウト /
        // SCStream異常停止)。保存フロー (~15秒) の suspension 中に別系統から重なると
        // runSaveFlow が二重実行され議事録が2重保存されるため、.running 以外は弾く。
        guard AppState.shared.captureStatus == .running else {
            DebugLog.log("[MeetScribe] AudioSession.stop() ignored (status != running)")
            return
        }
        DebugLog.log("[MeetScribe] AudioSession.stop() - with save")
        AppState.shared.captureStatus = .stopping
        // 保存フロー (実測1〜14秒) が終わるまで .stopping を維持する。
        // ここで先に .idle へ戻すと、保存中にヘッダーの録音ボタンやメニューバー
        // (`AppDelegate.toggleRecording` は `canStart` 判定) から次の録音を開始できてしまい:
        //   1. start() の TranscriptStore.clear() で直前の会議の文字起こしが消える
        //      (`meetingEntries` は isFinal を見ないので partial 1個で長時間の会議が数語に化ける)
        //   2. 旧セッションの保存フロー末尾の `meetingStartedAt = nil` が新セッションの
        //      開始時刻を潰し、次の stop() が `guard let startedAt` で落ちて
        //      「empty transcript → skip save」の嘘ログを出して2件目も丸ごと捨てる
        // `.stopping` は computeCanStart で開始不可・startBlockReason は「停止処理中です」・
        // HeaderView は ProgressView と既に配線済みなので、状態を維持するだけで塞げる。
        // 早期 return / 保存成功 / 保存失敗のどの経路でも必ず .idle に戻すため defer で落とす
        // (戻し忘れると録音が二度と開始できなくなる)。
        defer { AppState.shared.captureStatus = .idle }

        let startedAt = AppState.shared.meetingStartedAt
        let endedAt = Date()
        let sessionProvider = activeProvider ?? AppState.shared.selectedProvider
        // tearDown() で activeAPIKey がクリアされる前に退避する
        // (この後の runSaveFlow でタイトル生成に使う)
        let sessionAPIKey = activeAPIKey ?? KeychainStore.read(for: sessionProvider)
        CopilotController.shared.endSession()
        microphone.stop()
        await systemAudio.stop()
        silenceDetector?.stop()
        silenceDetector = nil
        await finishTranscriptionClients()
        // 残っている整形待ちセグメントを必ず処理する。runSaveFlow のタイトル生成
        // (~15秒) 中に再取得する latestEntries に間に合わせるため、tearDown前に待つ。
        await TranscriptCleanerBatcher.shared.flushAll()
        tearDown()
        AppState.shared.micLevel = 0.0
        AppState.shared.systemLevel = 0.0

        // 発話が無ければ保存しない
        let meetingEntries = TranscriptStore.shared.meetingEntries
        guard let startedAt = startedAt, !meetingEntries.isEmpty else {
            DebugLog.log("[MeetScribe] empty transcript → skip save")
            AppState.shared.meetingStartedAt = nil
            return
        }

        await runSaveFlow(
            startedAt: startedAt,
            endedAt: endedAt,
            meetingEntries: meetingEntries,
            provider: sessionProvider,
            apiKey: sessionAPIKey
        )
        AppState.shared.meetingStartedAt = nil
    }

    // MARK: - Kill (緊急停止: 保存しない)

    func kill() async {
        DebugLog.log("[MeetScribe] AudioSession.kill() - no save")
        AppState.shared.captureStatus = .stopping
        CopilotController.shared.endSession()
        microphone.stop()
        await systemAudio.stop()
        silenceDetector?.stop()
        silenceDetector = nil
        // 保存しない (結果を捨てる) ので、キュー中のセグメントをLLMに投げず破棄する
        // (無駄な課金を避ける)。
        await TranscriptCleanerBatcher.shared.discardAll()
        tearDown()
        TranscriptStore.shared.clear()
        AppState.shared.micLevel = 0.0
        AppState.shared.systemLevel = 0.0
        AppState.shared.captureStatus = .idle
        AppState.shared.meetingStartedAt = nil
        AppState.shared.lastSavedURL = nil
    }

    // MARK: - 同期シャットダウン (アプリ終了時)

    /// `applicationWillTerminate` から呼ぶ同期クリーンアップ。terminate 後は
    /// runloop が回らず async (`await systemAudio.stop()`) を待てないため、共有
    /// オーディオリソース (Voice Processing IO / SCStream) の解放を同期的に行う。
    /// 議事録の保存はしない (時間がかかり terminate に間に合わないため)。
    /// これを怠ると coreaudiod に孤児リソースが残り Mac 全体がフリーズする。
    func shutdownSync() {
        DebugLog.log("[MeetScribe] AudioSession.shutdownSync()")
        CopilotController.shared.endSession()
        // ベストエフォート (terminate に間に合わなくても実害なし: プロセス終了で
        // どのみち破棄される。await はしない — runSaveFlow 同様 terminate を待たせない)。
        Task { await TranscriptCleanerBatcher.shared.discardAll() }
        microphone.stop()        // VPIO を同期解放
        systemAudio.stopSync()   // SCStream をベストエフォート停止
        silenceDetector?.stop()
        silenceDetector = nil
        tearDown()
        AppState.shared.micLevel = 0.0
        AppState.shared.systemLevel = 0.0
    }

    // MARK: - 保存フロー

    private func runSaveFlow(
        startedAt: Date,
        endedAt: Date,
        meetingEntries: [TranscriptEntry],
        provider: AIProvider,
        apiKey: String?
    ) async {
        AppState.shared.isSavingMeeting = true
        defer { AppState.shared.isSavingMeeting = false }

        // 1. タイトル生成 (会議で使用中のプロバイダーのチャットモデル)
        let transcriptText = TranscriptStore.shared.meetingTranscriptText
        let title = await MeetingTitleGenerator.generate(
            from: transcriptText,
            apiKey: apiKey,
            provider: provider
        )
        DebugLog.log("[MeetScribe] generated title (\(title.count) chars)")

        // 2. レコード組み立て + 保存。
        // タイトル生成 (~15秒) の間に GPT-4.1 mini の整形結果が届くことがあるため、
        // 引数のスナップショットではなく store から最新エントリを取り直す。
        // (店じまい後に clear はされないので、録音停止時点の全エントリが残っている)
        let latestEntries = TranscriptStore.shared.meetingEntries
        let record = MeetingRecord(
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            meetingEntries: latestEntries.isEmpty ? meetingEntries : latestEntries,
            overview: AppState.shared.overview,
            catchupCards: AppState.shared.catchupCards,
            totalCostUSD: AppState.shared.totalCostUSD,
            model: provider.transcriptionModel,
            provider: provider,
            assistantModel: provider.chatModel
        )
        do {
            let url = try TranscriptExporter.save(record, to: AppState.shared.meetingsSaveDirectoryURL)
            AppState.shared.lastSavedURL = url
            AppState.shared.meetingSaveCount += 1
            // ファイル名には AI 生成タイトル (= 会議内容の要約) が入るため、
            // 保存先ディレクトリまでに留める
            DebugLog.log("[MeetScribe] saved to: \(url.deletingLastPathComponent().path)")
        } catch {
            DebugLog.log("[MeetScribe] save failed: \(error.localizedDescription)")
            // 保存先に書けなかった (フォルダ消失・権限喪失・ディスク不足等)。
            // 会議の記録を失わないよう、アプリ管理下の退避フォルダへ逃がす。
            do {
                let rescueURL = try TranscriptExporter.saveToRescue(record)
                AppState.shared.lastSavedURL = rescueURL
                AppState.shared.lastError =
                    "保存先に書き込めなかったため、バックアップに保存しました: \(rescueURL.path)"
                DebugLog.log("[MeetScribe] rescued to: \(rescueURL.deletingLastPathComponent().path)")
            } catch {
                AppState.shared.lastError =
                    "議事録の保存に失敗しました: \(error.localizedDescription)"
                DebugLog.log("[MeetScribe] rescue save also failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - リソース解放

    private func finishTranscriptionClients() async {
        let mic = micClient
        let sys = sysClient
        async let finishMic: Void = mic?.finish() ?? ()
        async let finishSys: Void = sys?.finish() ?? ()
        _ = await (finishMic, finishSys)
    }

    private func tearDown() {
        // キャプチャエンジンも必ず停止する (二重 stop は各 isRunning ガードで無害)。
        // 接続系だけ畳んでマイクが回り続けると、start() 途中失敗時に VPIO が
        // 孤児化して録りっぱなしになり、captureStatus=.error と合わせて復帰不能になる。
        microphone.stop()
        systemAudio.stopSync()
        systemAudio.onUnexpectedStop = nil
        micReconnectTask?.cancel()
        sysReconnectTask?.cancel()
        sysCaptureRestartTask?.cancel()
        // 監視/再起動 Task を残すと停止後や次セッションで誤発火するので必ず畳む。
        micWatchdogTask?.cancel()
        micCaptureRestartTask?.cancel()
        micReconnectTask = nil
        sysReconnectTask = nil
        sysCaptureRestartTask = nil
        micWatchdogTask = nil
        micCaptureRestartTask = nil
        micRestartCount = 0
        micClient?.disconnect()
        sysClient?.disconnect()
        micClient = nil
        sysClient = nil
        micPipeline = nil
        sysPipeline = nil
        activeLanguage = nil
        activeProvider = nil
        activeAPIKey = nil
        AppState.shared.reconnectingStreams = []
        // ミュートを次の会議へ持ち越すと片側が黙って文字起こしされない事故になる
        AppState.shared.mutedStreams = []
    }

    /// マイクキャプチャのバッファハンドラ。start() と tap 途絶からの engine 再起動の
    /// 両方から使うため一本化する (復帰パスだけミュートガードが漏れる事故を防ぐ)。
    private func makeMicrophoneHandler(
        pipeline: TranscriptionPipeline
    ) -> MicrophoneCapture.BufferHandler {
        { [preProcessor = micPreProcessor] buffer, _ in
            // ミュート中 (Scribe に聴かせないボタン) はフレームを破棄。
            // キャプチャと VU メーターは生かしたまま送信だけ止める。
            guard !StreamMuteState.shared.isMuted(.me) else { return }
            // ノイズゲート/スペクトル解析を通過したフレームだけ送信パイプラインへ渡す。
            // VU メーター用レベルは MicrophoneCapture 側で既に生バッファから計測済みなので、
            // ここでのゲーティングは表示には影響しない。
            preProcessor.processAndForward(buffer, sampleRate: buffer.format.sampleRate) { gated in
                pipeline.process(.pcm(gated))
            }
        }
    }

    /// システム音声キャプチャのバッファハンドラ。start() と SCStream 自動復帰の
    /// 両方から使うため一本化する (復帰パスだけミュートガードが漏れて、復帰後に
    /// ミュートが黙って無効化される事故を防ぐ)。
    private func makeSystemAudioHandler(
        pipeline: TranscriptionPipeline
    ) -> SystemAudioCapture.BufferHandler {
        { [preProcessor = sysPreProcessor] sampleBuffer in
            // ミュート中 (Scribe に聴かせないボタン) はフレームを破棄。
            guard !StreamMuteState.shared.isMuted(.other) else { return }
            preProcessor.processAndForward(sampleBuffer) { gated in
                pipeline.process(.sample(gated))
            }
        }
    }

    // MARK: - マイク tap 途絶の監視 (AVAudioEngine の無警告死)

    /// マイク監視フローが lastError に書く文言の接頭辞 (成功時に自分のメッセージだけ消すため)。
    private static let micStallErrorPrefix = "[マイク]"

    /// tap 途絶の監視を開始する。録音中のみ回し、`tearDown()` で必ず cancel する。
    private func startMicrophoneWatchdog() {
        micWatchdogTask?.cancel()
        micRestartCount = 0
        micWatchdogTask = Task { [weak self] in
            await self?.runMicrophoneWatchdogLoop()
        }
    }

    /// `MicrophoneTapWatchdog.pollIntervalSeconds` ごとに tap の途絶を確認し、
    /// 途絶していたら engine を再起動する。判定そのものは
    /// `MicrophoneTapWatchdog.isStalled` (純関数・テスト済み) に委ねる。
    private func runMicrophoneWatchdogLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(MicrophoneTapWatchdog.pollIntervalSeconds))
            if Task.isCancelled { return }
            // 録音中以外 (停止・保存フロー・エラー) では監視しない。
            guard AppState.shared.isRunning else { return }

            let stalled = MicrophoneTapWatchdog.isStalled(
                secondsSinceLastTap: microphone.secondsSinceLastTap,
                isMuted: StreamMuteState.shared.isMuted(.me),
                isRunning: AppState.shared.isRunning
            )
            guard stalled else {
                // tap が戻った → 次の事故に備えて再起動枠を戻し、自分のバナーだけ消す。
                if micRestartCount > 0 {
                    micRestartCount = 0
                    clearMicStallErrorIfMine()
                }
                continue
            }
            // 再起動中は次の tick を待つ (多重再起動の防止)。
            guard micCaptureRestartTask == nil else { continue }
            guard micRestartCount < MicrophoneTapWatchdog.maxRestartAttempts else {
                // 入力デバイスそのものが消えている (Bluetooth 切断等) 場合は再起動でも
                // 戻らない。無限リトライを止め、手掛かりだけ残して監視を終了する。
                DebugLog.log("[MeetScribe] mic watchdog gave up after \(micRestartCount) restarts")
                AppState.shared.lastError =
                    "\(Self.micStallErrorPrefix) 音声が届いていません。入力デバイスの接続を確認してください "
                    + "(再起動を\(micRestartCount)回試みました)。"
                return
            }
            micRestartCount += 1
            startMicrophoneRestart(attempt: micRestartCount)
        }
    }

    /// engine 再起動を1本だけ走らせる (`sysCaptureRestartTask` と同じ再入ガード)。
    private func startMicrophoneRestart(attempt: Int) {
        guard micCaptureRestartTask == nil else { return }
        micCaptureRestartTask = Task { [weak self] in
            await self?.runMicrophoneRestart(attempt: attempt)
            // AudioSession は @MainActor なので Task 本体も MainActor 継承。
            // ループ完了と同じ同期区間で nil に戻し、次回の途絶に備える。
            self?.micCaptureRestartTask = nil
        }
    }

    /// tap が途絶したマイクを stop → start で作り直す。
    ///
    /// `TranscriptionPipeline.converter` のリセットは**不要**: `PCMConverter.convert()`
    /// は毎フレーム buffer の実フォーマットから `AVAudioConverter` を作り直すので、
    /// デバイス切替によるフォーマット変更 (ch/sr の変化) は既に透過している。
    private func runMicrophoneRestart(attempt: Int) async {
        guard AppState.shared.isRunning, let micPipeline else { return }
        let stalledFor = microphone.secondsSinceLastTap ?? 0
        DebugLog.log(
            "[MeetScribe] mic tap stalled \(String(format: "%.1f", stalledFor))s"
            + " → restarting engine (attempt \(attempt))"
        )
        AppState.shared.lastError =
            "\(Self.micStallErrorPrefix) 音声が届かなくなりました (入力デバイスの切替?)。マイクを再起動しています…"
        microphone.stop()
        do {
            try microphone.start(onBuffer: makeMicrophoneHandler(pipeline: micPipeline))
            DebugLog.log("[MeetScribe] mic engine restarted (attempt \(attempt))")
            // 成功バナーの消去は監視ループ側で行う (実際に tap が戻ったのを確認してから)。
        } catch {
            DebugLog.log(
                "[MeetScribe] mic engine restart failed (attempt \(attempt)): \(error.localizedDescription)"
            )
            AppState.shared.lastError =
                "\(Self.micStallErrorPrefix) マイクを再起動できませんでした: \(error.localizedDescription)"
        }
    }

    /// マイク監視が立てたバナーだけを消す (他ストリームや他種のエラーは維持する)。
    private func clearMicStallErrorIfMine() {
        guard AppState.shared.lastError?.hasPrefix(Self.micStallErrorPrefix) == true else { return }
        AppState.shared.lastError = nil
    }

    // MARK: - SCStream 自動復帰

    /// SCStream 復帰のリトライ間隔。画面ロック・ディスプレイ切替のような一時的な
    /// 停止から戻れるよう合計 ~60秒粘る。復帰中もマイク側の録音と文字起こしは継続する。
    private static let captureRestartBackoffSeconds: [TimeInterval] = [1, 2, 4, 8, 15, 30]

    /// 復帰フローが lastError に書く文言の接頭辞 (成功時に自分のメッセージだけ消すため)。
    private static let captureRestartErrorPrefix = "[システム音声]"

    private func startSystemAudioRestart(reason: String) {
        guard sysCaptureRestartTask == nil else { return }
        sysCaptureRestartTask = Task { [weak self] in
            await self?.runSystemAudioRestartLoop(reason: reason)
            // AudioSession は @MainActor なので Task 本体も MainActor 継承。
            // ループ完了と同じ同期区間で nil に戻し、次回の異常停止に備える。
            self?.sysCaptureRestartTask = nil
        }
    }

    private func runSystemAudioRestartLoop(reason: String) async {
        DebugLog.log("[MeetScribe] system audio restart start (reason: \(reason))")
        AppState.shared.lastError =
            "\(Self.captureRestartErrorPrefix) 停止しました (\(reason))。復帰を試みています…"

        for (attempt, delay) in Self.captureRestartBackoffSeconds.enumerated() {
            try? await Task.sleep(for: .seconds(delay))
            // ユーザーが stop/kill を押していたら黙って退く (stop 側が畳み済み)
            if Task.isCancelled || !AppState.shared.isRunning { return }
            guard let sysPipeline else { return }
            do {
                try await systemAudio.start(onBuffer: makeSystemAudioHandler(pipeline: sysPipeline))
                DebugLog.log("[MeetScribe] system audio restart succeeded (attempt \(attempt + 1))")
                if AppState.shared.lastError?.hasPrefix(Self.captureRestartErrorPrefix) == true {
                    AppState.shared.lastError = nil
                }
                return
            } catch {
                DebugLog.log("[MeetScribe] system audio restart attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }

        // 復帰失敗 → 従来どおり安全に終了して議事録を保存する
        guard AppState.shared.isRunning else { return }
        DebugLog.log("[MeetScribe] system audio restart gave up → stop & save")
        AppState.shared.lastError =
            "\(Self.captureRestartErrorPrefix) 復帰できませんでした (\(reason))。録音を終了して議事録を保存します。"
        await stop()
    }

    // MARK: - 自動再接続実装

    /// Client に onUnexpectedClose ハンドラを取り付ける (ロック保護経由)。
    /// `wired` 後に切断検知すると `reconnect(speaker:)` が走る。
    private func wireUnexpectedClose(client: TranscriptionClient, speaker: SpeakerLabel) {
        client.setOnUnexpectedClose { [weak self] quiet in
            // コールバックは MainActor 外スレッドから呼ばれる可能性があるので跳ばす。
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.startReconnect(speaker: speaker, quiet: quiet)
            }
        }
    }

    /// 指定ストリームの再接続 Task を起動 (既に走っているなら何もしない)。
    private func startReconnect(speaker: SpeakerLabel, quiet: Bool) {
        // 録音中でなければ再接続しない (stop / kill 後の遅延発火対策)
        guard AppState.shared.isRunning else { return }

        switch speaker {
        case .me:
            guard micReconnectTask == nil else { return }
            micReconnectTask = Task { [weak self] in
                await self?.runReconnectLoop(speaker: .me, quiet: quiet)
                await MainActor.run { self?.micReconnectTask = nil }
            }
        case .other:
            guard sysReconnectTask == nil else { return }
            sysReconnectTask = Task { [weak self] in
                await self?.runReconnectLoop(speaker: .other, quiet: quiet)
                await MainActor.run { self?.sysReconnectTask = nil }
            }
        default:
            return
        }
    }

    /// 指数バックオフで再接続を試みる。成功したら pipeline.client を差し替え、
    /// 失敗継続したらユーザーに通知して諦める。
    /// `quiet` は正常系の切断 (xAI 無音タイムアウト等) 起因の再接続で、途中経過の
    /// バナーを出さない。ただし諦めた時 (ストリーム死亡) だけは quiet でも表示する。
    private func runReconnectLoop(speaker: SpeakerLabel, quiet: Bool) async {
        AppState.shared.reconnectingStreams.insert(speaker)
        if !quiet {
            setReconnectError("\(Self.reconnectErrorPrefix) [\(speaker.displayName)] 接続切れ、再接続中…")
        }
        DebugLog.log("[MeetScribe] reconnect start for \(speaker.rawValue) (quiet=\(quiet))")

        guard let provider = activeProvider,
              let apiKey = activeAPIKey,
              !apiKey.isEmpty else {
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

            let newClient = TranscriptionClient(
                apiKey: apiKey,
                speaker: speaker,
                language: activeLanguage,
                provider: provider
            )
            do {
                try await newClient.connect()
                // connect 中に stop/kill が来ていたらゾンビ client を残さず破棄して終了
                if Task.isCancelled || !AppState.shared.isRunning {
                    newClient.disconnect()
                    DebugLog.log("[MeetScribe] reconnect cancelled after connect for \(speaker.rawValue)")
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
                clearReconnectErrorIfMine(speaker: speaker)
                DebugLog.log("[MeetScribe] reconnect succeeded for \(speaker.rawValue) (attempt \(attempt + 1))")
                return
            } catch {
                DebugLog.log("[MeetScribe] reconnect attempt \(attempt + 1) failed for \(speaker.rawValue): \(error.localizedDescription)")
                newClient.disconnect()
                if !quiet {
                    setReconnectError("\(Self.reconnectErrorPrefix) [\(speaker.displayName)] 再接続失敗 (\(attempt + 1)/\(Self.maxReconnectAttempts)): \(error.localizedDescription)")
                }
            }
        }

        AppState.shared.reconnectingStreams.remove(speaker)
        setReconnectError("\(Self.reconnectErrorPrefix) [\(speaker.displayName)] 再接続を諦めました。録音は継続しますが、文字起こしは止まります。")
        DebugLog.log("[MeetScribe] reconnect gave up for \(speaker.rawValue)")
    }

    /// 再接続関連のエラーメッセージだけを更新する (他種のエラーを上書きしない方針を保ちつつ、
    /// 再接続中の最新状況は反映する)。
    private func setReconnectError(_ message: String) {
        AppState.shared.lastError = message
    }

    /// 再接続成功時の lastError クリア。自分が立てた `[再接続]` 接頭辞のメッセージに加え、
    /// speaker 指定時は該当ストリームの通信系エラー (受信エラー / APIエラー) も消す
    /// — 再接続に成功した時点でそれらは解消済みであり、残すと赤字が出続ける。
    /// 他ストリームや他種のエラーは維持する。
    private func clearReconnectErrorIfMine(speaker: SpeakerLabel? = nil) {
        guard let lastError = AppState.shared.lastError else { return }
        if lastError.hasPrefix(Self.reconnectErrorPrefix) {
            AppState.shared.lastError = nil
            return
        }
        if let speaker,
           lastError.hasPrefix("[\(speaker.displayName)] 受信エラー:")
            || lastError.hasPrefix("[\(speaker.displayName)] APIエラー:") {
            AppState.shared.lastError = nil
        }
    }
}
