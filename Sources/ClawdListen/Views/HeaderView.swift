import SwiftUI
import AppKit

/// 小窓上部のヘッダー。VUメーター、コスト、録音/停止、Kill Switchを右寄せで配置。
/// 左側の空白はウィンドウドラッグ領域を兼ねる。
struct HeaderView: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 10) {
            // 左側はドラッグ用の空白
            Spacer()
            knowledgeFolderButton
            VUMeterView(state: state)
            reconnectBadge
            costLabel
            captureButton
            killSwitch
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// 知識源フォルダの選択/変更ボタン。アイコン + フォルダ名 (lastPathComponent) を
    /// 常時表示。マウスオーバーでフルパス (tilde 短縮) が tooltip に出る。
    private var knowledgeFolderButton: some View {
        Button(action: selectKnowledgeFolder) {
            HStack(spacing: 3) {
                Image(systemName: state.knowledgeFolderURL == nil
                      ? "folder.badge.plus"
                      : "folder.fill")
                    .foregroundStyle(state.knowledgeFolderURL == nil ? Color.gray : Color.blue)
                    .font(.system(size: 12))
                if let url = state.knowledgeFolderURL {
                    Text(url.lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120)
                }
            }
        }
        .buttonStyle(.plain)
        .help(state.knowledgeFolderURL
              .map { "知識源フォルダ: \(Self.tildePath($0))（クリックで変更）" }
              ?? "知識源フォルダを選択（Q&A時にClaudeが参照）")
    }

    /// ホームディレクトリを `~` に短縮したパス表記を返す。
    static func tildePath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func selectKnowledgeFolder() {
        let panel = NSOpenPanel()
        panel.title = "知識源フォルダを選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            state.knowledgeFolderURL = url
        }
    }

    /// 現セッションでの OpenAI 累計コスト。0 でも常時表示してユーザーが
    /// 「課金状況が見えてる」感覚を持てるようにする。
    private var costLabel: some View {
        Text(String(format: "$%.4f", state.totalCostUSD))
            .font(.system(size: 10, weight: .regular).monospacedDigit())
            .foregroundStyle(state.totalCostUSD > 0 ? .secondary : Color.secondary.opacity(0.5))
            .help("このセッションでの OpenAI API 累計課金 (アプリ再起動でリセット)")
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
        return "OpenAI Realtime API のセッション上限に達したため再接続中です: \(names)"
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
                .help(state.canStart ? "録音開始" : "セットアップが必要")
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
