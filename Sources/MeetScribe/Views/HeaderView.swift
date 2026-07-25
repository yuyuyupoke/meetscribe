import SwiftUI
import AppKit

/// 小窓上部のヘッダー。VUメーター、コスト、録音/停止、Kill Switchを右寄せで配置。
/// 左側の空白はウィンドウドラッグ領域を兼ねる。
struct HeaderView: View {
    let state: AppState
    @State private var showAISettings = false

    var body: some View {
        HStack(spacing: 10) {
            // 左側はドラッグ用の空白
            Spacer()
            aiSettingsButton
            muteButton(
                speaker: .me,
                activeIcon: "mic.fill",
                mutedIcon: "mic.slash.fill"
            )
            muteButton(
                speaker: .other,
                activeIcon: "speaker.wave.2.fill",
                mutedIcon: "speaker.slash.fill"
            )
            VUMeterView(state: state)
            reconnectBadge
            costLabel
            captureButton
            killSwitch
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// 現セッションでの選択中AIプロバイダーの累計コスト。0 でも常時表示してユーザーが
    /// 「課金状況が見えてる」感覚を持てるようにする。
    private var costLabel: some View {
        Text(String(format: "$%.4f", state.totalCostUSD))
            .font(.scaled(10, weight: .regular).monospacedDigit())
            .foregroundStyle(state.totalCostUSD > 0 ? .secondary : Color.secondary.opacity(0.5))
            .help("このセッションでのAI API累計課金（会議開始時にリセット）")
    }

    /// 初期設定完了後も常にアクセスできるAI設定。
    /// プロバイダーの変更は次回会議から適用し、録音中だけロックする。
    private var aiSettingsButton: some View {
        Button(action: { showAISettings.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.scaled(11))
                Text("AI: \(state.selectedProvider.shortDisplayName)")
                    .font(.scaled(10, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.scaled(7, weight: .semibold))
            }
            .foregroundStyle(state.hasAPIKey ? Color.primary : Color.orange)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("ai-settings-button")
        .accessibilityValue(state.selectedProvider.rawValue)
        .help("AIプロバイダーとAPIキーを変更")
        .popover(isPresented: $showAISettings, arrowEdge: .top) {
            aiSettingsPopover
        }
    }

    private var aiSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI設定")
                .font(.scaled(13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("会議に使うプロバイダー")
                    .font(.scaled(10, weight: .medium))
                HStack(spacing: 6) {
                    ForEach(AIProvider.allCases) { provider in
                        providerSelectionButton(provider)
                    }
                }

                Text(state.canChangeProvider
                     ? "変更は次回の会議開始から適用されます。"
                     : "現在の会議には影響せず、変更は次回の会議から適用されます。")
                    .font(.scaled(9))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("API Keys")
                .font(.scaled(11, weight: .semibold))
            ForEach(AIProvider.allCases) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: state.hasAPIKey(for: provider)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(state.hasAPIKey(for: provider) ? Color.green : .secondary)
                        Text(provider.displayName)
                            .font(.scaled(10, weight: .medium))
                        Spacer()
                        Text(state.hasAPIKey(for: provider) ? "設定済み" : "未設定")
                            .font(.scaled(9))
                            .foregroundStyle(.secondary)
                    }
                    APIKeyEditorView(
                        state: state,
                        provider: provider,
                        fieldWidth: 280
                    )
                }
                if provider != AIProvider.allCases.last { Divider() }
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    /// Pickerの無効状態が選択を妨げないよう、各プロバイダーを明示的なボタンにする。
    /// 録音中に選択してもAudioSessionのactiveProviderは変わらず、次回会議から反映される。
    private func providerSelectionButton(_ provider: AIProvider) -> some View {
        let isSelected = state.selectedProvider == provider
        return Button(action: { state.selectedProvider = provider }) {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                Text(provider.displayName)
                    .font(.scaled(10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.displayName)
        .accessibilityIdentifier("provider-\(provider.rawValue)")
        .accessibilityValue(isSelected ? "selected" : "not-selected")
        .help("次回の会議で\(provider.displayName)を使用")
    }

    /// ストリーム別ミュート (Scribe に聴かせない)。ハイブリッド会議で部屋の発話が
    /// マイクと Zoom 経由の両方から二重に文字起こしされるとき、片側を止める用途。
    /// 録音中でなくても切り替え可能 (録音開始直後から効く)。録音終了時に自動解除。
    private func muteButton(
        speaker: SpeakerLabel,
        activeIcon: String,
        mutedIcon: String
    ) -> some View {
        let isMuted = state.mutedStreams.contains(speaker)
        return Button(action: { state.toggleMute(speaker) }) {
            Image(systemName: isMuted ? mutedIcon : activeIcon)
                .foregroundStyle(isMuted ? Color.orange : Color.secondary)
                .font(.scaled(12))
                .frame(width: 16)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mute-\(speaker.rawValue)")
        .accessibilityLabel("\(speaker.displayName)の音声を文字起こしから除外")
        .accessibilityValue(isMuted ? "muted" : "active")
        .help(isMuted
              ? "[\(speaker.displayName)] ミュート中: この音は文字起こしされません（クリックで再開）"
              : "[\(speaker.displayName)] の音を文字起こしから除外する（対面+オンライン同時参加で二重記録される時に）")
    }

    /// 再接続中のストリームを🔄バッジで表示。Realtime API の ~30-60分セッション上限で
    /// WebSocket が切れたとき、AudioSession が自動再接続している間表示される。
    @ViewBuilder
    private var reconnectBadge: some View {
        if !state.reconnectingStreams.isEmpty {
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text("再接続中")
                    .font(.scaled(9))
                    .foregroundStyle(.orange)
            }
            .help(Self.reconnectTooltip(streams: state.reconnectingStreams))
        }
    }

    /// 再接続バッジの tooltip 文言を組み立てる。文字列補間ネストの可読性確保用。
    private static func reconnectTooltip(streams: Set<SpeakerLabel>) -> String {
        let names = streams.map(\.displayName).joined(separator: ", ")
        return "文字起こしAPIへ再接続中です: \(names)"
    }

    @ViewBuilder
    private var captureButton: some View {
        if state.isSavingMeeting {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("保存中…")
                    .font(.scaled(9))
                    .foregroundStyle(.secondary)
            }
        } else {
            switch state.captureStatus {
            case .idle, .error:
                Button(action: { Task { await AudioSession.shared.start() } }) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(state.canStart ? .red : .gray)
                        .font(.scaled(16))
                }
                .buttonStyle(.plain)
                .disabled(!state.canStart)
                .help(state.canStart ? "録音開始" : (state.startBlockReason ?? "セットアップが必要"))
            case .starting, .stopping:
                ProgressView().controlSize(.small)
            case .running:
                Button(action: { Task { await AudioSession.shared.stop() } }) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                        .font(.scaled(16))
                }
                .buttonStyle(.plain)
                .help("録音停止 & 議事録保存")
            }
        }
    }

    private var killSwitch: some View {
        Button(action: { Task { await AudioSession.shared.kill() } }) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red.opacity(state.isRunning ? 1.0 : 0.3))
                .font(.scaled(16))
        }
        .buttonStyle(.plain)
        .disabled(!state.isRunning)
        .help("Kill Switch（緊急停止・保存せず）")
    }
}
