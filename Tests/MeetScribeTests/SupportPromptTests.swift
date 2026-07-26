import XCTest
@testable import MeetScribeCore

/// 応援バナーの表示判定。
/// 「使ってもらう前に頼まない」「一度出したら間隔を置く」「拒否したら二度と出さない」
/// の3条件を固定する。押し付けがましさは実装の細部ではなくこの条件で決まる。
final class SupportPromptTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func shouldShow(
        saveCount: Int,
        lastShownAt: Date? = nil,
        dismissed: Bool = false
    ) -> Bool {
        AppState.shouldShowSupportPrompt(
            saveCount: saveCount,
            lastShownAt: lastShownAt,
            dismissed: dismissed,
            now: now
        )
    }

    // MARK: - 初回利用では出さない

    func test_beforeMinimumSaves_doesNotShow() {
        for count in 0..<AppState.supportPromptMinSaves {
            XCTAssertFalse(shouldShow(saveCount: count), "保存\(count)回で表示された")
        }
    }

    func test_atMinimumSaves_shows() {
        XCTAssertTrue(shouldShow(saveCount: AppState.supportPromptMinSaves))
    }

    func test_wellAboveMinimumSaves_shows() {
        XCTAssertTrue(shouldShow(saveCount: 100))
    }

    // MARK: - 拒否したら出さない

    func test_dismissed_neverShows() {
        XCTAssertFalse(shouldShow(saveCount: 100, dismissed: true))
        XCTAssertFalse(shouldShow(saveCount: 100, lastShownAt: nil, dismissed: true))
    }

    // MARK: - 表示間隔

    func test_justShown_doesNotShowAgain() {
        XCTAssertFalse(shouldShow(saveCount: 100, lastShownAt: now))
    }

    func test_withinInterval_doesNotShow() {
        let recent = now.addingTimeInterval(-AppState.supportPromptInterval + 60)
        XCTAssertFalse(shouldShow(saveCount: 100, lastShownAt: recent))
    }

    func test_afterInterval_showsAgain() {
        let old = now.addingTimeInterval(-AppState.supportPromptInterval)
        XCTAssertTrue(shouldShow(saveCount: 100, lastShownAt: old))
    }

    func test_longAfterInterval_showsAgain() {
        let veryOld = now.addingTimeInterval(-AppState.supportPromptInterval * 5)
        XCTAssertTrue(shouldShow(saveCount: 100, lastShownAt: veryOld))
    }

    // MARK: - 設定値の妥当性

    /// 毎回出すような設定になっていないこと (押し付けの防止線)。
    func test_intervalIsAtLeastOneWeek() {
        XCTAssertGreaterThanOrEqual(AppState.supportPromptInterval, 7 * 24 * 60 * 60)
    }

    func test_minSavesIsAtLeastTwo() {
        XCTAssertGreaterThanOrEqual(AppState.supportPromptMinSaves, 2)
    }

    // MARK: - リンク

    func test_supportLink_isHTTPS() {
        XCTAssertEqual(SupportLink.url.scheme, "https")
    }

    func test_supportLink_hasSuggestedAmountLabel() {
        XCTAssertFalse(SupportLink.suggestedAmountLabel.isEmpty)
    }
}
