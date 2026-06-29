import AVFoundation
import XCTest

enum TestHelpers {
    /// Create a mono Float32 PCM buffer filled with a sine wave.
    static func makeSineBuffer(
        frequency: Float = 440.0,
        amplitude: Float = 1.0,
        sampleRate: Double = 48000.0,
        frameCount: AVAudioFrameCount = 1024
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else { return buffer }
        let ptr = channelData[0]
        for i in 0..<Int(frameCount) {
            let phase = 2.0 * Float.pi * frequency * Float(i) / Float(sampleRate)
            ptr[i] = amplitude * sinf(phase)
        }
        return buffer
    }

    /// Create a mono Float32 PCM buffer filled with silence (all zeros).
    static func makeSilentBuffer(
        sampleRate: Double = 48000.0,
        frameCount: AVAudioFrameCount = 1024
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Already zeroed by default
        return buffer
    }

    /// Create a mono Float32 PCM buffer filled with white noise.
    static func makeNoiseBuffer(
        amplitude: Float = 0.5,
        sampleRate: Double = 48000.0,
        frameCount: AVAudioFrameCount = 1024
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else { return buffer }
        let ptr = channelData[0]
        // Deterministic pseudo-random for reproducibility
        var seed: UInt32 = 42
        for i in 0..<Int(frameCount) {
            seed = seed &* 1664525 &+ 1013904223
            let normalized = Float(seed) / Float(UInt32.max) * 2.0 - 1.0
            ptr[i] = amplitude * normalized
        }
        return buffer
    }

    /// Create a mono Float32 PCM buffer with constant value.
    static func makeConstantBuffer(
        value: Float,
        sampleRate: Double = 48000.0,
        frameCount: AVAudioFrameCount = 1024
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else { return buffer }
        let ptr = channelData[0]
        for i in 0..<Int(frameCount) {
            ptr[i] = value
        }
        return buffer
    }

    /// Create a stereo Float32 PCM buffer with sine waves (different frequencies per channel).
    static func makeStereoSineBuffer(
        frequency1: Float = 440.0,
        frequency2: Float = 880.0,
        amplitude: Float = 1.0,
        sampleRate: Double = 48000.0,
        frameCount: AVAudioFrameCount = 1024
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else { return buffer }
        for i in 0..<Int(frameCount) {
            let phase1 = 2.0 * Float.pi * frequency1 * Float(i) / Float(sampleRate)
            let phase2 = 2.0 * Float.pi * frequency2 * Float(i) / Float(sampleRate)
            channelData[0][i] = amplitude * sinf(phase1)
            channelData[1][i] = amplitude * sinf(phase2)
        }
        return buffer
    }

    /// Create an empty buffer (frameLength = 0).
    static func makeEmptyBuffer(sampleRate: Double = 48000.0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0)!
        buffer.frameLength = 0
        return buffer
    }
}
