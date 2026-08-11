import Foundation

/// アプリ稼働ログ。
/// - release/debug いずれでも `~/Library/Logs/MeetScribe/meetscribe.log` に追記
/// - 標準エラーには NSLog (Console.app と launchagent.err.log にも残る)
/// - 重要イベントのみ呼び出す前提 (音声デルタなど高頻度のものは含めない)
/// - ファイル I/O は専用シリアルキューで実行 (オーディオスレッドをブロックしない)
/// - **テスト実行中はファイルへ書かない** (本番ログを汚染するとログ由来の分析が壊れる)
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

    // MARK: - ファイル出力の可否

    /// 「その場限り」の上書き用の環境変数。`1`/`0` で強制的にON/OFFする。
    static let environmentKey = "MEETSCRIBE_LOG_TO_FILE"
    /// GUI (Finder/Dock) 起動でも効く恒久設定のキー。
    /// **環境変数だけでは不十分**: GUI 起動はシェルの環境を継承しない。
    /// `defaults write com.meetscribe.app logToFile -bool YES` で上書きできる。
    static let userDefaultsKey = "logToFile"

    /// ファイルログを書くか。既定は「テスト実行中以外は書く」。
    ///
    /// `swift test` の出力が本番ログ (`~/Library/Logs/MeetScribe/meetscribe.log`) に
    /// 混ざると、ログを一次データにした分析が壊れる。2026-08-11 のコスト分析では
    /// テストが出した `[silence] 0s` 176件・cleaner のパース失敗44件が混入し、
    /// 実測22件の失敗を66件と誤読していた (**3倍の誤差**)。
    ///
    /// 本番実行では絶対に止めないこと (止まると障害調査ができない)。判定は
    /// XCTest 由来の環境変数と XCTest のリンク有無だけを見ており、配布ビルドの
    /// プロセスではどちらも成立しない。
    static let writesToFile: Bool = resolveWritesToFile()

    /// 上書き設定を解決する (テストから注入できるよう純関数にしてある)。
    /// 優先順位は 環境変数 → UserDefaults → 既定 (テスト中でなければ書く)。
    static func resolveWritesToFile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults? = .standard,
        isRunningTests: Bool = detectRunningTests()
    ) -> Bool {
        if let explicit = parseBool(environment[environmentKey]) { return explicit }
        if let explicit = parseBoolObject(defaults?.object(forKey: userDefaultsKey)) {
            return explicit
        }
        return !isRunningTests
    }

    /// XCTest プロセスで動いているか。
    static func detectRunningTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        // XCTest がプロセスにリンクされているか (配布ビルドには含まれない)。
        return NSClassFromString("XCTestCase") != nil
    }

    private static func parseBool(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    private static func parseBoolObject(_ object: Any?) -> Bool? {
        switch object {
        case let number as NSNumber: return number.boolValue
        case let string as String: return parseBool(string)
        default: return nil
        }
    }

    static func log(_ message: @autoclosure () -> String) {
        let resolved = message()
        NSLog("%@", resolved)
        // テスト出力を本番ログに混ぜない (NSLog は残すのでテスト側の可視性は変わらない)。
        guard writesToFile else { return }
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
