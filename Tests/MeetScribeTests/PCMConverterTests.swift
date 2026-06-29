import XCTest
import AVFoundation
@testable import MeetScribeCore

final class PCMConverterTests: XCTestCase {

    // MARK: - init

    func test_init_validFormat_succeeds() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!
        let converter = PCMConverter(sourceFormat: format)
        XCTAssertNotNil(converter)
    }

    func test_init_targetFormat_is24kHzInt16Mono() {
        XCTAssertEqual(PCMConverter.targetSampleRate, 24_000)
        XCTAssertEqual(PCMConverter.targetChannels, 1)
        XCTAssertEqual(PCMConverter.targetFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(PCMConverter.targetFormat.sampleRate, 24_000)
        XCTAssertEqual(PCMConverter.targetFormat.channelCount, 1)
    }

    // MARK: - convert AVAudioPCMBuffer

    func test_convert_emptyBuffer_returnsNil() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0)!
        buffer.frameLength = 0

        let converter = PCMConverter(sourceFormat: format)!
        let result = converter.convert(buffer)
        XCTAssertNil(result, "Empty buffer should return nil")
    }

    func test_convert_48kHzToTarget_producesData() {
        let buffer = TestHelpers.makeSineBuffer(
            frequency: 440,
            amplitude: 0.5,
            sampleRate: 48000,
            frameCount: 4800  // 100ms at 48kHz
        )
        let converter = PCMConverter(sourceFormat: buffer.format)!
        let data = converter.convert(buffer)

        XCTAssertNotNil(data)
        guard let data = data else { return }

        // Expected: 2400 samples at 24kHz (100ms) * 2 bytes/sample = 4800 bytes
        // Allow some tolerance for resampler rounding
        let expectedBytes = 2400 * 2
        XCTAssertGreaterThan(data.count, expectedBytes - 100)
        XCTAssertLessThan(data.count, expectedBytes + 100)
    }

    func test_convert_44100HzToTarget_producesData() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410  // 100ms at 44.1kHz

        // Fill with sine wave
        if let channelData = buffer.floatChannelData {
            for i in 0..<4410 {
                channelData[0][i] = sinf(2.0 * Float.pi * 440.0 * Float(i) / 44100.0)
            }
        }

        let converter = PCMConverter(sourceFormat: format)!
        let data = converter.convert(buffer)
        XCTAssertNotNil(data)

        // ~2400 samples at 24kHz * 2 bytes
        if let data = data {
            XCTAssertGreaterThan(data.count, 4000)
            XCTAssertLessThan(data.count, 5200)
        }
    }

    func test_convert_24kHzToTarget_noop() {
        // Input already at target rate — conversion should still produce data
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        buffer.frameLength = 2400

        if let channelData = buffer.floatChannelData {
            for i in 0..<2400 {
                channelData[0][i] = sinf(2.0 * Float.pi * 440.0 * Float(i) / 24000.0)
            }
        }

        let converter = PCMConverter(sourceFormat: format)!
        let data = converter.convert(buffer)
        XCTAssertNotNil(data)

        if let data = data {
            // Same rate: 2400 * 2 bytes
            XCTAssertEqual(data.count, 2400 * 2, "Same rate conversion should preserve sample count")
        }
    }

    func test_convert_silentBuffer_returnsData() {
        let buffer = TestHelpers.makeSilentBuffer(sampleRate: 48000, frameCount: 4800)
        let converter = PCMConverter(sourceFormat: buffer.format)!
        let data = converter.convert(buffer)

        XCTAssertNotNil(data)
        if let data = data {
            // Verify all samples are zero (or near-zero)
            data.withUnsafeBytes { bytes in
                let int16s = bytes.bindMemory(to: Int16.self)
                for sample in int16s {
                    XCTAssertEqual(sample, 0, "Silent input should produce zero output")
                }
            }
        }
    }

    func test_convert_outputIsInt16LE() {
        let buffer = TestHelpers.makeSineBuffer(
            frequency: 440,
            amplitude: 0.8,
            sampleRate: 48000,
            frameCount: 4800
        )
        let converter = PCMConverter(sourceFormat: buffer.format)!
        let data = converter.convert(buffer)

        XCTAssertNotNil(data)
        guard let data = data else { return }

        // Int16 output: each sample is 2 bytes
        XCTAssertEqual(data.count % 2, 0, "Output byte count must be even for Int16")

        // Verify some samples are non-zero (signal is present)
        var hasNonZero = false
        data.withUnsafeBytes { bytes in
            let int16s = bytes.bindMemory(to: Int16.self)
            for sample in int16s {
                if sample != 0 { hasNonZero = true; break }
            }
        }
        XCTAssertTrue(hasNonZero, "Sine wave conversion should produce non-zero samples")
    }

    // MARK: - Multiple conversions (converter per-frame creation)

    func test_convert_multipleBuffers_allProduce() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!
        let converter = PCMConverter(sourceFormat: format)!

        for i in 0..<5 {
            let buffer = TestHelpers.makeSineBuffer(
                frequency: Float(440 + i * 100),
                amplitude: 0.5,
                sampleRate: 48000,
                frameCount: 2400
            )
            let data = converter.convert(buffer)
            XCTAssertNotNil(data, "Conversion \(i) should succeed")
        }
    }
}
