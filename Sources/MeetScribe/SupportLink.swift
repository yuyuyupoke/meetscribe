import Foundation
import AppKit

/// 開発の応援 (投げ銭) 導線。
///
/// リンク先を1箇所に集約する。以前は CopilotPanelView と README に URL が
/// 散っていたため、リンク切れの修正漏れが起きやすかった。
enum SupportLink {
    /// note のサポート記事。金額はページ側で選ぶ (100円 / 500円 / 自由金額)。
    static let url = URL(string: "https://note.com/yuyuyu303030jp/n/n17ba34bf2ffb?app_launch=false")!

    /// 想定している金額。文言に具体性を持たせるために使う
    /// (「開発を応援」より使い道が伝わる方が納得されやすい)。
    static let suggestedAmountLabel = "コーヒー一杯分"

    @MainActor
    static func open() {
        NSWorkspace.shared.open(url)
    }
}
