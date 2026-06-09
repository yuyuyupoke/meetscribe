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

    // Q&A に使う Claude モデル (UI で切替可能)
    var selectedModel: ClaudeModel = .sonnet

    // Claude 回答生成中フラグ
    var isAsking: Bool = false

    // 質問入力欄の状態 (E2Eテストから触れるようここに置く)
    var queryText: String = ""

    // OpenAI API 累計コスト (USD) — 現セッションのみ、再起動でリセット
    var totalCostUSD: Double = 0.0

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
        if let url = Self.loadFolder(key: Self.meetingsKey) {
            self.meetingsSaveDirectoryURL = url
        }
        if let url = Self.loadFolder(key: Self.knowledgeKey) {
            self.knowledgeFolderURL = url
        }
    }

    // MARK: - フォルダ永続化 (Security-Scoped Bookmark)

    private static let meetingsKey = "meetingsSaveDirectoryBookmark"
    private static let knowledgeKey = "knowledgeFolderBookmark"

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

    /// 録音開始できる状態か (権限 + API Key + 議事録保存先 + idle)
    var canStart: Bool {
        allPermissionsGranted
            && KeychainStore.hasAPIKey
            && meetingsSaveDirectoryURL != nil
            && captureStatus == .idle
    }
}
