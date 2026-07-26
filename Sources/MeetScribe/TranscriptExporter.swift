import Foundation

/// 保存対象の会議データをまとめたレコード。
struct MeetingRecord: Sendable {
    let startedAt: Date
    let endedAt: Date
    let title: String
    let meetingEntries: [TranscriptEntry]
    /// AIが傍聴して生成した最終版の全体像 (nil = 生成前に終了)
    let overview: MeetingOverview?
    /// セッション中に実行した Catchup 要約 (新しい順で保持されている)
    let catchupCards: [CatchupCard]
    let totalCostUSD: Double
    let model: String
    let provider: AIProvider
    let assistantModel: String

    init(
        startedAt: Date,
        endedAt: Date,
        title: String,
        meetingEntries: [TranscriptEntry],
        overview: MeetingOverview? = nil,
        catchupCards: [CatchupCard] = [],
        totalCostUSD: Double,
        model: String,
        provider: AIProvider = .openAI,
        assistantModel: String? = nil
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.meetingEntries = meetingEntries
        self.overview = overview
        self.catchupCards = catchupCards
        self.totalCostUSD = totalCostUSD
        self.model = model
        self.provider = provider
        self.assistantModel = assistantModel ?? provider.chatModel
    }

    var durationMinutes: Int {
        max(1, Int(endedAt.timeIntervalSince(startedAt) / 60))
    }
}

/// Markdown への書き出し + ファイル保存を行う。
enum TranscriptExporter {
    enum ExportError: Error, LocalizedError {
        case saveDirectoryNotConfigured

        var errorDescription: String? {
            switch self {
            case .saveDirectoryNotConfigured:
                return "議事録の保存先フォルダが未設定です。設定画面から指定してください。"
            }
        }
    }

    /// 会議レコードを Markdown ファイルに保存する。
    /// - Parameters:
    ///   - record: 保存する会議レコード
    ///   - directory: 保存先フォルダ。必須 (デフォルト無し: 配布時の個人パス漏洩を防ぐ)。
    /// - Returns: 書き出した URL
    @discardableResult
    static func save(_ record: MeetingRecord, to directory: URL?) throws -> URL {
        guard let dir = directory else {
            throw ExportError.saveDirectoryNotConfigured
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = availableURL(in: dir, filename: makeFilename(for: record))
        let content = render(record: record)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 退避保存

    /// 通常の保存先に書けなかったときの退避先。
    /// 保存先フォルダが移動・削除された、権限を失った、ディスクが足りない等でも
    /// 会議の記録を失わないための最後の受け皿。
    static var rescueDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetScribe/rescue", isDirectory: true)
    }

    /// 議事録をアプリ管理下の退避フォルダへ保存する。`save` が失敗したときに使う。
    @discardableResult
    static func saveToRescue(_ record: MeetingRecord) throws -> URL {
        let dir = rescueDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = availableURL(in: dir, filename: makeFilename(for: record))
        try render(record: record).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 既存ファイルを上書きしない URL を返す。衝突時は `-2`, `-3`… を付ける。
    /// タイトル生成に失敗すると `会議_HH-mm` が固定名になり、同じ分に2件保存すると
    /// 先の議事録が黙って消えるため、書き込み前に必ず通す。
    static func availableURL(in directory: URL, filename: String) -> URL {
        let fm = FileManager.default
        let candidate = directory.appendingPathComponent(filename)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for suffix in 2...999 {
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
        }
        // ここまで来たら連番が尽きている。既存を上書きするくらいなら一意名で残す。
        let unique = String(UUID().uuidString.prefix(8)).lowercased()
        let name = ext.isEmpty ? "\(base)-\(unique)" : "\(base)-\(unique).\(ext)"
        return directory.appendingPathComponent(name)
    }

    // MARK: - Markdown

    static func render(record: MeetingRecord) -> String {
        let timestamp = frontMatterTimestamps(record: record)

        var lines: [String] = []
        lines.append("---")
        lines.append("date: \(timestamp.date)")
        lines.append("startedAt: \(timestamp.start)")
        lines.append("endedAt: \(timestamp.end)")
        lines.append("duration: \(record.durationMinutes)m")
        lines.append(String(format: "cost: $%.4f", record.totalCostUSD))
        lines.append("provider: \(record.provider.rawValue)")
        lines.append("model: \(record.model)")
        lines.append("assistantModel: \(record.assistantModel)")
        lines.append("speakers:")
        lines.append("  - \"自分\"")
        lines.append("  - \"相手\"")
        lines.append("---")
        lines.append("")
        lines.append("# \(record.title)")
        lines.append("")

        // 全体像 (AIの傍聴サマリ) を冒頭に
        if let overview = record.overview {
            lines.append("## 🧭 全体像")
            lines.append("")
            lines.append("- **目的**: \(overview.purpose)")
            if !overview.agenda.isEmpty {
                lines.append("- **議題**:")
                for item in overview.agenda {
                    lines.append("  - \(item)")
                }
            }
            if !overview.currentTopic.isEmpty {
                lines.append("- **終了時点の話題**: \(overview.currentTopic)")
            }
            lines.append("")
        }

        lines.append("## 📝 文字起こし")
        lines.append("")
        if record.meetingEntries.isEmpty {
            lines.append("_(発話なし)_")
        } else {
            for entry in record.meetingEntries {
                lines.append("**[\(entry.speaker.displayName)]** \(entry.text)")
                // 対訳 (英語セグメントのみ) は引用行で直下に
                if let translation = entry.translation, !translation.isEmpty {
                    lines.append("> 訳: \(translation)")
                }
                lines.append("")
            }
        }

        // Catchup 履歴 (実行時系列 = 古い順)。エラー・発話なしカードは議事録には残さない。
        let savableCards = record.catchupCards
            .filter { !$0.isError && !$0.isNoSpeech }
            .sorted(by: { $0.createdAt < $1.createdAt })
        if !savableCards.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("## ⏱ Catchup履歴")
            lines.append("")
            for card in savableCards {
                lines.append("### \(card.periodLabel)（\(card.minutes)分）")
                lines.append("")
                lines.append(card.text)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - ファイル名

    static func makeFilename(for record: MeetingRecord) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        let stamp = df.string(from: record.startedAt)
        return "\(stamp)_\(sanitize(record.title)).md"
    }

    private static func sanitize(_ s: String) -> String {
        // ファイル名に使えない/紛らわしい文字を _ に置換
        var result = s
        for c in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"] {
            result = result.replacingOccurrences(of: c, with: "_")
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "untitled" : String(trimmed.prefix(60))
    }

    // MARK: - タイムスタンプ

    private struct Timestamps {
        let date: String
        let start: String
        let end: String
    }

    private static func frontMatterTimestamps(record: MeetingRecord) -> Timestamps {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.locale = Locale(identifier: "en_US_POSIX")

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.locale = Locale(identifier: "en_US_POSIX")

        return Timestamps(
            date: dateFmt.string(from: record.startedAt),
            start: timeFmt.string(from: record.startedAt),
            end: timeFmt.string(from: record.endedAt)
        )
    }
}
