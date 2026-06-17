import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        let hostingController = NSHostingController(rootView: contentView)

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "MeetScribe"
        panel.contentViewController = hostingController
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)

        setupMenuBar()

        // MEETSCRIBE_SMOKE_TEST=1 が指定されていたら、モデル切替を自動で回して
        // クラッシュしないかを検証する (Phase 4 回帰テスト用)
        if ProcessInfo.processInfo.environment["MEETSCRIBE_SMOKE_TEST"] == "1" {
            runSmokeTest()
        }

        // MEETSCRIBE_AUTO_RECORD=1: 自動回帰テスト用。起動直後に録音開始 → N秒待機 →
        // 録音停止 → 議事録保存 → アプリ終了。MEETSCRIBE_AUTO_RECORD_SEC で録音時間
        // を指定 (デフォルト 10秒)。MEETSCRIBE_AUTO_MEETINGS_DIR で議事録保存先を
        // 一時的に上書き (テスト用、永続化はされない場合がある)。外部から
        // `say` 等で音声を流して文字起こしが動くか検証するためのフック。
        if ProcessInfo.processInfo.environment["MEETSCRIBE_AUTO_RECORD"] == "1" {
            let seconds = TimeInterval(
                ProcessInfo.processInfo.environment["MEETSCRIBE_AUTO_RECORD_SEC"]
                    .flatMap { Double($0) } ?? 10.0
            )
            Task { @MainActor in
                // テスト用に議事録保存先を環境変数から上書き
                if let dir = ProcessInfo.processInfo.environment["MEETSCRIBE_AUTO_MEETINGS_DIR"] {
                    let url = URL(fileURLWithPath: dir)
                    try? FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: true
                    )
                    AppState.shared.meetingsSaveDirectoryURL = url
                    NSLog("[AUTO_RECORD] meetings dir set to \(dir)")
                }
                NSLog("[AUTO_RECORD] starting in 2s …")
                try? await Task.sleep(for: .seconds(2))
                await AudioSession.shared.start()
                NSLog("[AUTO_RECORD] recording for \(seconds)s")
                try? await Task.sleep(for: .seconds(seconds))
                NSLog("[AUTO_RECORD] stopping & saving")
                await AudioSession.shared.stop()
                // タイトル生成 + 保存完了待ち
                try? await Task.sleep(for: .seconds(20))
                NSLog("[AUTO_RECORD] done, terminating")
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - メニューバー常駐

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MeetScribe")
            button.image?.isTemplate = true
            button.toolTip = "MeetScribe"
        }

        let menu = NSMenu()
        menu.delegate = self

        let show = NSMenuItem(title: "ウィンドウを表示", action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        let rec = NSMenuItem(title: "録音開始", action: #selector(toggleRecording), keyEquivalent: "")
        rec.target = self
        rec.tag = 100
        menu.addItem(rec)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "MeetScribe を終了", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item

        // 録音中はメニューバーアイコンを赤く着色 (0.5秒間隔で同期)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statusItem?.button?.contentTintColor =
                    AppState.shared.isRunning ? .systemRed : nil
            }
        }
    }

    @objc private func showMainWindow() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleRecording() {
        Task { @MainActor in
            if AppState.shared.isRunning {
                await AudioSession.shared.stop()
            } else if AppState.shared.canStart {
                await AudioSession.shared.start()
            } else {
                // 録音開始できない場合はセットアップを促すためウィンドウを出す
                self.panel?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func runSmokeTest() {
        Task { @MainActor in
            NSLog("[SMOKE] Starting smoke test")
            let state = AppState.shared

            // 1. モデル切替
            let models: [ClaudeModel] = [.opus, .sonnet, .haiku, .opus, .haiku, .sonnet]
            for (i, m) in models.enumerated() {
                state.selectedModel = m
                NSLog("[SMOKE] model \(i+1)/\(models.count): \(m.displayName)")
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSLog("[SMOKE] ✅ model switching passed")

            // 2. ClaudeQAClient 初期化
            do {
                _ = try ClaudeQAClient()
                NSLog("[SMOKE] ✅ ClaudeQAClient init passed")
            } catch {
                NSLog("[SMOKE] ⚠️ ClaudeQAClient init failed: \(error.localizedDescription)")
            }

            // 3. queryText 状態更新 (TextField 相当)
            let samples = ["こ", "こん", "こんに", "こんにちは", ""]
            for s in samples {
                state.queryText = s
                NSLog("[SMOKE] queryText = '\(s)'")
                try? await Task.sleep(for: .milliseconds(80))
            }
            NSLog("[SMOKE] ✅ queryText update passed")

            // 4. TranscriptStore 操作
            let qaId = TranscriptStore.shared.startClaudeAnswer()
            TranscriptStore.shared.appendToAnswer(itemId: qaId, chunk: "テスト応答")
            TranscriptStore.shared.finalizeAnswer(itemId: qaId)
            NSLog("[SMOKE] ✅ transcript store passed")

            // 5. 権限状態更新
            state.microphonePermission = .granted
            state.screenRecordingPermission = .granted
            state.micLevel = 0.5
            state.systemLevel = 0.3
            try? await Task.sleep(for: .milliseconds(100))
            state.micLevel = 0.0
            state.systemLevel = 0.0
            NSLog("[SMOKE] ✅ state updates passed")

            // 6. Phase 5 — 議事録保存フロー (タイトル生成はスキップ)
            await Self.runPhase5SmokeTest()

            NSLog("[SMOKE] 🎉 all smoke tests passed")
            try? await Task.sleep(for: .seconds(1))
            NSApp.terminate(nil)
        }
    }

    /// Phase 5 専用 smoke test: 文字起こしダミー追加 → TranscriptExporter.save()
    @MainActor
    private static func runPhase5SmokeTest() async {
        // サンプル文字起こしを注入
        TranscriptStore.shared.clear()
        let now = Date()
        for (i, (spk, text)) in [
            (SpeakerLabel.me, "こんにちは、テストです"),
            (SpeakerLabel.other, "了解しました、進めましょう"),
            (SpeakerLabel.me, "よろしくお願いします")
        ].enumerated() {
            TranscriptStore.shared.completeItem(
                itemId: "smk-\(i)",
                finalText: text,
                speaker: spk
            )
        }

        // Q&A も1件
        TranscriptStore.shared.addUserQuery("テスト質問")
        let aid = TranscriptStore.shared.startClaudeAnswer()
        TranscriptStore.shared.appendToAnswer(itemId: aid, chunk: "テスト応答")
        TranscriptStore.shared.finalizeAnswer(itemId: aid)

        // 保存先を一時ディレクトリにして TranscriptExporter を直接検証
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "meetscribe-smoke-\(UUID().uuidString.prefix(8))")
        let record = MeetingRecord(
            startedAt: now.addingTimeInterval(-60),
            endedAt: now,
            title: "スモークテスト会議",
            meetingEntries: TranscriptStore.shared.meetingEntries,
            qaEntries: TranscriptStore.shared.qaEntries,
            totalCostUSD: 0.0042,
            model: "gpt-4o-transcribe"
        )
        do {
            let url = try TranscriptExporter.save(record, to: tmpDir)
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if content.contains("スモークテスト会議") && content.contains("こんにちは、テストです") {
                NSLog("[SMOKE] ✅ TranscriptExporter save passed: \(url.lastPathComponent)")
            } else {
                NSLog("[SMOKE] ❌ exported content unexpected")
            }
            try? FileManager.default.removeItem(at: tmpDir)
        } catch {
            NSLog("[SMOKE] ❌ TranscriptExporter save failed: \(error.localizedDescription)")
        }

        TranscriptStore.shared.clear()
        NSLog("[SMOKE] ✅ Phase 5 save flow passed")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 権限再チェックは throttle 版で。SCShareableContent を毎フォーカス時に
        // 叩くと CPU/バッテリーを食うため、既に granted なら 30秒は再確認しない。
        Task { @MainActor in
            PermissionManager.refreshMicrophone()
            await PermissionManager.refreshScreenRecordingThrottled()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // メニューバー常駐のため、ウィンドウを閉じてもアプリは終了しない。
        // 終了はメニューバーの「MeetScribe を終了」から。
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 共有オーディオリソース (Voice Processing IO / SCStream) を同期解放する。
        // これを怠ると coreaudiod に孤児リソースが残り、終了後に Mac 全体の
        // オーディオ HAL がブロックしてフリーズする。録音中の終了でも安全に。
        statusTimer?.invalidate()
        statusTimer = nil
        AudioSession.shared.shutdownSync()
    }
}

extension AppDelegate: NSWindowDelegate {
    /// ×ボタン = アプリ終了。applicationWillTerminate → shutdownSync で録音と
    /// 画面共有 (ScreenCaptureKit / SCStream) を停止してから終了する。
    /// 「隠す」のではなく「終了」する (ウィンドウを残したいときは −ボタンで最小化)。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // 録音状態に応じてメニュー項目のラベル/有効状態を更新
        guard let rec = menu.item(withTag: 100) else { return }
        let state = AppState.shared
        if state.isRunning {
            rec.title = "録音停止 & 議事録保存"
            rec.isEnabled = true
        } else {
            rec.title = "録音開始"
            rec.isEnabled = state.canStart
        }
    }
}
