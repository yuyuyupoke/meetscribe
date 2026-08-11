import XCTest
@testable import MeetScribeCore

/// 「ストリームが死んだ」警告が他ストリームの復帰で消えないことを固定する。
///
/// 潰した事故 (2026-08-11 監査 Q5): 片方のストリームが再接続を諦めた警告は、
/// もう片方のストリームの再接続成功 (`clearReconnectErrorIfMine`) や進捗表示
/// (`setReconnectError`) で消えていた。相手ストリームが死んだ唯一の手掛かりが
/// 消滅するため、**オンライン会議で相手の発言ゼロのまま議事録が保存され、
/// 原因も残らない**。実装のコメント自身が「他ストリームのエラーは維持する」と
/// 宣言しているのに実装が破っていた。
@MainActor
final class AudioSessionErrorBannerTests: XCTestCase {

    private let micDead = "[再接続] [自分] \(AudioSession.reconnectGiveUpMarker)。録音は継続しますが、文字起こしは止まります。"
    private let otherDead = "[再接続] [相手] \(AudioSession.reconnectGiveUpMarker)。録音は継続しますが、文字起こしは止まります。"

    // MARK: - 上書き

    /// 中核の不変条件: 死亡警告は進捗バナーで潰されない。
    func test_streamDeadWarning_isNotOverwrittenByProgress() {
        XCTAssertFalse(AudioSession.shouldOverwriteError(
            current: otherDead,
            next: "[再接続] [自分] 接続切れ、再接続中…"
        ), "相手ストリーム死亡の手掛かりが自分の再接続表示で消える")
    }

    func test_streamDeadWarning_isNotOverwrittenByRetryFailure() {
        XCTAssertFalse(AudioSession.shouldOverwriteError(
            current: otherDead,
            next: "[再接続] [自分] 再接続失敗 (1/7): timeout"
        ))
    }

    /// 両方死んだら最新の死亡警告を出す (どちらも「死んでいる」ので情報は失われない)。
    func test_streamDeadWarning_canBeReplacedByAnotherDeath() {
        XCTAssertTrue(AudioSession.shouldOverwriteError(current: otherDead, next: micDead))
    }

    func test_normalBanner_isOverwritable() {
        XCTAssertTrue(AudioSession.shouldOverwriteError(
            current: "[再接続] [自分] 接続切れ、再接続中…",
            next: "[再接続] [自分] 再接続失敗 (1/7): timeout"
        ))
        XCTAssertTrue(AudioSession.shouldOverwriteError(current: nil, next: micDead))
    }

    // MARK: - クリア

    /// 中核の不変条件: 自分の再接続成功で相手の死亡警告を消さない。
    func test_otherStreamDeath_survivesMyReconnectSuccess() {
        XCTAssertFalse(AudioSession.shouldClearReconnectError(current: otherDead, speaker: .me))
        XCTAssertFalse(AudioSession.shouldClearReconnectError(current: micDead, speaker: .other))
    }

    /// 自分の死亡警告も自分では消さない (諦めた後にそのストリームは復帰しない)。
    func test_ownDeathWarning_isNotCleared() {
        XCTAssertFalse(AudioSession.shouldClearReconnectError(current: micDead, speaker: .me))
    }

    func test_ownReconnectProgress_isCleared() {
        XCTAssertTrue(AudioSession.shouldClearReconnectError(
            current: "[再接続] [自分] 再接続失敗 (1/7): timeout",
            speaker: .me
        ))
        XCTAssertTrue(AudioSession.shouldClearReconnectError(
            current: "[再接続] [自分] 接続切れ、再接続中…",
            speaker: .me
        ))
    }

    /// 他ストリームの「再接続中…」を消すと、まだ復帰していない側の手掛かりが失われる。
    func test_otherStreamReconnectProgress_isKept() {
        XCTAssertFalse(AudioSession.shouldClearReconnectError(
            current: "[再接続] [相手] 接続切れ、再接続中…",
            speaker: .me
        ))
    }

    /// 該当ストリームの通信系エラーは再接続成功で解消済みなので消す (赤字が残り続ける対策)。
    func test_ownTransportError_isCleared() {
        XCTAssertTrue(AudioSession.shouldClearReconnectError(
            current: "[自分] 受信エラー: 通信が切断されました",
            speaker: .me
        ))
        XCTAssertTrue(AudioSession.shouldClearReconnectError(
            current: "[自分] APIエラー: レート制限",
            speaker: .me
        ))
    }

    func test_otherStreamTransportError_isKept() {
        XCTAssertFalse(AudioSession.shouldClearReconnectError(
            current: "[相手] 受信エラー: 通信が切断されました",
            speaker: .me
        ))
    }

    /// 他種のエラー (システム音声復帰・保存失敗・マイク監視) は再接続と無関係なので維持する。
    func test_unrelatedErrors_areKept() {
        let unrelated = [
            "[システム音声] 停止しました (display change)。復帰を試みています…",
            "[マイク] 音声が届かなくなりました (入力デバイスの切替?)。マイクを再起動しています…",
            "議事録の保存に失敗しました: no space left"
        ]
        for message in unrelated {
            XCTAssertFalse(
                AudioSession.shouldClearReconnectError(current: message, speaker: .me),
                "再接続成功で '\(message.prefix(10))…' を消してはいけない"
            )
        }
    }
}
