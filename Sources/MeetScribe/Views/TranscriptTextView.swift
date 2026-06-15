import SwiftUI
import AppKit

/// 文字起こしを 1 つの NSTextView に流し込んで描画する Representable。
/// SwiftUI の Text + textSelection は View ごとに選択範囲が分断されるため、
/// 複数発言をまたいでドラッグ選択・コピーするには NSTextView を使う必要がある。
///
/// 機能:
/// - 話者ラベルを色分け (自分=青 / 相手=緑)
/// - 未確定 (isFinal=false) は薄色表示
/// - スクロール位置が末尾付近にあるときだけ自動スクロール
///   (ユーザーが過去ログを読んで選択している最中は割り込まない)
struct TranscriptTextView: NSViewRepresentable {
    let entries: [TranscriptEntry]

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 描画パラメータの中央集約。magic number 散布を防ぐ。
    enum Style {
        static let labelFontSize: CGFloat = 9
        static let bodyFontSize: CGFloat = 12
        static let horizontalInset: CGFloat = 12
        static let verticalInset: CGFloat = 4
        static let bottomFollowThreshold: CGFloat = 40
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(
            width: Style.horizontalInset,
            height: Style.verticalInset
        )
        textView.setAccessibilityLabel("文字起こし")
        textView.allowsUndo = false
        textView.usesFindBar = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.linkTextAttributes = [:]
        textView.textContainer?.lineFragmentPadding = 0

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let textStorage = textView.textStorage else { return }

        let signature = Self.signature(of: entries)
        guard signature != context.coordinator.lastSignature else { return }

        let wasAtBottom = scrollView.isNearBottom(
            threshold: Style.bottomFollowThreshold
        )
        let hasActiveSelection = (textView.selectedRange().length > 0)

        let attributed = Self.buildAttributed(entries: entries)

        textStorage.beginEditing()
        textStorage.setAttributedString(attributed)
        textStorage.endEditing()
        context.coordinator.lastSignature = signature

        // 自動追従: 末尾近く && 選択範囲なし のときのみ。
        // 選択中に飛ばすとユーザーのコピー操作を破壊する。
        if wasAtBottom && !hasActiveSelection {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// updateNSView 内で前回描画との差分を判定するための軽量シグネチャ。
    /// (件数, 末尾エントリの id, 末尾エントリの text 長, 末尾エントリの isFinal)。
    /// 末尾以外が破壊的に書き換わるユースケースは現状なし (TranscriptStore は append-only)。
    private static func signature(of entries: [TranscriptEntry]) -> String {
        guard let last = entries.last else { return "0" }
        return "\(entries.count)|\(last.id)|\(last.text.count)|\(last.isFinal ? 1 : 0)"
    }

    /// 将来 NSTextViewDelegate を持たせる枠 + 描画差分判定の保持場所。
    final class Coordinator {
        var lastSignature: String = ""
    }

    // MARK: - Rendering

    static func buildAttributed(entries: [TranscriptEntry]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, entry) in entries.enumerated() {
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(
                    ofSize: Style.labelFontSize,
                    weight: .semibold
                ),
                .foregroundColor: speakerColor(for: entry.speaker)
            ]
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(
                    ofSize: Style.bodyFontSize,
                    weight: .regular
                ),
                .foregroundColor: NSColor.labelColor
                    .withAlphaComponent(entry.isFinal ? 1.0 : 0.7)
            ]

            result.append(NSAttributedString(
                string: entry.speaker.displayName,
                attributes: labelAttrs
            ))
            result.append(NSAttributedString(string: "\n", attributes: labelAttrs))
            result.append(NSAttributedString(
                string: entry.text,
                attributes: bodyAttrs
            ))
            if i < entries.count - 1 {
                result.append(NSAttributedString(string: "\n\n", attributes: bodyAttrs))
            }
        }
        return result
    }

    /// 話者カラー解決。`me` のみ青、それ以外（`other` 含む将来追加分）は緑。
    /// `meetingEntries` フィルタにより `.user`/`.claude` は本ビューには流れてこない想定。
    private static func speakerColor(for speaker: SpeakerLabel) -> NSColor {
        switch speaker {
        case .me: return .systemBlue
        case .other: return .systemGreen
        case .user, .claude: return .labelColor  // 想定外: 安全側でラベル色
        }
    }
}

private extension NSScrollView {
    /// 現在のスクロール位置がドキュメント末尾付近かを判定する。
    /// 自動追従スクロールの可否判定に使う。
    /// `documentView` が nil の初回 / 空状態は「末尾扱い」とし、最初の表示で末尾追従させる。
    func isNearBottom(threshold: CGFloat) -> Bool {
        guard let documentView = documentView else { return true }
        let visibleMaxY = contentView.bounds.maxY
        let documentMaxY = documentView.frame.maxY
        return (documentMaxY - visibleMaxY) <= threshold
    }
}
