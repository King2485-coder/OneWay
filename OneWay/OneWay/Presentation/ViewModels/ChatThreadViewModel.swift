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
    @Published private(set) var externalMessagingDisabledReason: String?
    @Published var errorMessage: String?
    @Published var replyToMessage: ChatMessage?
    @Published var privacySettings: ConversationPrivacySettings
    @Published var nextMessageDisappearing: MessageDisappearingOverride = .inherit
    @Published var privacyStatusMessage: String?

    let chat: ChatSummary
    private let messagingService: MessagingService
    private let friendService: FriendService
    private let callService: CallService
    private var isRefreshingMessages = false
    private var realtimeMessagesTask: Task<Void, Never>?

    init(chat: ChatSummary, messagingService: MessagingService, friendService: FriendService, callService: CallService) {
        self.chat = chat
        self.privacySettings = chat.privacySettings
        self.messagingService = messagingService
        self.friendService = friendService
        self.callService = callService
    }

    func loadPrivacySettings() async {
        guard !chat.isExternal else { return }
        do {
            privacySettings = try await messagingService.fetchPrivacySettings(chatID: chat.id)
        } catch {
            errorMessage = "Unable to load privacy settings."
        }
    }

    func savePrivacySettings(_ settings: ConversationPrivacySettings) async {
        do {
            privacySettings = try await messagingService.updatePrivacySettings(settings, chatID: chat.id)
            privacyStatusMessage = settings.expirationMode == .afterRead
                ? "Disappearing messages are on. OneWay removes content after all recipients read it and the selected timer ends."
                : "Disappearing messages are off."
        } catch {
            errorMessage = "Privacy settings were not saved."
        }
    }

    func recordScreenshotWarning() {
        privacyStatusMessage = "A screenshot was detected. OneWay cannot prevent screenshots or copies made outside the app."
    }

    var filteredMessages: [ChatMessage] {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return messages }
        let query = searchQuery.lowercased()
        return messages.filter {
            $0.body.lowercased().contains(query) || ($0.attachment?.fileName.lowercased().contains(query) ?? false)
        }
    }

    var canSendMessages: Bool {
        externalMessagingDisabledReason == nil
    }

    func prepareExternalMessaging() async {
        guard chat.isExternal else {
            externalMessagingDisabledReason = nil
            return
        }

        do {
            if chat.participantHandle == "External SMS" {
                let preflight = try await SMSBridgeService.shared.preflight()
                if !preflight.ok {
                    externalMessagingDisabledReason = externalSetupMessage(
                        reason: preflight.setupRequiredReason,
                        missing: preflight.missing,
                        warnings: preflight.warnings,
                        fallback: "OneWay SMS is not ready for off-network delivery yet."
                    )
                    return
                }
            } else if chat.participantHandle == "External Email" {
                let preflight = try await SMSBridgeService.shared.emailPreflight()
                if !preflight.ok || preflight.mode == "stub" {
                    externalMessagingDisabledReason = externalSetupMessage(
                        reason: nil,
                        missing: preflight.missing,
                        warnings: preflight.warnings,
                        fallback: "OneWay email is not ready for off-network delivery yet."
                    )
                    return
                }
            }

            externalMessagingDisabledReason = nil
        } catch {
            externalMessagingDisabledReason = "Unable to verify OneWay external messaging setup."
        }
    }

    func loadMessages(showLoading: Bool = true) async {
        guard !isRefreshingMessages else { return }
        isRefreshingMessages = true
        let loadStartedAt = OneWayPerformanceLogger.mark("chat.messages.load", metadata: "chatId=\(chat.id.uuidString.lowercased())")
        if showLoading {
            isLoading = true
        }
        defer {
            isRefreshingMessages = false
            if showLoading {
                isLoading = false
            }
            _ = OneWayPerformanceLogger.finish(
                "chat.messages.load",
                startedAt: loadStartedAt,
                target: showLoading ? nil : .chatOpenFromCache,
                metadata: "chatId=\(chat.id.uuidString.lowercased()) count=\(messages.count)"
            )
        }

        do {
            let fetched = try await messagingService.fetchMessages(chatID: chat.id)
            messages = mergeMessages(existing: messages, incoming: fetched, preferIncoming: true)
            errorMessage = nil
        } catch {
            if showLoading {
                errorMessage = "Unable to load messages."
            }
        }
    }

    func startRealtimeMessages() {
        realtimeMessagesTask?.cancel()
        realtimeMessagesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = self.messagingService.observeMessages(chatID: self.chat.id)
                for try await message in stream {
                    await MainActor.run {
                        self.messages = self.mergeMessages(
                            existing: self.messages,
                            incoming: [message],
                            preferIncoming: true
                        )
                        self.errorMessage = nil
                    }
                }
            } catch {
                await MainActor.run {
                    if self.messages.isEmpty {
                        self.errorMessage = "Realtime messages are reconnecting."
                    }
                }
            }
        }
    }

    func stopRealtimeMessages() {
        realtimeMessagesTask?.cancel()
        realtimeMessagesTask = nil
    }

    func sendMessage() async {
        guard canSendMessages else {
            errorMessage = externalMessagingDisabledReason
            return
        }

        let text = composerText
        let sendStartedAt = Date()
        composerText = ""
        let optimisticID = UUID()
        let optimisticMessage = ChatMessage(
            id: optimisticID,
            chatID: chat.id,
            body: text,
            sentAt: Date(),
            direction: .outgoing,
            deliveryStatus: .sending,
            readAt: nil,
            attachment: pendingAttachment,
            replyToMessageID: replyToMessage?.id
        )
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingAttachment != nil {
            messages.append(optimisticMessage)
            _ = OneWayPerformanceLogger.finish(
                "chat.message.localBubble",
                startedAt: sendStartedAt,
                target: .messageLocalBubble,
                metadata: "chatId=\(chat.id.uuidString.lowercased()) localMessageId=\(optimisticID.uuidString.lowercased())"
            )
        }

        do {
            var confirmedMessage: ChatMessage?
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
                case .audio:
                    maxBytes = maxGenericBytes
                    maxLabel = "5MB voice message"
                case .file:
                    maxBytes = maxGenericBytes
                    maxLabel = "5MB file"
                }

                guard attachment.byteCount <= maxBytes else {
                    replaceOptimisticMessage(optimisticID, withStatus: .failed)
                    errorMessage = "Attachment is too large (max \(maxLabel))."
                    return
                }
                confirmedMessage = try await messagingService.sendMediaMessage(attachment, caption: text, chatID: chat.id, disappearing: nextMessageDisappearing)
                pendingAttachment = nil
            } else if let replyTarget = replyToMessage {
                confirmedMessage = try await messagingService.reply(to: replyTarget.id, text: text, chatID: chat.id)
                replyToMessage = nil
            } else {
                confirmedMessage = try await messagingService.sendMessage(text, chatID: chat.id, disappearing: nextMessageDisappearing)
            }

            if let confirmedMessage {
                replaceOptimisticMessage(optimisticID, with: confirmedMessage)
            } else {
                replaceOptimisticMessage(optimisticID, withStatus: .sent)
            }
            nextMessageDisappearing = .inherit
            errorMessage = nil
            _ = OneWayPerformanceLogger.finish(
                "chat.message.delivered",
                startedAt: sendStartedAt,
                target: .messageDeliveredOnline,
                metadata: "chatId=\(chat.id.uuidString.lowercased()) localMessageId=\(optimisticID.uuidString.lowercased())"
            )
            await simulateTypingPulse()
        } catch {
            replaceOptimisticMessage(optimisticID, withStatus: .failed)
            errorMessage = error.localizedDescription.isEmpty ? "Message not sent." : error.localizedDescription
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
            try await callService.endCall(sessionID: id, reason: .localHangup, source: .inCallButton)
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

    private func replaceOptimisticMessage(_ id: UUID, withStatus status: MessageDeliveryStatus) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let current = messages[index]
        messages[index] = ChatMessage(
            id: current.id,
            chatID: current.chatID,
            body: current.body,
            sentAt: current.sentAt,
            direction: current.direction,
            deliveryStatus: status,
            readAt: current.readAt,
            attachment: current.attachment,
            expiresAt: current.expiresAt,
            replyToMessageID: current.replyToMessageID,
            reactions: current.reactions,
            isPinned: current.isPinned,
            isStarred: current.isStarred,
            editedAt: current.editedAt,
            linkPreview: current.linkPreview,
            forwardedCount: current.forwardedCount
        )
    }

    private func replaceOptimisticMessage(_ id: UUID, with confirmed: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = confirmed
        } else {
            messages = mergeMessages(existing: messages, incoming: [confirmed], preferIncoming: true)
        }
    }

    private func mergeMessages(existing: [ChatMessage], incoming: [ChatMessage], preferIncoming: Bool = false) -> [ChatMessage] {
        var byID: [UUID: ChatMessage] = [:]
        let ordered = preferIncoming ? existing + incoming : incoming + existing
        for message in ordered {
            byID[message.id] = message
        }
        return byID.values.sorted { $0.sentAt < $1.sentAt }
    }

    private func externalSetupMessage(reason: String?, missing: [String], warnings: [String], fallback: String) -> String {
        if let reason, !reason.isEmpty {
            return reason
        }
        if !missing.isEmpty {
            return "OneWay external messaging is not configured yet: \(missing.joined(separator: ", "))"
        }
        if !warnings.isEmpty {
            return warnings.joined(separator: "\n")
        }
        return fallback
    }
}
