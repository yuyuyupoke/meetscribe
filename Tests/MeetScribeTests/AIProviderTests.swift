import XCTest
@testable import MeetScribeCore

final class AIProviderTests: XCTestCase {
    func test_providers_useSeparateKeychainAccounts() {
        XCTAssertEqual(AIProvider.openAI.keychainAccount, "openai-api-key")
        XCTAssertEqual(AIProvider.xAI.keychainAccount, "xai-api-key")
        XCTAssertNotEqual(AIProvider.openAI.keychainAccount, AIProvider.xAI.keychainAccount)
    }

    func test_modelsAndSampleRates_matchProviderConfiguration() {
        XCTAssertEqual(AIProvider.openAI.transcriptionModel, "gpt-realtime-whisper")
        XCTAssertEqual(AIProvider.openAI.chatModel, "gpt-4.1-mini")
        XCTAssertEqual(AIProvider.openAI.transcriptionSampleRate, 24_000)

        XCTAssertEqual(AIProvider.xAI.transcriptionModel, "Grok Speech to Text")
        XCTAssertEqual(AIProvider.xAI.chatModel, "grok-4.3")
        XCTAssertEqual(AIProvider.xAI.transcriptionSampleRate, 16_000)
    }

    func test_xAIChatEndpoint_isOfficialAPIHost() {
        XCTAssertEqual(AIProvider.xAI.chatEndpoint.host, "api.x.ai")
        XCTAssertEqual(AIProvider.xAI.chatEndpoint.path, "/v1/chat/completions")
    }
}
