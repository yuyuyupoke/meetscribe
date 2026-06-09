import SwiftUI

/// メインUI。2カラム構成:
/// - 左: 会議文字起こしストリーム (`TranscriptListView`)
/// - 右: Clawd Q&A エリア (`ClawdQAView`)
/// HSplitView でドラッグによる左右リサイズが可能。VUメーターは HeaderView に統合済。
struct ContentView: View {
    @Bindable private var state = AppState.shared
    private let transcripts = TranscriptStore.shared

    @State private var apiKeyInput = ""
    @State private var hasAPIKey = KeychainStore.hasAPIKey

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
                        apiKeyInput: $apiKeyInput,
                        hasAPIKey: $hasAPIKey
                    )
                    Divider().opacity(0.3)
                }
                HSplitView {
                    TranscriptListView(state: state, transcripts: transcripts)
                        .frame(minWidth: 200, idealWidth: 300, maxWidth: .infinity)
                    ClawdQAView(
                        state: state,
                        transcripts: transcripts,
                        queryText: $state.queryText,
                        onSubmit: submitQuestion
                    )
                    .frame(minWidth: 200, idealWidth: 300, maxWidth: .infinity)
                }
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
            && hasAPIKey
            && state.meetingsSaveDirectoryURL != nil
    }

    private func submitQuestion() {
        let trimmed = state.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !state.isAsking else { return }
        state.queryText = ""
        Task {
            await QAController.shared.ask(question: trimmed)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 600, height: 500)
}
