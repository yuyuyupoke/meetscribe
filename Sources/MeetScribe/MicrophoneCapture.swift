import AVFoundation
import Foundation

/// マイク音声をリアルタイムキャプチャする。
///
/// 設計:
///   * input ノードに直接 tap を install してハードウェアサンプルレートのまま PCM
///     バッファを取得する。リサンプル (48kHz → 24kHz) は PCMConverter で行う。
///   * **Voice Processing (AEC + AGC + NS) を有効化** して以下を実現:
///       - AEC: スピーカーから出ている相手の声をマイクが拾っても除去 (オンライン
///         会議で相手の発話が `[自分]` として2重記録される問題の解消)
///       - AGC: マイク入力レベルが小さい時に自動増幅 → 文字起こし精度向上
///       - NS:  環境ノイズ抑制 → 文字起こし精度向上
///   * 副作用としてシステム音出力が ducking (自動減衰) されるが、macOS 14+ の
///     `voiceProcessingOtherAudioDuckingConfiguration` で `.min` レベルに固定し、
///     体感では音量低下を感じない状態にする。
///
/// macOS 26 で `outputFormat(forBus:)` を使うと tap callback が初回しか呼ばれない
/// 既知挙動があるため、フォーマット取得は `inputFormat(forBus:)` を使う。
///
/// マイクキャプチャ開始が失敗した理由 (ObjC 例外にせず Swift エラーで返すもの)。
enum MicrophoneCaptureError: LocalizedError {
    /// 入力デバイスが無い / 使えない (sampleRate か channelCount が 0)。
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "利用できるマイク入力デバイスがありません"
        }
    }
}

/// `@unchecked Sendable`: tap callback はシリアルキューから呼ばれる前提。
final class MicrophoneCapture: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let engine = AVAudioEngine()
    private var bufferHandler: BufferHandler?
    private var tapCount = 0
    private(set) var isRunning = false

    /// bus 0 に tap を install 済みか。`isRunning` とは別に持つ必要がある:
    /// `installTap` 成功後に `engine.start()` が throw すると isRunning は false の
    /// まま tap だけが残り、`stop()` の isRunning ガードで**片付けが飛ぶ**。残った tap は
    /// 次の start() で2本目の installTap になり、AVAudioEngine が ObjC 例外
    /// (`nullptr == Tap()`) を投げて Swift から catch 不能 = プロセス即死する。
    private var tapInstalled = false

    /// tap の到達状況 (watchdog の唯一の入力)。判定材料の意味づけは
    /// `MicrophoneTapClock` 側のコメント参照。
    private let tapClock = MicrophoneTapClock()

    /// 監視起点 (engine 起動 / 起動失敗 / 最後の tap) からの経過秒。停止中・未開始は nil。
    /// `MicrophoneTapWatchdog` が engine の無警告死を検知するための入力。
    var secondsSinceLastTap: TimeInterval? {
        tapClock.secondsSinceLastTap(now: ProcessInfo.processInfo.systemUptime)
    }

    /// 直近の engine 起動 (または起動失敗) 以降に**実バッファ**が届いたか。
    /// watchdog が「再起動枠を戻して警告を消してよいか」を判断するために使う。
    /// engine が running を報告するだけでは true にならないのが要点。
    var hasTapArrivedSinceStart: Bool { tapClock.hasTapArrived }

    func start(onBuffer: BufferHandler? = nil) throws {
        // 既に動いている場合は一旦止めてから開始する。早期 return すると新しい
        // bufferHandler への差し替えがスキップされ、切断済みの旧パイプラインに
        // 音声が流れ続けて「録音中なのに文字起こしが来ない」詰みになる。
        // tapInstalled も見るのは、前回の start() が途中失敗して tap だけ残っている
        // ケースを必ず回収するため (残すと次の installTap が ObjC 例外になる)。
        if isRunning || tapInstalled { stop() }
        bufferHandler = onBuffer
        tapCount = 0

        let input = engine.inputNode

        // Voice Processing 有効化 (AEC + AGC + NS)。
        do {
            try input.setVoiceProcessingEnabled(true)
            DebugLog.log("[mic] voice processing enabled (AEC+AGC+NS)")
        } catch {
            // 失敗してもキャプチャ自体は続行 (生音で動かす)
            DebugLog.log("[mic] voice processing enable failed: \(error.localizedDescription)")
        }

        // 他オーディオへの ducking を最小化 (システム音減衰を抑制)。
        // macOS 14+ のみ。`.min` でも完全にゼロにはならないが、体感では問題ない範囲。
        if #available(macOS 14.0, *) {
            let ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
            DebugLog.log("[mic] ducking configured: level=.min")
        }

        let inputFormat = input.inputFormat(forBus: 0)
        DebugLog.log("[mic] hw input format: ch=\(inputFormat.channelCount) sr=\(Int(inputFormat.sampleRate))")

        // 入力デバイスが消えていると sampleRate / channelCount が 0 で返り、
        // installTap 自体が ObjC 例外を投げる (Swift から catch 不能 = プロセス即死)。
        // watchdog は「デバイスが消えた直後」= まさにこの状態で start() を呼ぶので、
        // 例外ではなく Swift エラーで返してバナーに載せる。
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            let error = MicrophoneCaptureError.noInputDevice
            rollbackFailedStart()
            DebugLog.log("[mic] start aborted: no usable input device")
            throw error
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            self.tapCount += 1
            let count = self.tapCount
            if count == 1 || count % 500 == 0 {
                DebugLog.log("[mic] tap #\(count) frameLength=\(buffer.frameLength) ch=\(buffer.format.channelCount)")
            }
            let mono = Self.extractFirstChannel(buffer) ?? buffer
            self.processBuffer(mono, time: time)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // 途中失敗で tap と VPIO を残すと (a) stop() が isRunning ガードで no-op に
            // なって孤児 VPIO が coreaudiod に残り Mac 全体がフリーズしうる、
            // (b) 次の start() が2本目の installTap で ObjC 例外を投げてプロセスが死ぬ。
            // 自分が作ったものは必ず自分で片付けてから rethrow する。
            rollbackFailedStart()
            throw error
        }
        DebugLog.log("[mic] engine started: running=\(engine.isRunning)")
        // 監視の起点を engine 起動時刻にする。1バッファも届かないケース
        // (権限や入力デバイス消失) も閾値経過で検知させるため。
        // **tap 到達扱いにはしない** (hasTapArrivedSinceStart は false のまま):
        // 「engine は running なのに tap が来ない」状態で watchdog が再起動枠を
        // 戻してしまうと、5秒周期の無限再起動になり打ち切りに到達できない。
        tapClock.markMonitoringStart(at: ProcessInfo.processInfo.systemUptime)
        isRunning = true
    }

    func stop() {
        // tapInstalled も見る: start() が engine.start() で throw した後は
        // isRunning == false / tap 残留の状態になりうるので、ここで回収できないと
        // 孤児 VPIO と二重 installTap の両方が残る。
        guard isRunning || tapInstalled else { return }
        teardownEngine()
        isRunning = false
        // 停止中は「途絶」ではないので監視の材料を消す (再起動中の誤発火防止)。
        tapClock.clear()
        // micLevel のリセットは呼び出し側 (AudioSession, @MainActor) で行う。
        // ここで Task を撒くと、アプリ終了経路でスケジュール前にプロセスが消える。
    }

    /// start() が途中で失敗した時の巻き戻し。監視の起点だけは**進めて**おく。
    /// nil に戻すと watchdog が「判断材料なし」として黙り、再試行も
    /// give-up 警告も永久に来ない (= マイクが無警告で死ぬ) ため。
    private func rollbackFailedStart() {
        teardownEngine()
        isRunning = false
        tapClock.markMonitoringStart(at: ProcessInfo.processInfo.systemUptime)
    }

    /// tap と VoiceProcessingIO を確実に解放する (stop と start 失敗の共通経路)。
    private func teardownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        // VoiceProcessingIO AudioUnit (AEC/AGC/NS) を明示解放する。これを怠ると
        // CoreAudio (coreaudiod) に孤児 VPIO が残り、プロセス終了時に OS 全体の
        // オーディオ HAL がブロックして Mac がフリーズする。setVoiceProcessingEnabled
        // が start 時に失敗していても try? で無害。
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        bufferHandler = nil
    }

    /// 多チャンネル PCM バッファからチャンネル0のみを取り出して
    /// 1チャンネルバッファに変換する
    private static func extractFirstChannel(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let srcFormat = buffer.format
        guard srcFormat.channelCount > 1 else { return buffer }
        guard let monoFormat = AVAudioFormat(
            commonFormat: srcFormat.commonFormat,
            sampleRate: srcFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        out.frameLength = buffer.frameLength

        if srcFormat.commonFormat == .pcmFormatFloat32,
           let srcCh0 = buffer.floatChannelData?[0],
           let dstCh0 = out.floatChannelData?[0] {
            memcpy(dstCh0, srcCh0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        return out
    }

    private var lastLevelUpdate: TimeInterval = 0

    private func processBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let now = ProcessInfo.processInfo.systemUptime
        // tap 到達の記録は**ミュート判定 (AudioSession 側のハンドラ) とノイズゲートより
        // 前**で行う。下流で記録すると「ミュート中」「無音の講義室」を engine の死と
        // 誤診して再起動を繰り返し、音声を刻む。
        tapClock.markTapArrived(at: now)
        // VU メーター用 level 更新は 100ms ごとに throttle (UI 描画負荷削減)
        if now - lastLevelUpdate >= 0.1 {
            lastLevelUpdate = now
            let level = AudioLevelMeter.normalizedLevel(from: buffer)
            Task { @MainActor in
                AppState.shared.micLevel = level
            }
        }
        bufferHandler?(buffer, time)
    }
}
