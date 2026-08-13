import XCTest
@testable import MeetScribeCore

/// ヘッダーの「開始時刻 / 経過時間」表示の文字列化。
/// 実機の時計を待たずに境界を固定するため、フォーマッタを純関数に切り出してある。
final class SessionClockFormatterTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 経過時間

    func test_elapsed_formatsMinutesAndSeconds() {
        XCTAssertEqual(SessionClockFormatter.elapsed(from: base, to: base), "00:00")
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(1)),
            "00:01"
        )
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(59)),
            "00:59"
        )
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(60)),
            "01:00"
        )
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(9 * 60 + 5)),
            "09:05"
        )
    }

    /// 1時間を超えても時:分:秒に切り替えず、分を3桁に伸ばす。
    /// 講義の長さ (61分・75分) をそのまま読めるようにするための仕様。
    func test_elapsed_beyondOneHour_keepsMinuteFormat() {
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(3_599)),
            "59:59"
        )
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(3_600)),
            "60:00"
        )
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(75 * 60 + 4)),
            "75:04"
        )
        // セッションキャップ (既定180分) 到達時
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(180 * 60)),
            "180:00"
        )
    }

    /// 端数は切り捨て (カウントアップが実時間より先に進まないように)。
    func test_elapsed_truncatesSubSecond() {
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(1.99)),
            "00:01"
        )
    }

    /// スリープ復帰やNTP補正で now が開始時刻より前になっても負の表示にしない。
    func test_elapsed_clockGoingBackwards_clampsToZero() {
        XCTAssertEqual(
            SessionClockFormatter.elapsed(from: base, to: base.addingTimeInterval(-500)),
            "00:00"
        )
    }

    // MARK: - 開始時刻

    func test_startTime_is24HourWithSeconds() {
        let utc = TimeZone(secondsFromGMT: 0)!
        // 1970-01-01 14:32:05 UTC
        let date = Date(timeIntervalSince1970: 14 * 3_600 + 32 * 60 + 5)
        XCTAssertEqual(SessionClockFormatter.startTime(date, timeZone: utc), "14:32:05")
    }

    /// 午後も24時間表記のまま (ロケールの AM/PM に引っ張られない)。
    func test_startTime_afternoon_hasNoMeridiem() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 23 * 3_600 + 5 * 60 + 9)
        let text = SessionClockFormatter.startTime(date, timeZone: utc)
        XCTAssertEqual(text, "23:05:09")
        XCTAssertFalse(text.contains("PM"))
        XCTAssertFalse(text.contains("午後"))
    }

    func test_startTime_respectsTimeZone() {
        // テキサス (CDT = UTC-5) と日本 (UTC+9) で同じ瞬間が違う表記になる
        let date = Date(timeIntervalSince1970: 12 * 3_600)
        XCTAssertEqual(
            SessionClockFormatter.startTime(date, timeZone: TimeZone(secondsFromGMT: -5 * 3_600)!),
            "07:00:00"
        )
        XCTAssertEqual(
            SessionClockFormatter.startTime(date, timeZone: TimeZone(secondsFromGMT: 9 * 3_600)!),
            "21:00:00"
        )
    }

    // MARK: - 待機中のプレースホルダ

    /// 録音の有無でヘッダーの高さや横位置が動かないよう、待機中も同じ桁数を出す。
    func test_idlePlaceholders_matchRealWidth() {
        XCTAssertEqual(
            SessionClockFormatter.idleElapsed.count,
            SessionClockFormatter.elapsed(from: base, to: base).count,
            "経過時間のプレースホルダが実表示と桁数違い = 録音開始でレイアウトが動く"
        )
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(
            SessionClockFormatter.idleStartTime.count,
            SessionClockFormatter.startTime(base, timeZone: utc).count,
            "開始時刻のプレースホルダが実表示と桁数違い"
        )
    }
}
