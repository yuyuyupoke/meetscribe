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

    /// SCStream が OS 都合で予期せず停止したときに呼ばれる (画面ロック解除失敗、
    /// 外部ディスプレイ切断、画面収録権限の失効等)。AudioSession がここで
    /// クリーンアップと状態更新を一括で行う。delegate から AppState.captureStatus を
    /// 直接書き換えてはいけない — AudioSession 内部状態と不整合になり、録音中に
    /// 停止ボタンも Kill も消えてマイクだけ回り続ける「詰み」になる。
    var onUnexpectedStop: (@Sendable (String) -> Void)?

    func start(onBuffer: BufferHandler? = nil) async throws {
        // 既に動いている場合は畳んでから開始する (早期 return すると新しい
        // bufferHandler への差し替えがスキップされ、音声が旧パイプラインに流れ続ける)。
        if isRunning { await stop() }
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
            sampleHandlerQueue: DispatchQueue(label: "com.meetscribe.app.sysaudio", qos: .userInitiated)
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
        // systemLevel のリセットは呼び出し側 (AudioSession, @MainActor) で行う。
    }

    /// アプリ終了直前用の同期停止。terminate 後は runloop が回らず await できないため
    /// `stopCapture` の完了は待たない (プロセス消滅が先)。SCStream の解放要求だけ
    /// 確実に投げて、孤児ストリームが OS に残らないようにする。
    func stopSync() {
        guard isRunning else { return }
        stream?.stopCapture { _ in }
        stream = nil
        streamOutput = nil
        bufferHandler = nil
        isRunning = false
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
        DebugLog.log("[sys] SCStream stopped unexpectedly: \(error.localizedDescription)")
        // delegate キューから直接プロパティを書き換えると、MainActor 側の
        // start()/stop()/tearDown() と競合してデータレース (ARC over-release) に
        // なるため、start/stop と同じ MainActor 隔離に跳ばしてから畳む。
        // 順序が入れ替わっても stop() 側の isRunning ガードで安全。
        let reason = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stream = nil
            self.streamOutput = nil
            self.bufferHandler = nil
            self.isRunning = false
            // captureStatus の書き換えは AudioSession の一本化された停止経路に任せる。
            self.onUnexpectedStop?(reason)
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
