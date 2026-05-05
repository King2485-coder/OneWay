import SwiftUI

struct ChatHomeView: View {
    @State private var searchText = ""

    private let stories: [StoryPreview] = [
        StoryPreview(name: "Alex", color: Color(hex: 0x00C6FF)),
        StoryPreview(name: "Maya", color: Color(hex: 0x00FF9C)),
        StoryPreview(name: "Jules", color: Color(hex: 0x3E6BFF)),
        StoryPreview(name: "Noah", color: Color(hex: 0x2DE2E6))
    ]

    private let chats: [ChatPreview] = [
        ChatPreview(name: "Alex", message: "Keys synced and ready.", time: "10:42", unread: 2),
        ChatPreview(name: "Maya", message: "Can we do a quick voice call?", time: "09:15", unread: 0),
        ChatPreview(name: "Core Team", message: "Story upload checks are green.", time: "Yesterday", unread: 7),
        ChatPreview(name: "Noah", message: "Sent the build profile.", time: "Tue", unread: 0),
        ChatPreview(name: "Priya", message: "Looks solid from my side.", time: "Mon", unread: 1)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("CipherChat")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)

                    SearchBar(text: $searchText)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Stories")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(stories) { story in
                                    VStack(spacing: 8) {
                                        Circle()
                                            .fill(Theme.glassSurface)
                                            .overlay(
                                                Circle()
                                                    .stroke(Theme.accentGradient, lineWidth: 2)
                                            )
                                            .overlay(
                                                Circle()
                                                    .fill(story.color.opacity(0.28))
                                                    .padding(6)
                                            )
                                            .frame(width: 66, height: 66)

                                        Text(story.name)
                                            .font(.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Chats")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)

                        LazyVStack(spacing: 10) {
                            ForEach(filteredChats) { chat in
                                ChatRow(chat: chat)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var filteredChats: [ChatPreview] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return chats }
        return chats.filter {
            $0.name.lowercased().contains(query) || $0.message.lowercased().contains(query)
        }
    }
}

private struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textMuted)
            TextField("Search encrypted chats", text: $text)
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.glassSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.divider, lineWidth: 1)
                )
        )
    }
}

private struct ChatRow: View {
    let chat: ChatPreview

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.glassSurface)
                .overlay(
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textSecondary)
                )
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(chat.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(chat.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Text(chat.time)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)

                if chat.unread > 0 {
                    Text("\(chat.unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accentGradient, in: Capsule())
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.glassSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.divider, lineWidth: 1)
                )
        )
    }
}

private struct StoryPreview: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
}

private struct ChatPreview: Identifiable {
    let id = UUID()
    let name: String
    let message: String
    let time: String
    let unread: Int
}
