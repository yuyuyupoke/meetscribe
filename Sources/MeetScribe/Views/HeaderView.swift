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
            .font(.system(size: 10, weight: .regular).monospacedDigit())
            .foregroundStyle(state.totalCostUSD > 0 ? .secondary : Color.secondary.opacity(0.5))
            .help("このセッションでのAI API累計課金（会議開始時にリセット）")
    }

    /// 初期設定完了後も常にアクセスできるAI設定。
    /// プロバイダーの変更は次回会議から適用し、録音中だけロックする。
    private var aiSettingsButton: some View {
        Button(action: { showAISettings.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 11))
                Text("AI: \(state.selectedProvider.shortDisplayName)")
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
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
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("会議に使うプロバイダー")
                    .font(.system(size: 10, weight: .medium))
                HStack(spacing: 6) {
                    ForEach(AIProvider.allCases) { provider in
                        providerSelectionButton(provider)
                    }
                }

                Text(state.canChangeProvider
                     ? "変更は次回の会議開始から適用されます。"
                     : "現在の会議には影響せず、変更は次回の会議から適用されます。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("API Keys")
                .font(.system(size: 11, weight: .semibold))
            ForEach(AIProvider.allCases) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: state.hasAPIKey(for: provider)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(state.hasAPIKey(for: provider) ? Color.green : .secondary)
                        Text(provider.displayName)
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text(state.hasAPIKey(for: provider) ? "設定済み" : "未設定")
                            .font(.system(size: 9))
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
                    .font(.system(size: 10, weight: .medium))
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

    /// 再接続中のストリームを🔄バッジで表示。Realtime API の ~30-60分セッション上限で
    /// WebSocket が切れたとき、AudioSession が自動再接続している間表示される。
    @ViewBuilder
    private var reconnectBadge: some View {
        if !state.reconnectingStreams.isEmpty {
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text("再接続中")
                    .font(.system(size: 9))
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
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        } else {
            switch state.captureStatus {
            case .idle, .error:
                Button(action: { Task { await AudioSession.shared.start() } }) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(state.canStart ? .red : .gray)
                        .font(.system(size: 16))
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
                        .font(.system(size: 16))
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
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .disabled(!state.isRunning)
        .help("Kill Switch（緊急停止・保存せず）")
    }
}
