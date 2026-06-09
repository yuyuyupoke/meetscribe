import Foundation

/// 保存対象の会議データをまとめたレコード。
struct MeetingRecord: Sendable {
    let startedAt: Date
    let endedAt: Date
    let title: String
    let meetingEntries: [TranscriptEntry]
    let qaEntries: [TranscriptEntry]
    let totalCostUSD: Double
    let model: String

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
        let url = dir.appendingPathComponent(makeFilename(for: record))
        let content = render(record: record)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
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
        lines.append("model: \(record.model)")
        lines.append("speakers:")
        lines.append("  - \"自分\"")
        lines.append("  - \"相手\"")
        lines.append("---")
        lines.append("")
        lines.append("# \(record.title)")
        lines.append("")
        lines.append("## 📝 文字起こし")
        lines.append("")
        if record.meetingEntries.isEmpty {
            lines.append("_(発話なし)_")
        } else {
            for entry in record.meetingEntries {
                lines.append("**[\(entry.speaker.displayName)]** \(entry.text)")
                lines.append("")
            }
        }

        if !record.qaEntries.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("## 💬 Q&A")
            lines.append("")
            appendQAEntries(record.qaEntries, to: &lines)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendQAEntries(_ entries: [TranscriptEntry], to lines: inout [String]) {
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            if entry.speaker == .user {
                lines.append("### Q: \(entry.text)")
                lines.append("")
                // 直後の Claude 回答をペアリング
                if i + 1 < entries.count, entries[i + 1].speaker == .claude {
                    lines.append("**A:**")
                    lines.append("")
                    lines.append(entries[i + 1].text)
                    lines.append("")
                    i += 2
                    continue
                }
            }
            i += 1
        }
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
