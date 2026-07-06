import XCTest
@testable import MeetScribeCore

/// canStart 判定ロジックの状態機械テスト。
/// 「接続タイムアウト (.error) 後に録音ボタンが永久に無効になり
/// アプリ再起動が必要になる」バグの再発防止が主目的。
@MainActor
final class AppStateCanStartTests: XCTestCase {

    /// 前提条件 (権限・キー・保存先) が全部揃った状態での判定ヘルパー
    private func canStart(status: CaptureStatus) -> Bool {
        AppState.computeCanStart(
            permissionsGranted: true,
            hasAPIKey: true,
            saveFolderSet: true,
            status: status
        )
    }

    // MARK: - ステータス別の開始可否

    func test_idle_canStart() {
        XCTAssertTrue(canStart(status: .idle))
    }

    /// 回帰テスト: エラー後 (接続タイムアウト等) も再試行できること。
    func test_error_canStart() {
        XCTAssertTrue(canStart(status: .error("OpenAI接続タイムアウト")))
    }

    func test_running_cannotStart() {
        XCTAssertFalse(canStart(status: .running))
    }

    func test_starting_cannotStart() {
        XCTAssertFalse(canStart(status: .starting))
    }

    func test_stopping_cannotStart() {
        XCTAssertFalse(canStart(status: .stopping))
    }

    // MARK: - 前提条件の欠落

    func test_missingPermissions_cannotStart() {
        XCTAssertFalse(AppState.computeCanStart(
            permissionsGranted: false, hasAPIKey: true, saveFolderSet: true, status: .idle
        ))
    }

    func test_missingAPIKey_cannotStart() {
        XCTAssertFalse(AppState.computeCanStart(
            permissionsGranted: true, hasAPIKey: false, saveFolderSet: true, status: .idle
        ))
    }

    func test_missingSaveFolder_cannotStart() {
        XCTAssertFalse(AppState.computeCanStart(
            permissionsGranted: true, hasAPIKey: true, saveFolderSet: false, status: .idle
        ))
    }

    // MARK: - startBlockReason との整合

    /// startBlockReason (ツールチップ) と computeCanStart は同じ条件の二重実装。
    /// 「canStart == true ⇔ 不足理由なし」の対応が崩れたら片方だけ直した事故。
    /// 全条件の組み合わせを総当たりで検証する (2^4 × 5 status = 80通り)。
    func test_startBlockReason_consistentWithCanStart() {
        let bools = [true, false]
        let statuses: [CaptureStatus] = [.idle, .error("x"), .starting, .running, .stopping]
        for mic in bools {
            for screen in bools {
                for key in bools {
                    for folder in bools {
                        for status in statuses {
                            let canStart = AppState.computeCanStart(
                                permissionsGranted: mic && screen,
                                hasAPIKey: key,
                                saveFolderSet: folder,
                                status: status
                            )
                            let reason = AppState.computeStartBlockReason(
                                microphoneGranted: mic,
                                screenRecordingGranted: screen,
                                hasAPIKey: key,
                                saveFolderSet: folder,
                                status: status
                            )
                            XCTAssertEqual(
                                reason == nil, canStart,
                                "mic=\(mic) screen=\(screen) key=\(key) folder=\(folder) status=\(status): 乖離"
                            )
                        }
                    }
                }
            }
        }
    }
}
