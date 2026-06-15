import Foundation

/// VU レベルをポーリングして、N分間無音が続いたらコールバックを発火する。
/// - 閾値以下のレベルが `timeoutMinutes` 分連続で記録されると onTimeout() を呼ぶ
/// - 閾値超えが観測されたら最終アクティブ時刻を更新
@MainActor
final class SilenceDetector {
    private var timer: Timer?
    private var lastActivityAt: Date = Date()
    private let threshold: Float
    private let timeoutSeconds: TimeInterval
    private let pollIntervalSeconds: TimeInterval
    private let onTimeout: @MainActor () -> Void

    init(
        timeoutMinutes: Double = 10.0,
        pollIntervalSeconds: TimeInterval = 5.0,
        threshold: Float = 0.05,
        onTimeout: @escaping @MainActor () -> Void
    ) {
        self.threshold = threshold
        self.timeoutSeconds = timeoutMinutes * 60
        self.pollIntervalSeconds = pollIntervalSeconds
        self.onTimeout = onTimeout
    }

    func start() {
        stop()
        lastActivityAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let level = max(AppState.shared.micLevel, AppState.shared.systemLevel)
        if level > threshold {
            lastActivityAt = Date()
            return
        }
        let elapsed = Date().timeIntervalSince(lastActivityAt)
        if elapsed >= timeoutSeconds {
            DebugLog.log("[silence] \(Int(timeoutSeconds))s silence detected → auto-stop")
            stop()
            onTimeout()
        }
    }
}
