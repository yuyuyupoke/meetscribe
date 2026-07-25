import SwiftUI
import AppKit

/// 画面下部に常時表示するフッター。議事録の保存先パスを表示し、
/// GUI でいつでも変更できる。
struct SettingsFooterView: View {
    @Bindable var state: AppState

    // API Key 編集ポップオーバーの表示状態
    @State private var showAPIKeyPopover = false

    var body: some View {
        HStack(spacing: 10) {
            // ウィンドウが狭くてもAI切替とキー設定を最優先で表示する。
            providerControl
                .layoutPriority(2)
            Divider().frame(height: 12)
            apiKeyControl
                .layoutPriority(2)
            Divider().frame(height: 12)
            folderControl(
                icon: state.meetingsSaveDirectoryURL == nil ? "exclamationmark.triangle.fill" : "tray.full.fill",
                label: "議事録",
                url: state.meetingsSaveDirectoryURL,
                tint: state.meetingsSaveDirectoryURL == nil ? .orange : .green,
                onChange: selectMeetingsFolder,
                hint: "録音停止時に議事録がここに保存されます。未設定だと録音を開始できません"
            )
            Divider().frame(height: 12)
            languageControl
            Divider().frame(height: 12)
            translationToggle
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
        hint: String? = nil
    ) -> some View {
        // アイコン + ラベル + パス全体がクリック可能。押すとフォルダ選択ダイアログ。
        Button(action: onChange) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.scaled(12))
                Text("\(label):")
                    .font(.scaled(10))
                    .foregroundStyle(.secondary)
                if let url {
                    Text(Self.tildePath(url))
                        .font(.scaled(10).monospaced())
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                } else {
                    Text("未設定")
                        .font(.scaled(10))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help({
            let base = url.map { "\(label): \($0.path)（クリックで変更）" } ?? "\(label)フォルダを選択"
            return hint.map { "\(base)。\($0)" } ?? base
        }())
    }

    /// 文字起こし言語の切替。Auto = API側の自動検出 (languageパラメータ省略)。
    /// 録音中に変えても現セッションには効かず、次回の録音開始から適用される。
    private var languageControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .foregroundStyle(.blue)
                .font(.scaled(12))
            Picker("", selection: $state.transcriptionLanguage) {
                Text("Auto").tag("auto")
                Text("🇯🇵").tag("ja")
                Text("🇺🇸").tag("en")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()
        }
        .help("文字起こしの言語。Auto = 発話から自動検出。次回の録音開始から適用")
    }

    /// 文字起こし・整形・翻訳・Copilotへ一貫して使うプロバイダー。
    private var providerControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "network")
                .foregroundStyle(.blue)
                .font(.scaled(12))
            Picker("", selection: $state.selectedProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.shortDisplayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("footer-provider-picker")
        }
        .help("会議に使うAIプロバイダー。録音中の変更は次回の会議から適用されます")
    }

    /// 対訳表示 (英語の発話に日本語訳を併記) の ON/OFF。
    private var translationToggle: some View {
        Button(action: { state.showTranslations.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "character.book.closed.fill")
                    .foregroundStyle(state.showTranslations ? Color.blue : .secondary.opacity(0.6))
                    .font(.scaled(12))
                Text("対訳")
                    .font(.scaled(10))
                    .foregroundStyle(state.showTranslations ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state.showTranslations
              ? "対訳ON: 英語の発話に日本語訳を併記します（クリックでOFF）"
              : "対訳OFF: クリックすると英語の発話に日本語訳を併記します")
    }

    // MARK: - API Key 管理 (常時アクセス可能)

    /// OpenAI/xAI API Key の登録・変更。セットアップ完了後は SetupSectionView が
    /// 消えるため、いつでも触れるようフッターに常設する。
    private var apiKeyControl: some View {
        Button(action: { showAPIKeyPopover.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "key.fill")
                    .foregroundStyle(state.hasAPIKey ? Color.green : .orange)
                    .font(.scaled(12))
                Text("APIキー:")
                    .font(.scaled(10))
                    .foregroundStyle(.secondary)
                Text("\(state.selectedProvider.shortDisplayName) \(state.hasAPIKey ? "設定済み" : "未設定")")
                    .font(.scaled(10))
                    .foregroundStyle(state.hasAPIKey ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("OpenAI / xAI API Key を登録・変更（クリックで入力欄を開く）")
        .popover(isPresented: $showAPIKeyPopover, arrowEdge: .top) {
            apiKeyEditor
        }
    }

    private var apiKeyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .frame(width: 340)
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

}
