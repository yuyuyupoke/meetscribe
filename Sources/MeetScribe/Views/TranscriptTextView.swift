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
/// - 更新は前回描画済みエントリとの差分のみを textStorage に適用する
///   (全文再構築だと選択範囲・スクロール位置が毎回破壊されるため)
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
        let coordinator = context.coordinator

        // entries は Equatable (struct 全フィールド比較) なので、内容が本当に
        // 変わっていない再描画呼び出しはここで早期リターンする。
        guard entries != coordinator.lastEntries || showTranslations != coordinator.lastShowTranslations else {
            return
        }

        let wasAtBottom = scrollView.isNearBottom(threshold: Style.bottomFollowThreshold)
        let selectionBefore = textView.selectedRange()
        let hasActiveSelection = selectionBefore.length > 0
        let visibleRectBefore = scrollView.contentView.documentVisibleRect
        // 末尾追従しない (= 過去ログを読んでいる) 場合のみ、画面最上部の文字を
        // アンカーとして記録し、編集後も同じ文字が同じ位置に来るよう補正する。
        let anchorBefore: Int? = wasAtBottom
            ? nil
            : Self.topAnchorCharacterIndex(textView: textView, visibleRect: visibleRectBefore)

        let edits: [TranscriptTextDiff.TextEdit]
        if let ops = TranscriptTextDiff.diffOps(
            old: coordinator.lastEntries,
            new: entries,
            oldShowTranslations: coordinator.lastShowTranslations,
            newShowTranslations: showTranslations
        ) {
            edits = Self.applyDiff(
                ops,
                old: coordinator.lastEntries,
                new: entries,
                oldShowTranslations: coordinator.lastShowTranslations,
                newShowTranslations: showTranslations,
                textStorage: textStorage
            )
        } else {
            // id の並べ替え・重複などの想定外ケースのみ全文再構築にフォールバックする。
            // (appendDelta/removeItem の実装上、通常運用では発生しない安全網)
            // この経路では選択範囲・スクロール位置の厳密な保持は保証しない。
            let attributed = Self.buildAttributed(entries: entries, showTranslations: showTranslations)
            textStorage.beginEditing()
            textStorage.setAttributedString(attributed)
            textStorage.endEditing()
            edits = []
        }

        coordinator.lastEntries = entries
        coordinator.lastShowTranslations = showTranslations

        // 自動追従: 末尾近く && 選択範囲なし のときのみ。
        // 選択中に飛ばすとユーザーのコピー操作を破壊する。
        if wasAtBottom {
            if !hasActiveSelection {
                textView.scrollToEndOfDocument(nil)
            }
        } else if let anchorBefore {
            let anchorAfter = TranscriptTextDiff.remapPosition(anchorBefore, through: edits)
            Self.restoreScrollAnchor(
                textView: textView,
                scrollView: scrollView,
                anchorCharIndex: anchorAfter,
                previousVisibleRect: visibleRectBefore
            )
        }

        if hasActiveSelection {
            let newLocation = TranscriptTextDiff.remapPosition(selectionBefore.location, through: edits)
            let newEnd = TranscriptTextDiff.remapPosition(
                selectionBefore.location + selectionBefore.length,
                through: edits
            )
            let clampedLength = textStorage.length
            let start = min(newLocation, clampedLength)
            let end = min(max(newEnd, start), clampedLength)
            textView.setSelectedRange(NSRange(location: start, length: end - start))
        }
    }

    /// 将来 NSTextViewDelegate を持たせる枠 + 直前描画状態の保持場所。
    final class Coordinator {
        var lastEntries: [TranscriptEntry] = []
        var lastShowTranslations: Bool = true
    }

    // MARK: - Diff 適用

    /// diffOps が返した編集列を実際に textStorage へ適用する。
    /// 変化のない (.keep) エントリには一切触れないため、そのエントリの glyph / layout
    /// は再生成されない (= カクつきの主因だった全文再レイアウトを回避できる)。
    /// - Returns: 旧座標系での編集列。選択範囲・スクロールアンカーの座標補正に使う。
    @discardableResult
    static func applyDiff(
        _ ops: [TranscriptTextDiff.ChunkOp],
        old: [TranscriptEntry],
        new: [TranscriptEntry],
        oldShowTranslations: Bool,
        newShowTranslations: Bool,
        textStorage: NSTextStorage
    ) -> [TranscriptTextDiff.TextEdit] {
        var edits: [TranscriptTextDiff.TextEdit] = []
        var cursor = 0
        var oldCursor = 0

        for op in ops {
            switch op {
            case let .keep(_, newIndex):
                // 内容不変。textStorage には触れず、カーソルだけ進める。
                let length = renderChunk(
                    entry: new[newIndex],
                    showTranslations: newShowTranslations,
                    isLast: newIndex == new.count - 1
                ).length
                cursor += length
                oldCursor += length

            case let .update(oldIndex, newIndex):
                let oldLength = renderChunk(
                    entry: old[oldIndex],
                    showTranslations: oldShowTranslations,
                    isLast: oldIndex == old.count - 1
                ).length
                let newChunk = renderChunk(
                    entry: new[newIndex],
                    showTranslations: newShowTranslations,
                    isLast: newIndex == new.count - 1
                )
                textStorage.replaceCharacters(in: NSRange(location: cursor, length: oldLength), with: newChunk)
                edits.append(TranscriptTextDiff.TextEdit(
                    oldRange: NSRange(location: oldCursor, length: oldLength),
                    newLength: newChunk.length
                ))
                cursor += newChunk.length
                oldCursor += oldLength

            case let .delete(oldIndex):
                let oldLength = renderChunk(
                    entry: old[oldIndex],
                    showTranslations: oldShowTranslations,
                    isLast: oldIndex == old.count - 1
                ).length
                textStorage.deleteCharacters(in: NSRange(location: cursor, length: oldLength))
                edits.append(TranscriptTextDiff.TextEdit(
                    oldRange: NSRange(location: oldCursor, length: oldLength),
                    newLength: 0
                ))
                oldCursor += oldLength

            case let .insert(newIndex):
                let newChunk = renderChunk(
                    entry: new[newIndex],
                    showTranslations: newShowTranslations,
                    isLast: newIndex == new.count - 1
                )
                textStorage.replaceCharacters(in: NSRange(location: cursor, length: 0), with: newChunk)
                edits.append(TranscriptTextDiff.TextEdit(
                    oldRange: NSRange(location: oldCursor, length: 0),
                    newLength: newChunk.length
                ))
                cursor += newChunk.length
            }
        }
        return edits
    }

    // MARK: - スクロールアンカー

    /// 現在のビューポート最上部に表示されている文字のインデックスを求める。
    /// 末尾追従していない時のスクロール位置保持のアンカーに使う。
    private static func topAnchorCharacterIndex(textView: NSTextView, visibleRect: NSRect) -> Int? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let point = NSPoint(x: visibleRect.minX - origin.x, y: visibleRect.minY - origin.y)
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    /// アンカー文字 (編集後の座標に補正済み) が編集前と同じ画面位置に来るよう
    /// スクロール位置を復元する。末尾追従していない状態で他エントリが更新された時に
    /// 画面が動いて見えないようにするための処理。
    private static func restoreScrollAnchor(
        textView: NSTextView,
        scrollView: NSScrollView,
        anchorCharIndex: Int,
        previousVisibleRect: NSRect
    ) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage else { return }
        let origin = textView.textContainerOrigin
        let clampedIndex = max(0, min(anchorCharIndex, textStorage.length))

        let anchorY: CGFloat
        if textStorage.length == 0 {
            anchorY = origin.y
        } else if clampedIndex >= textStorage.length {
            anchorY = layoutManager.usedRect(for: textContainer).maxY + origin.y
        } else {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: clampedIndex, length: 1),
                actualCharacterRange: nil
            )
            anchorY = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).minY + origin.y
        }

        let proposed = NSRect(
            x: previousVisibleRect.minX,
            y: anchorY,
            width: previousVisibleRect.width,
            height: previousVisibleRect.height
        )
        let constrained = scrollView.contentView.constrainBoundsRect(proposed)
        scrollView.contentView.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Rendering

    /// エントリ列を1本の attributed string にする (初回描画・フォールバック用)。
    /// 差分更新パス (applyDiff) も含め、renderChunk を唯一のレンダリング経路として
    /// 共有することで見た目の不一致を防ぐ。
    static func buildAttributed(
        entries: [TranscriptEntry],
        showTranslations: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, entry) in entries.enumerated() {
            result.append(renderChunk(
                entry: entry,
                showTranslations: showTranslations,
                isLast: i == entries.count - 1
            ))
        }
        return result
    }

    /// エントリの最終段落に付ける (次エントリとの余白)。
    private static let entryEndStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = Style.entrySpacing
        return style
    }()
    /// 本文の直後に対訳が続く場合の本文段落 (訳と密着させる)。
    private static let tightStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 1
        return style
    }()

    /// 1エントリ分の attributed string を生成する。
    /// - 話者ラベルは「[自分] 」形式で本文と同一行 (コピペした時に読みやすい)
    /// - エントリ間の余白は改行の重ね打ちではなく paragraphSpacing で確保
    ///   (ドラッグ選択・コピーに余計な空行が混入しない)
    /// - 対訳は本文の次の行に「└ 」接頭辞 + 小さめ薄色で表示
    /// - isLast: エントリ列全体の最後なら区切りの "\n" を付けない
    static func renderChunk(
        entry: TranscriptEntry,
        showTranslations: Bool,
        isLast: Bool
    ) -> NSAttributedString {
        let translation: String? = {
            guard showTranslations, let t = entry.translation, !t.isEmpty else { return nil }
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

        let result = NSMutableAttributedString()
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

        if !isLast {
            result.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
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

// MARK: - TranscriptTextDiff

/// TranscriptTextView 用の差分計算ロジック (AppKit 非依存の純粋関数)。
/// TranscriptStore の更新は「id で既存エントリを更新」「新規 id を末尾に追加」
/// 「id で削除」のみで、id の相対順序が入れ替わることはない (appendDelta は末尾追加、
/// removeItem はフィルタ削除のみで並べ替えを行わない)。この前提のもと、
/// id ベースの2ポインタ走査で最小限の編集列 (ChunkOp) を求める。
enum TranscriptTextDiff {
    enum ChunkOp: Equatable {
        case keep(oldIndex: Int, newIndex: Int)
        case update(oldIndex: Int, newIndex: Int)
        case delete(oldIndex: Int)
        case insert(newIndex: Int)
    }

    /// 実際に textStorage に適用した編集を旧座標系で記録したもの。
    /// remapPosition で選択範囲・スクロールアンカーの座標補正に使う。
    struct TextEdit {
        let oldRange: NSRange
        let newLength: Int
    }

    struct ChunkKey: Equatable {
        let text: String
        let translation: String?
        let isFinal: Bool
        let isLast: Bool
    }

    /// レンダリング結果を左右するフィールドだけを抽出したキー。
    /// これが等しければ画面上のバイト列は変わらないので textStorage に触れる必要がない。
    static func chunkKey(_ entry: TranscriptEntry, isLast: Bool, showTranslations: Bool) -> ChunkKey {
        let effectiveTranslation: String? = {
            guard showTranslations, let t = entry.translation, !t.isEmpty else { return nil }
            return t
        }()
        return ChunkKey(text: entry.text, translation: effectiveTranslation, isFinal: entry.isFinal, isLast: isLast)
    }

    /// old → new の編集列を計算する。
    /// id の並べ替え検知 or 重複 id など想定外の入力の場合は nil を返し、
    /// 呼び出し側は安全に全文再構築へフォールバックできるようにする。
    static func diffOps(
        old: [TranscriptEntry],
        new: [TranscriptEntry],
        oldShowTranslations: Bool,
        newShowTranslations: Bool
    ) -> [ChunkOp]? {
        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)
        guard Set(oldIDs).count == oldIDs.count, Set(newIDs).count == newIDs.count else {
            return nil
        }
        let oldIndexByID = Dictionary(uniqueKeysWithValues: zip(oldIDs, oldIDs.indices))
        let newIndexByID = Dictionary(uniqueKeysWithValues: zip(newIDs, newIDs.indices))

        var ops: [ChunkOp] = []
        var i = 0
        var j = 0
        while i < oldIDs.count && j < newIDs.count {
            if oldIDs[i] == newIDs[j] {
                let oldKey = chunkKey(old[i], isLast: i == old.count - 1, showTranslations: oldShowTranslations)
                let newKey = chunkKey(new[j], isLast: j == new.count - 1, showTranslations: newShowTranslations)
                ops.append(oldKey == newKey ? .keep(oldIndex: i, newIndex: j) : .update(oldIndex: i, newIndex: j))
                i += 1
                j += 1
            } else if newIndexByID[oldIDs[i]] == nil {
                ops.append(.delete(oldIndex: i))
                i += 1
            } else if oldIndexByID[newIDs[j]] == nil {
                ops.append(.insert(newIndex: j))
                j += 1
            } else {
                // 両方の id が互いのリストの別の位置にも存在する = 並べ替え。
                // 想定外の入力なので呼び出し側で全文再構築させる。
                return nil
            }
        }
        while i < oldIDs.count {
            ops.append(.delete(oldIndex: i))
            i += 1
        }
        while j < newIDs.count {
            ops.append(.insert(newIndex: j))
            j += 1
        }
        return ops
    }

    /// 旧座標系の位置 `position` を、適用済みの編集列 `edits`
    /// (oldRange.location 昇順、非重複) を通して新座標系に写像する。
    /// position が編集範囲の内側に入る場合はその編集の開始位置にクランプする。
    static func remapPosition(_ position: Int, through edits: [TextEdit]) -> Int {
        var result = position
        for edit in edits {
            let oldEnd = edit.oldRange.location + edit.oldRange.length
            if oldEnd <= position {
                result += edit.newLength - edit.oldRange.length
            } else if edit.oldRange.location >= position {
                break
            } else {
                result = edit.oldRange.location + (result - position)
                break
            }
        }
        return max(0, result)
    }
}
