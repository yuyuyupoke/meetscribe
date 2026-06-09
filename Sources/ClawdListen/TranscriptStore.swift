import Foundation
import Observation

struct TranscriptEntry: Identifiable, Equatable {
    let id: String              // item_id (API) or UUID
    let speaker: SpeakerLabel
    var text: String
    let createdAt: Date
    var isFinal: Bool
}

@MainActor
@Observable
final class TranscriptStore {
    static let shared = TranscriptStore()

    private(set) var entries: [TranscriptEntry] = []

    private init() {}

    /// ストリーミング中の delta を追加 (item_id で既存エントリに追記 or 新規作成)
    func appendDelta(_ delta: String, itemId: String, speaker: SpeakerLabel) {
        if let idx = entries.firstIndex(where: { $0.id == itemId }) {
            entries[idx].text += delta
        } else {
            entries.append(TranscriptEntry(
                id: itemId,
                speaker: speaker,
                text: delta,
                createdAt: Date(),
                isFinal: false
            ))
        }
    }

    /// 確定した文字起こしで上書き
    func completeItem(itemId: String, finalText: String, speaker: SpeakerLabel) {
        if let idx = entries.firstIndex(where: { $0.id == itemId }) {
            entries[idx].text = finalText
            entries[idx].isFinal = true
        } else {
            entries.append(TranscriptEntry(
                id: itemId,
                speaker: speaker,
                text: finalText,
                createdAt: Date(),
                isFinal: true
            ))
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// 会議の文字起こしのみ (マイク + システム音声)
    var meetingEntries: [TranscriptEntry] {
        entries.filter { $0.speaker == .me || $0.speaker == .other }
    }

    /// Q&A セッションのみ (ユーザー質問 + Claude回答)
    var qaEntries: [TranscriptEntry] {
        entries.filter { $0.speaker == .user || $0.speaker == .claude }
    }

    /// Claude に渡すための会議文字起こしテキスト
    var meetingTranscriptText: String {
        meetingEntries.map { "[\($0.speaker.displayName)] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Q&A 操作

    /// ユーザーの質問を追加。
    @discardableResult
    func addUserQuery(_ text: String) -> String {
        let id = "qa-user-\(UUID().uuidString)"
        entries.append(TranscriptEntry(
            id: id,
            speaker: .user,
            text: text,
            createdAt: Date(),
            isFinal: true
        ))
        return id
    }

    /// Claude の空の回答プレースホルダーを追加 (ストリーミングで追記していく用)。
    @discardableResult
    func startClaudeAnswer() -> String {
        let id = "qa-claude-\(UUID().uuidString)"
        entries.append(TranscriptEntry(
            id: id,
            speaker: .claude,
            text: "",
            createdAt: Date(),
            isFinal: false
        ))
        return id
    }

    /// 指定 id のエントリにテキストを追記する (Claude応答のストリーミング用)。
    func appendToAnswer(itemId: String, chunk: String) {
        if let idx = entries.firstIndex(where: { $0.id == itemId }) {
            entries[idx].text += chunk
        }
    }

    /// 指定 id のエントリを確定させる。
    func finalizeAnswer(itemId: String) {
        if let idx = entries.firstIndex(where: { $0.id == itemId }) {
            entries[idx].isFinal = true
        }
    }
}
