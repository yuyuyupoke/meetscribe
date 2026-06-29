import AVFoundation

/// ノイズゲートとスペクトル解析を統合する音声前処理パイプライン。
///
/// 判定フロー:
///   1. NoiseGate: RMS が閾値以下 → スキップ（環境音の大半をここで除去）
///   2. SpectralAnalyzer: ゲートを通過した音のスペクトルを解析
///      → 人声帯域比率低 or 高スペクトル平坦度 → ノイズ判定でスキップ
///
/// NoiseGate を先にかけることで、無音〜微小音を安価にフィルタし、
/// 計算コストの高い FFT はゲートを通過した音にだけ適用する。
///
/// `@unchecked Sendable`: オーディオスレッド（シリアルキュー）から呼ばれる前提。
final class AudioPreProcessor: @unchecked Sendable {
    struct Config: Sendable {
        var noiseGateConfig: NoiseGate.Config
        var spectralConfig: SpectralAnalyzer.Config
        /// スペクトル解析を有効にするか。false なら NoiseGate のみ
        var enableSpectralAnalysis: Bool

        static let microphone = Config(
            noiseGateConfig: .microphone,
            spectralConfig: .default,
            enableSpectralAnalysis: false
        )

        static let systemAudio = Config(
            noiseGateConfig: .systemAudio,
            spectralConfig: SpectralAnalyzer.Config(
                voiceLowHz: 80.0,
                voiceHighHz: 4000.0,
                voiceEnergyRatioThreshold: 0.25,
                spectralFlatnessThreshold: 0.65,
                consecutiveNoiseFramesThreshold: 5
            ),
            enableSpectralAnalysis: true
        )
    }

    private let noiseGate: NoiseGate
    private let spectralAnalyzer: SpectralAnalyzer
    private let enableSpectral: Bool
    private let label: String

    private var totalFrames: Int = 0
    private var passedFrames: Int = 0
    private var gateFilteredFrames: Int = 0
    private var spectralFilteredFrames: Int = 0

    init(config: Config, label: String = "pre") {
        self.noiseGate = NoiseGate(config: config.noiseGateConfig)
        self.spectralAnalyzer = SpectralAnalyzer(config: config.spectralConfig)
        self.enableSpectral = config.enableSpectralAnalysis
        self.label = label
    }

    /// AVAudioPCMBuffer を処理。ノイズと判定されたら nil を返す。
    func process(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> AVAudioPCMBuffer? {
        totalFrames += 1

        // Stage 1: NoiseGate
        guard let gatedBuffer = noiseGate.process(buffer, sampleRate: sampleRate) else {
            gateFilteredFrames += 1
            logPeriodically()
            return nil
        }

        // Stage 2: SpectralAnalyzer (optional)
        if enableSpectral {
            let result = spectralAnalyzer.analyze(gatedBuffer, sampleRate: sampleRate)
            if !result.isLikelyVoice {
                spectralFilteredFrames += 1
                logPeriodically()
                return nil
            }
        }

        passedFrames += 1
        logPeriodically()
        return gatedBuffer
    }

    /// CMSampleBuffer を AVAudioPCMBuffer に変換してから処理する便利メソッド。
    /// SystemAudioCapture 向け。
    func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription,
              var asbd = formatDescription.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            return sampleBuffer
        }

        guard let pcmBuffer = sampleBuffer.toPCMBuffer(format: format) else {
            return sampleBuffer
        }

        let sampleRate = format.sampleRate
        if process(pcmBuffer, sampleRate: sampleRate) != nil {
            return sampleBuffer
        }
        return nil
    }

    /// 統計をリセット
    func resetStats() {
        totalFrames = 0
        passedFrames = 0
        gateFilteredFrames = 0
        spectralFilteredFrames = 0
        noiseGate.resetStats()
        spectralAnalyzer.resetStats()
    }

    /// 通過率（0.0〜1.0、1.0 = 全フレーム通過）
    var passRate: Float {
        guard totalFrames > 0 else { return 1.0 }
        return Float(passedFrames) / Float(totalFrames)
    }

    private func logPeriodically() {
        if totalFrames == 1 || totalFrames % 500 == 0 {
            DebugLog.log("[\(label)] total=\(totalFrames) passed=\(passedFrames) gateFiltered=\(gateFilteredFrames) spectralFiltered=\(spectralFilteredFrames) passRate=\(String(format: "%.1f%%", passRate * 100))")
        }
    }
}
