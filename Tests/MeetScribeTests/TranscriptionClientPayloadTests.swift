import XCTest
@testable import MeetScribeCore

/// TranscriptionClient.makeSessionUpdatePayload の構造検証。
/// LecTrace 方式 (ストリーミングモデル + VAD 無効 + 手動 commit) と
/// 言語パラメータの有無を保証する。
final class TranscriptionClientPayloadTests: XCTestCase {

    func test_openAIEndpoint_keepsRealtimeTranscriptionIntent() {
        let url = TranscriptionClient.makeEndpoint(provider: .openAI, language: nil)
        XCTAssertEqual(url.absoluteString, "wss://api.openai.com/v1/realtime?intent=transcription")
    }

    func test_xAIEndpoint_hasStreamingConfiguration() {
        let url = TranscriptionClient.makeEndpoint(provider: .xAI, language: "ja")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues:
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(components?.host, "api.x.ai")
        XCTAssertEqual(components?.path, "/v1/stt")
        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["encoding"], "pcm")
        XCTAssertEqual(query["interim_results"], "true")
        XCTAssertEqual(query["endpointing"], "500")
        XCTAssertEqual(query["language"], "ja")
    }

    func test_xAIEndpoint_autoDetect_omitsLanguage() {
        let url = TranscriptionClient.makeEndpoint(provider: .xAI, language: nil)
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.name) ?? [])
        XCTAssertFalse(names.contains("language"))
    }

    private func inputSection(_ payload: [String: Any]) -> [String: Any]? {
        let session = payload["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        return audio?["input"] as? [String: Any]
    }

    func test_payload_usesStreamingWhisperModel() {
        let payload = TranscriptionClient.makeSessionUpdatePayload(language: nil)
        let transcription = inputSection(payload)?["transcription"] as? [String: Any]

        XCTAssertEqual(transcription?["model"] as? String, TranscriptionClient.transcriptionModel)
        XCTAssertEqual(TranscriptionClient.transcriptionModel, "gpt-realtime-whisper")
    }

    func test_payload_turnDetectionDisabled() {
        let payload = TranscriptionClient.makeSessionUpdatePayload(language: nil)
        let turnDetection = inputSection(payload)?["turn_detection"]

        // server_vad 無効化 = JSON では null。NSNull であること。
        XCTAssertTrue(turnDetection is NSNull)
    }

    func test_payload_autoDetect_omitsLanguageKey() {
        let payload = TranscriptionClient.makeSessionUpdatePayload(language: nil)
        let transcription = inputSection(payload)?["transcription"] as? [String: Any]

        XCTAssertNil(transcription?["language"])
    }

    func test_payload_explicitLanguage_isIncluded() {
        for lang in ["ja", "en"] {
            let payload = TranscriptionClient.makeSessionUpdatePayload(language: lang)
            let transcription = inputSection(payload)?["transcription"] as? [String: Any]
            XCTAssertEqual(transcription?["language"] as? String, lang)
        }
    }

    /// gpt-realtime-whisper は prompt パラメータ非対応
    /// (`The 'prompt' parameter is not supported for this model.` で拒否される)。
    func test_payload_omitsUnsupportedPromptKey() {
        let payload = TranscriptionClient.makeSessionUpdatePayload(language: nil)
        let transcription = inputSection(payload)?["transcription"] as? [String: Any]

        XCTAssertNil(transcription?["prompt"])
    }

    func test_payload_sessionTypeIsTranscription() {
        let payload = TranscriptionClient.makeSessionUpdatePayload(language: nil)
        let session = payload["session"] as? [String: Any]

        XCTAssertEqual(payload["type"] as? String, "session.update")
        XCTAssertEqual(session?["type"] as? String, "transcription")
    }

    // MARK: - peakAmplitude (有声判定)

    private func pcmData(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func test_peakAmplitude_silence_isZero() {
        let data = pcmData([Int16](repeating: 0, count: 1_000))
        XCTAssertEqual(TranscriptionClient.peakAmplitude(data), 0)
    }

    func test_peakAmplitude_findsNegativePeak() {
        let data = pcmData([0, 100, -2_000, 500])
        XCTAssertEqual(TranscriptionClient.peakAmplitude(data), 2_000)
    }

    func test_peakAmplitude_int16min_doesNotCrash() {
        let data = pcmData([Int16.min, 0])
        XCTAssertEqual(TranscriptionClient.peakAmplitude(data), Int16.max)
    }

    func test_peakAmplitude_emptyData_isZero() {
        XCTAssertEqual(TranscriptionClient.peakAmplitude(Data()), 0)
    }

    func test_payload_isValidJSON() {
        let payload = TranscriptionClient.makeSessionUpdatePayload(language: "ja")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))

        let data = try? JSONSerialization.data(withJSONObject: payload)
        XCTAssertNotNil(data)
        // null がシリアライズされているか (文字列レベルで確認)
        let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"turn_detection\":null"))
    }
}
