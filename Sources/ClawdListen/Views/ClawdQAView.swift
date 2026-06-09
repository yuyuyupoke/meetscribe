import SwiftUI
import AppKit

/// 小窓右カラム。Clawd が会議を傍聴しつつ Q&A に答える UI。
/// - 上部: Clawd アイコン + ステータス + モデル選択
/// - 中央: Q&A 履歴 (ユーザー質問 + Claude回答)
/// - 下部: 入力欄 (InputBarView)
struct ClawdQAView: View {
    @Bindable var state: AppState
    let transcripts: TranscriptStore
    @Binding var queryText: String
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.3)
            qaList
            Divider().opacity(0.3)
            InputBarView(
                queryText: $queryText,
                // 入力欄: API Key さえあれば回答生成中でも編集可能
                canType: KeychainStore.hasAPIKey,
                // 送信ボタン: API Key + 回答生成中でない時のみ
                canSubmit: KeychainStore.hasAPIKey && !state.isAsking,
                onSubmit: onSubmit
            )
        }
    }

    // MARK: - ヘッダ (Clawd アイコン + ステータス + モデル選択)

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                clawdIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clawd")
                        .font(.system(size: 12, weight: .semibold))
                    Text(statusText)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                supportButton
            }
            modelPicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 開発者サポート (note サポート記事へ遷移)。アイコンだけのさりげない配置。
    private var supportButton: some View {
        Button(action: openSupportLink) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("開発者を note で応援する")
    }

    private func openSupportLink() {
        guard let url = URL(string: "https://note.com/yuyuyu303030jp/n/n17ba34bf2ffb?app_launch=false") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var clawdIcon: some View {
        Group {
            if let url = Bundle.main.url(forResource: "Clawd", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "pawprint.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var statusText: String {
        if state.isAsking {
            return "回答を生成中…"
        }
        if state.isRunning {
            return "会議を聞いています"
        }
        return "待機中"
    }

    /// モデル切替をセグメント型の Button 3つで実装する。
    /// NSPanel (.floating) 環境で Picker(.menu) / SwiftUI Menu がクラッシュする問題を回避。
    private var modelPicker: some View {
        HStack(spacing: 6) {
            Text("モデル")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ForEach(ClaudeModel.allCases) { model in
                modelButton(for: model)
            }
            Spacer()
        }
    }

    private func modelButton(for model: ClaudeModel) -> some View {
        let isSelected = state.selectedModel == model
        let bgColor: Color = isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1)
        return Button {
            state.selectedModel = model
        } label: {
            Text(model.displayName)
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(bgColor))
        }
        .buttonStyle(.plain)
        .help(model.subtitle)
    }

    // MARK: - Q&A リスト

    private var qaList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if transcripts.qaEntries.isEmpty {
                        placeholder
                    }
                    ForEach(transcripts.qaEntries) { entry in
                        bubble(entry)
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .onChange(of: transcripts.qaEntries.count) { _, _ in
                if let lastId = transcripts.qaEntries.last?.id {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("💬 下の欄から質問してください")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("例: 「今の話題の◯◯って何？」「関連する資料を知識源から探して」")
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func bubble(_ entry: TranscriptEntry) -> some View {
        let color: Color = entry.speaker == .user ? .purple : .orange
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.speaker.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                if !entry.isFinal && entry.speaker == .claude {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(entry.text.isEmpty ? "…" : entry.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(entry.isFinal ? 1.0 : 0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}
