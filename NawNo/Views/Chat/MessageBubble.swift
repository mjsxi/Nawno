import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var isStreaming = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 12) {
            if message.role == .user {
                Text(message.content)
                    .textSelection(.enabled)
                    .lineSpacing(3.5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            } else {
                MarkdownTextView(markdown: message.content)
                    .padding(.horizontal, 12)
            }

            if let stats = message.stats {
                HStack(spacing: 8) {
                    Label(stats.formattedTPS, systemImage: "speedometer")
                    Label("\(stats.totalTokens) tokens", systemImage: "number")
                    Label(stats.formattedTTFT, systemImage: "clock")
                    Label(stats.formattedTotal, systemImage: "timer")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 12)
            }
        }
        .frame(maxWidth: 550, alignment: message.role == .user ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 16)
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return .accentColor
        case .assistant:
            return Color(.controlBackgroundColor)
        case .system:
            return .orange.opacity(0.2)
        }
    }
}
