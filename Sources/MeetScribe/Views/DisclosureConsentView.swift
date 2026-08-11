import SwiftUI
import AppKit

/// 初回起動時に一度だけ表示する、外部送信と録音についての説明。
///
/// - 会議の音声が第三者API (OpenAI / xAI) へ送られることを、送信が始まる前に開示する
/// - 会議参加者への録音告知が利用者の責任であることを明示する
/// - 同意しない場合はアプリを終了できる（黙って使わせない）
///
/// 同意状態は `AppState.hasAcceptedDisclosure` に永続化され、
/// 未同意の間は `canStart` が false になるため録音を開始できない。
struct DisclosureConsentView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 10) {
                section(
                    icon: "waveform",
                    title: "音声は外部のAIサービスへ送信されます",
                    body: "マイクの音声と、Macが再生している音声（通話相手の声を含む）を、あなたが設定したAPIキーで OpenAI または xAI に送信し、文字起こしと要約を行います。"
                )
                section(
                    icon: "lock.shield",
                    title: "開発者はデータを受け取りません",
                    body: "MeetScribe は独自のサーバーを持ちません。通信はあなたのMacから各AIサービスへ直接行われ、議事録はあなたが指定したフォルダにのみ保存されます。"
                )
                section(
                    icon: "person.2.wave.2",
                    title: "録音の告知はご自身の責任で行ってください",
                    body: "会議を録音・文字起こしすることを参加者に伝える責任は利用者にあります。録音が制限される場面では使用しないでください。"
                )
                section(
                    icon: "yensign.circle",
                    title: "AIの利用料はご自身の負担になります",
                    // 一律の金額は書かない: この画面はプロバイダー選択より前に出るのに
                    // 既定は OpenAI 経路で、実勢はここに書いていた $0.5/時間の2倍以上ある。
                    // 実費は録音中のヘッダー表示 (実請求額ベース) に委ねる。
                    body: "文字起こしと要約の費用は、あなたのAPIキーに対して各AIサービスから直接請求されます。料金は選択したAIプロバイダーの公式価格に従い、録音中はヘッダーにその会議の実費が表示されます。"
                )
            }

            Divider()

            HStack {
                Button("同意しない（終了）") {
                    NSApp.terminate(nil)
                }
                .controlSize(.large)
                Spacer()
                Button("同意して始める") {
                    state.hasAcceptedDisclosure = true
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ご利用の前に")
                .font(.scaled(16, weight: .semibold))
            Text("MeetScribe がどのようにデータを扱うかをご確認ください。")
                .font(.scaled(11))
                .foregroundStyle(.secondary)
        }
    }

    private func section(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.scaled(13))
                .foregroundStyle(.blue)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.scaled(12, weight: .medium))
                Text(body)
                    .font(.scaled(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
