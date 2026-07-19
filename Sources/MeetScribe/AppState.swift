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

    // ローカル知識源フォルダ (Q&A 時に Claude が参照、任意)。
    // UserDefaults キー "knowledgeFolderBookmark" にブックマークデータで永続化。
    var knowledgeFolderURL: URL? {
        didSet { Self.persistFolder(knowledgeFolderURL, key: Self.knowledgeKey) }
    }

    private init() {
        if let rawProvider = UserDefaults.standard.string(forKey: Self.providerKey),
           let provider = AIProvider(rawValue: rawProvider) {
            self.selectedProvider = provider
        }
        if let url = Self.loadFolder(key: Self.meetingsKey) {
            self.meetingsSaveDirectoryURL = url
        }
        if let url = Self.loadFolder(key: Self.knowledgeKey) {
            self.knowledgeFolderURL = url
        }
        if let lang = UserDefaults.standard.string(forKey: Self.languageKey),
           Self.supportedLanguages.contains(lang) {
            self.transcriptionLanguage = lang
        }
        if UserDefaults.standard.object(forKey: Self.translationsKey) != nil {
            self.showTranslations = UserDefaults.standard.bool(forKey: Self.translationsKey)
        }
    }

    // MARK: - フォルダ永続化 (Security-Scoped Bookmark)

    private static let meetingsKey = "meetingsSaveDirectoryBookmark"
    private static let knowledgeKey = "knowledgeFolderBookmark"
    private static let providerKey = "selectedAIProvider"
    private static let languageKey = "transcriptionLanguage"

    /// 言語設定の許容値 (UI の Picker と対応)。UserDefaults 破損対策。
    static let supportedLanguages: Set<String> = ["auto", "ja", "en"]
    private static let translationsKey = "showTranslations"

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

    /// 録音開始できる状態か (権限 + API Key + 議事録保存先 + 開始可能ステータス)
    var canStart: Bool {
        Self.computeCanStart(
            permissionsGranted: allPermissionsGranted,
            hasAPIKey: hasAPIKey,
            saveFolderSet: meetingsSaveDirectoryURL != nil,
            status: captureStatus
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
            status: captureStatus
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
        status: CaptureStatus
    ) -> String? {
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
    static func computeCanStart(
        permissionsGranted: Bool,
        hasAPIKey: Bool,
        saveFolderSet: Bool,
        status: CaptureStatus
    ) -> Bool {
        let startable: Bool
        switch status {
        case .idle, .error:
            startable = true
        case .starting, .running, .stopping:
            startable = false
        }
        return permissionsGranted && hasAPIKey && saveFolderSet && startable
    }
}
