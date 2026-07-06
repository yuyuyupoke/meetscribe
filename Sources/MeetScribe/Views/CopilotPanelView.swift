import SwiftUI
import AppKit

/// 小窓右カラム。AIが会議を傍聴して支援する「Copilotパネル」。
/// (旧 ScribeQAView のタイプ入力式 Q&A を置き換え)
/// - 上部: 全体像パネル (目的/議題/現在地、自動更新)
/// - 中央: Catchup要約カード (新しい順)
/// - 下部: Catchupボタン (1/3/5/10分)
struct CopilotPanelView: View {
    let state: AppState

    /// Catchup ボタンの分数
    private static let catchupMinutes = [1, 3, 5, 10]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.3)
            overviewPanel
            Divider().opacity(0.3)
            catchupList
            Divider().opacity(0.3)
            catchupButtonBar
        }
    }

    // MARK: - ヘッダ (Scribe アイコン + ステータス + サポート)

    private var headerBar: some View {
        HStack(spacing: 8) {
            meetscribeIcon
            VStack(alignment: .leading, spacing: 1) {
                Text("Scribe")
                    .font(.system(size: 12, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            supportButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusText: String {
        if state.isCatchupRunning { return "要約を生成中…" }
        if state.isRunning { return "会議を傍聴しています" }
        return "待機中"
    }

    /// 開発者サポート (note サポート記事へ遷移)。アイコンだけのさりげない配置。
    private var supportButton: some View {
        Button(action: openSupportLink) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("開発者を note で応援する")
    }

    private func openSupportLink() {
        guard let url = URL(string: "https://note.com/yuyuyu303030jp/n/n17ba34bf2ffb?app_launch=false") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var meetscribeIcon: some View {
        Group {
            if let url = Bundle.main.url(forResource: "Scribe", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "pawprint.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 28, height: 28)
    }

    // MARK: - 全体像パネル

    @ViewBuilder
    private var overviewPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "map.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                Text("全体像")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if state.isOverviewUpdating {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
            if let overview = state.overview {
                VStack(alignment: .leading, spacing: 3) {
                    overviewRow(label: "目的", text: overview.purpose)
                    if !overview.agenda.isEmpty {
                        overviewRow(label: "議題", text: overview.agenda.map { "・\($0)" }.joined(separator: "  "))
                    }
                    overviewRow(label: "現在", text: overview.currentTopic)
                }
            } else {
                Text(state.isRunning
                     ? "👂 傍聴中… 発話が溜まると全体像を表示します"
                     : "録音を開始すると、AIが会議の目的・議題を自動で把握します")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func overviewRow(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Catchup カード一覧

    private var catchupList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if state.catchupCards.isEmpty {
                    placeholder
                }
                ForEach(state.catchupCards) { card in
                    catchupCard(card)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("⏱ 下のボタンで直近の内容に追いつけます")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("離席から戻った時・聞き逃した時に、その間の要約を数秒で表示します")
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(.top, 4)
    }

    private func catchupCard(_ card: CatchupCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: card.isError ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(card.isError ? .red : .orange)
                Text("\(card.periodLabel)（\(card.minutes)分）")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(card.text)
                .font(.system(size: 11))
                .foregroundStyle(card.isError ? Color.red.opacity(0.9) : .primary.opacity(0.95))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(card.isError ? Color.red.opacity(0.08) : Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Catchup ボタン行

    private var catchupButtonBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(state.isRunning ? .orange : .secondary.opacity(0.5))
                .help("Catchup: 直近N分の要約")
            ForEach(Self.catchupMinutes, id: \.self) { minutes in
                catchupButton(minutes: minutes)
            }
            if state.isCatchupRunning {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func catchupButton(minutes: Int) -> some View {
        let enabled = state.isRunning && !state.isCatchupRunning
        return Button {
            CopilotController.shared.requestCatchup(minutes: minutes)
        } label: {
            Text("\(minutes)分")
                .font(.system(size: 10))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(enabled ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled
              ? "直近\(minutes)分を日本語で要約"
              : (state.isRunning ? "要約を生成中です" : "録音中のみ使えます"))
    }
}
