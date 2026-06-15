import SwiftUI

/// 下部の質問入力欄。回答生成中でも次の質問を入力できるよう、
/// 「入力可能」と「送信可能」を別フラグで制御する。
struct InputBarView: View {
    @Binding var queryText: String

    /// 入力欄が編集可能か (通常 API Key があれば true)
    var canType: Bool = false

    /// 送信ボタンが押下可能か (canType かつ Claude 応答生成中でない)
    var canSubmit: Bool = false

    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            TextField("質問を入力…", text: $queryText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .disabled(!canType)
                .onSubmit { if canSubmit { onSubmit() } }
            Button(action: onSubmit) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(canSubmit && !queryText.isEmpty ? .blue : .gray)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit || queryText.isEmpty)
        }
        .padding(12)
    }
}
