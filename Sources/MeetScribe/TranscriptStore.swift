import Foundation
import Observation

struct TranscriptEntry: Identifiable, Equatable {
    let id: String              // item_id (API) or UUID
    let speaker: SpeakerLabel
    var text: String
    let createdAt: Date
    var isFinal: Bool
    /// 日本語訳 (原文が英語等の場合のみ)。整形LLMが確定後に付与する。
    var translation: String?

    init(
        id: String,
        speaker: SpeakerLabel,
        text: String,
        createdAt: Date,
        isFinal: Bool,
        translation: String? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.createdAt = createdAt
        self.isFinal = isFinal
        self.translation = translation
    }
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

    /// 確定済みエントリのテキストを整形結果で置き換え、対訳があれば付与する
    /// (GPT-4.1 mini クリーナー用)。該当 itemId が無ければ何もしない
    /// (kill/clear 後の遅延到着対策)。
    func updateFinalText(itemId: String, text: String, translation: String? = nil) {
        if let idx = entries.firstIndex(where: { $0.id == itemId }) {
            entries[idx].text = text
            entries[idx].translation = translation
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// 会議の文字起こしのみ (マイク + システム音声)
    var meetingEntries: [TranscriptEntry] {
        entries.filter { $0.speaker == .me || $0.speaker == .other }
    }

    /// タイトル生成・要約に渡すための会議文字起こしテキスト
    var meetingTranscriptText: String {
        meetingEntries.map { "[\($0.speaker.displayName)] \($0.text)" }.joined(separator: "\n")
    }
}
