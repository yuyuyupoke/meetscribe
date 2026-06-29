import XCTest
@testable import MeetScribeCore

final class TranscriptionConfidenceFilterTests: XCTestCase {

    typealias Filter = TranscriptionConfidenceFilter
    typealias Entry = Filter.LogprobEntry

    // MARK: - parseLogprobs

    func test_parseLogprobs_validArray_returnsEntries() {
        let json: [[String: Any]] = [
            ["token": "こんにちは", "logprob": -0.12],
            ["token": "世界", "logprob": -0.05]
        ]
        let entries = Filter.parseLogprobs(from: json)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].token, "こんにちは")
        XCTAssertEqual(entries[0].logprob, -0.12, accuracy: 1e-10)
        XCTAssertEqual(entries[1].token, "世界")
        XCTAssertEqual(entries[1].logprob, -0.05, accuracy: 1e-10)
    }

    func test_parseLogprobs_missingToken_skipsEntry() {
        let json: [[String: Any]] = [
            ["logprob": -0.12],
            ["token": "OK", "logprob": -0.3]
        ]
        let entries = Filter.parseLogprobs(from: json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].token, "OK")
    }

    func test_parseLogprobs_missingLogprob_skipsEntry() {
        let json: [[String: Any]] = [
            ["token": "test"],
            ["token": "OK", "logprob": -0.1]
        ]
        let entries = Filter.parseLogprobs(from: json)
        XCTAssertEqual(entries.count, 1)
    }

    func test_parseLogprobs_wrongType_skipsEntry() {
        let json: [[String: Any]] = [
            ["token": 123, "logprob": -0.1],
            ["token": "OK", "logprob": "bad"],
            ["token": "fine", "logprob": -0.2]
        ]
        let entries = Filter.parseLogprobs(from: json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].token, "fine")
    }

    func test_parseLogprobs_nanOrInf_skipsEntry() {
        let json: [[String: Any]] = [
            ["token": "nan", "logprob": Double.nan],
            ["token": "inf", "logprob": Double.infinity],
            ["token": "ok", "logprob": -0.1]
        ]
        let entries = Filter.parseLogprobs(from: json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].token, "ok")
    }

    func test_parseLogprobs_emptyArray_returnsEmpty() {
        let entries = Filter.parseLogprobs(from: [])
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - averageLogprob

    func test_averageLogprob_multipleEntries_calculatesCorrectly() {
        let entries = [
            Entry(token: "a", logprob: -0.2),
            Entry(token: "b", logprob: -0.4),
            Entry(token: "c", logprob: -0.6)
        ]
        let avg = Filter.averageLogprob(entries)
        XCTAssertEqual(avg, -0.4, accuracy: 1e-10)
    }

    func test_averageLogprob_singleEntry_returnsThatValue() {
        let entries = [Entry(token: "x", logprob: -0.75)]
        XCTAssertEqual(Filter.averageLogprob(entries), -0.75, accuracy: 1e-10)
    }

    func test_averageLogprob_empty_returnsZero() {
        XCTAssertEqual(Filter.averageLogprob([]), 0.0)
    }

    // MARK: - shouldFilter (logprobs array)

    func test_shouldFilter_highConfidence_returnsFalse() {
        let entries = [
            Entry(token: "こんにちは", logprob: -0.05),
            Entry(token: "世界", logprob: -0.15)
        ]
        XCTAssertFalse(Filter.shouldFilter(logprobs: entries))
    }

    func test_shouldFilter_lowConfidence_returnsTrue() {
        let entries = [
            Entry(token: "ありがとう", logprob: -1.8),
            Entry(token: "ございます", logprob: -1.2)
        ]
        XCTAssertTrue(Filter.shouldFilter(logprobs: entries))
    }

    func test_shouldFilter_exactThreshold_returnsTrue() {
        // threshold default = -1.0, average = -1.0 → <= threshold → true
        let entries = [
            Entry(token: "a", logprob: -0.5),
            Entry(token: "b", logprob: -1.5)
        ]
        XCTAssertTrue(Filter.shouldFilter(logprobs: entries))
    }

    func test_shouldFilter_slightlyAboveThreshold_returnsFalse() {
        let entries = [
            Entry(token: "a", logprob: -0.4),
            Entry(token: "b", logprob: -1.5)
        ]
        // average = -0.95, threshold = -1.0, -0.95 > -1.0 → false
        XCTAssertFalse(Filter.shouldFilter(logprobs: entries))
    }

    func test_shouldFilter_emptyLogprobs_returnsFalse() {
        XCTAssertFalse(Filter.shouldFilter(logprobs: []))
    }

    func test_shouldFilter_singleToken_lowConfidence_returnsTrue() {
        let entries = [Entry(token: "はい", logprob: -0.6)]
        // single token, logprob < -0.5 → true
        XCTAssertTrue(Filter.shouldFilter(logprobs: entries))
    }

    func test_shouldFilter_singleToken_highConfidence_returnsFalse() {
        let entries = [Entry(token: "はい", logprob: -0.3)]
        // single token, logprob >= -0.5 → false
        XCTAssertFalse(Filter.shouldFilter(logprobs: entries))
    }

    func test_shouldFilter_singleToken_exactBoundary_returnsFalse() {
        let entries = [Entry(token: "test", logprob: -0.5)]
        // single token, logprob == -0.5, not < -0.5 → false
        XCTAssertFalse(Filter.shouldFilter(logprobs: entries))
    }

    func test_shouldFilter_customThreshold_usesIt() {
        let entries = [
            Entry(token: "a", logprob: -0.6),
            Entry(token: "b", logprob: -0.8)
        ]
        // average = -0.7
        XCTAssertFalse(Filter.shouldFilter(logprobs: entries, threshold: -1.0))
        XCTAssertTrue(Filter.shouldFilter(logprobs: entries, threshold: -0.5))
    }

    // MARK: - shouldFilter (from JSON obj)

    func test_shouldFilter_fromObj_withLogprobs_filtersCorrectly() {
        let obj: [String: Any] = [
            "type": "conversation.item.input_audio_transcription.completed",
            "transcript": "ありがとう",
            "logprobs": [
                ["token": "ありがとう", "logprob": -2.0]
            ]
        ]
        // single token, -2.0 < -0.5 → true
        XCTAssertTrue(Filter.shouldFilter(from: obj))
    }

    func test_shouldFilter_fromObj_withoutLogprobs_returnsFalse() {
        let obj: [String: Any] = [
            "type": "conversation.item.input_audio_transcription.completed",
            "transcript": "こんにちは"
        ]
        XCTAssertFalse(Filter.shouldFilter(from: obj))
    }

    func test_shouldFilter_fromObj_logprobsWrongType_returnsFalse() {
        let obj: [String: Any] = [
            "transcript": "test",
            "logprobs": "not an array"
        ]
        XCTAssertFalse(Filter.shouldFilter(from: obj))
    }

    func test_shouldFilter_fromObj_highConfidence_returnsFalse() {
        let obj: [String: Any] = [
            "transcript": "会議を始めましょう",
            "logprobs": [
                ["token": "会議を", "logprob": -0.05],
                ["token": "始め", "logprob": -0.1],
                ["token": "ましょう", "logprob": -0.08]
            ]
        ]
        XCTAssertFalse(Filter.shouldFilter(from: obj))
    }
}
