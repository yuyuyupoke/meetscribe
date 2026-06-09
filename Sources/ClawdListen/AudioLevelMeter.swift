import AVFoundation
import CoreMedia
import Accelerate

/// PCM バッファから 0.0〜1.0 に正規化されたレベル値を計算する。
/// RMS を dBFS に変換し、-60dB 以下を 0、0dB を 1 にマップ。
enum AudioLevelMeter {
    static let silenceFloorDB: Float = -60.0

    static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0.0 }

        var rms: Float = 0.0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frames))

        return dbToNormalized(dbFromRMS(rms))
    }

    static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return 0.0 }
        guard let format = sampleBuffer.formatDescription,
              let asbd = format.audioStreamBasicDescription else { return 0.0 }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, totalLength > 0 else { return 0.0 }

        // Float32 前提 (ScreenCaptureKit のデフォルト)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bytesPerSample = Int(asbd.mBitsPerChannel) / 8
        guard isFloat, bytesPerSample == 4 else { return 0.0 }

        let sampleCount = totalLength / bytesPerSample
        guard sampleCount > 0 else { return 0.0 }

        let floatPtr = ptr.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }
        var rms: Float = 0.0
        vDSP_rmsqv(floatPtr, 1, &rms, vDSP_Length(sampleCount))

        return dbToNormalized(dbFromRMS(rms))
    }

    private static func dbFromRMS(_ rms: Float) -> Float {
        guard rms > 0 else { return silenceFloorDB }
        return 20.0 * log10f(rms)
    }

    private static func dbToNormalized(_ db: Float) -> Float {
        let clamped = max(silenceFloorDB, min(0.0, db))
        return (clamped - silenceFloorDB) / -silenceFloorDB
    }
}
