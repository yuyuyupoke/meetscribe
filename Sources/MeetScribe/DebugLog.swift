import Foundation

/// アプリ稼働ログ。
/// - release/debug いずれでも `~/Library/Logs/MeetScribe/meetscribe.log` に追記
/// - 標準エラーには NSLog (Console.app と launchagent.err.log にも残る)
/// - 重要イベントのみ呼び出す前提 (音声デルタなど高頻度のものは含めない)
/// - ファイル I/O は専用シリアルキューで実行 (オーディオスレッドをブロックしない)
/// - **会議の発話内容は書かない** (文字数などのメタ情報のみ)。ログは平文で長期間
///   残るため、議事録の意図しない二重保存になってしまう
/// - サイズ上限を超えたら1世代だけ退避して切り詰める (無制限に肥大させない)
enum DebugLog {
    private static let queue = DispatchQueue(label: "com.meetscribe.app.log", qos: .utility)

    /// 1ファイルあたりの上限。超えたら `.1` へ退避して新規作成する (最大2世代 = 10MB)。
    static let maxBytes: UInt64 = 5 * 1024 * 1024

    private static let logsDirectory: URL = {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetScribe", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let logURL = logsDirectory.appendingPathComponent("meetscribe.log")
    private static let rotatedURL = logsDirectory.appendingPathComponent("meetscribe.1.log")

    /// 会議の発話内容をログに含めるか。既定は false。
    /// バグ調査時のみ `MEETSCRIBE_LOG_TRANSCRIPT=1` を付けて起動して有効化する
    /// (反復ハルシネーションのような「何が出力されたか」を要する調査用)。
    static let logsTranscriptContent: Bool =
        ProcessInfo.processInfo.environment["MEETSCRIBE_LOG_TRANSCRIPT"] == "1"

    /// 発話内容を含むログ。既定では文字数だけを残す。
    /// - Parameters:
    ///   - label: 種別 (例: `"[other] completed"`)
    ///   - text: 発話本文。`logsTranscriptContent` が有効なときだけ出力される
    static func logTranscript(_ label: @autoclosure () -> String, text: String) {
        if logsTranscriptContent {
            log("\(label()): '\(text)'")
        } else {
            log("\(label()) (\(text.count) chars)")
        }
    }

    static func log(_ message: @autoclosure () -> String) {
        let resolved = message()
        NSLog("%@", resolved)
        let line = "\(Date().ISO8601Format()) \(resolved)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            rotateIfNeeded()
            let url = logURL
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 上限超過時に現在のログを1世代退避する。必ず `queue` 上から呼ぶこと。
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxBytes else { return }
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: logURL, to: rotatedURL)
    }
}
