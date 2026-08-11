import Foundation
import Observation
import XCTest
@testable import MeetScribeCore

/// 「録音停止 → 議事録保存完了」の間に新しい録音を開始できないことを固定する。
///
/// 潰した事故 (2026-08-11 監査 Q1): `stop()` は保存フロー (実測1〜14秒) に入る**前**に
/// `captureStatus` を `.idle` へ戻していたため、保存中に録音を開始できた。すると
///   1. `start()` の `TranscriptStore.clear()` で直前の会議の文字起こし・全体像・
///      Catchupカードが消える (`meetingEntries` は isFinal を見ないので partial が1個
///      入るだけで長時間の会議が数語に化ける)
///   2. 旧セッションの保存フロー末尾の `meetingStartedAt = nil` が新セッションの開始時刻を
///      潰し、次の `stop()` が `guard let startedAt` で落ちて「empty transcript → skip save」の
///      嘘ログを出して2件目も丸ごと捨てる
///
/// 守る不変条件:
///   * 録音停止から保存完了まで `.stopping` を維持する (= UI もメニューバーも開始不可)
///   * 早期 return / 保存成功 / 保存失敗のどの経路を通っても最終的に `.idle` へ戻る
///     (戻し忘れると録音を二度と開始できなくなる)
///
/// これらは共有シングルトン (`AppState.shared` / `TranscriptStore.shared`) を触るため、
/// 各テストは開始前の状態を退避して必ず復元する。
@MainActor
final class AudioSessionStopStatusTests: XCTestCase {

    // MARK: - 開始ブロックの配線 (保存中は開始不可 + 理由を出す)

    /// 保存フロー中の状態 (`.stopping`) では、前提条件が全部揃っていても開始できず、
    /// かつ理由が UI に出せること。`AudioSession.stop()` はこの2つに依存して
    /// 「保存中は開始不可」を実現しているので、外されたら即失敗させる。
    func test_duringSaveFlow_cannotStartAndReasonIsShown() {
        XCTAssertFalse(AppState.computeCanStart(
            permissionsGranted: true,
            hasAPIKey: true,
            saveFolderSet: true,
            status: .stopping,
            disclosureAccepted: true
        ), "保存フロー中に録音を開始できてしまう")

        let reason = AppState.computeStartBlockReason(
            microphoneGranted: true,
            screenRecordingGranted: true,
            hasAPIKey: true,
            saveFolderSet: true,
            status: .stopping,
            disclosureAccepted: true
        )
        XCTAssertNotNil(reason, "開始できない理由が無いとツールチップが空になる")
        XCTAssertEqual(reason, "停止処理中です")
    }

    // MARK: - .idle への復帰 (全経路)

    /// 早期 return 経路 (発話ゼロ → 保存スキップ)。ここで `.idle` に戻し忘れると
    /// 録音ボタンが永久に無効化される。
    func test_stop_withEmptyTranscript_returnsToIdle() async {
        let snapshot = StateSnapshot.capture()
        defer { snapshot.restore() }

        TranscriptStore.shared.clear()
        AppState.shared.meetingStartedAt = Date()
        AppState.shared.captureStatus = .running

        await AudioSession.shared.stop()

        XCTAssertEqual(AppState.shared.captureStatus, .idle)
        XCTAssertNil(AppState.shared.meetingStartedAt)
    }

    /// 保存成功経路。保存フローに入った時点で `.stopping` が維持されており
    /// (= その間は開始不可)、完了後に `.idle` へ戻ること。
    func test_stop_whenSaveSucceeds_staysStoppingThenIdle() async throws {
        let snapshot = StateSnapshot.capture()
        defer { snapshot.restore() }
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        AppState.shared.meetingsSaveDirectoryURL = dir
        seedShortTranscript()
        AppState.shared.meetingStartedAt = Date()
        AppState.shared.lastSavedURL = nil
        AppState.shared.captureStatus = .running

        let probe = probeStatusWhenSaveFlowStarts()
        await AudioSession.shared.stop()

        XCTAssertEqual(
            probe.status, .stopping,
            "保存フロー開始時に .stopping が外れている = 保存中に録音を開始できる"
        )
        XCTAssertEqual(AppState.shared.captureStatus, .idle)
        let saved = AppState.shared.lastSavedURL
        XCTAssertNotNil(saved, "保存フローが走っていない (テストの前提が崩れている)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved?.path ?? ""))
    }

    /// 保存失敗経路 (保存先未設定 → 退避保存)。ここも `.stopping` 維持 → `.idle` 復帰。
    func test_stop_whenSaveFails_staysStoppingThenIdle() async {
        let snapshot = StateSnapshot.capture()
        defer { snapshot.restore() }

        // 保存先未設定 → TranscriptExporter.save が throw し、退避保存へ落ちる
        AppState.shared.meetingsSaveDirectoryURL = nil
        seedShortTranscript()
        AppState.shared.meetingStartedAt = Date()
        AppState.shared.lastSavedURL = nil
        AppState.shared.captureStatus = .running

        let probe = probeStatusWhenSaveFlowStarts()
        await AudioSession.shared.stop()

        XCTAssertEqual(
            probe.status, .stopping,
            "保存失敗経路でも保存中は .stopping を維持していないと録音を開始できる"
        )
        XCTAssertEqual(AppState.shared.captureStatus, .idle)

        // 退避保存に逃げた痕跡を確認し、テストが作ったファイルは片付ける
        let rescued = AppState.shared.lastSavedURL
        XCTAssertEqual(
            rescued?.deletingLastPathComponent().standardizedFileURL,
            TranscriptExporter.rescueDirectory.standardizedFileURL,
            "保存に失敗したのに退避保存されていない"
        )
        if let rescued { try? FileManager.default.removeItem(at: rescued) }
    }

    // MARK: - ヘルパー

    /// 20文字未満に留めるのが重要: `MeetingTitleGenerator` はこの長さだと
    /// ネットワークを使わずフォールバックタイトルを返すため、テストが通信も課金もしない。
    private func seedShortTranscript() {
        TranscriptStore.shared.clear()
        TranscriptStore.shared.completeItem(
            itemId: "stop-status-test",
            finalText: "テスト",
            speaker: .me
        )
    }

    private func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meetscribe-stop-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存フロー開始時点 (`isSavingMeeting` が立つ直前) の `captureStatus` を捕まえる。
    /// Observation の `onChange` は willSet 相当で、変更した MainActor 上から同期的に
    /// 呼ばれるので、保存フローの途中の状態をレースなしに観測できる。
    private func probeStatusWhenSaveFlowStarts() -> StatusProbe {
        let probe = StatusProbe()
        withObservationTracking {
            _ = AppState.shared.isSavingMeeting
        } onChange: {
            MainActor.assumeIsolated {
                probe.status = AppState.shared.captureStatus
            }
        }
        return probe
    }

    /// `onChange` は `@Sendable` なので参照型の箱で受ける。書き込みは MainActor 上のみ。
    private final class StatusProbe: @unchecked Sendable {
        var status: CaptureStatus?
    }

    /// 共有シングルトンの退避と復元。
    private struct StateSnapshot {
        let status: CaptureStatus
        let startedAt: Date?
        let saveDirectory: URL?
        let saveCount: Int
        let lastSavedURL: URL?
        let lastError: String?
        let mutedStreams: Set<SpeakerLabel>

        @MainActor
        static func capture() -> StateSnapshot {
            let state = AppState.shared
            return StateSnapshot(
                status: state.captureStatus,
                startedAt: state.meetingStartedAt,
                saveDirectory: state.meetingsSaveDirectoryURL,
                saveCount: state.meetingSaveCount,
                lastSavedURL: state.lastSavedURL,
                lastError: state.lastError,
                mutedStreams: state.mutedStreams
            )
        }

        @MainActor
        func restore() {
            let state = AppState.shared
            state.captureStatus = status
            state.meetingStartedAt = startedAt
            state.meetingsSaveDirectoryURL = saveDirectory
            state.meetingSaveCount = saveCount
            state.lastSavedURL = lastSavedURL
            state.lastError = lastError
            state.mutedStreams = mutedStreams
            TranscriptStore.shared.clear()
        }
    }
}
