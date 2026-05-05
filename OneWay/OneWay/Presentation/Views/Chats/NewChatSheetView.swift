import SwiftUI

struct NewChatSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let messagingService: MessagingService
    let friendService: FriendService
    let groupService: GroupService
    let callService: CallService

    @State private var searchQuery = ""
    @State private var friends: [FriendConnection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingAddFriend = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    quickActionRow(
                        icon: "person.2.fill",
                        title: "New group",
                        subtitle: "Create a group chat"
                    )
                    quickActionRow(
                        icon: "person.badge.plus.fill",
                        title: "New contact",
                        subtitle: "Add a friend by handle or invite"
                    ) {
                        isShowingAddFriend = true
                    }
                    NavigationLink {
                        FriendsListView(friendService: friendService)
                    } label: {
                        quickActionLabel(
                            icon: "person.crop.circle.badge.checkmark",
                            title: "Friends",
                            subtitle: "View connected and pending"
                        )
                    }
                    .buttonStyle(.plain)
                }

                Section("Contacts on OneWay") {
                    if filteredFriends.isEmpty {
                        Text(isLoading ? "Loading contacts..." : "No contacts found.")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(filteredFriends) { friend in
                            NavigationLink {
                                ChatThreadView(
                                    chat: ChatSummary(
                                        id: friend.id,
                                        participantName: friend.displayName,
                                        participantHandle: friend.handle,
                                        lastMessagePreview: "Start a secure conversation",
                                        lastMessageAt: .now,
                                        unreadCount: 0,
                                        presence: .online,
                                        isPinned: false,
                                        isMuted: false,
                                        isArchived: false,
                                        isGroup: false
                                    ),
                                    messagingService: messagingService,
                                    groupService: groupService,
                                    friendService: friendService,
                                    callService: callService
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(Color.white.opacity(0.12))
                                        .frame(width: 40, height: 40)
                                        .overlay {
                                            Text(initials(for: friend.displayName))
                                                .font(.subheadline.weight(.bold))
                                                .foregroundStyle(Theme.textPrimary)
                                        }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(friend.displayName)
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(friend.handle)
                                            .font(.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { SideMenuBackground() }
            .oneWayMenuBar()
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Search name or handle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadFriends() }
            .refreshable { await loadFriends() }
            .alert("New chat", isPresented: Binding(
                get: { errorMessage != nil },
                set: { value in if !value { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $isShowingAddFriend) {
                AddFriendView(friendService: friendService)
            }
        }
    }

    private var filteredFriends: [FriendConnection] {
        let connected = friends.filter { $0.status == .connected }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return connected }
        return connected.filter {
            $0.displayName.lowercased().contains(query) || $0.handle.lowercased().contains(query)
        }
    }

    private func loadFriends() async {
        isLoading = true
        defer { isLoading = false }
        do {
            friends = try await friendService.fetchFriends()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load contacts."
        }
    }

    @ViewBuilder
    private func quickActionRow(icon: String, title: String, subtitle: String, action: (() -> Void)? = nil) -> some View {
        if let action {
            Button(action: action) {
                quickActionLabel(icon: icon, title: title, subtitle: subtitle)
            }
            .buttonStyle(.plain)
        } else {
            quickActionLabel(icon: icon, title: title, subtitle: subtitle)
        }
    }

    private func quickActionLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: 0x25D366))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .foregroundStyle(.black.opacity(0.9))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func initials(for name: String) -> String {
        let chars = name.split(separator: " ").prefix(2).compactMap(\.first)
        return chars.isEmpty ? "?" : String(chars)
    }
}
