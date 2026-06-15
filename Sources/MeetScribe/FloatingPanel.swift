import AppKit

/// 半透明・常に最前面のフローティングウィンドウ。
/// 以前は `NSPanel` を使っていたが、テキスト入力時に IMKCFRunLoopWakeUpReliable
/// エラーでクラッシュする問題があったため `NSWindow` ベースに変更。
/// - `.floating` レベルで常に最前面
/// - ブラーエフェクトで macOS ネイティブのすりガラス感
final class FloatingPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        configure()
    }

    private func configure() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // 画面共有・画面収録から除外 (Stealth / Private Window)
        // Zoom/Meet/Teams での画面共有、QuickTime/OBS/Loom 等の録画ツール、
        // どれを使っても本ウィンドウは映らない。本人の画面上には通常表示される。
        sharingType = .none

        // ほぼ solid の背景 (可読性優先)
        // .sidebar はシステム側で濃いガラス感を出す。blendingMode を withinWindow
        // にすることで背景透過を抑える
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.state = .active
        visualEffect.blendingMode = .withinWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        contentView = visualEffect
    }
}
