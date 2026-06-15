import Foundation

/// アプリ稼働ログ。
/// - release/debug いずれでも `~/Library/Logs/MeetScribe/meetscribe.log` に追記
/// - 標準エラーには NSLog (Console.app と launchagent.err.log にも残る)
/// - 重要イベントのみ呼び出す前提 (音声デルタなど高頻度のものは含めない)
/// - ファイル I/O は専用シリアルキューで実行 (オーディオスレッドをブロックしない)
enum DebugLog {
    private static let queue = DispatchQueue(label: "com.meetscribe.app.log", qos: .utility)
    private static let logURL: URL = {
        let fm = FileManager.default
        let logsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetScribe", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("meetscribe.log")
    }()

    static func log(_ message: @autoclosure () -> String) {
        let resolved = message()
        NSLog("%@", resolved)
        let line = "\(Date().ISO8601Format()) \(resolved)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
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
}
