import SwiftUI

extension Font {
    /// `AppState.uiScale` (⌘+ / ⌘- で変更) を反映した system font。
    /// View の body 評価中に呼ばれることで @Observable のアクセストラッキングに
    /// uiScale への依存が記録され、スケール変更時に各 View が自動再描画される。
    /// UI のフォント指定は `.system(size:)` 直書きではなくこれを使うこと。
    @MainActor
    static func scaled(_ size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let scaledSize = size * AppState.shared.uiScale
        if let weight {
            return .system(size: scaledSize, weight: weight)
        }
        return .system(size: scaledSize)
    }
}
