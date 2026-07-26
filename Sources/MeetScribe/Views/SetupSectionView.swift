import SwiftUI
import AppKit

/// 初回セットアップ (権限 + API Key + 議事録保存先) セクション。
/// すべて許可されて API Key も設定済みなら ContentView 側で非表示になる。
struct SetupSectionView: View {
    let state: AppState
    /// 登録済みキーの変更モード。選択中プロバイダーごとに管理する。
    @State private var isEditingAPIKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("⚙️ 初回セットアップ")
                    .font(.scaled(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: refreshChecks) {
                    Image(systemName: "arrow.clockwise")
                        .font(.scaled(10))
                }
                .buttonStyle(.borderless)
                .help("権限の状態を再チェック")
            }
            permissionRow(
                label: "マイク (必須)",
                current: state.microphonePermission,
                action: requestMic
            )
            permissionRow(
                label: "画面収録・システム音声 (必須)",
                current: state.screenRecordingPermission,
                action: requestScreen
            )
            providerRow
            apiKeyRow
            meetingsFolderRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 権限をまとめて再チェックする (更新ボタン用)。
    private func refreshChecks() {
        PermissionManager.refreshAll()
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
                .font(.scaled(11))
            Spacer()
            if let url = state.meetingsSaveDirectoryURL {
                Text(Self.tildePath(url))
                    .font(.scaled(9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .help(url.path)
                Button("変更") { selectMeetingsFolder() }
                    .buttonStyle(.borderless)
                    .font(.scaled(10))
            } else {
                Button("選択") { selectMeetingsFolder() }
                    .buttonStyle(.borderless)
                    .font(.scaled(10))
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
                .font(.scaled(11))
            Spacer()
            if current != .granted {
                Button("許可する", action: action)
                    .buttonStyle(.borderless)
                    .font(.scaled(10))
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

    private var providerRow: some View {
        HStack {
            Image(systemName: "network")
                .foregroundStyle(.blue)
            Text("AIプロバイダー")
                .font(.scaled(11))
            Spacer()
            Picker("", selection: Binding(
                get: { state.selectedProvider },
                set: {
                    state.selectedProvider = $0
                    isEditingAPIKey = false
                }
            )) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
        .help("文字起こし・整形・翻訳・Copilotに使うプロバイダー。録音中の変更は次回の会議から適用されます")
    }

    @ViewBuilder
    private var apiKeyRow: some View {
        if state.hasAPIKey && !isEditingAPIKey {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(state.selectedProvider.shortDisplayName) API Key (必須)")
                    .font(.scaled(11))
                Spacer()
                Button("変更") { isEditingAPIKey = true }
                    .buttonStyle(.borderless)
                    .font(.scaled(10))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // 未設定は録音開始をブロックする必須項目なので、
                    // フォルダ未設定と同じ警告三角で統一する。
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(state.selectedProvider.shortDisplayName) API Key (必須)")
                        .font(.scaled(11))
                    Spacer()
                }
                APIKeyEditorView(
                    state: state,
                    provider: state.selectedProvider,
                    onSaved: { isEditingAPIKey = false },
                    onCancel: isEditingAPIKey ? { isEditingAPIKey = false } : nil
                )
            }
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
                // macOS の仕様で、画面収録の許可はアプリ再起動まで反映されない。
                // これを伝えないと「許可したのに変わらない」という行き止まりになる。
                state.lastError = "システム設定で画面収録を許可した後、MeetScribe の再起動が必要です（メニューバーのアイコン → 終了 → 再度起動）"
            }
        }
    }
}
