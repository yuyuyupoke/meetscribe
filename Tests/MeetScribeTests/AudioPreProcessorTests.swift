import XCTest
import AVFoundation
@testable import MeetScribeCore

final class AudioPreProcessorTests: XCTestCase {

    // MARK: - Config

    /// マイク側の spectral 解析は意図的に無効 (コミット 504aa34:
    /// "disabled in pipeline — client-side filtering caused more harm than good")。
    func test_microphoneConfig_disablesSpectral() {
        let config = AudioPreProcessor.Config.microphone
        XCTAssertFalse(config.enableSpectralAnalysis)
    }

    func test_systemAudioConfig_enablesSpectral() {
        let config = AudioPreProcessor.Config.systemAudio
        XCTAssertTrue(config.enableSpectralAnalysis)
    }

    // MARK: - Silent input → filtered by NoiseGate (Stage 1)

    func test_process_silentInput_filteredByGate() {
        let processor = AudioPreProcessor(config: .microphone, label: "test")
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)

        let result = processor.process(silent, sampleRate: 24000)
        XCTAssertNil(result, "Silent input should be filtered by noise gate")
    }

    // MARK: - Loud voice-band signal → passes through

    func test_process_loudVoiceBandSine_passes() {
        let config = AudioPreProcessor.Config(
            noiseGateConfig: NoiseGate.Config(
                openThresholdDB: -60.0,
                closeThresholdDB: -65.0,
                attackMs: 0.1,
                releaseMs: 0.1
            ),
            spectralConfig: .default,
            enableSpectralAnalysis: true
        )
        let processor = AudioPreProcessor(config: config, label: "test")
        let voiceSine = TestHelpers.makeSineBuffer(
            frequency: 300, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )

        // Process multiple frames to open gate
        var lastResult: AVAudioPCMBuffer?
        for _ in 0..<5 {
            lastResult = processor.process(voiceSine, sampleRate: 24000)
        }
        XCTAssertNotNil(lastResult, "Voice-band signal should pass through both stages")
    }

    // MARK: - Spectral disabled → only gate matters

    func test_process_spectralDisabled_onlyGateFilters() {
        let config = AudioPreProcessor.Config(
            noiseGateConfig: NoiseGate.Config(
                openThresholdDB: -60.0,
                closeThresholdDB: -65.0,
                attackMs: 0.1,
                releaseMs: 0.1
            ),
            spectralConfig: .default,
            enableSpectralAnalysis: false
        )
        let processor = AudioPreProcessor(config: config, label: "test")

        // High-frequency signal that would fail spectral analysis
        let highFreq = TestHelpers.makeSineBuffer(
            frequency: 11000, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )

        var lastResult: AVAudioPCMBuffer?
        for _ in 0..<5 {
            lastResult = processor.process(highFreq, sampleRate: 24000)
        }
        // With spectral disabled, high-freq passes (only gate matters)
        XCTAssertNotNil(lastResult, "Without spectral analysis, signal should pass gate")
    }

    // MARK: - passRate tracking

    func test_passRate_initiallyOne() {
        let processor = AudioPreProcessor(config: .microphone, label: "test")
        XCTAssertEqual(processor.passRate, 1.0, accuracy: 0.001)
    }

    func test_passRate_afterAllFiltered_isZero() {
        let processor = AudioPreProcessor(config: .microphone, label: "test")
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)

        for _ in 0..<10 {
            _ = processor.process(silent, sampleRate: 24000)
        }
        XCTAssertEqual(processor.passRate, 0.0, accuracy: 0.001)
    }

    // MARK: - resetStats

    func test_resetStats_clearsAll() {
        let processor = AudioPreProcessor(config: .microphone, label: "test")
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        for _ in 0..<5 {
            _ = processor.process(silent, sampleRate: 24000)
        }

        processor.resetStats()
        XCTAssertEqual(processor.passRate, 1.0, accuracy: 0.001,
                       "After reset, passRate should be 1.0 (0 of 0 → default)")
    }

    // MARK: - Pipeline ordering: gate first, then spectral

    func test_pipeline_gateFiltersPreventsSpectralExecution() {
        // If gate filters (silent input), spectral should not even run.
        // We verify by checking that passRate = 0 and the processor works.
        let processor = AudioPreProcessor(config: .microphone, label: "test")
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)

        for _ in 0..<5 {
            let result = processor.process(silent, sampleRate: 24000)
            XCTAssertNil(result)
        }
        XCTAssertEqual(processor.passRate, 0.0, accuracy: 0.001)
    }

    // MARK: - processAndForward (AudioSession が実際に呼ぶ配線ポイント)
    //
    // 施策1: NoiseGate/AudioPreProcessor を本番配線するにあたって、AudioSession の
    // マイク/システム音コールバックはこの processAndForward だけを呼ぶ。ここでの
    // 「nil→onPass呼ばれない」保証が、そのまま「無音フレームは送信されない
    // (=xAI課金・OpenAI commit頻度が減る)」という配線バグ修正の効果そのものになる。

    func test_processAndForward_silentInput_onPassNotCalled() {
        let processor = AudioPreProcessor(config: .microphone, label: "test")
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)

        var onPassCallCount = 0
        for _ in 0..<5 {
            processor.processAndForward(silent, sampleRate: 24000) { _ in
                onPassCallCount += 1
            }
        }
        XCTAssertEqual(onPassCallCount, 0, "無音フレームは送信パイプラインに転送されてはいけない")
    }

    // MARK: - Hold中はSpectralAnalyzerをバイパスする (施策A×systemAudio連携)
    //
    // NoiseGateのhold (発話終了後、xAI endpointing用に無音送信を継続する仕組み) 中は
    // SpectralAnalyzerの判定を素通りさせる。バイパスしないと、hold中に流れる無音バッファは
    // voiceEnergyRatio≈0でノイズ判定され (consecutiveNoiseFramesThreshold超で) 除去されて
    // しまい、hold自体が無効化されてspeech_final発火という主目的が果たせなくなる。

    func test_process_duringHold_bypassesSpectralAnalysisAndPasses() {
        let config = AudioPreProcessor.Config(
            noiseGateConfig: NoiseGate.Config(
                openThresholdDB: -60.0,
                closeThresholdDB: -65.0,
                attackMs: 0.1,
                releaseMs: 0.1,
                holdMs: 100.0
            ),
            spectralConfig: SpectralAnalyzer.Config(
                voiceLowHz: 80.0,
                voiceHighHz: 4000.0,
                voiceEnergyRatioThreshold: 0.3,
                spectralFlatnessThreshold: 0.6,
                consecutiveNoiseFramesThreshold: 1 // 1フレームでノイズ確定させ、バイパスがないと即除去される設定
            ),
            enableSpectralAnalysis: true
        )
        let processor = AudioPreProcessor(config: config, label: "test")
        let voiceSine = TestHelpers.makeSineBuffer(
            frequency: 300, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )
        for _ in 0..<5 { _ = processor.process(voiceSine, sampleRate: 24000) }

        // 無音 (voiceEnergyRatio≈0 でスペクトル判定なら即ノイズ扱いされるはずの入力) を
        // hold期間中に流す → バイパスにより通過するはず
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        let result = processor.process(silent, sampleRate: 24000)
        XCTAssertNotNil(result, "hold中はSpectralAnalyzerをバイパスして通過させるべき")
    }

    func test_process_afterHoldExpires_spectralFiltersAgain() {
        let config = AudioPreProcessor.Config(
            noiseGateConfig: NoiseGate.Config(
                openThresholdDB: -60.0,
                closeThresholdDB: -65.0,
                attackMs: 0.1,
                releaseMs: 0.1,
                holdMs: 50.0
            ),
            spectralConfig: SpectralAnalyzer.Config(
                voiceLowHz: 80.0,
                voiceHighHz: 4000.0,
                voiceEnergyRatioThreshold: 0.3,
                spectralFlatnessThreshold: 0.6,
                consecutiveNoiseFramesThreshold: 1
            ),
            enableSpectralAnalysis: true
        )
        let processor = AudioPreProcessor(config: config, label: "test")
        let voiceSine = TestHelpers.makeSineBuffer(
            frequency: 300, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )
        for _ in 0..<5 { _ = processor.process(voiceSine, sampleRate: 24000) }

        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        // hold(50ms)を十分超えるフレーム数を流し、NoiseGate自体がcloseするまで進める
        for _ in 0..<10 { _ = processor.process(silent, sampleRate: 24000) }
        // NoiseGateがcloseした後の無音はStage 1で既に除去される (Stage 2に到達しない)
        let result = processor.process(silent, sampleRate: 24000)
        XCTAssertNil(result, "hold期間超過後はNoiseGate自体が閉じて除去されるべき")
    }

    func test_processAndForward_loudVoiceBandSine_onPassCalledWithGatedBuffer() {
        let config = AudioPreProcessor.Config(
            noiseGateConfig: NoiseGate.Config(
                openThresholdDB: -60.0,
                closeThresholdDB: -65.0,
                attackMs: 0.1,
                releaseMs: 0.1
            ),
            spectralConfig: .default,
            enableSpectralAnalysis: true
        )
        let processor = AudioPreProcessor(config: config, label: "test")
        let voiceSine = TestHelpers.makeSineBuffer(
            frequency: 300, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )

        var forwardedBuffers: [AVAudioPCMBuffer] = []
        for _ in 0..<5 {
            processor.processAndForward(voiceSine, sampleRate: 24000) { gated in
                forwardedBuffers.append(gated)
            }
        }
        XCTAssertFalse(forwardedBuffers.isEmpty, "ゲートを通過した発話フレームは転送されるべき")
    }
}
