import Foundation

/// 右カラム「Copilotパネル」のロジック統括。
/// - Catchup要約: ボタン押下で直近N分の転写を日本語要約してカード追加
/// - 全体像: 発話が溜まったら自動で「目的/議題/現在地」を更新
/// LLM は録音開始時に固定したプロバイダーへ統一。失敗しても録音・文字起こしには影響しない。
@MainActor
final class CopilotController {
    static let shared = CopilotController()

    private init() {}

    // MARK: - 全体像の自動更新トリガー設定
    //
    // 2026-08-10 に61分の英語講義でコスト内訳を実測した結果、全体像 (Overview) の
    // 自動更新が総額 $0.8197 の**40%超**を占めていた (STT 25% / 整形+対訳 32% を上回る)。
    // 全体像は「目的/議題/現在地」という遅く動く情報なので、この頻度は明らかに過多。
    // 各トリガーを約2倍に緩めて呼び出し回数を半分以下にする。
    // 内部定数だが、閾値がテストで固定できるよう internal で公開している。

    /// 監視ループの周期 (コスト削減: 30→60 秒)
    static let monitorInterval: TimeInterval = 60
    /// 初回の全体像がまだ無いあいだの監視周期。
    /// `monitorInterval` を60秒に伸ばすと**初回表示が最大60秒待ち**になり、
    /// 「傍聴中…」が長く残って体感が悪い。初回は1会議1回しか走らずコストに影響しないので、
    /// 従来の30秒を維持して初回だけ速く出す。
    static let firstOverviewMonitorInterval: TimeInterval = 30
    /// 「発話量」トリガー: 前回更新から新規に確定した文字数がこれを超えたら更新
    /// (コスト削減: 1,200→2,400 に緩めて呼び出しを半減 → 2026-08-10 の実測を受けて
    ///  さらに 2,400→5,000。61分授業で Overview が総額の40%超だった)
    static let updateCharThreshold = 5_000
    /// 「経過時間」トリガー: 前回更新からこの秒数が経過し、かつ最低限の新規発話があれば更新
    /// (コスト削減: 180→300 秒 / 最低文字数 200→400。発話が薄い時間帯に
    ///  ほぼ同じ内容の全体像を作り直すのを防ぐ)
    static let updateTimeThreshold: TimeInterval = 300
    static let minCharsForTimeUpdate = 400
    /// 初回生成に必要な最低文字数 (これ未満は「傍聴中…」のまま)。
    /// **変更しない**: ここは初回表示の速さ = 体感に直結し、1会議1回しか効かないので
    /// コストにはほぼ影響しない。
    static let minCharsForFirstOverview = 300
    /// LLM へ渡す文字起こしの末尾クリップ幅。
    ///
    /// `updateCharThreshold` (新規5,000字で発火) より必ず**広く**なければならない:
    /// 窓が新規発話量を下回ると、更新の合間に流れた発話が一度も全体像に反映されないまま
    /// 窓の外へ出てしまう。2,400字閾値の頃は 6,000字で 2.5倍の余裕があったが、
    /// 5,000字に緩めた時点で 1.2倍まで縮んでいた (`isOverviewUpdating` 中の取りこぼしや
    /// 発話の急増で簡単に溢れる)。8,000字に広げて 1.6倍を確保する。
    /// 入力は約+600トークン ($0.0008/回) 増えるが、発火自体が1/3になるので総額は下がる。
    /// この不変条件は `CopilotControllerTests` で固定している。
    static let overviewContextChars = 8_000

    private var monitorTask: Task<Void, Never>?
    /// 実行中の Catchup。セッション終了/再開時に cancel し、旧セッションの
    /// 遅延応答が新セッションのカードリストや実行中フラグを汚さないようにする。
    private var catchupTask: Task<Void, Never>?
    /// 全体像の発火判定に使う状態。判定ロジックは純粋な値型 (`OverviewUpdateTrigger`)
    /// に切り出してあり、テストが監視ループを実際に回さずに検証できる。
    private var overviewTrigger = OverviewUpdateTrigger()
    private var activeProvider: AIProvider?
    private var activeAPIKey: String?

    // MARK: - セッションライフサイクル

    /// 録音開始時に呼ぶ。前セッションの状態をクリアして全体像の監視を開始する。
    func startSession(provider: AIProvider, apiKey: String) {
        catchupTask?.cancel()
        catchupTask = nil
        AppState.shared.catchupCards = []
        AppState.shared.overview = nil
        AppState.shared.isCatchupRunning = false
        AppState.shared.isOverviewUpdating = false
        overviewTrigger = OverviewUpdateTrigger()
        activeProvider = provider
        activeAPIKey = apiKey

        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                // 初回だけ短い周期で見る (初回表示の体感を犠牲にせずコストを削る)。
                let interval = AppState.shared.overview == nil
                    ? Self.firstOverviewMonitorInterval
                    : Self.monitorInterval
                try? await Task.sleep(for: .seconds(interval))
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
        activeProvider = nil
        activeAPIKey = nil
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
        guard let provider = activeProvider,
              let apiKey = activeAPIKey,
              !apiKey.isEmpty else { return }

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
            provider: provider,
            timeout: 20,
            cacheKey: PromptCacheKey.catchup,
            usageLabel: "catchup"
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
        guard overviewTrigger.shouldUpdate(
            textLength: fullText.count,
            hasOverview: AppState.shared.overview != nil,
            now: Date()
        ) else { return }
        guard let provider = activeProvider,
              let apiKey = activeAPIKey,
              !apiKey.isEmpty else { return }

        AppState.shared.isOverviewUpdating = true
        defer { AppState.shared.isOverviewUpdating = false }

        // 入力肥大を防ぐため末尾を `overviewContextChars` 文字に制限 (冒頭の目的把握は
        // 既存 overview が引き継ぐため、直近の文脈を優先する。コスト削減のため
        // 12,000→6,000 に縮小 → 2026-08-10 に updateCharThreshold を5,000へ緩めたので、
        // 更新の合間の発話を取りこぼさないよう 6,000→8,000 に戻した)
        let clipped = String(fullText.suffix(Self.overviewContextChars))
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
            provider: provider,
            timeout: 20,
            forceJSON: true,
            cacheKey: PromptCacheKey.overview,
            usageLabel: "overview"
        )
        if costUSD > 0 { AppState.shared.addCost(costUSD) }

        // **成功でも失敗でも状態を前進させる。** 失敗時に据え置くと `newChars` が
        // 閾値に張り付いたまま監視周期ごとに再試行し続け、課金が発散する
        // (2026-08-11 の監査 C3: 61分で7回のはずの全体像が約60回になり得る)。
        // 前進させる文字数はLLM呼び出し**前**に測った長さを使う (呼び出し中に
        // 流れた発話を「反映済み」にしてしまわないため)。
        overviewTrigger.recordAttempt(textLength: fullText.count, now: Date())

        // 失敗時は前の内容を維持 (チラつき・消失させない)
        if let text, let parsed = MeetingOverview.parse(text) {
            AppState.shared.overview = parsed
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

/// 全体像 (Overview) 自動更新の発火判定と状態前進だけを持つ値型。
///
/// `CopilotController` から切り出してあるのは、**発火回数が課金そのもの**なのに
/// 監視ループを実際に回さないと検証できない形だったため (閾値の定数ミラーだけでは
/// 呼び出し側を書き換えても全通してしまう)。ここに切り出すことで
/// 「失敗が連続しても発火回数が増え続けない」不変条件をテストで直接固定できる。
///
/// 状態は「前回**試行**時」を指す。成功時だけでなく失敗時も前進させるのが要点:
/// 据え置くと `newChars` が閾値に張り付き、監視周期ごとに再試行し続ける
/// (2026-08-11 監査 C3)。閾値は `CopilotController` の static 定数を唯一の出典とし、
/// MainActor 隔離を合わせるためこの型も `@MainActor` にしている。
@MainActor
struct OverviewUpdateTrigger: Equatable {
    /// 前回試行時の文字起こし全文の長さ。
    private(set) var lastTextLength = 0
    /// 前回試行の時刻。
    private(set) var lastAttemptAt = Date.distantPast
    /// これまでの試行回数 (成功・失敗の別を問わない)。
    private(set) var attempts = 0

    /// 初回の全体像が出るまでに「速い周期」での試行を許す回数。
    ///
    /// 初回判定は `overview == nil` の間ずっと真になる条件 (全文長のみ) なので、
    /// パースが失敗し続けると 30秒ごとに永久に再試行してしまう
    /// (失敗時に状態を前進させても、初回条件が状態を見ないので効かない)。
    /// 一時的な失敗からは速く復帰したいので即座には諦めず、この回数を超えたら
    /// 通常のカデンス (文字数 / 経過時間) に落として発散を止める。
    static let maxFastFirstAttempts = 3

    /// 発火すべきか。判定は副作用なし。
    /// - Parameters:
    ///   - textLength: 文字起こし全文の現在の長さ
    ///   - hasOverview: すでに全体像が表示されているか (= 初回生成が成功済みか)
    func shouldUpdate(textLength: Int, hasOverview: Bool, now: Date) -> Bool {
        // 初回だけは最低文字数のみで速く出す (体感優先)。ただし有限回まで。
        if !hasOverview && attempts < Self.maxFastFirstAttempts {
            return textLength >= CopilotController.minCharsForFirstOverview
        }
        let newChars = textLength - lastTextLength
        let elapsed = now.timeIntervalSince(lastAttemptAt)
        return newChars >= CopilotController.updateCharThreshold
            || (elapsed >= CopilotController.updateTimeThreshold
                && newChars >= CopilotController.minCharsForTimeUpdate)
    }

    /// LLM 呼び出しを1回行ったことを記録する。**成功・失敗どちらでも呼ぶ。**
    mutating func recordAttempt(textLength: Int, now: Date) {
        lastTextLength = textLength
        lastAttemptAt = now
        attempts += 1
    }
}
