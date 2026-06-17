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

    func start(onBuffer: BufferHandler? = nil) throws {
        guard !isRunning else { return }
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
        // VU メーター用 level 更新は 100ms ごとに throttle (UI 描画負荷削減)
        let now = ProcessInfo.processInfo.systemUptime
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
