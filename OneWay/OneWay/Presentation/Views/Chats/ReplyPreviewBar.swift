import SwiftUI

struct ReplyPreviewBar: View {
    let message: ChatMessage
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Rectangle()
                .fill(Color.blue.opacity(0.6))
                .frame(width: 3)
                .cornerRadius(2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.body)
                    .lineLimit(1)
                    .font(.footnote.weight(.semibold))
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}
