import SwiftUI

/// マイク・システム音の音量レベルをコンパクトに表示する縦バー2本のミニメーター。
/// HeaderView 右端に埋め込む前提のため、固定サイズで揃えてある。
struct VUMeterView: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            verticalBar(level: state.micLevel, color: .blue, hint: "自分(マイク)")
            verticalBar(level: state.systemLevel, color: .green, hint: "相手(システム音)")
        }
    }

    private func verticalBar(level: Float, color: Color, hint: String) -> some View {
        let barWidth: CGFloat = 4
        let barHeight: CGFloat = 18
        let normalized = max(0, min(CGFloat(level), 1.0))
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: barWidth, height: barHeight)
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.85))
                .frame(width: barWidth, height: normalized * barHeight)
                .animation(.easeOut(duration: 0.08), value: level)
        }
        .help(hint)
    }
}
