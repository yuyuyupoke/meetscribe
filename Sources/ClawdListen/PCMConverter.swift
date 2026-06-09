import AVFoundation
import CoreMedia
import Foundation

/// 任意のサンプルレート・ビット深度の PCM を OpenAI Realtime API が要求する
/// 24kHz 16bit mono PCM (little-endian) に変換する。
///
/// 重要設計: AVAudioConverter のインスタンスは **毎フレーム新規生成する**。
/// 同一インスタンスを使い回すと、macOS では2回目以降の `convert()` 呼出で
/// 内部 stream state (anti-aliasing filter prime, partial input buffering) が
/// 腐って `outputBuffer.frameLength = 0` を返し続ける症状に遭遇する。
/// `reset()` を呼んでも完全には解消しない (Apple Dev Forum thread/88144 周辺の
/// 既知挙動)。性能オーバーヘッドより信頼性を優先する。
final class PCMConverter {
    static let targetSampleRate: Double = 24_000
    static let targetChannels: AVAudioChannelCount = 1
    static let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: targetChannels,
        interleaved: true
    )!

    let sourceFormat: AVAudioFormat

    init?(sourceFormat: AVAudioFormat) {
        self.sourceFormat = sourceFormat
    }

    /// AVAudioPCMBuffer (任意フォーマット) → 24kHz mono PCM16 LE bytes。
    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        return Self.convertBuffer(buffer)
    }

    /// CMSampleBuffer → 24kHz mono PCM16 LE bytes。
    /// `converterRef` は API 互換のために残してあるが内部では使い回さない。
    static func convert(_ sampleBuffer: CMSampleBuffer, using converterRef: inout PCMConverter?) -> Data? {
        guard let formatDescription = sampleBuffer.formatDescription,
              var asbd = formatDescription.audioStreamBasicDescription else { return nil }
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }
        if converterRef == nil {
            converterRef = PCMConverter(sourceFormat: sourceFormat)
        }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer(format: sourceFormat) else { return nil }
        return convertBuffer(pcmBuffer)
    }

    /// AVAudioPCMBuffer の単発変換。AVAudioConverter は毎回新規生成。
    private static func convertBuffer(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0 else { return nil }
        guard let avConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else { return nil }

        var supplied = false
        var error: NSError?
        let status = avConverter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !supplied {
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            } else {
                // 1チャンク単発処理。残った internal buffer を flush して終了。
                outStatus.pointee = .endOfStream
                return nil
            }
        }
        if status == .error || error != nil {
            DebugLog.log("[pcm-converter] convert failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        guard outputBuffer.frameLength > 0,
              let int16Channel = outputBuffer.int16ChannelData?[0] else { return nil }
        let byteCount = Int(outputBuffer.frameLength) * 2
        return Data(bytes: int16Channel, count: byteCount)
    }
}

extension CMSampleBuffer {
    /// CMSampleBuffer を AVAudioPCMBuffer に変換する (Float32 PCM 前提)
    func toPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let dataBuffer = dataBuffer else { return nil }

        let frameCount = AVAudioFrameCount(numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let src = dataPointer else { return nil }

        if format.commonFormat == .pcmFormatFloat32 {
            if format.isInterleaved {
                if let dst = pcmBuffer.floatChannelData?[0] {
                    memcpy(dst, src, totalLength)
                }
            } else {
                let channels = Int(format.channelCount)
                let bytesPerChannel = totalLength / channels
                for ch in 0..<channels {
                    if let dst = pcmBuffer.floatChannelData?[ch] {
                        memcpy(dst, src.advanced(by: ch * bytesPerChannel), bytesPerChannel)
                    }
                }
            }
        }
        return pcmBuffer
    }
}
