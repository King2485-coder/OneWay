import Foundation
import Combine

@MainActor
final class ChatsListViewModel: ObservableObject {
    @Published private(set) var chats: [ChatSummary] = []
    @Published private(set) var friendStories: [StoryItem] = []
    @Published private(set) var isLoading = false
    @Published var searchQuery = ""
    @Published var showArchived = false
    @Published var errorMessage: String?

    private let messagingService: MessagingService
    private let storyService: StoryService

    init(messagingService: MessagingService, storyService: StoryService) {
        self.messagingService = messagingService
        self.storyService = storyService
    }

    var visibleChats: [ChatSummary] {
        let source = showArchived ? chats.filter { $0.isArchived } : chats.filter { !$0.isArchived }
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return source }
        let query = searchQuery.lowercased()
        return source.filter {
            $0.participantName.lowercased().contains(query) ||
            $0.participantHandle.lowercased().contains(query) ||
            $0.lastMessagePreview.lowercased().contains(query)
        }
    }

    func loadChats() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let loadedChats = messagingService.fetchChats()
            async let loadedStories = storyService.fetchFriendStories()
            chats = try await loadedChats
            friendStories = try await loadedStories
            errorMessage = nil
        } catch {
            errorMessage = "Unable to load chats."
        }
    }

    func togglePinned(_ chat: ChatSummary) {
        update(chat.id) { current in
            ChatSummary(
                id: current.id,
                participantName: current.participantName,
                participantHandle: current.participantHandle,
                lastMessagePreview: current.lastMessagePreview,
                lastMessageAt: current.lastMessageAt,
                unreadCount: current.unreadCount,
                presence: current.presence,
                isPinned: !current.isPinned,
                isMuted: current.isMuted,
                isArchived: current.isArchived,
                isGroup: current.isGroup
            )
        }
    }

    func toggleMuted(_ chat: ChatSummary) {
        update(chat.id) { current in
            ChatSummary(
                id: current.id,
                participantName: current.participantName,
                participantHandle: current.participantHandle,
                lastMessagePreview: current.lastMessagePreview,
                lastMessageAt: current.lastMessageAt,
                unreadCount: current.unreadCount,
                presence: current.presence,
                isPinned: current.isPinned,
                isMuted: !current.isMuted,
                isArchived: current.isArchived,
                isGroup: current.isGroup
            )
        }
    }

    func toggleArchived(_ chat: ChatSummary) {
        update(chat.id) { current in
            ChatSummary(
                id: current.id,
                participantName: current.participantName,
                participantHandle: current.participantHandle,
                lastMessagePreview: current.lastMessagePreview,
                lastMessageAt: current.lastMessageAt,
                unreadCount: current.unreadCount,
                presence: current.presence,
                isPinned: current.isPinned,
                isMuted: current.isMuted,
                isArchived: !current.isArchived,
                isGroup: current.isGroup
            )
        }
    }

    func markAllAsRead() {
        chats = chats.map { current in
            ChatSummary(
                id: current.id,
                participantName: current.participantName,
                participantHandle: current.participantHandle,
                lastMessagePreview: current.lastMessagePreview,
                lastMessageAt: current.lastMessageAt,
                unreadCount: 0,
                presence: current.presence,
                isPinned: current.isPinned,
                isMuted: current.isMuted,
                isArchived: current.isArchived,
                isGroup: current.isGroup
            )
        }
    }

    func markAsRead(chatIDs: Set<UUID>) {
        guard !chatIDs.isEmpty else { return }
        chats = chats.map { current in
            guard chatIDs.contains(current.id) else { return current }
            return ChatSummary(
                id: current.id,
                participantName: current.participantName,
                participantHandle: current.participantHandle,
                lastMessagePreview: current.lastMessagePreview,
                lastMessageAt: current.lastMessageAt,
                unreadCount: 0,
                presence: current.presence,
                isPinned: current.isPinned,
                isMuted: current.isMuted,
                isArchived: current.isArchived,
                isGroup: current.isGroup
            )
        }
    }

    func archive(chatIDs: Set<UUID>) {
        guard !chatIDs.isEmpty else { return }
        chats = chats.map { current in
            guard chatIDs.contains(current.id) else { return current }
            return ChatSummary(
                id: current.id,
                participantName: current.participantName,
                participantHandle: current.participantHandle,
                lastMessagePreview: current.lastMessagePreview,
                lastMessageAt: current.lastMessageAt,
                unreadCount: current.unreadCount,
                presence: current.presence,
                isPinned: current.isPinned,
                isMuted: current.isMuted,
                isArchived: true,
                isGroup: current.isGroup
            )
        }
    }

    func delete(chatIDs: Set<UUID>) {
        guard !chatIDs.isEmpty else { return }
        chats.removeAll { chatIDs.contains($0.id) }
    }

    private func update(_ chatID: UUID, transform: (ChatSummary) -> ChatSummary) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[index] = transform(chats[index])
        chats.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.lastMessageAt > $1.lastMessageAt
        }
    }
}
