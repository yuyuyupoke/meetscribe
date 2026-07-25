import Foundation

/// ストリーム別ミュート (Scribe に聴かせない) のスレッドセーフな保持。
///
/// ハイブリッド会議 (オフライン参加 + Zoom 等に同時入室) では、部屋の発話が
/// マイクと Zoom 経由のシステム音の両方から拾われて二重に文字起こしされる。
/// その間だけ片側ストリームを止めるためのフラグ。
///
/// UI (メインスレッド) が書き、オーディオキャプチャのコールバック
/// (キャプチャスレッド) がフレームごとに読むため、@MainActor の AppState とは
/// 分離して NSLock で保護する。UI 表示用の状態は `AppState.mutedStreams` が持ち、
/// didSet でこちらへ同期される。
final class StreamMuteState: @unchecked Sendable {
    static let shared = StreamMuteState()

    private let lock = NSLock()
    private var muted: Set<SpeakerLabel> = []

    func isMuted(_ speaker: SpeakerLabel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return muted.contains(speaker)
    }

    func sync(with streams: Set<SpeakerLabel>) {
        lock.lock(); defer { lock.unlock() }
        muted = streams
    }
}
