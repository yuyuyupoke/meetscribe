import SwiftUI

/// メインUI。2カラム構成:
/// - 左: 会議文字起こしストリーム (`TranscriptListView`)
/// - 右: AI傍聴パネル (`CopilotPanelView`: 全体像 + Catchup要約)
/// HSplitView でドラッグによる左右リサイズが可能。VUメーターは HeaderView に統合済。
struct ContentView: View {
    @Bindable private var state = AppState.shared
    private let transcripts = TranscriptStore.shared

    var body: some View {
        ZStack {
            // 背景を濃くして文字可読性を優先
            Color(nsColor: .windowBackgroundColor).opacity(0.75)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderView(state: state)
                Divider().opacity(0.3)
                if !setupComplete {
                    SetupSectionView(
                        state: state,
                        hasAPIKey: $state.hasAPIKey
                    )
                    Divider().opacity(0.3)
                }
                HSplitView {
                    TranscriptListView(state: state, transcripts: transcripts)
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: .infinity)
                    CopilotPanelView(state: state)
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: .infinity)
                }
                Divider().opacity(0.3)
                SettingsFooterView(state: state)
            }
            .padding(.top, 28)
        }
        .frame(minWidth: 520, minHeight: 420)
        .task {
            PermissionManager.refreshAll()
        }
    }

    private var setupComplete: Bool {
        state.allPermissionsGranted
            && state.hasAPIKey
            && state.meetingsSaveDirectoryURL != nil
    }

}

#Preview {
    ContentView()
        .frame(width: 600, height: 500)
}
