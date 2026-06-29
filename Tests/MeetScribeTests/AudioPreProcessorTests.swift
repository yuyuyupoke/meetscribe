import XCTest
import AVFoundation
@testable import MeetScribeCore

final class AudioPreProcessorTests: XCTestCase {

    // MARK: - Config

    func test_microphoneConfig_enablesSpectral() {
        let config = AudioPreProcessor.Config.microphone
        XCTAssertTrue(config.enableSpectralAnalysis)
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
}
