import XCTest
@testable import MeetScribeCore

final class CostTrackerTests: XCTestCase {

    // MARK: - cost() calculation

    func test_cost_allZeroTokens_returnsZero() {
        let result = CostTracker.cost(textInputTokens: 0, audioInputTokens: 0, outputTokens: 0)
        XCTAssertEqual(result, 0.0, accuracy: 1e-12)
    }

    func test_cost_textInputOnly_calculatesCorrectly() {
        // 1M text input tokens = $2.50
        let result = CostTracker.cost(textInputTokens: 1_000_000, audioInputTokens: 0, outputTokens: 0)
        XCTAssertEqual(result, 2.50, accuracy: 0.001)
    }

    func test_cost_audioInputOnly_calculatesCorrectly() {
        // 1M audio input tokens = $6.00
        let result = CostTracker.cost(textInputTokens: 0, audioInputTokens: 1_000_000, outputTokens: 0)
        XCTAssertEqual(result, 6.00, accuracy: 0.001)
    }

    func test_cost_outputOnly_calculatesCorrectly() {
        // 1M output tokens = $10.00
        let result = CostTracker.cost(textInputTokens: 0, audioInputTokens: 0, outputTokens: 1_000_000)
        XCTAssertEqual(result, 10.00, accuracy: 0.001)
    }

    func test_cost_mixedTokens_calculatesCorrectly() {
        let result = CostTracker.cost(textInputTokens: 100, audioInputTokens: 200, outputTokens: 50)
        let expected = 100.0 * 2.50 / 1_000_000
                     + 200.0 * 6.00 / 1_000_000
                     + 50.0 * 10.00 / 1_000_000
        XCTAssertEqual(result, expected, accuracy: 1e-10)
    }

    func test_cost_typicalTranscriptionEvent_smallCost() {
        // Typical: ~1 text, ~52 audio, ~31 output
        let result = CostTracker.cost(textInputTokens: 1, audioInputTokens: 52, outputTokens: 31)
        XCTAssertGreaterThan(result, 0)
        XCTAssertLessThan(result, 0.001, "Single transcription event should cost < $0.001")
    }

    // MARK: - extractCost() from JSON dict

    func test_extractCost_validUsageDict_extractsCorrectly() {
        let usage: [String: Any] = [
            "input_tokens": 53,
            "input_token_details": [
                "text_tokens": 1,
                "audio_tokens": 52
            ],
            "output_tokens": 31
        ]

        let result = CostTracker.extractCost(from: usage)
        let expected = CostTracker.cost(textInputTokens: 1, audioInputTokens: 52, outputTokens: 31)
        XCTAssertEqual(result, expected, accuracy: 1e-12)
    }

    func test_extractCost_emptyDict_returnsZero() {
        let result = CostTracker.extractCost(from: [:])
        XCTAssertEqual(result, 0.0, accuracy: 1e-12)
    }

    func test_extractCost_missingDetails_treatsAsZero() {
        let usage: [String: Any] = [
            "output_tokens": 100
        ]
        let result = CostTracker.extractCost(from: usage)
        // Only output_tokens counted
        let expected = CostTracker.cost(textInputTokens: 0, audioInputTokens: 0, outputTokens: 100)
        XCTAssertEqual(result, expected, accuracy: 1e-12)
    }

    func test_extractCost_missingOutputTokens_treatsAsZero() {
        let usage: [String: Any] = [
            "input_token_details": [
                "text_tokens": 10,
                "audio_tokens": 20
            ]
        ]
        let result = CostTracker.extractCost(from: usage)
        let expected = CostTracker.cost(textInputTokens: 10, audioInputTokens: 20, outputTokens: 0)
        XCTAssertEqual(result, expected, accuracy: 1e-12)
    }

    func test_extractCost_wrongTypes_treatsAsZero() {
        let usage: [String: Any] = [
            "output_tokens": "not_a_number",
            "input_token_details": "not_a_dict"
        ]
        let result = CostTracker.extractCost(from: usage)
        XCTAssertEqual(result, 0.0, accuracy: 1e-12)
    }

    // MARK: - Rate constants

    func test_rates_matchDocumentedPricing() {
        XCTAssertEqual(CostTracker.textInputRate, 2.50 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(CostTracker.audioInputRate, 6.00 / 1_000_000, accuracy: 1e-15)
        XCTAssertEqual(CostTracker.outputRate, 10.00 / 1_000_000, accuracy: 1e-15)
    }
}
