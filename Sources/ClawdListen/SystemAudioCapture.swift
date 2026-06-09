import ScreenCaptureKit
import AVFoundation
import Foundation

/// ScreenCaptureKit を使ってシステム音声 (他アプリ・オンライン会議の音) をキャプチャする。
/// - 画面キャプチャは最小化 (2x2, 1fps) してオーディオのみに近い挙動にする
/// - 自アプリの音は `excludesCurrentProcessAudio` で除外
/// - dB レベルを AppState.systemLevel に反映
///
/// `@unchecked Sendable`: SCStream は sampleHandlerQueue (シリアル) で
/// サンプルを配信する。stream/streamOutput の読み書きは start/stop の
/// async 境界と output コールバックの間に発生するが、シリアルキュー前提。
final class SystemAudioCapture: NSObject, @unchecked Sendable {
    typealias BufferHandler = @Sendable (CMSampleBuffer) -> Void

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var bufferHandler: BufferHandler?
    private(set) var isRunning = false

    func start(onBuffer: BufferHandler? = nil) async throws {
        guard !isRunning else { return }
        bufferHandler = onBuffer

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = shareableContent.displays.first else {
            throw CaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1fps
        config.showsCursor = false
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = AudioStreamOutput { [weak self] sampleBuffer in
            self?.processSampleBuffer(sampleBuffer)
        }
        try stream.addStreamOutput(
            output,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "com.clawdlisten.app.sysaudio", qos: .userInitiated)
        )
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = output
        self.isRunning = true
    }

    func stop() async {
        guard isRunning else { return }
        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        bufferHandler = nil
        isRunning = false
        await MainActor.run {
            AppState.shared.systemLevel = 0.0
        }
    }

    private var lastLevelUpdate: TimeInterval = 0

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // VU メーター用 level 更新は 100ms ごとに throttle (UI 描画負荷削減)。
        // 20ms バッファで 1秒50回呼ばれるが UI 反映は 10回/秒で十分。
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelUpdate >= 0.1 {
            lastLevelUpdate = now
            let level = AudioLevelMeter.normalizedLevel(from: sampleBuffer)
            Task { @MainActor in
                AppState.shared.systemLevel = level
            }
        }
        bufferHandler?(sampleBuffer)
    }
}

extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            AppState.shared.lastError = "System audio stream stopped: \(error.localizedDescription)"
            AppState.shared.captureStatus = .error(error.localizedDescription)
        }
    }
}

private final class AudioStreamOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }
        handler(sampleBuffer)
    }
}

enum CaptureError: Error, LocalizedError {
    case noDisplayAvailable

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "キャプチャ対象のディスプレイが見つかりませんでした"
        }
    }
}
