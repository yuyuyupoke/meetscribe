import Foundation
import Observation

enum CaptureStatus: Equatable {
    case idle
    case starting
    case running
    case stopping
    case error(String)
}

enum PermissionState: Equatable {
    case unknown
    case granted
    case denied
    case notDetermined
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // キャプチャ全体の状態
    var captureStatus: CaptureStatus = .idle

    // 権限状態
    var microphonePermission: PermissionState = .unknown
    var screenRecordingPermission: PermissionState = .unknown

    // 音声レベル (dBFS 正規化: 0.0=無音, 1.0=最大)
    var micLevel: Float = 0.0
    var systemLevel: Float = 0.0

    // 直近のエラーメッセージ
    var lastError: String?

    // 選択中プロバイダーのAPI累計コスト (USD) — 現セッションのみ
    var totalCostUSD: Double = 0.0

    // 会議に使うプロバイダー。次回の録音開始から適用され、UserDefaultsへ永続化。
    var selectedProvider: AIProvider = .openAI {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: Self.providerKey) }
    }

    // Keychain の登録状態をUIへ反映するキャッシュ。キー文字列自体は保持しない。
    var hasOpenAIAPIKey: Bool = KeychainStore.hasAPIKey(for: .openAI)
    var hasXAIAPIKey: Bool = KeychainStore.hasAPIKey(for: .xAI)

    /// 選択中プロバイダーのAPIキー登録状態。既存UI/判定との互換名。
    var hasAPIKey: Bool { hasAPIKey(for: selectedProvider) }

    func hasAPIKey(for provider: AIProvider) -> Bool {
        switch provider {
        case .openAI: return hasOpenAIAPIKey
        case .xAI: return hasXAIAPIKey
        }
    }

    func setHasAPIKey(_ value: Bool, for provider: AIProvider) {
        switch provider {
        case .openAI: hasOpenAIAPIKey = value
        case .xAI: hasXAIAPIKey = value
        }
    }

    // 文字起こし言語 ("auto" = 自動検出, それ以外は ISO-639-1 コード)。
    // 次回の録音開始から適用される。UserDefaults に永続化。
    var transcriptionLanguage: String = "auto" {
        didSet { UserDefaults.standard.set(transcriptionLanguage, forKey: Self.languageKey) }
    }

    /// TranscriptionClient に渡す language 値。"auto" は nil (パラメータ省略 = 自動検出)。
    var transcriptionLanguageCode: String? {
        transcriptionLanguage == "auto" ? nil : transcriptionLanguage
    }

    // 対訳表示 (英語セグメントの下に日本語訳を併記) の ON/OFF。UserDefaults 永続化。
    var showTranslations: Bool = true {
        didSet { UserDefaults.standard.set(showTranslations, forKey: Self.translationsKey) }
    }

    // MARK: - 開発の応援バナー

    /// 議事録を保存した累計回数。応援バナーの表示判定に使う。
    var meetingSaveCount: Int = 0 {
        didSet { UserDefaults.standard.set(meetingSaveCount, forKey: Self.saveCountKey) }
    }

    /// 応援バナーを最後に表示した日時。
    var supportPromptLastShownAt: Date? {
        didSet {
            UserDefaults.standard.set(
                supportPromptLastShownAt?.timeIntervalSince1970 ?? 0,
                forKey: Self.supportShownKey
            )
        }
    }

    /// 「今後表示しない」を選んだか。
    var supportPromptDismissed: Bool = false {
        didSet { UserDefaults.standard.set(supportPromptDismissed, forKey: Self.supportDismissedKey) }
    }

    /// 応援バナーを出す最小保存回数。数回使って価値を感じてもらってから初めて出す。
    nonisolated static let supportPromptMinSaves = 3
    /// 一度出したら次に出すまで置く間隔。
    nonisolated static let supportPromptInterval: TimeInterval = 30 * 24 * 60 * 60

    /// 応援バナーを表示すべきか (純関数)。
    /// 押し付けにならないよう「十分使った」「前回から間隔が空いた」「拒否していない」
    /// の3条件を満たすときだけ出す。
    nonisolated static func shouldShowSupportPrompt(
        saveCount: Int,
        lastShownAt: Date?,
        dismissed: Bool,
        now: Date
    ) -> Bool {
        guard !dismissed else { return false }
        guard saveCount >= supportPromptMinSaves else { return false }
        guard let lastShownAt else { return true }
        return now.timeIntervalSince(lastShownAt) >= supportPromptInterval
    }

    /// 現在の状態で応援バナーを出すべきか。
    var shouldShowSupportPrompt: Bool {
        Self.shouldShowSupportPrompt(
            saveCount: meetingSaveCount,
            lastShownAt: supportPromptLastShownAt,
            dismissed: supportPromptDismissed,
            now: Date()
        )
    }

    /// 外部送信と録音についての説明に同意済みか。
    /// 音声が第三者API (OpenAI / xAI) へ送られること、会議参加者への録音告知が
    /// 利用者の責任であることを、最初の録音より前に必ず提示する。
    var hasAcceptedDisclosure: Bool = false {
        didSet { UserDefaults.standard.set(hasAcceptedDisclosure, forKey: Self.disclosureKey) }
    }

    // MARK: - UI 文字スケール (⌘+ / ⌘- / ⌘0)

    /// UI 全体の文字スケール (1.0 = 標準)。フォントサイズに乗算して適用する。
    /// メインメニュー「表示」の 拡大/縮小/実際のサイズ から変更、UserDefaults 永続化。
    var uiScale: Double = 1.0 {
        didSet { UserDefaults.standard.set(uiScale, forKey: Self.uiScaleKey) }
    }

    nonisolated static let uiScaleRange: ClosedRange<Double> = 0.8...1.8
    nonisolated static let uiScaleStep: Double = 0.1

    func zoomIn() { uiScale = Self.steppedScale(uiScale, by: +Self.uiScaleStep) }
    func zoomOut() { uiScale = Self.steppedScale(uiScale, by: -Self.uiScaleStep) }
    func zoomReset() { uiScale = 1.0 }

    /// スケールを1段階増減する (範囲クランプ + 浮動小数点誤差の10分の1丸め)。純関数。
    nonisolated static func steppedScale(_ current: Double, by delta: Double) -> Double {
        let next = ((current + delta) * 10).rounded() / 10
        return min(max(next, uiScaleRange.lowerBound), uiScaleRange.upperBound)
    }

    // MARK: - Copilot (右カラム: Catchup要約 + 全体像)

    /// Catchup要約カード (新しい順)。録音開始でクリア。
    var catchupCards: [CatchupCard] = []

    /// Catchup実行中フラグ (ボタン無効化用)
    var isCatchupRunning: Bool = false

    /// AIが傍聴して自動更新する会議の全体像。nil = まだ情報不足
    var overview: MeetingOverview?

    /// 全体像の更新中フラグ (パネル右上のスピナー用)
    var isOverviewUpdating: Bool = false

    /// 再接続中のストリーム集合。UI でバッジ表示するため。
    /// AudioSession.runReconnectLoop が出し入れする。
    var reconnectingStreams: Set<SpeakerLabel> = []

    /// ミュート中 (Scribe に聴かせない) のストリーム集合。UI 表示用。
    /// 実際のフレーム破棄はオーディオスレッドが StreamMuteState を読んで行うため、
    /// didSet で同期する。持ち越し事故 (次の会議で片側が文字起こしされない) を
    /// 防ぐため、録音終了時に AudioSession.tearDown がリセットする。
    var mutedStreams: Set<SpeakerLabel> = [] {
        didSet { StreamMuteState.shared.sync(with: mutedStreams) }
    }

    func toggleMute(_ speaker: SpeakerLabel) {
        if mutedStreams.contains(speaker) {
            mutedStreams.remove(speaker)
        } else {
            mutedStreams.insert(speaker)
        }
    }

    // 会議の開始時刻 (nil = 未録音)
    var meetingStartedAt: Date?

    // 直近保存した議事録の URL (UI表示用)
    var lastSavedURL: URL?

    // 保存フロー (タイトル生成含む) 進行中
    var isSavingMeeting: Bool = false

    // 議事録保存先フォルダ (必須・ユーザー指定)。
    // 未設定なら録音停止後の保存ができないため、起動時セットアップで必ず選択させる。
    // UserDefaults キー "meetingsSaveDirectoryBookmark" にブックマークデータで永続化。
    var meetingsSaveDirectoryURL: URL? {
        didSet { Self.persistFolder(meetingsSaveDirectoryURL, key: Self.meetingsKey) }
    }

    private init() {
        // 撤去済みの知識源フォルダ (旧 claude -p Q&A) のブックマークを掃除
        UserDefaults.standard.removeObject(forKey: "knowledgeFolderBookmark")
        if let rawProvider = UserDefaults.standard.string(forKey: Self.providerKey),
           let provider = AIProvider(rawValue: rawProvider) {
            self.selectedProvider = provider
        }
        if let url = Self.loadFolder(key: Self.meetingsKey) {
            self.meetingsSaveDirectoryURL = url
        }
        if let lang = UserDefaults.standard.string(forKey: Self.languageKey),
           Self.supportedLanguages.contains(lang) {
            self.transcriptionLanguage = lang
        }
        if UserDefaults.standard.object(forKey: Self.translationsKey) != nil {
            self.showTranslations = UserDefaults.standard.bool(forKey: Self.translationsKey)
        }
        self.hasAcceptedDisclosure = UserDefaults.standard.bool(forKey: Self.disclosureKey)
        self.meetingSaveCount = UserDefaults.standard.integer(forKey: Self.saveCountKey)
        self.supportPromptDismissed = UserDefaults.standard.bool(forKey: Self.supportDismissedKey)
        let shownAt = UserDefaults.standard.double(forKey: Self.supportShownKey)
        if shownAt > 0 {
            self.supportPromptLastShownAt = Date(timeIntervalSince1970: shownAt)
        }
        let storedScale = UserDefaults.standard.double(forKey: Self.uiScaleKey)
        if storedScale > 0 {
            // 破損・旧バージョン値対策で必ず範囲へクランプする
            self.uiScale = min(max(storedScale, Self.uiScaleRange.lowerBound), Self.uiScaleRange.upperBound)
        }
    }

    // MARK: - フォルダ永続化 (Security-Scoped Bookmark)

    private static let meetingsKey = "meetingsSaveDirectoryBookmark"
    private static let providerKey = "selectedAIProvider"
    private static let languageKey = "transcriptionLanguage"

    /// 言語設定の許容値 (UI の Picker と対応)。UserDefaults 破損対策。
    static let supportedLanguages: Set<String> = ["auto", "ja", "en"]
    private static let translationsKey = "showTranslations"
    private static let uiScaleKey = "uiScale"
    private static let disclosureKey = "hasAcceptedDisclosure"
    private static let saveCountKey = "meetingSaveCount"
    private static let supportShownKey = "supportPromptLastShownAt"
    private static let supportDismissedKey = "supportPromptDismissed"

    private static func persistFolder(_ url: URL?, key: String) {
        let defaults = UserDefaults.standard
        guard let url = url else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: key)
        } catch {
            NSLog("folder bookmark save failed (\(key)): \(error.localizedDescription)")
        }
    }

    private static func loadFolder(key: String) -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            _ = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            NSLog("folder bookmark load failed (\(key)): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 派生プロパティ

    func addCost(_ usd: Double) {
        totalCostUSD += usd
    }

    var isRunning: Bool {
        if case .running = captureStatus { return true }
        return false
    }

    var allPermissionsGranted: Bool {
        microphonePermission == .granted && screenRecordingPermission == .granted
    }

    /// 録音中にプロバイダーを変えると再接続・整形先が混在するため変更不可。
    var canChangeProvider: Bool {
        switch captureStatus {
        case .idle, .error: return true
        case .starting, .running, .stopping: return false
        }
    }

    /// 録音開始できる状態か (同意 + 権限 + API Key + 議事録保存先 + 開始可能ステータス)
    var canStart: Bool {
        Self.computeCanStart(
            permissionsGranted: allPermissionsGranted,
            hasAPIKey: hasAPIKey,
            saveFolderSet: meetingsSaveDirectoryURL != nil,
            status: captureStatus,
            disclosureAccepted: hasAcceptedDisclosure
        )
    }

    /// 録音を開始できない理由 (最初に見つかった1つ)。ツールチップ表示用。
    /// canStart が true のときは nil。
    var startBlockReason: String? {
        Self.computeStartBlockReason(
            microphoneGranted: microphonePermission == .granted,
            screenRecordingGranted: screenRecordingPermission == .granted,
            hasAPIKey: hasAPIKey,
            providerName: selectedProvider.shortDisplayName,
            saveFolderSet: meetingsSaveDirectoryURL != nil,
            status: captureStatus,
            disclosureAccepted: hasAcceptedDisclosure
        )
    }

    /// startBlockReason の判定ロジック (純関数)。computeCanStart と同じ条件の
    /// 言語化なので、「reason == nil ⇔ canStart == true」の整合をテストで固定する。
    static func computeStartBlockReason(
        microphoneGranted: Bool,
        screenRecordingGranted: Bool,
        hasAPIKey: Bool,
        providerName: String = "選択中プロバイダー",
        saveFolderSet: Bool,
        status: CaptureStatus,
        disclosureAccepted: Bool
    ) -> String? {
        if !disclosureAccepted { return "ご利用前の説明への同意が必要です" }
        if !microphoneGranted { return "マイク権限の許可が必要です" }
        if !screenRecordingGranted { return "画面収録権限の許可が必要です" }
        if !hasAPIKey { return "\(providerName) APIキーが未設定です（フッターの🔑から登録）" }
        if !saveFolderSet { return "議事録の保存先が未設定です（フッターから選択）" }
        switch status {
        case .starting: return "開始処理中です"
        case .stopping: return "停止処理中です"
        case .running: return "録音中です"
        case .idle, .error: return nil
        }
    }

    /// canStart の判定ロジック (テスト可能にするため純関数に分離)。
    /// `.error` からも開始可能にする — 接続タイムアウト等でエラーになった後、
    /// アプリ再起動しないと録音ボタンが復活しない事故を防ぐ (再試行はいつでも安全:
    /// start() は冒頭で状態をリセットして進むため)。
    /// - Parameter disclosureAccepted: 外部送信・録音についての説明への同意。
    ///   同意前に音声を第三者APIへ送らないための最終ガード (UI側はシートで強制する)。
    ///   省略できるようにすると新しい呼び出し元が同意チェックを素通りしうるため必須にする。
    static func computeCanStart(
        permissionsGranted: Bool,
        hasAPIKey: Bool,
        saveFolderSet: Bool,
        status: CaptureStatus,
        disclosureAccepted: Bool
    ) -> Bool {
        let startable: Bool
        switch status {
        case .idle, .error:
            startable = true
        case .starting, .running, .stopping:
            startable = false
        }
        return permissionsGranted && hasAPIKey && saveFolderSet && startable && disclosureAccepted
    }
}
