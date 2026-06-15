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
                TranscriptTextView(entries: transcripts.meetingEntries)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = state.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 再接続中はバナーを消されると状況不明になるので ✕ を出さない。
                    // それ以外のエラーは既読後に ✕ で消せる。
                    if state.reconnectingStreams.isEmpty {
                        Button(action: { state.lastError = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
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
            }
        }
    }

    private var placeholder: some View {
        Text("🎧 録音開始すると文字起こしがここに流れる")
            .font(.system(size: 11))
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
                    .font(.system(size: 10, weight: .semibold))
                Text(url.lastPathComponent)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
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
