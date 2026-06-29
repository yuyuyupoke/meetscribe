import XCTest
import AVFoundation
@testable import MeetScribeCore

final class NoiseGateTests: XCTestCase {

    // MARK: - Default Config

    func test_microphoneConfig_hasCorrectDefaults() {
        let config = NoiseGate.Config.microphone
        XCTAssertEqual(config.openThresholdDB, -40.0)
        XCTAssertEqual(config.closeThresholdDB, -45.0)
        XCTAssertGreaterThan(config.openThresholdDB, config.closeThresholdDB,
                             "Open threshold must be higher than close for hysteresis")
    }

    func test_systemAudioConfig_hasCorrectDefaults() {
        let config = NoiseGate.Config.systemAudio
        XCTAssertEqual(config.openThresholdDB, -50.0)
        XCTAssertEqual(config.closeThresholdDB, -55.0)
    }

    // MARK: - Initial state

    func test_initialState_isClosed() {
        let gate = NoiseGate(config: .microphone)
        XCTAssertEqual(gate.state, .closed)
    }

    func test_initialGateRatio_isZero() {
        let gate = NoiseGate(config: .microphone)
        XCTAssertEqual(gate.gateRatio, 0.0)
    }

    // MARK: - Silent input → gate stays closed → returns nil

    func test_process_silentInput_returnsNil() {
        let gate = NoiseGate(config: .microphone)
        let buffer = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        let result = gate.process(buffer, sampleRate: 24000)
        XCTAssertNil(result, "Silent input should be gated (nil)")
    }

    func test_process_silentInput_stateRemainsClosed() {
        let gate = NoiseGate(config: .microphone)
        let buffer = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        _ = gate.process(buffer, sampleRate: 24000)
        XCTAssertEqual(gate.state, .closed)
    }

    // MARK: - Loud input → gate opens → returns buffer

    func test_process_loudInput_returnsBuffer() {
        // Use config with very low thresholds so our signal easily passes
        let config = NoiseGate.Config(
            openThresholdDB: -60.0,
            closeThresholdDB: -65.0,
            attackMs: 0.1,
            releaseMs: 0.1
        )
        let gate = NoiseGate(config: config)
        let buffer = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )

        // Process multiple times to allow state transition through opening → open
        var lastResult: AVAudioPCMBuffer?
        for _ in 0..<5 {
            lastResult = gate.process(buffer, sampleRate: 24000)
        }
        XCTAssertNotNil(lastResult, "Loud signal should pass through gate")
    }

    // MARK: - Hysteresis

    func test_hysteresis_gateOpensAndCloses() {
        let config = NoiseGate.Config(
            openThresholdDB: -30.0,
            closeThresholdDB: -40.0,
            attackMs: 0.1,
            releaseMs: 0.1
        )
        let gate = NoiseGate(config: config)

        // 1. Loud signal → should open eventually
        let loud = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.8, sampleRate: 24000, frameCount: 1024
        )
        for _ in 0..<10 {
            _ = gate.process(loud, sampleRate: 24000)
        }
        XCTAssertEqual(gate.state, .open, "Loud signal should eventually open gate")

        // 2. Silent signal → should close eventually
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        for _ in 0..<10 {
            _ = gate.process(silent, sampleRate: 24000)
        }
        XCTAssertEqual(gate.state, .closed, "Silence should eventually close gate")
    }

    // MARK: - Gate ratio tracking

    func test_gateRatio_afterAllGated_isOne() {
        let gate = NoiseGate(config: .microphone)
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)

        for _ in 0..<10 {
            _ = gate.process(silent, sampleRate: 24000)
        }
        XCTAssertEqual(gate.gateRatio, 1.0, accuracy: 0.001)
    }

    func test_gateRatio_afterMixed_isBetween() {
        let config = NoiseGate.Config(
            openThresholdDB: -60.0,
            closeThresholdDB: -65.0,
            attackMs: 0.1,
            releaseMs: 0.1
        )
        let gate = NoiseGate(config: config)
        let loud = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.5, sampleRate: 24000, frameCount: 1024
        )
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)

        // Alternate loud and silent
        for _ in 0..<5 {
            _ = gate.process(loud, sampleRate: 24000)
            _ = gate.process(silent, sampleRate: 24000)
        }
        let ratio = gate.gateRatio
        XCTAssertGreaterThan(ratio, 0.0)
        XCTAssertLessThan(ratio, 1.0)
    }

    // MARK: - resetStats

    func test_resetStats_clearsCounters() {
        let gate = NoiseGate(config: .microphone)
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        for _ in 0..<5 {
            _ = gate.process(silent, sampleRate: 24000)
        }
        XCTAssertGreaterThan(gate.gateRatio, 0.0)

        gate.resetStats()
        XCTAssertEqual(gate.gateRatio, 0.0)
    }

    // MARK: - Very quiet noise → gated

    func test_process_veryQuietNoise_gated() {
        let gate = NoiseGate(config: .microphone)
        // Amplitude 0.001 → RMS dB ≈ -63 dBFS, below -45 close threshold
        let quiet = TestHelpers.makeNoiseBuffer(
            amplitude: 0.001, sampleRate: 24000, frameCount: 1024
        )
        let result = gate.process(quiet, sampleRate: 24000)
        XCTAssertNil(result, "Very quiet noise should be gated")
    }
}
