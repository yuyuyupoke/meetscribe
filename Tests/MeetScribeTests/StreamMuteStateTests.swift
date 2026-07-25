import XCTest
@testable import MeetScribeCore

final class StreamMuteStateTests: XCTestCase {

    func test_initialState_nothingMuted() {
        let state = StreamMuteState()
        XCTAssertFalse(state.isMuted(.me))
        XCTAssertFalse(state.isMuted(.other))
    }

    func test_sync_reflectsMutedStreams() {
        let state = StreamMuteState()
        state.sync(with: [.me])
        XCTAssertTrue(state.isMuted(.me))
        XCTAssertFalse(state.isMuted(.other))

        state.sync(with: [.me, .other])
        XCTAssertTrue(state.isMuted(.me))
        XCTAssertTrue(state.isMuted(.other))
    }

    func test_sync_emptySet_unmutesAll() {
        let state = StreamMuteState()
        state.sync(with: [.me, .other])
        state.sync(with: [])
        XCTAssertFalse(state.isMuted(.me))
        XCTAssertFalse(state.isMuted(.other))
    }

    /// オーディオスレッド (読み) と UI スレッド (書き) の並行アクセスで
    /// クラッシュ・データ破壊がないことを確認する。
    func test_concurrentReadWrite_isThreadSafe() {
        let state = StreamMuteState()
        let iterations = 10_000
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            for i in 0..<iterations {
                state.sync(with: i % 2 == 0 ? [.me] : [])
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<iterations {
                _ = state.isMuted(.me)
                _ = state.isMuted(.other)
            }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    }
}
