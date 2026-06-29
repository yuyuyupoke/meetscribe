import XCTest
@testable import MeetScribeCore

@MainActor
final class SilenceDetectorTests: XCTestCase {

    // MARK: - Initialization

    func test_init_defaultValues() {
        let called = expectation(description: "onTimeout")
        called.isInverted = true // Should NOT be called during init

        let detector = SilenceDetector(
            timeoutMinutes: 1.0,
            pollIntervalSeconds: 1.0,
            threshold: 0.05,
            onTimeout: { called.fulfill() }
        )

        // Verify it doesn't fire immediately
        wait(for: [called], timeout: 0.5)
        detector.stop()
    }

    // MARK: - start/stop lifecycle

    func test_stop_beforeStart_doesNotCrash() {
        let detector = SilenceDetector(
            timeoutMinutes: 1.0,
            onTimeout: {}
        )
        // Should be safe to call stop without start
        detector.stop()
    }

    func test_multipleStartStop_doesNotCrash() {
        let detector = SilenceDetector(
            timeoutMinutes: 1.0,
            onTimeout: {}
        )
        detector.start()
        detector.stop()
        detector.start()
        detector.stop()
        detector.start()
        detector.stop()
    }

    func test_doubleStart_replacesTimer() {
        let detector = SilenceDetector(
            timeoutMinutes: 1.0,
            onTimeout: {}
        )
        detector.start()
        detector.start() // Should not crash, replaces old timer
        detector.stop()
    }

    // MARK: - Timeout fires when levels are below threshold

    func test_timeout_firesWhenSilent() {
        let called = expectation(description: "onTimeout")

        // Very short timeout for testing: 0.01 minutes = 0.6 seconds
        // Poll every 0.2 seconds
        let detector = SilenceDetector(
            timeoutMinutes: 0.01,
            pollIntervalSeconds: 0.2,
            threshold: 0.05,
            onTimeout: { called.fulfill() }
        )

        // Set levels to zero (below threshold)
        AppState.shared.micLevel = 0.0
        AppState.shared.systemLevel = 0.0

        detector.start()
        wait(for: [called], timeout: 3.0)
        detector.stop()
    }

    // MARK: - Activity above threshold resets timer

    func test_activityAboveThreshold_preventsTimeout() {
        let called = expectation(description: "onTimeout")
        called.isInverted = true // Should NOT fire

        let detector = SilenceDetector(
            timeoutMinutes: 0.01,
            pollIntervalSeconds: 0.2,
            threshold: 0.05,
            onTimeout: { called.fulfill() }
        )

        // Keep levels above threshold
        AppState.shared.micLevel = 0.5
        AppState.shared.systemLevel = 0.0

        detector.start()
        wait(for: [called], timeout: 1.5)
        detector.stop()

        // Reset levels
        AppState.shared.micLevel = 0.0
    }

    // MARK: - Stop prevents callback

    func test_stop_preventsCallback() {
        let called = expectation(description: "onTimeout")
        called.isInverted = true

        let detector = SilenceDetector(
            timeoutMinutes: 0.005, // Very short
            pollIntervalSeconds: 0.1,
            threshold: 0.05,
            onTimeout: { called.fulfill() }
        )

        AppState.shared.micLevel = 0.0
        AppState.shared.systemLevel = 0.0

        detector.start()
        detector.stop() // Immediately stop

        wait(for: [called], timeout: 1.0)
    }

    // MARK: - Threshold boundary

    func test_threshold_exactlyAtThreshold_countsAsActive() {
        // SilenceDetector: `if level > threshold` → at threshold, not active
        // So exactly at threshold should NOT reset activity
        let called = expectation(description: "onTimeout")

        let detector = SilenceDetector(
            timeoutMinutes: 0.005,
            pollIntervalSeconds: 0.1,
            threshold: 0.05,
            onTimeout: { called.fulfill() }
        )

        // Set to exactly threshold (NOT above)
        AppState.shared.micLevel = 0.05
        AppState.shared.systemLevel = 0.0

        detector.start()
        wait(for: [called], timeout: 2.0)
        detector.stop()

        AppState.shared.micLevel = 0.0
    }

    func test_threshold_justAbove_countsAsActive() {
        let called = expectation(description: "onTimeout")
        called.isInverted = true

        let detector = SilenceDetector(
            timeoutMinutes: 0.01,
            pollIntervalSeconds: 0.2,
            threshold: 0.05,
            onTimeout: { called.fulfill() }
        )

        // Just above threshold
        AppState.shared.micLevel = 0.051
        AppState.shared.systemLevel = 0.0

        detector.start()
        wait(for: [called], timeout: 1.5)
        detector.stop()

        AppState.shared.micLevel = 0.0
    }

    // MARK: - Max of mic and system levels

    func test_usesMaxOfMicAndSystemLevel() {
        let called = expectation(description: "onTimeout")
        called.isInverted = true

        let detector = SilenceDetector(
            timeoutMinutes: 0.01,
            pollIntervalSeconds: 0.2,
            threshold: 0.05,
            onTimeout: { called.fulfill() }
        )

        // micLevel is below, but systemLevel is above
        AppState.shared.micLevel = 0.0
        AppState.shared.systemLevel = 0.5

        detector.start()
        wait(for: [called], timeout: 1.5)
        detector.stop()

        AppState.shared.systemLevel = 0.0
    }
}
