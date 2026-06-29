import XCTest
@testable import MeetScribeCore

final class AudioLevelMeterTests: XCTestCase {

    // MARK: - normalizedLevel from AVAudioPCMBuffer

    func test_normalizedLevel_silentBuffer_returnsZero() {
        let buffer = TestHelpers.makeSilentBuffer()
        let level = AudioLevelMeter.normalizedLevel(from: buffer)
        XCTAssertEqual(level, 0.0, accuracy: 0.001, "Silent buffer should return 0.0")
    }

    func test_normalizedLevel_fullScaleSine_returnsNearOne() {
        // Full-scale sine wave: RMS = amplitude / sqrt(2) ≈ 0.707
        // dBFS = 20*log10(0.707) ≈ -3.01 dB → normalized ≈ (60-3.01)/60 ≈ 0.95
        let buffer = TestHelpers.makeSineBuffer(amplitude: 1.0, frameCount: 4096)
        let level = AudioLevelMeter.normalizedLevel(from: buffer)
        XCTAssertGreaterThan(level, 0.9, "Full-scale sine should produce level > 0.9")
        XCTAssertLessThanOrEqual(level, 1.0, "Level should not exceed 1.0")
    }

    func test_normalizedLevel_halfAmplitudeSine_returnsIntermediateValue() {
        let buffer = TestHelpers.makeSineBuffer(amplitude: 0.5, frameCount: 4096)
        let level = AudioLevelMeter.normalizedLevel(from: buffer)
        // RMS ≈ 0.354, dBFS ≈ -9.03, normalized ≈ 0.85
        XCTAssertGreaterThan(level, 0.7)
        XCTAssertLessThan(level, 0.95)
    }

    func test_normalizedLevel_veryQuietSignal_returnsLowValue() {
        // Very quiet: amplitude 0.001 → RMS ≈ 0.000707 → dBFS ≈ -63 → normalized ≈ 0 (clamped)
        let buffer = TestHelpers.makeSineBuffer(amplitude: 0.001, frameCount: 4096)
        let level = AudioLevelMeter.normalizedLevel(from: buffer)
        XCTAssertLessThan(level, 0.1, "Very quiet signal should produce very low level")
    }

    func test_normalizedLevel_emptyBuffer_returnsZero() {
        let buffer = TestHelpers.makeEmptyBuffer()
        let level = AudioLevelMeter.normalizedLevel(from: buffer)
        XCTAssertEqual(level, 0.0, accuracy: 0.001)
    }

    func test_normalizedLevel_constantDCOffset_returnsCorrectLevel() {
        // Constant 0.5 → RMS = 0.5 → dBFS = -6.02 → normalized ≈ 0.90
        let buffer = TestHelpers.makeConstantBuffer(value: 0.5, frameCount: 4096)
        let level = AudioLevelMeter.normalizedLevel(from: buffer)
        XCTAssertGreaterThan(level, 0.85)
        XCTAssertLessThan(level, 0.95)
    }

    func test_normalizedLevel_noiseBuffer_returnsReasonableLevel() {
        let buffer = TestHelpers.makeNoiseBuffer(amplitude: 0.3, frameCount: 4096)
        let level = AudioLevelMeter.normalizedLevel(from: buffer)
        XCTAssertGreaterThan(level, 0.3)
        XCTAssertLessThan(level, 0.9)
    }

    // MARK: - Monotonicity: louder signal → higher level

    func test_normalizedLevel_louderSignalProducesHigherLevel() {
        let quiet = TestHelpers.makeSineBuffer(amplitude: 0.1, frameCount: 4096)
        let medium = TestHelpers.makeSineBuffer(amplitude: 0.3, frameCount: 4096)
        let loud = TestHelpers.makeSineBuffer(amplitude: 0.8, frameCount: 4096)

        let quietLevel = AudioLevelMeter.normalizedLevel(from: quiet)
        let mediumLevel = AudioLevelMeter.normalizedLevel(from: medium)
        let loudLevel = AudioLevelMeter.normalizedLevel(from: loud)

        XCTAssertLessThan(quietLevel, mediumLevel)
        XCTAssertLessThan(mediumLevel, loudLevel)
    }

    // MARK: - Range: output is always [0, 1]

    func test_normalizedLevel_outputAlwaysClamped() {
        let amplitudes: [Float] = [0.0, 0.001, 0.01, 0.1, 0.5, 1.0]
        for amp in amplitudes {
            let buffer = TestHelpers.makeSineBuffer(amplitude: amp, frameCount: 4096)
            let level = AudioLevelMeter.normalizedLevel(from: buffer)
            XCTAssertGreaterThanOrEqual(level, 0.0, "Level must be >= 0.0 for amplitude \(amp)")
            XCTAssertLessThanOrEqual(level, 1.0, "Level must be <= 1.0 for amplitude \(amp)")
        }
    }
}
