import SwiftUI

/// プロバイダー別 API Key の入力・保存 UI。SetupSectionView (インライン) と
/// SettingsFooterView (ポップオーバー) の両方で共用する。
/// 表示/非表示トグル (目のアイコン)・前後空白の trim・Keychain 保存・
/// AppState.hasAPIKey の更新をここに一元化する — 実装が分かれていた頃、
/// 片方だけ trim 漏れでコピペ由来の壊れたキーが保存されるバグがあった。
struct APIKeyEditorView: View {
    let state: AppState
    let provider: AIProvider
    /// 保存成功時に呼ばれる (ポップオーバーを閉じる等)
    var onSaved: (() -> Void)? = nil
    /// 指定するとキャンセルボタンを表示する (登録済みキーの変更モード用)
    var onCancel: (() -> Void)? = nil
    /// 入力欄の固定幅。nil なら親レイアウトに従う
    var fieldWidth: CGFloat? = nil

    @State private var input = ""
    @State private var isRevealed = false

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Group {
                    if isRevealed {
                        TextField(provider.apiKeyPlaceholder, text: $input)
                    } else {
                        SecureField(provider.apiKeyPlaceholder, text: $input)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.scaled(10))
                .frame(width: fieldWidth)

                Button(action: { isRevealed.toggle() }) {
                    Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                        .font(.scaled(10))
                }
                .buttonStyle(.borderless)
                .help(isRevealed ? "APIキーを隠す" : "APIキーを表示")

                Button("保存") { save() }
                    .buttonStyle(.borderless)
                    .font(.scaled(10))
                    .disabled(trimmedInput.isEmpty)

                if let onCancel {
                    Button("キャンセル") {
                        reset()
                        onCancel()
                    }
                    .buttonStyle(.borderless)
                    .font(.scaled(10))
                }
            }
            Text(state.hasAPIKey(for: provider)
                 ? "Keychain に安全に保存されます。保存すると既存のキーを上書きし、次回の録音開始から適用されます。"
                 : "Keychain に安全に保存されます。")
                .font(.scaled(9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // popover を保存せず閉じた場合などに入力中のキーを残さない
        .onDisappear { reset() }
    }

    private func save() {
        let key = trimmedInput
        guard !key.isEmpty else { return }
        do {
            try KeychainStore.save(key, for: provider)
            state.setHasAPIKey(true, for: provider)
            reset()
            onSaved?()
        } catch {
            state.lastError = "\(provider.shortDisplayName) API Key保存失敗: \(error.localizedDescription)"
        }
    }

    private func reset() {
        input = ""
        isRevealed = false
    }
}
