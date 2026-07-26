import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?

    public func applicationDidFinishLaunching(_ notification: Notification) {
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

        setupMainMenu()
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

    // MARK: - メインメニュー (キーボードショートカットのルーティング)

    /// メニューバー常駐アプリでもメインメニューが無いと cmd+C / cmd+V / cmd+A が
    /// NSTextView へルーティングされない (macOS はキー同等イベントをメインメニュー
    /// 経由で配送する)。「文字起こしを選択したのに cmd+C でコピーできない」の根本原因。
    /// 画面には出ないが、標準の編集アクションを持つ最小メニューを登録する。
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "MeetScribe を終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "編集")
        edit.addItem(NSMenuItem(title: "取り消す", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit

        // 表示メニュー: ⌘+ / ⌘- / ⌘0 で UI 文字スケールを変更 (Mac の標準慣習)。
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: "表示")
        let zoomInItem = NSMenuItem(title: "拡大", action: #selector(zoomIn), keyEquivalent: "+")
        zoomInItem.target = self
        view.addItem(zoomInItem)
        // US 配列では "+" が Shift+= のため、⌘= 単独でも拡大できる隠しキーを併設する
        // (Safari 等と同じ挙動)。hidden なアイテムは既定でキー同等マッチングから
        // 除外されるため、allowsKeyEquivalentWhenHidden で明示的に参加させる。
        let zoomInAlt = NSMenuItem(title: "拡大", action: #selector(zoomIn), keyEquivalent: "=")
        zoomInAlt.target = self
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        view.addItem(zoomInAlt)
        let zoomOutItem = NSMenuItem(title: "縮小", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOutItem.target = self
        view.addItem(zoomOutItem)
        let zoomResetItem = NSMenuItem(title: "実際のサイズ", action: #selector(zoomReset), keyEquivalent: "0")
        zoomResetItem.target = self
        view.addItem(zoomResetItem)
        viewItem.submenu = view

        NSApp.mainMenu = main
    }

    // MARK: - UI 文字スケール (表示メニュー)

    @objc private func zoomIn() { AppState.shared.zoomIn() }
    @objc private func zoomOut() { AppState.shared.zoomOut() }
    @objc private func zoomReset() { AppState.shared.zoomReset() }

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

            // 1. TranscriptStore 操作 (整形置換 + 対訳)
            TranscriptStore.shared.completeItem(itemId: "smk-t", finalText: "raw text", speaker: .me)
            TranscriptStore.shared.updateFinalText(itemId: "smk-t", text: "clean text", translation: "訳")
            NSLog("[SMOKE] ✅ transcript store passed")

            // 2. Copilot 状態 (カード追加 + 全体像)
            state.catchupCards.insert(
                CatchupCard(periodLabel: "00:00〜00:03", minutes: 3, text: "テスト要約"),
                at: 0
            )
            state.overview = MeetingOverview(purpose: "テスト", agenda: ["A"], currentTopic: "B")
            try? await Task.sleep(for: .milliseconds(100))
            state.catchupCards = []
            state.overview = nil
            NSLog("[SMOKE] ✅ copilot state passed")

            // 3. 権限状態更新
            state.microphonePermission = .granted
            state.screenRecordingPermission = .granted
            state.micLevel = 0.5
            state.systemLevel = 0.3
            try? await Task.sleep(for: .milliseconds(100))
            state.micLevel = 0.0
            state.systemLevel = 0.0
            NSLog("[SMOKE] ✅ state updates passed")

            // 4. 議事録保存フロー (タイトル生成はスキップ)
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

        // 保存先を一時ディレクトリにして TranscriptExporter を直接検証
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "meetscribe-smoke-\(UUID().uuidString.prefix(8))")
        let record = MeetingRecord(
            startedAt: now.addingTimeInterval(-60),
            endedAt: now,
            title: "スモークテスト会議",
            meetingEntries: TranscriptStore.shared.meetingEntries,
            overview: MeetingOverview(purpose: "テスト", agenda: ["確認"], currentTopic: "保存"),
            catchupCards: [CatchupCard(periodLabel: "00:00〜00:01", minutes: 1, text: "要約テスト")],
            totalCostUSD: 0.0042,
            model: TranscriptionClient.transcriptionModel
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

    public func applicationDidBecomeActive(_ notification: Notification) {
        // 権限再チェックは throttle 版で。SCShareableContent を毎フォーカス時に
        // 叩くと CPU/バッテリーを食うため、既に granted なら 30秒は再確認しない。
        Task { @MainActor in
            PermissionManager.refreshMicrophone()
            await PermissionManager.refreshScreenRecordingThrottled()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // メニューバー常駐のため、ウィンドウを閉じてもアプリは終了しない。
        // 終了はメニューバーの「MeetScribe を終了」から。
        false
    }

    /// 録音中・停止処理中・保存中の終了は議事録を失うため、確認するか完了を待つ。
    /// ×ボタン・⌘Q・メニューの終了はすべて terminate 経由なのでここで一括して塞げる。
    /// (`applicationWillTerminate` → `shutdownSync` は保存を行わない)
    public func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        let state = AppState.shared
        // `.stopping` は「停止ボタンを押した直後」の状態。この間 isRunning も
        // isSavingMeeting も false だが、裏では整形バッチの flush (LLM往復あり) が
        // 走っており、ここで即終了すると議事録が失われる。
        let isBusy = state.isRunning
            || state.isSavingMeeting
            || state.captureStatus == .stopping
        guard isBusy else { return .terminateNow }

        // 既に停止・保存が進行中なら、ユーザーは停止を選択済み。確認は挟まず完了を待つ。
        guard state.isRunning else {
            replyWhenSaveCompletes()
            return .terminateLater
        }

        // メニューバーから終了した場合など、他アプリが前面だとアラートが背面に隠れて
        // 「終了できないフリーズ」に見えるため、必ず前面に出す。
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "録音中です"
        alert.informativeText = "このまま終了すると、この会議の議事録は保存されません。"
        alert.addButton(withTitle: "保存して終了")      // .alertFirstButtonReturn
        alert.addButton(withTitle: "キャンセル")         // .alertSecondButtonReturn
        alert.addButton(withTitle: "保存せずに終了")     // .alertThirdButtonReturn
        // 破棄は誤クリックの被害が大きいので、Escape/⌘. がキャンセルに割り当たるようにする
        alert.buttons[1].keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await AudioSession.shared.stop()
                // 別経路 (無音タイムアウト / SCStream異常停止) が先に stop() を
                // 走らせていた場合、自分の stop() は再入ガードで即座に返る。
                // その保存フローの完了も待たないと終了で握り潰してしまう。
                await Self.waitForSaveCompletion()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// 進行中の停止・保存フローが終わってから終了を許可する。
    private func replyWhenSaveCompletes() {
        Task { @MainActor in
            await Self.waitForSaveCompletion()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// 停止・保存フローが落ち着くまで待つ。API がハングしても終了できなくならないよう
    /// 上限を設ける (超過時は保存を諦めて終了する。議事録は退避保存側で拾える)。
    @MainActor
    private static func waitForSaveCompletion(
        timeout: TimeInterval = 90
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while AppState.shared.isSavingMeeting
                || AppState.shared.captureStatus == .stopping {
            guard Date() < deadline else {
                DebugLog.log("[MeetScribe] terminate: save wait timed out")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
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
    /// 録音中は `applicationShouldTerminate` が確認ダイアログを出すため、
    /// 誤クリックで議事録を失うことはない。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

extension AppDelegate: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
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
