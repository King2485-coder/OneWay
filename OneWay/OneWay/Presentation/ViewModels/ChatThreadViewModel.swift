import Foundation
import Combine

@MainActor
final class ChatThreadViewModel: ObservableObject {
    private let maxPhotoBytes = 8 * 1024 * 1024
    private let maxVideoBytes = 20 * 1024 * 1024
    private let maxGenericBytes = 5 * 1024 * 1024

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isLoading = false
    @Published var composerText = ""
    @Published var searchQuery = ""
    @Published var pendingAttachment: MessageAttachment?
    @Published var activeCallID: UUID?
    @Published var activeCallType: CallType?
    @Published private(set) var isPeerTyping = false
    @Published var errorMessage: String?
    @Published var replyToMessage: ChatMessage?

    let chat: ChatSummary
    private let messagingService: MessagingService
    private let friendService: FriendService
    private let callService: CallService

    init(chat: ChatSummary, messagingService: MessagingService, friendService: FriendService, callService: CallService) {
        self.chat = chat
        self.messagingService = messagingService
        self.friendService = friendService
        self.callService = callService
    }

    var filteredMessages: [ChatMessage] {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return messages }
        let query = searchQuery.lowercased()
        return messages.filter {
            $0.body.lowercased().contains(query) || ($0.attachment?.fileName.lowercased().contains(query) ?? false)
        }
    }

    func loadMessages() async {
        isLoading = true
        defer { isLoading = false }

        do {
            messages = try await messagingService.fetchMessages(chatID: chat.id)
            errorMessage = nil
        } catch {
            errorMessage = "Unable to load messages."
        }
    }

    func sendMessage() async {
        let text = composerText
        composerText = ""

        do {
            if let attachment = pendingAttachment {
                let maxBytes: Int
                let maxLabel: String

                switch attachment.mediaType {
                case .photo:
                    maxBytes = maxPhotoBytes
                    maxLabel = "8MB photo"
                case .video:
                    maxBytes = maxVideoBytes
                    maxLabel = "20MB short video"
                case .file:
                    maxBytes = maxGenericBytes
                    maxLabel = "5MB file"
                }

                guard attachment.byteCount <= maxBytes else {
                    errorMessage = "Attachment is too large (max \(maxLabel))."
                    return
                }
                try await messagingService.sendMediaMessage(attachment, caption: text, chatID: chat.id)
                pendingAttachment = nil
            } else if let replyTarget = replyToMessage {
                try await messagingService.reply(to: replyTarget.id, text: text, chatID: chat.id)
                replyToMessage = nil
            } else {
                try await messagingService.sendMessage(text, chatID: chat.id)
            }

            messages = try await messagingService.fetchMessages(chatID: chat.id)
            errorMessage = nil
            await simulateTypingPulse()
        } catch {
            errorMessage = "Message not sent."
        }
    }

    func retry(_ message: ChatMessage) async {
        do {
            try await messagingService.retryMessage(messageID: message.id, chatID: chat.id)
            messages = try await messagingService.fetchMessages(chatID: chat.id)
            errorMessage = nil
        } catch {
            errorMessage = "Retry failed."
        }
    }

    func react(_ message: ChatMessage, emoji: String) async {
        do {
            try await messagingService.react(emoji, messageID: message.id, chatID: chat.id)
            messages = try await messagingService.fetchMessages(chatID: chat.id)
        } catch {
            errorMessage = "Reaction failed."
        }
    }

    func deleteMessage(_ message: ChatMessage, everyone: Bool) async {
        do {
            if everyone {
                try await messagingService.deleteForEveryone(messageID: message.id, chatID: chat.id)
            } else {
                try await messagingService.deleteForMe(messageID: message.id, chatID: chat.id)
            }
            messages = try await messagingService.fetchMessages(chatID: chat.id)
        } catch {
            errorMessage = "Delete failed."
        }
    }

    func forward(_ message: ChatMessage, to chatID: UUID) async {
        do {
            try await messagingService.forwardMessage(messageID: message.id, fromChatID: chat.id, toChatID: chatID)
            errorMessage = nil
        } catch {
            errorMessage = "Forward failed."
        }
    }

    func startCall(_ type: CallType) async {
        if !chat.isGroup {
            do {
                let friends = try await friendService.fetchFriends()
                let isConnected = friends.contains {
                    $0.status == .connected && normalizedHandle($0.handle) == normalizedHandle(chat.participantHandle)
                }

                guard isConnected else {
                    errorMessage = "Voice/video calls are available after you become friends."
                    return
                }
            } catch {
                errorMessage = "Unable to verify friendship status."
                return
            }
        }

        do {
            let session = try await callService.startCall(chatID: chat.id, type: type)
            activeCallID = session.id
            activeCallType = session.type
            errorMessage = nil
        } catch {
            errorMessage = "Unable to start call."
        }
    }

    func endCallPreview() {
        activeCallType = nil
        activeCallID = nil
    }

    func endActiveCall() async {
        guard let id = activeCallID else {
            endCallPreview()
            return
        }
        do {
            try await callService.endCall(sessionID: id)
        } catch {
            // Best-effort: if teardown fails, still dismiss UI.
        }
        endCallPreview()
    }

    private func simulateTypingPulse() async {
        isPeerTyping = true
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        isPeerTyping = false
    }

    private func normalizedHandle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("@") { return trimmed }
        return "@\(trimmed)"
    }
}
