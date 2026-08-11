import Foundation

/// マイク tap の途絶 (= AVAudioEngine の無警告死) を判定するポリシー。
///
/// 潰した事故 (2026-08-11 監査 Q2): AVAudioEngine は入力デバイスの切替や
/// ヘッドホンの挿抜で構成変化が起きると stop + uninitialize されることがある。
/// この時 tap は二度と呼ばれないのに `MicrophoneCapture.isRunning` は true、
/// `captureStatus` は `.running`、`lastError` は nil のままなので、
/// **講義が無音のまま終わる**。生音声はどこにも永続化していないので復元元がゼロ
/// = 1コマが不可逆に消える。相手ストリーム (SCStream) には `onUnexpectedStop`
/// 経由の自動復帰があるのに、マイク側は検知ゼロという非対称を埋める。
///
/// 判定は「ハードウェア tap がバッファを渡してきた時刻」だけを見る。ミュートや
/// ノイズゲートはどちらも tap より**下流**なので、無音の講義室でも tap は
/// 21ms 周期で届き続ける (= `SilenceDetector` のようにレベル閾値へ依存しない)。
enum MicrophoneTapWatchdog {
    /// tap の途絶を「マイクが死んだ」と判定するまでの秒数。**閾値はこの1箇所だけで持つ。**
    ///
    /// 根拠: 正常時の tap 周期は 1024フレーム / 48kHz ≈ 21ms なので、5秒の空白は
    /// 桁で異常。失う音声も engine 再起動の実測 ~0.2秒に留まる。
    /// **実運用で要検証**: 講義後アイドル時の挙動 (省電力でのバッファ間隔の伸び等) は
    /// まだ実測していないので、誤発火が出たらこの値を伸ばす。
    static let stallThresholdSeconds: TimeInterval = 5

    /// 監視のポーリング間隔。閾値より細かくないと検知が最大2倍遅れる。
    static let pollIntervalSeconds: TimeInterval = 1

    /// 1セッションで許す engine 再起動の回数上限。入力デバイスが消えた
    /// (Bluetooth が切れた等) 場合は再起動しても復活しないため、無限リトライで
    /// ログとメインスレッドを消費し続けないよう有限で打ち切り、以降はバナーを残す。
    /// tap が戻ってきたら呼び出し側がカウンタを 0 に戻す。
    static let maxRestartAttempts = 5

    /// tap が途絶したか (= engine を再起動すべきか) の判定。
    ///
    /// - Parameters:
    ///   - secondsSinceLastTap: 最後に tap がバッファを渡してからの経過秒。
    ///     `nil` (未開始 / 停止中 / 再起動中) は「判断材料なし」として発火しない。
    ///   - isMuted: マイクの Scribe ミュート状態。ミュートは tap より下流で
    ///     フレームを捨てるだけなので本来 tap は届き続けるが、上流の記録位置が
    ///     将来ずれても誤発火しないよう明示的に弾く (ミュート中の再起動は
    ///     「黙っているだけ」を「壊れた」と誤診して音声を刻む)。
    ///   - isRunning: 録音中か。停止・保存フロー中は監視しない。
    static func isStalled(
        secondsSinceLastTap: TimeInterval?,
        isMuted: Bool,
        isRunning: Bool,
        threshold: TimeInterval = stallThresholdSeconds
    ) -> Bool {
        guard isRunning, !isMuted, let elapsed = secondsSinceLastTap else { return false }
        return elapsed >= threshold
    }
}
