import Foundation

/// 右カラム「Copilotパネル」のロジック統括。
/// - Catchup要約: ボタン押下で直近N分の転写を日本語要約してカード追加
/// - 全体像: 発話が溜まったら自動で「目的/議題/現在地」を更新
/// LLM はすべて OpenAIChatClient (gpt-4.1-mini)。失敗しても録音・文字起こしには影響しない。
@MainActor
final class CopilotController {
    static let shared = CopilotController()

    private init() {}

    // MARK: - 全体像の自動更新トリガー設定

    /// 監視ループの周期
    private static let monitorInterval: TimeInterval = 30
    /// 「発話量」トリガー: 前回更新から新規に確定した文字数がこれを超えたら更新
    private static let updateCharThreshold = 1_200
    /// 「経過時間」トリガー: 前回更新からこの秒数が経過し、かつ最低限の新規発話があれば更新
    private static let updateTimeThreshold: TimeInterval = 180
    private static let minCharsForTimeUpdate = 200
    /// 初回生成に必要な最低文字数 (これ未満は「傍聴中…」のまま)
    private static let minCharsForFirstOverview = 300

    private var monitorTask: Task<Void, Never>?
    /// 実行中の Catchup。セッション終了/再開時に cancel し、旧セッションの
    /// 遅延応答が新セッションのカードリストや実行中フラグを汚さないようにする。
    private var catchupTask: Task<Void, Never>?
    private var lastOverviewTextLength = 0
    private var lastOverviewUpdateAt = Date.distantPast

    // MARK: - セッションライフサイクル

    /// 録音開始時に呼ぶ。前セッションの状態をクリアして全体像の監視を開始する。
    func startSession() {
        catchupTask?.cancel()
        catchupTask = nil
        AppState.shared.catchupCards = []
        AppState.shared.overview = nil
        AppState.shared.isCatchupRunning = false
        AppState.shared.isOverviewUpdating = false
        lastOverviewTextLength = 0
        lastOverviewUpdateAt = Date.distantPast

        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.monitorInterval))
                if Task.isCancelled { return }
                await self?.updateOverviewIfNeeded()
            }
        }
    }

    /// 録音停止/kill 時に呼ぶ。監視を止める (カード・全体像は表示のため残す)。
    func endSession() {
        monitorTask?.cancel()
        monitorTask = nil
        catchupTask?.cancel()
        catchupTask = nil
        AppState.shared.isOverviewUpdating = false
        AppState.shared.isCatchupRunning = false
    }

    // MARK: - Catchup要約

    /// UI から呼ぶ入口。Task を controller が保持し、セッション終了時に cancel できるようにする。
    func requestCatchup(minutes: Int) {
        guard !AppState.shared.isCatchupRunning else { return }
        catchupTask = Task { [weak self] in
            await self?.runCatchup(minutes: minutes)
        }
    }

    /// 直近 minutes 分の転写を日本語要約してカードを追加する。
    func runCatchup(minutes: Int) async {
        guard !AppState.shared.isCatchupRunning else { return }
        guard let apiKey = KeychainStore.read(), !apiKey.isEmpty else { return }

        let now = Date()
        let windowEntries = Self.entriesInWindow(
            TranscriptStore.shared.meetingEntries,
            minutes: minutes,
            now: now
        )
        let periodLabel = Self.periodLabel(
            from: now.addingTimeInterval(-Double(minutes) * 60),
            to: now
        )

        // 発話ゼロなら LLM を呼ばずその場でカード表示 (課金なし・議事録には残さない)
        guard !windowEntries.isEmpty else {
            AppState.shared.catchupCards.insert(
                CatchupCard(
                    periodLabel: periodLabel,
                    minutes: minutes,
                    text: "この期間の発話はありません",
                    isNoSpeech: true
                ),
                at: 0
            )
            return
        }

        AppState.shared.isCatchupRunning = true

        let transcript = Self.transcriptText(windowEntries)
        let (text, costUSD) = await OpenAIChatClient.complete(
            system: Self.catchupSystemPrompt,
            user: transcript,
            apiKey: apiKey,
            timeout: 20
        )
        // セッション終了/再開で cancel された遅延応答は、新セッションの状態
        // (カードリスト・isCatchupRunning) に触らず破棄する。フラグは
        // startSession/endSession が既にリセット済み。
        if Task.isCancelled { return }
        if costUSD > 0 { AppState.shared.addCost(costUSD) }
        AppState.shared.isCatchupRunning = false

        let card: CatchupCard
        if let text, !text.isEmpty {
            card = CatchupCard(periodLabel: periodLabel, minutes: minutes, text: text)
        } else {
            card = CatchupCard(
                periodLabel: periodLabel,
                minutes: minutes,
                text: "要約の生成に失敗しました。もう一度お試しください。",
                isError: true
            )
        }
        AppState.shared.catchupCards.insert(card, at: 0)
    }

    /// LecTrace の Catchup 設計を踏襲: 冒頭1文 + 箇条書き、用語は原語維持。
    static let catchupSystemPrompt = """
    あなたは会議・講義のリアルタイム傍聴アシスタント。渡された直近の文字起こしを、
    離席していた人が数秒で追いつけるように日本語で要約する。

    形式:
    - 1行目: この期間の内容の一文サマリ
    - 続けて箇条書き3〜6点 (重要な発言・決定・論点)
    - 専門用語・数値・固有名詞は原語のまま保持 (英語用語はそのまま)
    - 前置き・後書きは書かない。要約本文のみを出力
    """

    // MARK: - 全体像の自動更新

    private static let overviewSystemPrompt = """
    あなたは会議・講義のリアルタイム傍聴アシスタント。文字起こし全文から
    「この会議/講義の全体像」を日本語で抽出し、JSONのみで返す。

    ルール:
    - purpose: この会議/講義の目的を1文で
    - agenda: これまでに扱われた議題・トピックを2〜6個の短い名詞句で
    - current_topic: 直近で話していることを1文で
    - 専門用語・固有名詞は原語のまま
    - 推測しすぎない。文字起こしから読み取れる範囲で書く

    出力形式 (JSONのみ):
    {"purpose": "...", "agenda": ["...", "..."], "current_topic": "..."}
    """

    /// トリガー条件を満たしていれば全体像を更新する (満たさなければ何もしない = 課金なし)。
    private func updateOverviewIfNeeded() async {
        guard AppState.shared.isRunning else { return }
        guard !AppState.shared.isOverviewUpdating else { return }

        let fullText = TranscriptStore.shared.meetingTranscriptText
        let newChars = fullText.count - lastOverviewTextLength
        let elapsed = Date().timeIntervalSince(lastOverviewUpdateAt)

        let firstRun = (AppState.shared.overview == nil)
        let shouldUpdate: Bool
        if firstRun {
            shouldUpdate = fullText.count >= Self.minCharsForFirstOverview
        } else {
            shouldUpdate = newChars >= Self.updateCharThreshold
                || (elapsed >= Self.updateTimeThreshold && newChars >= Self.minCharsForTimeUpdate)
        }
        guard shouldUpdate else { return }
        guard let apiKey = KeychainStore.read(), !apiKey.isEmpty else { return }

        AppState.shared.isOverviewUpdating = true
        defer { AppState.shared.isOverviewUpdating = false }

        // 入力肥大を防ぐため末尾 ~12,000 文字に制限 (冒頭の目的把握は
        // 既存 overview が引き継ぐため、直近の文脈を優先する)
        let clipped = String(fullText.suffix(12_000))
        let userPrompt: String
        if let current = AppState.shared.overview {
            userPrompt = """
            前回までの全体像: 目的=\(current.purpose) / 議題=\(current.agenda.joined(separator: "、"))

            最新の文字起こし:
            \(clipped)
            """
        } else {
            userPrompt = clipped
        }

        let (text, costUSD) = await OpenAIChatClient.complete(
            system: Self.overviewSystemPrompt,
            user: userPrompt,
            apiKey: apiKey,
            timeout: 20,
            forceJSON: true
        )
        if costUSD > 0 { AppState.shared.addCost(costUSD) }

        // 失敗時は前の内容を維持 (チラつき・消失させない)
        if let text, let parsed = MeetingOverview.parse(text) {
            AppState.shared.overview = parsed
            lastOverviewTextLength = fullText.count
            lastOverviewUpdateAt = Date()
        } else {
            DebugLog.log("[copilot] overview update failed (keeping previous)")
        }
    }

    // MARK: - 純関数ヘルパー (テスト対象)

    /// 直近 minutes 分に確定したエントリを抽出する。
    static func entriesInWindow(
        _ entries: [TranscriptEntry],
        minutes: Int,
        now: Date = Date()
    ) -> [TranscriptEntry] {
        let cutoff = now.addingTimeInterval(-Double(minutes) * 60)
        return entries.filter { $0.isFinal && $0.createdAt >= cutoff && !$0.text.isEmpty }
    }

    /// Catchup カードの期間ラベル (例: "14:03〜14:06")。
    static func periodLabel(from: Date, to: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return "\(fmt.string(from: from))〜\(fmt.string(from: to))"
    }

    /// LLM に渡す転写テキスト (話者ラベル付き)。
    static func transcriptText(_ entries: [TranscriptEntry]) -> String {
        entries.map { "[\($0.speaker.displayName)] \($0.text)" }.joined(separator: "\n")
    }
}
