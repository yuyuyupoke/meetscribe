import XCTest
@testable import MeetScribeCore

/// UI 文字スケール (⌘+ / ⌘- / ⌘0) の段階計算ロジック。
final class UIScaleTests: XCTestCase {

    func test_steppedScale_incrementsByStep() {
        XCTAssertEqual(AppState.steppedScale(1.0, by: 0.1), 1.1)
        XCTAssertEqual(AppState.steppedScale(1.1, by: 0.1), 1.2)
        XCTAssertEqual(AppState.steppedScale(1.0, by: -0.1), 0.9)
    }

    func test_steppedScale_clampsAtBounds() {
        XCTAssertEqual(AppState.steppedScale(1.8, by: 0.1), 1.8)
        XCTAssertEqual(AppState.steppedScale(0.8, by: -0.1), 0.8)
    }

    func test_steppedScale_avoidsFloatingPointDrift() {
        // 0.1 の連続加算は二進浮動小数点で誤差が積もる (0.30000000000000004 問題)。
        // 10分の1丸めで 1.1 → 1.2 → ... が正確な値になることを固定する。
        var scale = 1.0
        for _ in 0..<8 {
            scale = AppState.steppedScale(scale, by: 0.1)
        }
        XCTAssertEqual(scale, 1.8)
        for _ in 0..<10 {
            scale = AppState.steppedScale(scale, by: -0.1)
        }
        XCTAssertEqual(scale, 0.8)
    }
}
