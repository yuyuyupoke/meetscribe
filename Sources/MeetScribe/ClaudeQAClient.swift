import Foundation

/// Claude Max (subscription) の `claude -p` CLI を subprocess で呼び出し、
/// 会議文字起こしを文脈として、ユーザー指定の知識源フォルダや Web の情報を
/// 参照しながら質問に答えさせる。
final class ClaudeQAClient: @unchecked Sendable {
    enum QAError: Error, LocalizedError {
        case claudeNotFound
        case processFailed(Int32, String?)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "claude CLI が見つかりません"
            case .processFailed(let code, let detail):
                return "claude プロセス異常終了 (code=\(code))" + (detail.map { " — \($0)" } ?? "")
            case .cancelled:
                return "質問がキャンセルされました"
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

    /// 質問を送信し、回答をストリーミングで受け取る。
    /// - Parameters:
    ///   - transcript: 会議文字起こし全文 (空文字可)
    ///   - question: ユーザーの質問
    ///   - model: 使用するモデル
    ///   - knowledgeFolderPath: ユーザー指定の知識源フォルダ (任意)。
    ///     未指定なら Web 情報のみで回答する。
    ///   - onDelta: 出力チャンクが来るたびに呼ばれる (UI更新用)
    /// - Returns: 回答全文
    func ask(
        transcript: String,
        question: String,
        model: ClaudeModel,
        knowledgeFolderPath: String? = nil,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let prompt = buildPrompt(
            transcript: transcript,
            question: question,
            knowledgeFolderPath: knowledgeFolderPath
        )
        DebugLog.log("[claude-qa] asking (\(model.cliArgument)): \(question.prefix(60))…")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: claudePath)
        var args = [
            "-p", prompt,
            "--model", model.cliArgument
        ]
        if let kf = knowledgeFolderPath {
            args.append("--add-dir")
            args.append(kf)
        }
        args.append(contentsOf: ["--allowedTools", "Read,Glob,Grep,WebFetch,WebSearch"])
        task.arguments = args

        // PATH を補正して claude が内部で呼ぶツール類を解決できるようにする
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/usr/local/bin:/opt/homebrew/bin:\(existingPath)"
        task.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        // stdout をストリーミング読み取り
        let collected = Collected()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                collected.append(chunk)
                onDelta(chunk)
            }
        }

        do {
            try task.run()
        } catch {
            throw QAError.processFailed(-1, error.localizedDescription)
        }

        // プロセス終了を待つ (cancel 対応)
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                task.terminationHandler = { _ in
                    // readabilityHandler の残りを flush
                    if let remaining = try? stdout.fileHandleForReading.readToEnd(),
                       let tail = String(data: remaining, encoding: .utf8),
                       !tail.isEmpty {
                        collected.append(tail)
                        onDelta(tail)
                    }
                    cont.resume()
                }
            }
        } onCancel: {
            task.terminate()
        }

        if task.terminationStatus != 0 {
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let errMsg = String(data: errData, encoding: .utf8)
            throw QAError.processFailed(task.terminationStatus, errMsg)
        }

        return collected.value
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

        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                task.terminationHandler = { _ in cont.resume() }
            }
        } onCancel: {
            task.terminate()
        }

        if task.terminationStatus != 0 {
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let errMsg = String(data: errData, encoding: .utf8)
            throw QAError.processFailed(task.terminationStatus, errMsg)
        }

        let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: outData, encoding: .utf8) ?? ""
    }

    // MARK: - Prompt 構築

    private func buildPrompt(
        transcript: String,
        question: String,
        knowledgeFolderPath: String? = nil
    ) -> String {
        let transcriptBlock: String
        if transcript.isEmpty {
            transcriptBlock = "(まだ発話なし)"
        } else {
            transcriptBlock = transcript
        }
        let knowledgeBlock: String
        if let kf = knowledgeFolderPath {
            knowledgeBlock = """
            参照可能な情報源 (優先順):
            - **ユーザー指定の知識源フォルダ** (\(kf)) — Glob/Grep/Read で必ず確認して根拠を引く
            - Web 上の最新情報 (WebSearch / WebFetch 可)
            """
        } else {
            knowledgeBlock = """
            参照可能な情報源:
            - Web 上の最新情報 (WebSearch / WebFetch 可)
            (ローカル知識源フォルダは未設定。会議文脈と Web 情報のみで回答する)
            """
        }
        return """
        あなたは MeetScribe というミーティング傍聴アシスタントです。
        ユーザーが参加している会議の文字起こしをリアルタイムで聞いており、
        質問されたときに的確に答えることが役割です。

        以下は現在進行中の会議のリアルタイム文字起こしです。

        <transcript>
        \(transcriptBlock)
        </transcript>

        上記の文脈を踏まえて、以下の質問に答えてください。

        \(knowledgeBlock)

        <question>
        \(question)
        </question>

        回答は日本語で、簡潔かつ実用的に。引用元のファイル名は最後に箇条書きで示す。
        """
    }

    // MARK: - claude 実行バイナリ探索

    private static func discoverClaudeExecutable() -> String? {
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

/// ストリーミング読み取り中に蓄積するためのシンプルなロック付きバッファ。
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += s
    }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
