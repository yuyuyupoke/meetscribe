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
    /// 対訳 (日本語訳) を表示するか。フッターのトグルと連動。
    var showTranslations: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 描画パラメータの中央集約。magic number 散布を防ぐ。
    enum Style {
        static let labelFontSize: CGFloat = 9
        static let bodyFontSize: CGFloat = 12
        static let translationFontSize: CGFloat = 11
        static let horizontalInset: CGFloat = 12
        static let verticalInset: CGFloat = 4
        static let bottomFollowThreshold: CGFloat = 40
        /// エントリ間の見た目の余白。改行文字を重ねるのではなく段落スタイルで
        /// 空けることで、コピー時に余計な空行が混入しないようにする。
        static let entrySpacing: CGFloat = 8
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

        let signature = Self.signature(of: entries, showTranslations: showTranslations)
        guard signature != context.coordinator.lastSignature else { return }

        let wasAtBottom = scrollView.isNearBottom(
            threshold: Style.bottomFollowThreshold
        )
        let hasActiveSelection = (textView.selectedRange().length > 0)

        let attributed = Self.buildAttributed(entries: entries, showTranslations: showTranslations)

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
    /// 整形・対訳は過去エントリを遅れて書き換える (updateFinalText) ため、
    /// 全エントリの内容をハッシュで畳み込む (文字数だけだと「同一文字数の
    /// 誤変換修正」が検知できず UI に反映されない)。対訳トグル切替でも再描画する。
    static func signature(of entries: [TranscriptEntry], showTranslations: Bool) -> String {
        var hasher = Hasher()
        for e in entries {
            hasher.combine(e.text)
            hasher.combine(e.translation)
            hasher.combine(e.isFinal)
        }
        hasher.combine(showTranslations)
        return "\(entries.count)|\(hasher.finalize())"
    }

    /// 将来 NSTextViewDelegate を持たせる枠 + 描画差分判定の保持場所。
    final class Coordinator {
        var lastSignature: String = ""
    }

    // MARK: - Rendering

    /// エントリ列を1本の attributed string にする。
    /// - 話者ラベルは「[自分] 」形式で本文と同一行 (コピペした時に読みやすい)
    /// - エントリ間の余白は改行の重ね打ちではなく paragraphSpacing で確保
    ///   (ドラッグ選択・コピーに余計な空行が混入しない)
    /// - 対訳は本文の次の行に「└ 」接頭辞 + 小さめ薄色で表示
    static func buildAttributed(
        entries: [TranscriptEntry],
        showTranslations: Bool
    ) -> NSAttributedString {
        // エントリの最終段落に付ける (次エントリとの余白)
        let entryEndStyle = NSMutableParagraphStyle()
        entryEndStyle.paragraphSpacing = Style.entrySpacing
        // 本文の直後に対訳が続く場合の本文段落 (訳と密着させる)
        let tightStyle = NSMutableParagraphStyle()
        tightStyle.paragraphSpacing = 1

        let result = NSMutableAttributedString()
        for (i, entry) in entries.enumerated() {
            let translation: String? = {
                guard showTranslations,
                      let t = entry.translation, !t.isEmpty else { return nil }
                return t
            }()
            let bodyStyle = (translation == nil) ? entryEndStyle : tightStyle

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(
                    ofSize: Style.labelFontSize,
                    weight: .semibold
                ),
                .foregroundColor: speakerColor(for: entry.speaker),
                .paragraphStyle: bodyStyle
            ]
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(
                    ofSize: Style.bodyFontSize,
                    weight: .regular
                ),
                .foregroundColor: NSColor.labelColor
                    .withAlphaComponent(entry.isFinal ? 1.0 : 0.7),
                .paragraphStyle: bodyStyle
            ]

            result.append(NSAttributedString(
                string: "[\(entry.speaker.displayName)] ",
                attributes: labelAttrs
            ))
            result.append(NSAttributedString(
                string: entry.text,
                attributes: bodyAttrs
            ))

            if let translation {
                let translationAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(
                        ofSize: Style.translationFontSize,
                        weight: .regular
                    ),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: entryEndStyle
                ]
                result.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
                result.append(NSAttributedString(
                    string: "└ \(translation)",
                    attributes: translationAttrs
                ))
            }

            if i < entries.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
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
