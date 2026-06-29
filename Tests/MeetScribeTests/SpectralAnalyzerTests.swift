import XCTest
import AVFoundation
@testable import MeetScribeCore

final class SpectralAnalyzerTests: XCTestCase {

    // MARK: - Default Config

    func test_defaultConfig_hasReasonableValues() {
        let config = SpectralAnalyzer.Config.default
        XCTAssertEqual(config.voiceLowHz, 80.0)
        XCTAssertEqual(config.voiceHighHz, 4000.0)
        XCTAssertGreaterThan(config.voiceEnergyRatioThreshold, 0.0)
        XCTAssertLessThan(config.voiceEnergyRatioThreshold, 1.0)
        XCTAssertGreaterThan(config.spectralFlatnessThreshold, 0.0)
        XCTAssertLessThan(config.spectralFlatnessThreshold, 1.0)
    }

    // MARK: - Voice-band sine wave → classified as voice-like

    func test_analyze_voiceBandSine_isLikelyVoice() {
        let analyzer = SpectralAnalyzer(config: .default)
        // 300 Hz sine wave — firmly in voice band (80–4000 Hz)
        let buffer = TestHelpers.makeSineBuffer(
            frequency: 300, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )

        let result = analyzer.analyze(buffer, sampleRate: 24000)
        // A pure tone in voice band: high voice ratio, low flatness
        XCTAssertGreaterThan(result.voiceEnergyRatio, 0.5,
                             "Voice-band sine should have high voice energy ratio")
        XCTAssertLessThan(result.spectralFlatness, 0.5,
                          "Pure tone should have low spectral flatness")
        XCTAssertTrue(result.isLikelyVoice)
    }

    // MARK: - High-frequency sine → less voice-like

    func test_analyze_highFrequencySine_lowVoiceRatio() {
        let analyzer = SpectralAnalyzer(config: .default)
        // 10000 Hz — well above voice band
        let buffer = TestHelpers.makeSineBuffer(
            frequency: 10000, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )

        let result = analyzer.analyze(buffer, sampleRate: 24000)
        XCTAssertLessThan(result.voiceEnergyRatio, 0.5,
                          "High-frequency tone should have low voice energy ratio")
    }

    // MARK: - White noise → high spectral flatness

    func test_analyze_whiteNoise_highSpectralFlatness() {
        let config = SpectralAnalyzer.Config(
            voiceLowHz: 80.0,
            voiceHighHz: 4000.0,
            voiceEnergyRatioThreshold: 0.3,
            spectralFlatnessThreshold: 0.4,
            consecutiveNoiseFramesThreshold: 1
        )
        let analyzer = SpectralAnalyzer(config: config)
        let buffer = TestHelpers.makeNoiseBuffer(
            amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )

        let result = analyzer.analyze(buffer, sampleRate: 24000)
        // White noise has relatively flat spectrum
        XCTAssertGreaterThan(result.spectralFlatness, 0.2,
                             "White noise should have higher spectral flatness than pure tones")
    }

    // MARK: - Silent buffer → defaults to voice (safe fallback)

    func test_analyze_silentBuffer_defaultsToVoice() {
        let analyzer = SpectralAnalyzer(config: .default)
        let buffer = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 512)

        // Buffer too short (< 1024 fftSize) → fallback
        let result = analyzer.analyze(buffer, sampleRate: 24000)
        XCTAssertTrue(result.isLikelyVoice,
                      "Buffer shorter than FFT size should default to voice (safe)")
    }

    func test_analyze_shortBuffer_defaultsToVoice() {
        let analyzer = SpectralAnalyzer(config: .default)
        // 512 frames < 1024 FFT size
        let buffer = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.5, sampleRate: 24000, frameCount: 512
        )

        let result = analyzer.analyze(buffer, sampleRate: 24000)
        XCTAssertTrue(result.isLikelyVoice)
        XCTAssertEqual(result.voiceEnergyRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.spectralFlatness, 0.0, accuracy: 0.001)
    }

    // MARK: - Consecutive noise frames threshold

    func test_consecutiveNoiseThreshold_delaysNoiseClassification() {
        let config = SpectralAnalyzer.Config(
            voiceLowHz: 80.0,
            voiceHighHz: 4000.0,
            voiceEnergyRatioThreshold: 0.3,
            spectralFlatnessThreshold: 0.3,
            consecutiveNoiseFramesThreshold: 3
        )
        let analyzer = SpectralAnalyzer(config: config)

        // Use high freq (above voice band) to trigger noise detection
        let highFreq = TestHelpers.makeSineBuffer(
            frequency: 11000, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )

        // First 2 frames: still classified as voice (below threshold)
        let r1 = analyzer.analyze(highFreq, sampleRate: 24000)
        let r2 = analyzer.analyze(highFreq, sampleRate: 24000)
        XCTAssertTrue(r1.isLikelyVoice, "Frame 1 should still be voice (consecutive threshold)")
        XCTAssertTrue(r2.isLikelyVoice, "Frame 2 should still be voice (consecutive threshold)")

        // Frame 3: hits consecutive threshold → noise
        let r3 = analyzer.analyze(highFreq, sampleRate: 24000)
        XCTAssertFalse(r3.isLikelyVoice, "Frame 3 should be classified as noise")
    }

    func test_consecutiveNoiseFrames_resetOnVoice() {
        let config = SpectralAnalyzer.Config(
            voiceLowHz: 80.0,
            voiceHighHz: 4000.0,
            voiceEnergyRatioThreshold: 0.3,
            spectralFlatnessThreshold: 0.3,
            consecutiveNoiseFramesThreshold: 3
        )
        let analyzer = SpectralAnalyzer(config: config)

        let highFreq = TestHelpers.makeSineBuffer(
            frequency: 11000, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )
        let voiceBand = TestHelpers.makeSineBuffer(
            frequency: 300, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )

        // 2 noise frames
        _ = analyzer.analyze(highFreq, sampleRate: 24000)
        _ = analyzer.analyze(highFreq, sampleRate: 24000)

        // 1 voice frame → reset counter
        let voiceResult = analyzer.analyze(voiceBand, sampleRate: 24000)
        XCTAssertTrue(voiceResult.isLikelyVoice)

        // Next 2 noise frames should NOT trigger noise (counter was reset)
        let r1 = analyzer.analyze(highFreq, sampleRate: 24000)
        let r2 = analyzer.analyze(highFreq, sampleRate: 24000)
        XCTAssertTrue(r1.isLikelyVoice)
        XCTAssertTrue(r2.isLikelyVoice)
    }

    // MARK: - Stats

    func test_noiseDetectionRatio_initiallyZero() {
        let analyzer = SpectralAnalyzer(config: .default)
        XCTAssertEqual(analyzer.noiseDetectionRatio, 0.0)
    }

    func test_resetStats_clearsCounters() {
        let analyzer = SpectralAnalyzer(config: .default)
        let buffer = TestHelpers.makeSineBuffer(
            frequency: 300, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )
        _ = analyzer.analyze(buffer, sampleRate: 24000)

        analyzer.resetStats()
        XCTAssertEqual(analyzer.noiseDetectionRatio, 0.0)
    }

    // MARK: - AnalysisResult values are in [0, 1]

    func test_analysisResult_valuesInRange() {
        let analyzer = SpectralAnalyzer(config: .default)
        let buffers = [
            TestHelpers.makeSineBuffer(frequency: 300, amplitude: 0.5, sampleRate: 24000, frameCount: 1024),
            TestHelpers.makeSineBuffer(frequency: 5000, amplitude: 0.5, sampleRate: 24000, frameCount: 1024),
            TestHelpers.makeNoiseBuffer(amplitude: 0.3, sampleRate: 24000, frameCount: 1024),
        ]

        for buffer in buffers {
            let result = analyzer.analyze(buffer, sampleRate: 24000)
            XCTAssertGreaterThanOrEqual(result.voiceEnergyRatio, 0.0)
            XCTAssertLessThanOrEqual(result.voiceEnergyRatio, 1.0)
            XCTAssertGreaterThanOrEqual(result.spectralFlatness, 0.0)
            XCTAssertLessThanOrEqual(result.spectralFlatness, 1.0)
        }
    }
}
