import AVFoundation
import Accelerate

/// RMS ベースのノイズゲート。ヒステリシス付きで環境ノイズを除去する。
///
/// 設計:
///   * open/close に異なる閾値を使い、チャタリング（高速な開閉の繰り返し）を防止
///   * attack/release でゲインを 0↔1 にスムーズに遷移させ、クリックノイズを回避
///   * `@unchecked Sendable`: オーディオスレッド（シリアルキュー）から呼ばれる前提
final class NoiseGate: @unchecked Sendable {
    struct Config: Sendable {
        /// ゲートを開く閾値 (dBFS)。この値より大きい RMS で開く
        var openThresholdDB: Float
        /// ゲートを閉じる閾値 (dBFS)。この値より小さい RMS で閉じる
        var closeThresholdDB: Float
        /// ゲートが開くまでの遷移時間 (ms)
        var attackMs: Float
        /// ゲートが閉じるまでの遷移時間 (ms)
        var releaseMs: Float
        /// 閉じ条件 (RMS < closeThresholdDB) が成立してから実際に閉じ始める (releaseへ移行する)
        /// までの保持時間 (ms)。xAI streaming STT は endpointing=500ms の無音でしか
        /// speech_final を発火しないため、ゲートが発話終了直後に送信を止めてしまうと
        /// サーバー側が500ms無音を観測できず speech_final が発火しにくくなる。
        /// hold で発話終了後も最低このms間は送信を継続することでそれを防ぐ
        var holdMs: Float = 0

        /// マイク用デフォルト: Voice Processing (AGC+NS) 後の信号は低レベルなため閾値を緩く
        static let microphone = Config(
            openThresholdDB: -55.0,
            closeThresholdDB: -60.0,
            attackMs: 5.0,
            releaseMs: 50.0,
            holdMs: 1000.0
        )

        /// システム音用デフォルト: ScreenCaptureKit 経由はレベルが安定
        static let systemAudio = Config(
            openThresholdDB: -60.0,
            closeThresholdDB: -65.0,
            attackMs: 5.0,
            releaseMs: 30.0,
            holdMs: 1000.0
        )
    }

    enum GateState: Sendable {
        case closed
        case opening
        case open
        case closing
    }

    let config: Config
    private(set) var state: GateState = .closed
    private var currentGain: Float = 0.0

    /// 連続してゲートが閉じたフレーム数（統計・デバッグ用）
    private var consecutiveClosedFrames: Int = 0
    private var totalFrames: Int = 0
    private var gatedFrames: Int = 0

    /// `.open` 状態で閉じ条件が成立してから経過したホールド時間 (ms)
    private var holdElapsedMs: Float = 0

    init(config: Config = .microphone) {
        self.config = config
    }

    /// PCM バッファを処理。ゲートが閉じていれば nil を返す（送信スキップ）。
    /// ゲートが開いていればバッファをそのまま返す。
    /// 遷移中はゲインを適用したバッファを返す。
    func process(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> AVAudioPCMBuffer? {
        totalFrames += 1
        let rmsDB = rmsInDB(buffer)
        let frameDurationMs = Float(buffer.frameLength) / Float(sampleRate) * 1000.0
        updateState(rmsDB: rmsDB, frameDurationMs: frameDurationMs)
        updateGain(frameDurationMs: frameDurationMs)

        switch state {
        case .closed:
            gatedFrames += 1
            consecutiveClosedFrames += 1
            logPeriodically()
            return nil

        case .open:
            consecutiveClosedFrames = 0
            logPeriodically()
            return buffer

        case .opening, .closing:
            consecutiveClosedFrames = 0
            logPeriodically()
            return applyGain(to: buffer)
        }
    }

    /// 統計をリセット
    func resetStats() {
        totalFrames = 0
        gatedFrames = 0
        consecutiveClosedFrames = 0
    }

    /// ゲート率（0.0〜1.0、1.0 = 全フレームがゲートされた）
    var gateRatio: Float {
        guard totalFrames > 0 else { return 0 }
        return Float(gatedFrames) / Float(totalFrames)
    }

    /// hold中 (閉じ条件成立後、holdMs経過前でopenを維持し送信継続中) かどうか。
    /// hold中に流れるバッファは無音/定常音であることが多いため、AudioPreProcessor が
    /// SpectralAnalyzer の判定をバイパスするかどうかの参照に使う
    /// (バイパスしないとhold自体がスペクトル解析側で無効化されてしまう)
    var isInHold: Bool {
        state == .open && holdElapsedMs > 0
    }

    // MARK: - Internal

    private func rmsInDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return -100.0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -100.0 }

        var rms: Float = 0.0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frames))

        guard rms > 0 else { return -100.0 }
        return 20.0 * log10f(rms)
    }

    private func updateState(rmsDB: Float, frameDurationMs: Float) {
        switch state {
        case .closed, .closing:
            holdElapsedMs = 0
            if rmsDB >= config.openThresholdDB {
                state = .opening
            }
        case .opening:
            // openへ遷移しきる前に音量が落ちた場合はholdを待たず即座にcloseへ戻す
            // (attack中の短いブリップに対してholdを適用する意味はないため)
            if rmsDB < config.closeThresholdDB {
                state = .closing
            }
        case .open:
            if rmsDB < config.closeThresholdDB {
                holdElapsedMs += frameDurationMs
                if holdElapsedMs >= config.holdMs {
                    state = .closing
                    holdElapsedMs = 0
                }
            } else {
                holdElapsedMs = 0
            }
        }
    }

    private func updateGain(frameDurationMs: Float) {
        switch state {
        case .opening:
            let step = frameDurationMs / max(config.attackMs, 0.1)
            currentGain = min(1.0, currentGain + step)
            if currentGain >= 1.0 {
                state = .open
            }
        case .closing:
            let step = frameDurationMs / max(config.releaseMs, 0.1)
            currentGain = max(0.0, currentGain - step)
            if currentGain <= 0.0 {
                state = .closed
            }
        case .open:
            currentGain = 1.0
        case .closed:
            currentGain = 0.0
        }
    }

    private func applyGain(to buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let channelData = buffer.floatChannelData else { return buffer }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        // In-place ゲイン適用。VU メーター更新は呼び出し元で先に行われるため安全。
        for ch in 0..<channels {
            var gain = currentGain
            vDSP_vsmul(channelData[ch], 1, &gain, channelData[ch], 1, vDSP_Length(frames))
        }
        return buffer
    }

    private func logPeriodically() {
        if totalFrames == 1 || totalFrames % 500 == 0 {
            DebugLog.log("[noise-gate] frames=\(totalFrames) gated=\(gatedFrames) ratio=\(String(format: "%.1f%%", gateRatio * 100)) state=\(state)")
        }
    }
}
