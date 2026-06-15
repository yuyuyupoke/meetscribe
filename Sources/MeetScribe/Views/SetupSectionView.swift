import SwiftUI
import AppKit

/// 初回セットアップ (権限 + API Key 入力 + 知識源フォルダ) セクション。
/// すべて許可されて API Key も設定済みなら ContentView 側で非表示になる。
struct SetupSectionView: View {
    let state: AppState
    @Binding var apiKeyInput: String
    @Binding var hasAPIKey: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("⚙️ 初回セットアップ")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { PermissionManager.refreshAll() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("権限状態を再チェック")
            }
            permissionRow(
                label: "マイク",
                current: state.microphonePermission,
                action: requestMic
            )
            permissionRow(
                label: "画面収録 (システム音声)",
                current: state.screenRecordingPermission,
                action: requestScreen
            )
            apiKeyRow
            meetingsFolderRow
            knowledgeFolderRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 議事録保存先フォルダ行 (必須)

    @ViewBuilder
    private var meetingsFolderRow: some View {
        HStack {
            Image(systemName: state.meetingsSaveDirectoryURL == nil
                  ? "exclamationmark.triangle.fill"
                  : "tray.full.fill")
                .foregroundStyle(state.meetingsSaveDirectoryURL == nil ? Color.orange : Color.green)
            Text("議事録の保存先 (必須)")
                .font(.system(size: 11))
            Spacer()
            if let url = state.meetingsSaveDirectoryURL {
                Text(Self.tildePath(url))
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .help(url.path)
                Button("変更") { selectMeetingsFolder() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            } else {
                Button("選択") { selectMeetingsFolder() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            }
        }
        .help("録音停止時に議事録 (Markdown) を書き出すフォルダ。設定するまで録音は開始できません。")
    }

    /// ホームディレクトリを `~` に短縮した表示用パス。
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

    // MARK: - 知識源フォルダ行 (任意)

    @ViewBuilder
    private var knowledgeFolderRow: some View {
        HStack {
            Image(systemName: state.knowledgeFolderURL == nil ? "folder.badge.questionmark" : "folder.fill")
                .foregroundStyle(state.knowledgeFolderURL == nil ? Color.gray : Color.blue)
            Text("知識源フォルダ (任意)")
                .font(.system(size: 11))
            Spacer()
            if let url = state.knowledgeFolderURL {
                Text(Self.tildePath(url))
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .help(url.path)
                Button("変更") { selectKnowledgeFolder() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                Button("解除") {
                    state.knowledgeFolderURL = nil
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            } else {
                Button("選択") { selectKnowledgeFolder() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            }
        }
        .help("会議中の Q&A で Claude が参照する知識源フォルダ (md/txt 等)。未指定なら Web 情報のみで回答する。")
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

    // MARK: - 権限行

    private func permissionRow(
        label: String,
        current: PermissionState,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: iconName(for: current))
                .foregroundStyle(color(for: current))
            Text(label)
                .font(.system(size: 11))
            Spacer()
            if current != .granted {
                Button("許可する", action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            }
        }
    }

    private func iconName(for s: PermissionState) -> String {
        switch s {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined, .unknown: return "questionmark.circle.fill"
        }
    }

    private func color(for s: PermissionState) -> Color {
        switch s {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined, .unknown: return .orange
        }
    }

    // MARK: - API Key 行

    @ViewBuilder
    private var apiKeyRow: some View {
        if hasAPIKey {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("OpenAI API Key")
                    .font(.system(size: 11))
                Spacer()
                Button("変更") { hasAPIKey = false }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                    Text("OpenAI API Key")
                        .font(.system(size: 11))
                    Spacer()
                }
                HStack(spacing: 4) {
                    SecureField("sk-proj-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                    Button("保存") { saveAPIKey() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .disabled(apiKeyInput.isEmpty)
                }
            }
        }
    }

    private func saveAPIKey() {
        do {
            try KeychainStore.save(apiKeyInput)
            hasAPIKey = true
            apiKeyInput = ""
        } catch {
            state.lastError = "API Key保存失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - 権限リクエスト

    private func requestMic() {
        Task {
            await PermissionManager.requestMicrophone()
            if state.microphonePermission == .denied {
                PermissionManager.openSystemSettings(for: .microphone)
            }
        }
    }

    private func requestScreen() {
        PermissionManager.requestScreenRecording()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await PermissionManager.refreshScreenRecording()
            if state.screenRecordingPermission != .granted {
                PermissionManager.openSystemSettings(for: .screenRecording)
            }
        }
    }
}
