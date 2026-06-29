import Accelerate
import AVFoundation

/// スペクトル解析で人間の音声帯域エネルギーを評価し、
/// 定常ノイズ（ファン、エアコン等）を検出する。
///
/// 判定基準:
///   1. 人声帯域 (80–4000Hz) のエネルギー比率が低ければノイズ
///   2. スペクトル平坦度 (spectral flatness) が高ければ定常ノイズ
///      - 白色ノイズ: ~1.0、純音: ~0.0、音声: 0.1–0.4 程度
///
/// `@unchecked Sendable`: オーディオスレッド（シリアルキュー）から呼ばれる前提。
final class SpectralAnalyzer: @unchecked Sendable {
    struct Config: Sendable {
        /// 人声帯域の下限 (Hz)
        var voiceLowHz: Float
        /// 人声帯域の上限 (Hz)
        var voiceHighHz: Float
        /// 人声帯域エネルギー比率の最低閾値。これ未満ならノイズ判定
        var voiceEnergyRatioThreshold: Float
        /// スペクトル平坦度の閾値。これ以上なら定常ノイズ判定
        var spectralFlatnessThreshold: Float
        /// 連続ノイズフレーム数の閾値。この回数以上連続でノイズと判定されたらフィルタ発動
        var consecutiveNoiseFramesThreshold: Int

        static let `default` = Config(
            voiceLowHz: 80.0,
            voiceHighHz: 4000.0,
            voiceEnergyRatioThreshold: 0.3,
            spectralFlatnessThreshold: 0.6,
            consecutiveNoiseFramesThreshold: 3
        )
    }

    struct AnalysisResult: Sendable {
        let voiceEnergyRatio: Float
        let spectralFlatness: Float
        let isLikelyVoice: Bool
    }

    let config: Config

    /// FFT サイズ (2の冪)。1024 サンプル ≈ 42ms @24kHz、周波数分解能 ~23Hz
    private let fftSize: Int = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?

    // 作業バッファ: init で一度だけ確保（オーディオスレッドでの毎フレームアロケーション回避）
    private var windowedSamples: [Float]
    private var hannWindow: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudesBuffer: [Float]

    private var consecutiveNoiseFrames: Int = 0
    private var totalAnalyzed: Int = 0
    private var noiseDetected: Int = 0

    init(config: Config = .default) {
        self.config = config
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        let n = fftSize
        let halfN = n / 2
        self.windowedSamples = [Float](repeating: 0, count: n)
        self.hannWindow = [Float](repeating: 0, count: n)
        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.magnitudesBuffer = [Float](repeating: 0, count: halfN)
        vDSP_hann_window(&hannWindow, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    /// AVAudioPCMBuffer を解析して音声らしさを判定する。
    func analyze(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> AnalysisResult {
        totalAnalyzed += 1

        guard let channelData = buffer.floatChannelData,
              buffer.frameLength >= fftSize,
              fftSetup != nil else {
            return AnalysisResult(voiceEnergyRatio: 1.0, spectralFlatness: 0.0, isLikelyVoice: true)
        }

        let magnitudes = computeMagnitudes(channelData[0], frameCount: Int(buffer.frameLength))
        let voiceRatio = computeVoiceEnergyRatio(magnitudes: magnitudes, sampleRate: sampleRate)
        let flatness = computeSpectralFlatness(magnitudes: magnitudes)

        let isVoiceByRatio = voiceRatio >= config.voiceEnergyRatioThreshold
        let isStationaryNoise = flatness >= config.spectralFlatnessThreshold

        let isLikelyVoice: Bool
        if !isVoiceByRatio || isStationaryNoise {
            consecutiveNoiseFrames += 1
            if consecutiveNoiseFrames >= config.consecutiveNoiseFramesThreshold {
                isLikelyVoice = false
                noiseDetected += 1
            } else {
                isLikelyVoice = true
            }
        } else {
            consecutiveNoiseFrames = 0
            isLikelyVoice = true
        }

        logPeriodically(voiceRatio: voiceRatio, flatness: flatness, isVoice: isLikelyVoice)

        return AnalysisResult(
            voiceEnergyRatio: voiceRatio,
            spectralFlatness: flatness,
            isLikelyVoice: isLikelyVoice
        )
    }

    /// 統計をリセット
    func resetStats() {
        totalAnalyzed = 0
        noiseDetected = 0
        consecutiveNoiseFrames = 0
    }

    /// ノイズ検出率
    var noiseDetectionRatio: Float {
        guard totalAnalyzed > 0 else { return 0 }
        return Float(noiseDetected) / Float(totalAnalyzed)
    }

    // MARK: - FFT

    private func computeMagnitudes(_ samples: UnsafePointer<Float>, frameCount: Int) -> [Float] {
        let n = fftSize
        let halfN = n / 2
        guard let setup = fftSetup else { return [] }

        // プロパティバッファをゼロクリアして再利用
        for i in 0..<n { windowedSamples[i] = 0 }
        for i in 0..<halfN { realPart[i] = 0; imagPart[i] = 0; magnitudesBuffer[i] = 0 }

        vDSP_vmul(samples, 1, hannWindow, 1, &windowedSamples, 1, vDSP_Length(n))

        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                windowedSamples.withUnsafeBufferPointer { sampleBuf in
                    sampleBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        realPart.withUnsafeBufferPointer { realBuf in
            imagPart.withUnsafeBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: UnsafeMutablePointer(mutating: realBuf.baseAddress!),
                    imagp: UnsafeMutablePointer(mutating: imagBuf.baseAddress!)
                )
                vDSP_zvmags(&splitComplex, 1, &magnitudesBuffer, 1, vDSP_Length(halfN))
            }
        }

        return magnitudesBuffer
    }

    /// 人声帯域 (voiceLowHz–voiceHighHz) のエネルギー比率を計算。
    private func computeVoiceEnergyRatio(magnitudes: [Float], sampleRate: Double) -> Float {
        let binCount = magnitudes.count
        let binWidth = Float(sampleRate) / Float(fftSize)

        let lowBin = max(0, Int(config.voiceLowHz / binWidth))
        let highBin = min(binCount - 1, Int(config.voiceHighHz / binWidth))

        guard lowBin < highBin else { return 1.0 }

        var totalEnergy: Float = 0
        vDSP_sve(magnitudes, 1, &totalEnergy, vDSP_Length(binCount))

        guard totalEnergy > 0 else { return 0 }

        var voiceEnergy: Float = 0
        magnitudes.withUnsafeBufferPointer { buf in
            vDSP_sve(buf.baseAddress! + lowBin, 1, &voiceEnergy, vDSP_Length(highBin - lowBin + 1))
        }

        return voiceEnergy / totalEnergy
    }

    /// スペクトル平坦度 = 幾何平均 / 算術平均。
    /// 1.0 に近い = 白色ノイズ的（全帯域均等）、0.0 に近い = 特定帯域に集中（音声的）。
    private func computeSpectralFlatness(magnitudes: [Float]) -> Float {
        let n = magnitudes.count
        guard n > 0 else { return 0 }

        let epsilon: Float = 1e-10

        var arithmeticMean: Float = 0
        vDSP_meanv(magnitudes, 1, &arithmeticMean, vDSP_Length(n))
        guard arithmeticMean > epsilon else { return 0 }

        var logMagnitudes = magnitudes.map { logf(max($0, epsilon)) }
        var logMean: Float = 0
        vDSP_meanv(&logMagnitudes, 1, &logMean, vDSP_Length(n))
        let geometricMean = expf(logMean)

        return min(1.0, geometricMean / arithmeticMean)
    }

    private func logPeriodically(voiceRatio: Float, flatness: Float, isVoice: Bool) {
        if totalAnalyzed == 1 || totalAnalyzed % 500 == 0 {
            DebugLog.log("[spectral] analyzed=\(totalAnalyzed) noiseDetected=\(noiseDetected) ratio=\(String(format: "%.1f%%", noiseDetectionRatio * 100)) lastVoiceRatio=\(String(format: "%.2f", voiceRatio)) lastFlatness=\(String(format: "%.2f", flatness))")
        }
    }
}
