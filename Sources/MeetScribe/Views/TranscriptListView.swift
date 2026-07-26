import SwiftUI
import AppKit

/// 小窓左カラム。会議音声のリアルタイム文字起こしを表示する。
/// 文字起こし本体は `TranscriptTextView` (NSTextView) を使い、
/// 全発言をまたいだドラッグ選択+コピーを可能にする。
/// プレースホルダ・エラー表示・保存完了バナーは SwiftUI のまま重ねる。
struct TranscriptListView: View {
    let state: AppState
    let transcripts: TranscriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if transcripts.meetingEntries.isEmpty {
                placeholder
                Spacer(minLength: 0)
            } else {
                TranscriptTextView(
                    entries: transcripts.meetingEntries,
                    showTranslations: state.showTranslations,
                    uiScale: state.uiScale
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = state.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Text(error)
                        .font(.scaled(10))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 再接続中はバナーを消されると状況不明になるので ✕ を出さない。
                    // それ以外のエラーは既読後に ✕ で消せる。
                    if state.reconnectingStreams.isEmpty {
                        Button(action: { state.lastError = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.scaled(11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("エラー表示を閉じる")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            if let savedURL = state.lastSavedURL {
                savedBanner(url: savedURL)
                if state.shouldShowSupportPrompt {
                    supportPrompt
                }
            }
        }
    }

    /// 議事録が保存できた直後 (= 価値を感じた瞬間) にだけ出す応援の導線。
    /// 数回使ってから・30日に1回まで・「今後表示しない」あり、の3点で
    /// 押し付けにならないようにしている。判定は `AppState.shouldShowSupportPrompt`。
    private var supportPrompt: some View {
        HStack(spacing: 6) {
            Text("☕")
                .font(.scaled(11))
                .accessibilityHidden(true)
            Text("議事録、お役に立ちましたか？ \(SupportLink.suggestedAmountLabel)で開発を応援できます。")
                .font(.scaled(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("応援する") {
                state.supportPromptLastShownAt = Date()
                SupportLink.open()
            }
            .buttonStyle(.borderless)
            .font(.scaled(10))
            Button("今後表示しない") {
                state.supportPromptDismissed = true
            }
            .buttonStyle(.borderless)
            .font(.scaled(10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .task {
            // 表示した時点で間隔を開始する (押さずに閉じた場合も次回まで置く)
            if state.supportPromptLastShownAt == nil {
                state.supportPromptLastShownAt = Date()
            }
        }
    }

    private var placeholder: some View {
        Text("🎧 録音開始すると文字起こしがここに流れる")
            .font(.scaled(11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
    }

    /// 議事録保存完了時のバナー
    private func savedBanner(url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("議事録を保存しました")
                    .font(.scaled(10, weight: .semibold))
                Text(url.lastPathComponent)
                    .font(.scaled(9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                Image(systemName: "folder.fill")
                    .font(.scaled(10))
            }
            .buttonStyle(.plain)
            .help("Finderで開く")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.green.opacity(0.15))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
