import SwiftUI
import AppKit

/// 画面下部に常時表示するフッター。議事録の保存先と知識源フォルダのパスを
/// 表示し、それぞれ GUI でいつでも変更できる。
struct SettingsFooterView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            folderControl(
                icon: state.meetingsSaveDirectoryURL == nil ? "exclamationmark.triangle.fill" : "tray.full.fill",
                label: "議事録",
                url: state.meetingsSaveDirectoryURL,
                tint: state.meetingsSaveDirectoryURL == nil ? .orange : .green,
                onChange: selectMeetingsFolder,
                onClear: nil
            )
            Divider().frame(height: 12)
            folderControl(
                icon: state.knowledgeFolderURL == nil ? "folder.badge.plus" : "folder.fill",
                label: "参照",
                url: state.knowledgeFolderURL,
                tint: state.knowledgeFolderURL == nil ? Color.gray : .blue,
                onChange: selectKnowledgeFolder,
                onClear: { state.knowledgeFolderURL = nil }
            )
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func folderControl(
        icon: String,
        label: String,
        url: URL?,
        tint: Color,
        onChange: @escaping () -> Void,
        onClear: (() -> Void)?
    ) -> some View {
        HStack(spacing: 4) {
            // アイコン + ラベル + パス全体がクリック可能。押すとフォルダ選択ダイアログ。
            Button(action: onChange) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .font(.system(size: 12))
                    Text("\(label):")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let url {
                        Text(Self.tildePath(url))
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.primary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .leading)
                    } else {
                        Text("未設定")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url.map { "\(label): \($0.path)（クリックで変更）" } ?? "\(label)フォルダを選択")

            // 解除（任意フォルダのみ）。xmark アイコンで文言なし。
            if let onClear, url != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("\(label)フォルダを解除")
            }
        }
    }

    static func tildePath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func selectMeetingsFolder() {
        let panel = NSOpenPanel()
        panel.title = "議事録の保存先フォルダを選択"
        panel.message = "録音停止時に Markdown 形式の議事録がここに保存されます"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            state.meetingsSaveDirectoryURL = url
        }
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
}
