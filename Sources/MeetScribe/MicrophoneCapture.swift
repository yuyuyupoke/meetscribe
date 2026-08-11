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
/// `@unchecked Sendable`: tap callback はシリアルキューから呼ばれる前提。
final class MicrophoneCapture: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let engine = AVAudioEngine()
    private var bufferHandler: BufferHandler?
    private var tapCount = 0
    private(set) var isRunning = false

    /// tap が最後にバッファを渡した時刻 (`systemUptime`)。停止中・未開始は nil。
    /// tap はキャプチャスレッドから、読み出しは MainActor の watchdog から来るので
    /// NSLock + var で保護する (`OSAllocatedUnfairLock` に**関数型を入れると**
    /// withLock ごとに reabstraction thunk が連鎖して stop 時にスタック
    /// オーバーフローする既知事故があるため、ここでも値型のみを扱う)。
    /// `systemUptime` はスリープ中進まないので、スリープ復帰直後に途絶と誤判定しない。
    private let tapClockLock = NSLock()
    private var _lastTapUptime: TimeInterval?

    /// 最後に tap がバッファを渡してからの経過秒。停止中・未開始は nil。
    /// `MicrophoneTapWatchdog` が engine の無警告死を検知するための唯一の入力。
    var secondsSinceLastTap: TimeInterval? {
        tapClockLock.lock(); defer { tapClockLock.unlock() }
        guard let last = _lastTapUptime else { return nil }
        return max(0, ProcessInfo.processInfo.systemUptime - last)
    }

    private func markTapArrived(at uptime: TimeInterval) {
        tapClockLock.lock(); defer { tapClockLock.unlock() }
        _lastTapUptime = uptime
    }

    private func clearTapClock() {
        tapClockLock.lock(); defer { tapClockLock.unlock() }
        _lastTapUptime = nil
    }

    func start(onBuffer: BufferHandler? = nil) throws {
        // 既に動いている場合は一旦止めてから開始する。早期 return すると新しい
        // bufferHandler への差し替えがスキップされ、切断済みの旧パイプラインに
        // 音声が流れ続けて「録音中なのに文字起こしが来ない」詰みになる。
        if isRunning { stop() }
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

        engine.prepare()
        try engine.start()
        DebugLog.log("[mic] engine started: running=\(engine.isRunning)")
        // 監視の起点を engine 起動時刻にする。1バッファも届かないケース
        // (権限や入力デバイス消失) も閾値経過で検知させるため。
        markTapArrived(at: ProcessInfo.processInfo.systemUptime)
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // VoiceProcessingIO AudioUnit (AEC/AGC/NS) を明示解放する。これを怠ると
        // CoreAudio (coreaudiod) に孤児 VPIO が残り、プロセス終了時に OS 全体の
        // オーディオ HAL がブロックして Mac がフリーズする。setVoiceProcessingEnabled
        // が start 時に失敗していても try? で無害。
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        bufferHandler = nil
        isRunning = false
        // 停止中は「途絶」ではないので監視の材料を消す (再起動中の誤発火防止)。
        clearTapClock()
        // micLevel のリセットは呼び出し側 (AudioSession, @MainActor) で行う。
        // ここで Task を撒くと、アプリ終了経路でスケジュール前にプロセスが消える。
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
        markTapArrived(at: now)
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
