import Foundation

/// クリーナー (確定セグメントの後処理) が何をするか。
///
/// `translateOnly` が既定。詳しい根拠は `CleanerModePolicy` を参照。
enum CleanerMode: String, Sendable, CaseIterable {
    /// 日本語訳だけを生成し、**本文には一切触れない**。
    case translateOnly = "translate-only"
    /// 従来動作。フィラー除去・言い直しの統合をした上で日本語訳も付ける。
    case formatAndTranslate = "format-translate"
}

/// クリーナーのモードを決めるポリシー。
///
/// **既定は `translateOnly` (整形しない)**。対訳の表示が遅い問題への対策で、
/// 2026-08-14 の講義 (cleaner 604回) の実測が根拠:
/// ```
/// セグメント確定 ──[ バッチ待ち 最大8秒 / 平均4秒 ]──▶ LLM呼び出し ──[ 6.0秒 ]──▶ 対訳表示
/// ```
/// 整形をやめると出力トークンが 84 → 48 に減り、応答も速くなる
/// (中央値 1.59s → 1.24s、1回あたり $0.000696 → $0.000497 = **-29%**)。
///
/// 品質面でも英語講義では整形の仕事がほぼ無い: 2026-08-11 に入力サンプルを調べたところ
/// `um`/`uh` が1つも無かった (xAI STT が書き起こし時点で落とす)。むしろ整形を効かせると
/// "In my history" → "In my experience" のような**原文の書き換え**が出ていた。
/// `translateOnly` では本文が STT の出力のまま残るので、この改変が構造的に起きない。
///
/// 注意: 2026-07-25 の調査では**日本語会議**で整形が効いている
/// (「めっちゃいいですねめっちゃいいですね」の重複除去など)。日本語主体の会議で
/// 整形が欲しい場合は従来動作に戻せる:
/// - GUI (Finder/Dock) 起動でも効く恒久設定:
///   `defaults write com.meetscribe.app cleanerMode format-translate`
/// - その場限りの切り替え (ターミナルから直接バイナリを起動する場合のみ):
///   `MEETSCRIBE_CLEANER_MODE=format-translate /Applications/MeetScribe.app/Contents/MacOS/MeetScribe`
enum CleanerModePolicy {
    /// その場限りの上書き (ターミナルから直接バイナリを起動した場合のみ効く)。
    static let environmentKey = "MEETSCRIBE_CLEANER_MODE"

    /// GUI 起動時のロールバック手段。**環境変数だけでは不十分**なため併設している:
    /// Finder/Dock/`open` から起動したアプリはシェルの環境を継承しないので、
    /// `MEETSCRIBE_CLEANER_MODE` は普段の使い方では届かない。
    static let userDefaultsKey = "cleanerMode"

    /// 環境変数も UserDefaults も無いときに使うモード。
    static let defaultMode: CleanerMode = .translateOnly

    /// 受け付ける値 (`CleanerMode` の rawValue)。未知の文字列は既定へ落とす:
    /// 綴り間違いで整形も対訳も止まるより、既定で動き続けるほうが被害が小さい。
    static var allowed: Set<String> { Set(CleanerMode.allCases.map(\.rawValue)) }

    /// 実際に使うモード。優先順位は 環境変数 → UserDefaults → 既定値。
    /// 環境変数を上に置くのは、恒久設定 (UserDefaults) を書き換えずに
    /// 1回だけ挙動を確かめられるようにするため。
    /// 未知の値・空文字は「指定なし」と見なして次の候補へ落ちる。
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults? = .standard
    ) -> CleanerMode {
        normalized(environment[environmentKey])
            ?? normalized(defaults?.string(forKey: userDefaultsKey))
            ?? defaultMode
    }

    /// 入力を正規化し、既知の値だけを返す (それ以外は nil)。
    private static func normalized(_ raw: String?) -> CleanerMode? {
        guard let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !value.isEmpty
        else {
            return nil
        }
        return CleanerMode(rawValue: value)
    }

    /// 実際に使う値。**呼び出しのたびに解決する** (`static let` にしない)。
    ///
    /// `static let` だと Swift のグローバル遅延初期化で「その起動で最初に
    /// cleaner が走った瞬間」に凍結され、以後プロセスが死ぬまで変わらない。
    /// MeetScribe はメニューバー常駐で何日も起動しっぱなしになるため、
    /// `defaults write com.meetscribe.app cleanerMode format-translate` を打っても
    /// **その起動で既に1回でも録音していたら反映されない**。しかも
    /// 「まだ録音していなければ効く／していれば効かない」という再現しない挙動になる。
    ///
    /// 実際 `SessionLengthLimitPolicy` は録音開始ごとに解決していて、
    /// `maxSessionMinutes` はアプリを再起動せずに反映された。ロールバック手段の
    /// 挙動が設定ごとに違うと混乱するので、こちらも都度解決に揃える。
    ///
    /// `UserDefaults` の読み取りはメモリキャッシュ経由で、cleaner のバッチ
    /// (数秒に1回) の頻度なら計測できるコストにならない。
    static var current: CleanerMode { resolve() }
}
