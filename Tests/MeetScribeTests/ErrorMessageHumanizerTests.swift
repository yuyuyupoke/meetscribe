import XCTest
@testable import MeetScribeCore

final class ErrorMessageHumanizerTests: XCTestCase {

    // MARK: - isRecoverableAPIErrorType

    func test_isRecoverable_serverError_returnsTrue() {
        XCTAssertTrue(ErrorMessageHumanizer.isRecoverableAPIErrorType("server_error"))
    }

    func test_isRecoverable_sessionExpired_returnsTrue() {
        XCTAssertTrue(ErrorMessageHumanizer.isRecoverableAPIErrorType("session_expired"))
    }

    func test_isRecoverable_rateLimitExceeded_returnsTrue() {
        XCTAssertTrue(ErrorMessageHumanizer.isRecoverableAPIErrorType("rate_limit_exceeded"))
    }

    func test_isRecoverable_internalError_returnsTrue() {
        XCTAssertTrue(ErrorMessageHumanizer.isRecoverableAPIErrorType("internal_error"))
    }

    func test_isRecoverable_timeout_returnsTrue() {
        XCTAssertTrue(ErrorMessageHumanizer.isRecoverableAPIErrorType("timeout"))
    }

    func test_isRecoverable_authError_returnsFalse() {
        XCTAssertFalse(ErrorMessageHumanizer.isRecoverableAPIErrorType("authentication_error"))
    }

    func test_isRecoverable_invalidRequest_returnsFalse() {
        XCTAssertFalse(ErrorMessageHumanizer.isRecoverableAPIErrorType("invalid_request_error"))
    }

    func test_isRecoverable_nil_returnsFalse() {
        XCTAssertFalse(ErrorMessageHumanizer.isRecoverableAPIErrorType(nil))
    }

    func test_isRecoverable_emptyString_returnsFalse() {
        XCTAssertFalse(ErrorMessageHumanizer.isRecoverableAPIErrorType(""))
    }

    func test_isRecoverable_unknownType_returnsFalse() {
        XCTAssertFalse(ErrorMessageHumanizer.isRecoverableAPIErrorType("unknown_type"))
    }

    // MARK: - humanize URLError

    func test_humanize_timedOut_returnsJapaneseMessage() {
        let error = URLError(.timedOut)
        let msg = ErrorMessageHumanizer.humanize(error)
        XCTAssertTrue(msg.contains("タイムアウト"))
    }

    func test_humanize_notConnected_returnsJapaneseMessage() {
        let error = URLError(.notConnectedToInternet)
        let msg = ErrorMessageHumanizer.humanize(error)
        XCTAssertTrue(msg.contains("インターネット"))
    }

    func test_humanize_networkLost_returnsJapaneseMessage() {
        let error = URLError(.networkConnectionLost)
        let msg = ErrorMessageHumanizer.humanize(error)
        XCTAssertTrue(msg.contains("ネットワーク"))
    }

    func test_humanize_cannotFindHost_returnsJapaneseMessage() {
        let error = URLError(.cannotFindHost)
        let msg = ErrorMessageHumanizer.humanize(error)
        XCTAssertTrue(msg.contains("サーバー") || msg.contains("DNS"))
    }

    func test_humanize_cancelled_returnsJapaneseMessage() {
        let error = URLError(.cancelled)
        let msg = ErrorMessageHumanizer.humanize(error)
        XCTAssertTrue(msg.contains("キャンセル"))
    }

    func test_humanize_badServerResponse_returnsJapaneseMessage() {
        let error = URLError(.badServerResponse)
        let msg = ErrorMessageHumanizer.humanize(error)
        XCTAssertTrue(msg.contains("サーバー"))
    }

    // MARK: - humanize TranscriptionClientError

    func test_humanize_connectionTimeout_returnsLocalizedDescription() {
        let error = TranscriptionClientError.connectionTimeout
        let msg = ErrorMessageHumanizer.humanize(error)
        XCTAssertTrue(msg.contains("タイムアウト"))
    }

    func test_humanize_sessionNotEstablished_returnsLocalizedDescription() {
        let error = TranscriptionClientError.sessionNotEstablished
        let msg = ErrorMessageHumanizer.humanize(error)
        XCTAssertTrue(msg.contains("セッション"))
    }

    // MARK: - humanize generic NSError

    func test_humanize_genericError_stripsBoilerplate() {
        let error = NSError(
            domain: "TestDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed. Something went wrong"]
        )
        let msg = ErrorMessageHumanizer.humanize(error)
        XCTAssertFalse(msg.contains("The operation couldn't be completed."))
        XCTAssertTrue(msg.contains("Something went wrong"))
    }
}
