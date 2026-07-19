import Foundation

/// xAI Streaming STT の `transcript.partial` / `transcript.done` イベントを
/// 「1発話=1エントリ」に正規化する状態機械。
///
/// xAI は1つの発話に対して2段階の確定を送ってくる:
///   - チャンク確定: `is_final=true, speech_final=false` — 約3秒分のテキストが確定
///     (荒い、句読点なしのことが多い)
///   - 発話確定: `is_final=true, speech_final=true` — 発話全体を縫い合わせ
///     (re-stitch) した全文が届く (再デコードされ句読点付きで高品質)
///
/// 旧実装は `is_final` のみを見て毎回アイテムを確定させていたため、チャンク確定と
/// 発話確定がそれぞれ別エントリとして TranscriptStore に残り、文字起こしの重複
/// (完全一致 or 累積全文の再出現) が発生していた。
///
/// 講義等の連続発話では500ms無音が来ず speech_final がいつまでも発火しないケースが
/// あるため、発話開始から `forceFinalizeAfterSeconds` 経過 or `forceFinalizeAfterChars`
/// 文字を超えたら、次のチャンク確定時点で強制的に確定し次のエントリへ切り替える
/// (強制確定)。強制確定が発生した系譜では、後から届く speech_final の縫い合わせ全文は
/// 「強制確定済み部分を含む発話全体」なのでそのまま使うと重複表示になる。そのため
/// `hasForcedSplit` フラグで系譜を追跡し、強制確定後は speech_final の縫い合わせ全文を
/// 捨てて、強制確定後に累積したチャンク＋最終interimのみで確定する。
///
/// ネットワーク/ロックから独立させ単体テスト可能にするため TranscriptionClient
/// から分離している。
struct XAIStreamState: Equatable {
    /// 発話開始からこの秒数を超えたら、次のチャンク確定時に強制的に確定する
    static let forceFinalizeAfterSeconds: TimeInterval = 15
    /// 累積文字数がこの値を超えたら、次のチャンク確定時に強制的に確定する
    static let forceFinalizeAfterChars: Int = 150

    private(set) var itemId: String?
    private(set) var finalizedText: String = ""
    private(set) var lastInterimText: String = ""
    private var utteranceStartedAt: Date?
    /// 現在の itemId の系譜で強制確定が発生済みか。true の間は speech_final の
    /// 縫い合わせ全文を信用せず、finalizedText + lastInterimText のみを確定に使う。
    ///
    /// 割り切り: 強制確定は itemId をリセットする (= 見た目上は新しい発話が始まる) が、
    /// このフラグはリセットしない。強制確定によって生まれた新しい itemId 群は、
    /// xAI サーバー側からは依然として「同じ1つの発話」として扱われ続けており、
    /// いつか届く speech_final の全文にはこの系譜の全チャンクが含まれてしまうため。
    /// つまりこのフラグは itemId 単位ではなく「元の発話」単位で意図的に持続させている。
    /// リセットされるのは通常確定 (speech_final / speech_final相当のフォールバック)
    /// または `takePending()` が呼ばれ、xAI 側の発話が本当に終わったと判断できた時のみ
    private var hasForcedSplit: Bool = false

    enum Action: Equatable {
        /// 確定はせず表示だけ更新する (TranscriptStore.replacePartial 相当)
        case updateDisplay(itemId: String, text: String)
        /// 発話確定。エントリを確定表示し、状態をリセットする
        case finalize(itemId: String, text: String)
    }

    /// `transcript.partial` イベントを1件処理する。
    ///
    /// - Parameters:
    ///   - text: イベントの `text` フィールド (チャンク単位のテキスト。累積ではない)
    ///   - isFinal: イベントの `is_final` フィールド
    ///   - speechFinal: イベントの `speech_final` フィールド。**キーが存在しない場合は nil**
    ///     を渡すこと。nil のときは `isFinal` を発話確定の代わりに使うフォールバックになる
    ///     (speech_final が実際に来ない実装だったとしても、現状より悪化させない)。
    ///   - now: 強制確定の経過時間判定に使う現在時刻。テスト容易性のため注入可能にしている
    ///   - makeItemId: 新しい発話の item ID を生成するクロージャ。
    mutating func handlePartial(
        text: String,
        isFinal: Bool,
        speechFinal: Bool?,
        now: Date = Date(),
        makeItemId: () -> String
    ) -> Action {
        if itemId == nil {
            itemId = makeItemId()
            utteranceStartedAt = now
        }
        let id = itemId!

        guard isFinal else {
            lastInterimText = text
            return .updateDisplay(itemId: id, text: finalizedText + text)
        }

        // speech_final キー欠落時は is_final=true をそのまま発話確定として扱う
        // (フォールバック: 旧動作と同じ挙動になるだけで、新たな不具合は生まれない)
        let isSpeechFinal = speechFinal ?? true

        if isSpeechFinal {
            // 強制確定済みの系譜では text (発話全体の縫い合わせ全文) を信用しない。
            // 強制確定後に累積した分だけを使うことで、強制確定済み部分との重複を防ぐ
            let finalText = hasForcedSplit ? (finalizedText + lastInterimText) : text
            resetUtterance()
            return .finalize(itemId: id, text: finalText)
        }

        finalizedText += text
        lastInterimText = ""

        let elapsed = utteranceStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let shouldForceFinalize = elapsed >= Self.forceFinalizeAfterSeconds
            || finalizedText.count > Self.forceFinalizeAfterChars

        guard shouldForceFinalize else {
            return .updateDisplay(itemId: id, text: finalizedText)
        }

        // 強制確定: 次のチャンクから新エントリに切り替える。hasForcedSplit は
        // リセットせず true にする (この系譜に強制確定があったことを後続に伝える)
        let forcedText = finalizedText
        itemId = nil
        finalizedText = ""
        lastInterimText = ""
        utteranceStartedAt = nil
        hasForcedSplit = true
        return .finalize(itemId: id, text: forcedText)
    }

    /// `transcript.done` 時に、未確定の発話があれば確定させて取り出す。
    /// 確定済みチャンク (`finalizedText`) + 最後の未確定 interim (`lastInterimText`)
    /// を縫い合わせたテキストを返す。空文字なら nil。
    mutating func takePending() -> (itemId: String, text: String)? {
        guard let id = itemId else { return nil }
        let text = finalizedText + lastInterimText
        resetUtterance()
        guard !text.isEmpty else { return nil }
        return (id, text)
    }

    private mutating func resetUtterance() {
        itemId = nil
        finalizedText = ""
        lastInterimText = ""
        utteranceStartedAt = nil
        hasForcedSplit = false
    }
}
