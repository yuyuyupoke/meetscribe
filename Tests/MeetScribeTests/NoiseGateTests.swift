import XCTest
import AVFoundation
@testable import MeetScribeCore

final class NoiseGateTests: XCTestCase {

    // MARK: - Default Config

    // 期待値は NoiseGate.swift の設計値に一致させる:
    // マイクは Voice Processing (AGC+NS) 後の低レベル信号に合わせ緩め (-55/-60)、
    // システム音はさらに緩め (-60/-65)。いずれも 5dB のヒステリシス幅。
    func test_microphoneConfig_hasCorrectDefaults() {
        let config = NoiseGate.Config.microphone
        XCTAssertEqual(config.openThresholdDB, -55.0)
        XCTAssertEqual(config.closeThresholdDB, -60.0)
        XCTAssertGreaterThan(config.openThresholdDB, config.closeThresholdDB,
                             "Open threshold must be higher than close for hysteresis")
        XCTAssertEqual(config.holdMs, 1000.0,
                       "xAI endpointing=500msより長く無音を観測させるためhold必須")
    }

    func test_systemAudioConfig_hasCorrectDefaults() {
        let config = NoiseGate.Config.systemAudio
        XCTAssertEqual(config.openThresholdDB, -60.0)
        XCTAssertEqual(config.closeThresholdDB, -65.0)
        XCTAssertGreaterThan(config.openThresholdDB, config.closeThresholdDB,
                             "Open threshold must be higher than close for hysteresis")
        XCTAssertEqual(config.holdMs, 1000.0,
                       "xAI endpointing=500msより長く無音を観測させるためhold必須")
    }

    func test_defaultHoldMs_isZero() {
        // holdMs を明示しないConfigは0 (旧動作=即close) を維持する。
        // 既存テストの多くはholdMsを明示しないConfigリテラルを使っているため、
        // ここが0でないと既存の「即座に閉じる」前提のテストが壊れる
        let config = NoiseGate.Config(
            openThresholdDB: -30.0,
            closeThresholdDB: -40.0,
            attackMs: 0.1,
            releaseMs: 0.1
        )
        XCTAssertEqual(config.holdMs, 0.0)
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

    // MARK: - Hold (施策A: xAI endpointing対応)

    private func makeHoldConfig(holdMs: Float) -> NoiseGate.Config {
        NoiseGate.Config(
            openThresholdDB: -30.0,
            closeThresholdDB: -40.0,
            attackMs: 0.1,
            releaseMs: 0.1,
            holdMs: holdMs
        )
    }

    // frameCount=1024, sampleRate=24000 → 1フレーム ≈ 42.7ms

    func test_hold_keepsGateOpenAndPassingBuffer_whileWithinHoldPeriod() {
        let gate = NoiseGate(config: makeHoldConfig(holdMs: 100.0))
        let loud = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.8, sampleRate: 24000, frameCount: 1024
        )
        for _ in 0..<10 { _ = gate.process(loud, sampleRate: 24000) }
        XCTAssertEqual(gate.state, .open)

        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        // 2フレーム分 (≈85ms) はholdMs(100ms)未満 → 閉じ条件成立後もopenを維持し送信継続
        let result1 = gate.process(silent, sampleRate: 24000)
        XCTAssertEqual(gate.state, .open, "hold期間中はcloseに遷移しない")
        XCTAssertNotNil(result1, "hold期間中は送信を継続する")

        let result2 = gate.process(silent, sampleRate: 24000)
        XCTAssertEqual(gate.state, .open, "hold期間中はcloseに遷移しない")
        XCTAssertNotNil(result2, "hold期間中は送信を継続する")
    }

    func test_hold_closesAfterHoldPeriodExceeded() {
        let gate = NoiseGate(config: makeHoldConfig(holdMs: 100.0))
        let loud = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.8, sampleRate: 24000, frameCount: 1024
        )
        for _ in 0..<10 { _ = gate.process(loud, sampleRate: 24000) }
        XCTAssertEqual(gate.state, .open)

        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        // holdMs(100ms)を十分超えるフレーム数を流す → release(0.1ms)も即座に完了しclosedへ
        for _ in 0..<10 { _ = gate.process(silent, sampleRate: 24000) }
        XCTAssertEqual(gate.state, .closed, "hold期間超過後は無音でゲートが閉じる")
    }

    func test_hold_cancelsAndResetsIfSignalResumesBeforeHoldExpires() {
        let gate = NoiseGate(config: makeHoldConfig(holdMs: 100.0))
        let loud = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.8, sampleRate: 24000, frameCount: 1024
        )
        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)

        for _ in 0..<10 { _ = gate.process(loud, sampleRate: 24000) }
        XCTAssertEqual(gate.state, .open)

        // hold中(1フレーム≈43ms < 100ms)に音声が戻る → holdカウントがリセットされopen維持
        _ = gate.process(silent, sampleRate: 24000)
        _ = gate.process(loud, sampleRate: 24000)
        XCTAssertEqual(gate.state, .open)

        // リセットされているはずなので、直後にもう1フレームだけ無音を流しても
        // (以前の残り + 今回では超えない量なら) まだclosingへ遷移しない
        let result = gate.process(silent, sampleRate: 24000)
        XCTAssertEqual(gate.state, .open, "音声再開でholdカウントがリセットされている")
        XCTAssertNotNil(result)
    }

    func test_isInHold_falseWhileFullyOpenWithSignal() {
        let gate = NoiseGate(config: makeHoldConfig(holdMs: 100.0))
        let loud = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.8, sampleRate: 24000, frameCount: 1024
        )
        for _ in 0..<10 { _ = gate.process(loud, sampleRate: 24000) }
        XCTAssertEqual(gate.state, .open)
        XCTAssertFalse(gate.isInHold, "音声継続中はholdではない")
    }

    func test_isInHold_trueWhileHoldPeriodActive() {
        let gate = NoiseGate(config: makeHoldConfig(holdMs: 100.0))
        let loud = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.8, sampleRate: 24000, frameCount: 1024
        )
        for _ in 0..<10 { _ = gate.process(loud, sampleRate: 24000) }

        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        _ = gate.process(silent, sampleRate: 24000)
        XCTAssertEqual(gate.state, .open)
        XCTAssertTrue(gate.isInHold, "閉じ条件成立後hold期間中はisInHold=trueであるべき")
    }

    func test_isInHold_falseAfterClosing() {
        let gate = NoiseGate(config: makeHoldConfig(holdMs: 100.0))
        let loud = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.8, sampleRate: 24000, frameCount: 1024
        )
        for _ in 0..<10 { _ = gate.process(loud, sampleRate: 24000) }

        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        for _ in 0..<10 { _ = gate.process(silent, sampleRate: 24000) }
        XCTAssertEqual(gate.state, .closed)
        XCTAssertFalse(gate.isInHold, "closed後はholdではない")
    }

    func test_defaultHoldMsZero_behavesLikeOriginalImmediateClose() {
        // holdMs=0 (デフォルト) では旧動作 (閉じ条件成立で即closing) を維持する
        let gate = NoiseGate(config: makeHoldConfig(holdMs: 0.0))
        let loud = TestHelpers.makeSineBuffer(
            frequency: 440, amplitude: 0.8, sampleRate: 24000, frameCount: 1024
        )
        for _ in 0..<10 { _ = gate.process(loud, sampleRate: 24000) }
        XCTAssertEqual(gate.state, .open)

        let silent = TestHelpers.makeSilentBuffer(sampleRate: 24000, frameCount: 1024)
        for _ in 0..<3 { _ = gate.process(silent, sampleRate: 24000) }
        XCTAssertEqual(gate.state, .closed, "holdMs=0なら即座に閉じる (releaseMsも極小)")
    }
}
