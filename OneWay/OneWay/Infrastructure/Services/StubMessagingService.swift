import Foundation

@MainActor
final class StubMessagingService: MessagingService {
    private let localPersistence: LocalPersistence
    private let cryptoService: CryptoService
    private let storageService: StorageService
    private var chats: [ChatSummary]
    private var messagesByChatID: [UUID: [ChatMessage]]

    init(localPersistence: LocalPersistence, cryptoService: CryptoService, storageService: StorageService) {
        self.localPersistence = localPersistence
        self.cryptoService = cryptoService
        self.storageService = storageService

        let seeded = MockChatSeed.seed()
        self.chats = seeded.chats
        self.messagesByChatID = seeded.messagesByChatID
    }

    func fetchChats() async throws -> [ChatSummary] {
        localPersistence.cacheChatSummaries(chats)
        return chats
            .filter { !$0.isArchived }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.lastMessageAt > $1.lastMessageAt
            }
    }

    func fetchMessages(chatID: UUID) async throws -> [ChatMessage] {
        let messages = messagesByChatID[chatID] ?? []
        localPersistence.cacheMessages(messages, for: chatID)
        return messages.sorted { $0.sentAt < $1.sentAt }
    }

    func sendMessage(_ text: String, chatID: UUID) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.lowercased().contains("fail") {
            try await addFailedOutgoing(body: trimmed, chatID: chatID)
            return
        }

        let outgoing = makeOutgoingMessage(body: trimmed, chatID: chatID, attachment: nil, status: .read)
        append(message: outgoing, to: chatID)
        try await encryptAndPersist(outgoing, chatID: chatID)

        let incoming = makeIncomingReply(for: trimmed, chatID: chatID)
        append(message: incoming, to: chatID)
        updateChatPreview(chatID: chatID, preview: incoming.body, timestamp: incoming.sentAt, bumpUnread: true)
    }

    func sendMediaMessage(_ attachment: MessageAttachment, caption: String, chatID: UUID) async throws {
        let outgoing = makeOutgoingMessage(body: caption, chatID: chatID, attachment: attachment, status: .delivered)
        append(message: outgoing, to: chatID)
        try await encryptAndPersist(outgoing, chatID: chatID)

        let incoming = makeIncomingReply(for: caption.isEmpty ? "media" : caption, chatID: chatID)
        append(message: incoming, to: chatID)
        updateChatPreview(chatID: chatID, preview: "[Media] \(incoming.body)", timestamp: incoming.sentAt, bumpUnread: true)
    }

    func retryMessage(messageID: UUID, chatID: UUID) async throws {
        guard var messages = messagesByChatID[chatID],
              let index = messages.firstIndex(where: { $0.id == messageID && $0.deliveryStatus == .failed }) else {
            return
        }

        let failed = messages[index]
        let retried = ChatMessage(
            id: failed.id,
            chatID: failed.chatID,
            body: failed.body,
            sentAt: Date(),
            direction: failed.direction,
            deliveryStatus: .read,
            readAt: Date(),
            attachment: failed.attachment
        )
        messages[index] = retried

        let incoming = makeIncomingReply(for: retried.body, chatID: chatID)
        messages.append(incoming)

        messagesByChatID[chatID] = messages
        updateChatPreview(chatID: chatID, preview: incoming.body, timestamp: incoming.sentAt, bumpUnread: true)
        try await encryptAndPersist(retried, chatID: chatID)
        try await encryptAndPersist(incoming, chatID: chatID)
    }

    func startCall(chatID: UUID, type: CallType) async throws {
        _ = (chatID, type)
    }

    func react(_ emoji: String, messageID: UUID, chatID: UUID) async throws {
        guard var list = messagesByChatID[chatID],
              let idx = list.firstIndex(where: { $0.id == messageID }) else { return }
        var msg = list[idx]
        var reactions = msg.reactions
        reactions.append(MessageReaction(id: UUID(), emoji: emoji, userID: UUID(), createdAt: Date()))
        msg = ChatMessage(
            id: msg.id,
            chatID: msg.chatID,
            body: msg.body,
            sentAt: msg.sentAt,
            direction: msg.direction,
            deliveryStatus: msg.deliveryStatus,
            readAt: msg.readAt,
            attachment: msg.attachment,
            expiresAt: msg.expiresAt,
            replyToMessageID: msg.replyToMessageID,
            reactions: reactions,
            isPinned: msg.isPinned,
            isStarred: msg.isStarred,
            editedAt: msg.editedAt,
            linkPreview: msg.linkPreview,
            forwardedCount: msg.forwardedCount
        )
        list[idx] = msg
        messagesByChatID[chatID] = list
    }

    func deleteForMe(messageID: UUID, chatID: UUID) async throws {
        messagesByChatID[chatID]?.removeAll { $0.id == messageID }
    }

    func deleteForEveryone(messageID: UUID, chatID: UUID) async throws {
        try await deleteForMe(messageID: messageID, chatID: chatID)
    }

    func editMessage(messageID: UUID, chatID: UUID, newText: String) async throws {
        guard var list = messagesByChatID[chatID],
              let idx = list.firstIndex(where: { $0.id == messageID }) else { return }
        var msg = list[idx]
        msg = ChatMessage(
            id: msg.id,
            chatID: msg.chatID,
            body: newText,
            sentAt: msg.sentAt,
            direction: msg.direction,
            deliveryStatus: msg.deliveryStatus,
            readAt: msg.readAt,
            attachment: msg.attachment,
            expiresAt: msg.expiresAt,
            replyToMessageID: msg.replyToMessageID,
            reactions: msg.reactions,
            isPinned: msg.isPinned,
            isStarred: msg.isStarred,
            editedAt: Date(),
            linkPreview: msg.linkPreview,
            forwardedCount: msg.forwardedCount
        )
        list[idx] = msg
        messagesByChatID[chatID] = list
    }

    func pinMessage(messageID: UUID, chatID: UUID) async throws {
        toggleFlag(messageID: messageID, chatID: chatID, flag: \ChatMessage.isPinned)
    }

    func starMessage(messageID: UUID, chatID: UUID) async throws {
        toggleFlag(messageID: messageID, chatID: chatID, flag: \ChatMessage.isStarred)
    }

    func forwardMessage(messageID: UUID, fromChatID: UUID, toChatID: UUID) async throws {
        guard let message = messagesByChatID[fromChatID]?.first(where: { $0.id == messageID }) else { return }
        let forwarded = ChatMessage(
            id: UUID(),
            chatID: toChatID,
            body: message.body,
            sentAt: Date(),
            direction: .outgoing,
            deliveryStatus: .sent,
            readAt: nil,
            attachment: message.attachment,
            expiresAt: message.expiresAt,
            replyToMessageID: nil,
            reactions: [],
            isPinned: false,
            isStarred: false,
            editedAt: nil,
            linkPreview: message.linkPreview,
            forwardedCount: message.forwardedCount + 1
        )
        append(message: forwarded, to: toChatID)
        updateChatPreview(chatID: toChatID, preview: forwarded.body, timestamp: forwarded.sentAt, bumpUnread: true)
    }

    func reply(to messageID: UUID, text: String, chatID: UUID) async throws {
        let reply = ChatMessage(
            id: UUID(),
            chatID: chatID,
            body: text,
            sentAt: Date(),
            direction: .outgoing,
            deliveryStatus: .sent,
            readAt: nil,
            attachment: nil,
            expiresAt: nil,
            replyToMessageID: messageID,
            reactions: [],
            isPinned: false,
            isStarred: false,
            editedAt: nil,
            linkPreview: nil,
            forwardedCount: 0
        )
        append(message: reply, to: chatID)
        updateChatPreview(chatID: chatID, preview: reply.body, timestamp: reply.sentAt, bumpUnread: false)
    }

    func wipeAllData() async {
        chats.removeAll()
        messagesByChatID.removeAll()
    }

    private func addFailedOutgoing(body: String, chatID: UUID) async throws {
        let failed = makeOutgoingMessage(body: body, chatID: chatID, attachment: nil, status: .failed)
        append(message: failed, to: chatID)
        updateChatPreview(chatID: chatID, preview: "Failed to send: \(body)", timestamp: failed.sentAt, bumpUnread: false)
    }

    private func makeOutgoingMessage(
        body: String,
        chatID: UUID,
        attachment: MessageAttachment?,
        status: MessageDeliveryStatus
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            chatID: chatID,
            body: body,
            sentAt: Date(),
            direction: .outgoing,
            deliveryStatus: status,
            readAt: status == .read ? Date() : nil,
            attachment: attachment
        )
    }

    private func makeIncomingReply(for text: String, chatID: UUID) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            chatID: chatID,
            body: autoReply(for: text),
            sentAt: Date().addingTimeInterval(1),
            direction: .incoming,
            deliveryStatus: .read,
            readAt: Date(),
            attachment: nil
        )
    }

    private func append(message: ChatMessage, to chatID: UUID) {
        var existing = messagesByChatID[chatID] ?? []
        existing.append(message)
        messagesByChatID[chatID] = existing
    }

    private func toggleFlag(messageID: UUID, chatID: UUID, flag: WritableKeyPath<ChatMessage, Bool>) {
        guard var list = messagesByChatID[chatID],
              let idx = list.firstIndex(where: { $0.id == messageID }) else { return }
        var msg = list[idx]
        msg[keyPath: flag].toggle()
        list[idx] = msg
        messagesByChatID[chatID] = list
    }

    private func encryptAndPersist(_ message: ChatMessage, chatID: UUID) async throws {
        let plaintext = PlaintextMessage(
            id: message.id,
            chatID: chatID,
            senderID: UUID(), // stub
            body: message.body,
            attachment: message.attachment,
            expiresAt: message.expiresAt
        )
        let recipient = UserProfile(userID: UUID(), displayName: "Peer", handle: nil, avatarURL: nil, about: nil, phoneNumber: nil, email: nil)
        let encrypted = try await cryptoService.encrypt(message: plaintext, for: recipient, context: MessageContext(isGroup: false, communityID: nil))
        storageService.storeCiphertext(encrypted)
    }

    private func updateChatPreview(chatID: UUID, preview: String, timestamp: Date, bumpUnread: Bool) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let chat = chats[index]
        chats[index] = ChatSummary(
            id: chat.id,
            participantName: chat.participantName,
            participantHandle: chat.participantHandle,
            lastMessagePreview: preview,
            lastMessageAt: timestamp,
            unreadCount: bumpUnread ? chat.unreadCount + 1 : chat.unreadCount,
            presence: chat.presence,
            isPinned: chat.isPinned,
            isMuted: chat.isMuted,
            isArchived: chat.isArchived,
            isGroup: chat.isGroup
        )
    }

    private func autoReply(for text: String) -> String {
        let lowered = text.lowercased()
        if lowered.contains("hello") || lowered.contains("hi") {
            return "Hey, got your message."
        }
        if lowered.contains("call") {
            return "I can hop on a call in a few minutes."
        }
        if lowered.contains("photo") {
            return "Nice photo. Received on my end."
        }
        return "Received. This is a dummy test reply."
    }
}

enum MockChatSeed {
    static func seed(now: Date = Date()) -> (chats: [ChatSummary], messagesByChatID: [UUID: [ChatMessage]]) {
        let alexID = UUID()
        let priyaID = UUID()
        let teamID = UUID()

        let chats = [
            ChatSummary(
                id: alexID,
                participantName: "Alex",
                participantHandle: "@alex",
                lastMessagePreview: "Can we sync on keys later?",
                lastMessageAt: now.addingTimeInterval(-60 * 9),
                unreadCount: 2,
                presence: .online,
                isPinned: true,
                isMuted: false,
                isArchived: false,
                isGroup: false
            ),
            ChatSummary(
                id: priyaID,
                participantName: "Priya",
                participantHandle: "@priya",
                lastMessagePreview: "Looks good to me.",
                lastMessageAt: now.addingTimeInterval(-60 * 42),
                unreadCount: 0,
                presence: .offline,
                isPinned: false,
                isMuted: false,
                isArchived: false,
                isGroup: false
            ),
            ChatSummary(
                id: teamID,
                participantName: "Core Team",
                participantHandle: "#core-team",
                lastMessagePreview: "Standup starts in 10.",
                lastMessageAt: now.addingTimeInterval(-60 * 120),
                unreadCount: 6,
                presence: .online,
                isPinned: false,
                isMuted: true,
                isArchived: false,
                isGroup: true
            )
        ]

        let incoming = MessageDeliveryStatus.read

        let messagesByChatID: [UUID: [ChatMessage]] = [
            alexID: [
                ChatMessage(id: UUID(), chatID: alexID, body: "Morning.", sentAt: now.addingTimeInterval(-60 * 40), direction: .incoming, deliveryStatus: incoming, readAt: now.addingTimeInterval(-60 * 39), attachment: nil),
                ChatMessage(id: UUID(), chatID: alexID, body: "Can we sync on keys later?", sentAt: now.addingTimeInterval(-60 * 9), direction: .incoming, deliveryStatus: incoming, readAt: now.addingTimeInterval(-60 * 8), attachment: nil)
            ],
            priyaID: [
                ChatMessage(id: UUID(), chatID: priyaID, body: "I reviewed the API shape.", sentAt: now.addingTimeInterval(-60 * 70), direction: .incoming, deliveryStatus: incoming, readAt: now.addingTimeInterval(-60 * 69), attachment: nil),
                ChatMessage(id: UUID(), chatID: priyaID, body: "Looks good to me.", sentAt: now.addingTimeInterval(-60 * 42), direction: .incoming, deliveryStatus: incoming, readAt: now.addingTimeInterval(-60 * 41), attachment: nil)
            ],
            teamID: [
                ChatMessage(id: UUID(), chatID: teamID, body: "Standup starts in 10.", sentAt: now.addingTimeInterval(-60 * 120), direction: .incoming, deliveryStatus: incoming, readAt: now.addingTimeInterval(-60 * 119), attachment: nil),
                ChatMessage(id: UUID(), chatID: teamID, body: "I will join from mobile.", sentAt: now.addingTimeInterval(-60 * 100), direction: .outgoing, deliveryStatus: .delivered, readAt: nil, attachment: nil)
            ]
        ]

        return (chats, messagesByChatID)
    }
}
