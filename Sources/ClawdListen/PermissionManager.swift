import AVFoundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

/// マイク権限と画面収録権限の確認・リクエストを一元管理する
enum PermissionManager {
    // applicationDidBecomeActive ごとに SCShareableContent を叩くとCPUを食うので、
    // 直前の更新から N 秒以内なら skip する throttle 用タイムスタンプ。
    private static let refreshThrottleSeconds: TimeInterval = 30
    @MainActor private static var lastRefreshAt: TimeInterval = 0

    @MainActor
    static func refreshAll() {
        refreshMicrophone()
        Task { await refreshScreenRecordingThrottled() }
    }

    /// applicationDidBecomeActive など頻繁に呼ばれる場所から使う throttle 版。
    /// 直前の成功から `refreshThrottleSeconds` 秒以内 かつ既に granted なら skip。
    @MainActor
    static func refreshScreenRecordingThrottled() async {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastRefreshAt
        if AppState.shared.screenRecordingPermission == .granted && elapsed < refreshThrottleSeconds {
            return
        }
        lastRefreshAt = now
        await refreshScreenRecording()
    }

    @MainActor
    static func refreshMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        AppState.shared.microphonePermission = mapAVAuthStatus(status)
    }

    /// ScreenCaptureKit の実APIを叩いて画面収録許可を確認する。
    /// CGPreflightScreenCaptureAccess は ad-hoc 署名や再ビルド時に不正確なので使わない。
    static func refreshScreenRecording() async {
        let granted: Bool
        var errorDetail: String?
        if #available(macOS 13.0, *) {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                // 成功時はログに出さない (頻繁すぎてバッテリー&ノイズ源になるため)。
                granted = true
            } catch {
                DebugLog.log("[ClawdListen] SCShareableContent FAIL: \(error.localizedDescription)")
                errorDetail = "\(error.localizedDescription)"
                granted = false
            }
        } else {
            granted = CGPreflightScreenCaptureAccess()
        }
        await MainActor.run {
            AppState.shared.screenRecordingPermission = granted ? .granted : .notDetermined
            if !granted {
                AppState.shared.lastError = "画面収録: \(errorDetail ?? "unknown")"
            } else if AppState.shared.lastError?.hasPrefix("画面収録") == true {
                AppState.shared.lastError = nil
            }
        }
    }

    /// マイク使用許可をリクエスト (初回はOSダイアログが出る)
    static func requestMicrophone() async {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        await MainActor.run {
            AppState.shared.microphonePermission = granted ? .granted : .denied
        }
    }

    /// 画面収録許可をリクエスト。
    /// 初回は OS が自動でダイアログを出し、ユーザーがシステム設定で許可した後に
    /// アプリを再起動する必要がある。
    @MainActor
    static func requestScreenRecording() {
        // 許可済みならそのまま
        if CGPreflightScreenCaptureAccess() {
            AppState.shared.screenRecordingPermission = .granted
            return
        }
        // 未許可ならリクエスト (システム設定を開くプロンプトが出る)
        _ = CGRequestScreenCaptureAccess()
        // CGRequestScreenCaptureAccess は即時 true/false を返さないので
        // ユーザーが設定画面で許可→アプリ再起動で反映される
        AppState.shared.screenRecordingPermission = .notDetermined
    }

    /// システム設定の「プライバシーとセキュリティ」を開く
    static func openSystemSettings(for pane: SettingsPane) {
        let url: URL
        switch pane {
        case .microphone:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
        NSWorkspace.shared.open(url)
    }

    enum SettingsPane {
        case microphone
        case screenRecording
    }

    private static func mapAVAuthStatus(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
}
