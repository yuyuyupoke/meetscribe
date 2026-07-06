import Foundation

/// Claude Max (subscription) の `claude -p` CLI を subprocess で呼び出すクライアント。
/// 現在の用途は議事録タイトル生成 (`invokeRaw`) のみ。
/// (タイプ入力式 Q&A は 2026-07 の右カラム刷新で廃止した)
final class ClaudeQAClient: @unchecked Sendable {
    enum QAError: Error, LocalizedError {
        case claudeNotFound
        case processFailed(Int32, String?)
        case cancelled
        case timedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "claude CLI が見つかりません"
            case .processFailed(let code, let detail):
                return "claude プロセス異常終了 (code=\(code))" + (detail.map { " — \($0)" } ?? "")
            case .cancelled:
                return "質問がキャンセルされました"
            case .timedOut(let seconds):
                return "claude が \(Int(seconds))秒以内に応答しませんでした (タイムアウト)"
            }
        }
    }

    /// プロセス待ちの上限。claude CLI がハングすると isSavingMeeting が
    /// 永久に立ちっぱなしになり UI がロックされるため、必ず上限を設ける。
    static let rawInvokeTimeoutSeconds: TimeInterval = 60 // タイトル生成等の軽量呼び出し

    /// タイムアウト超過でプロセスを強制終了するウォッチドッグを起動する。
    /// terminate (SIGTERM) で3秒待っても死なない場合は SIGKILL で確殺する。
    /// 終了すれば terminationHandler が呼ばれるので、呼び出し側の待機は自然に解ける。
    private static func startWatchdog(
        for task: Process,
        timeout: TimeInterval,
        timedOut: TimedOutFlag
    ) -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, task.isRunning else { return }
            timedOut.set()
            DebugLog.log("[claude-qa] watchdog: timeout (\(Int(timeout))s) → terminate")
            task.terminate()
            try? await Task.sleep(for: .seconds(3))
            if task.isRunning {
                DebugLog.log("[claude-qa] watchdog: still alive → SIGKILL")
                kill(task.processIdentifier, SIGKILL)
            }
        }
    }

    let claudePath: String

    init(claudePath: String? = nil) throws {
        if let path = claudePath, FileManager.default.isExecutableFile(atPath: path) {
            self.claudePath = path
        } else if let discovered = Self.discoverClaudeExecutable() {
            self.claudePath = discovered
        } else {
            throw QAError.claudeNotFound
        }
    }

    /// 任意プロンプトで claude -p を呼び、標準出力をまとめて返す (ストリーミング無し)。
    /// ツール無効 (Read/Glob/Grep/WebFetch/WebSearch 全て不使用) で軽量実行。
    /// タイトル生成など短時間で終わる用途向け。
    func invokeRaw(prompt: String, model: ClaudeModel) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: claudePath)
        task.arguments = [
            "-p", prompt,
            "--model", model.cliArgument
        ]
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/usr/local/bin:/opt/homebrew/bin:\(existingPath)"
        task.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        do {
            try task.run()
        } catch {
            throw QAError.processFailed(-1, error.localizedDescription)
        }

        // ハング対策: 上限超過で強制終了するウォッチドッグ
        let timedOut = TimedOutFlag()
        let watchdog = Self.startWatchdog(for: task, timeout: Self.rawInvokeTimeoutSeconds, timedOut: timedOut)

        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                task.terminationHandler = { _ in cont.resume() }
            }
        } onCancel: {
            task.terminate()
        }
        watchdog.cancel()

        // timedOut と正常終了の競合時は完走結果を優先 (ask と同じ理由)
        if timedOut.value && task.terminationStatus != 0 {
            throw QAError.timedOut(Self.rawInvokeTimeoutSeconds)
        }
        if task.terminationStatus != 0 {
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let errMsg = String(data: errData, encoding: .utf8)
            throw QAError.processFailed(task.terminationStatus, errMsg)
        }

        let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: outData, encoding: .utf8) ?? ""
    }

    // MARK: - claude 実行バイナリ探索

    /// claude CLI がインストールされているか (セットアップ画面のチェックリスト用)。
    /// `which` フォールバックでプロセスを起動するため、UI からはバックグラウンドで呼ぶこと。
    static var isClaudeInstalled: Bool {
        discoverClaudeExecutable() != nil
    }

    static func discoverClaudeExecutable() -> String? {
        let fm = FileManager.default
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // `which` で最終フォールバック
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "command -v claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let output, !output.isEmpty, fm.isExecutableFile(atPath: output) {
            return output
        }
        return nil
    }
}

/// ウォッチドッグがタイムアウトで terminate したことを伝えるロック付きフラグ。
private final class TimedOutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}

