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
    @Published private(set) var sentinelAssessment: SentinelAssessment?

    let chat: ChatSummary
    private let messagingService: MessagingService
    private let friendService: FriendService
    private let callService: CallService
    private let sentinel: any SentinelAnalyzing

    init(
        chat: ChatSummary,
        messagingService: MessagingService,
        friendService: FriendService,
        callService: CallService,
        sentinel: any SentinelAnalyzing = OnDeviceSentinelService()
    ) {
        self.chat = chat
        self.messagingService = messagingService
        self.friendService = friendService
        self.callService = callService
        self.sentinel = sentinel
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
            await inspectRecentMessages()
        } catch {
            errorMessage = "Unable to load messages."
        }
    }

    func sendMessage() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)

        let messageAssessment = await sentinel.analyzeMessage(text)
        if messageAssessment.riskScore >= 20 {
            sentinelAssessment = messageAssessment
            errorMessage = sentinelMessage(for: messageAssessment)
            return
        }

        if let attachment = pendingAttachment {
            let attachmentAssessment = await sentinel.analyzeFile(
                name: attachment.fileName,
                mimeType: nil,
                bytes: Data()
            )
            if attachmentAssessment.riskScore >= 20 {
                sentinelAssessment = attachmentAssessment
                errorMessage = sentinelMessage(for: attachmentAssessment)
                return
            }
        }

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
            sentinelAssessment = nil
            errorMessage = nil
            await inspectRecentMessages()
            await simulateTypingPulse()
        } catch {
            errorMessage = "Message not sent."
        }
    }

    func retry(_ message: ChatMessage) async {
        let assessment = await sentinel.analyzeMessage(message.body)
        guard assessment.riskScore < 20 else {
            sentinelAssessment = assessment
            errorMessage = sentinelMessage(for: assessment)
            return
        }

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
        let assessment = await sentinel.analyzeMessage(message.body)
        guard assessment.riskScore < 20 else {
            sentinelAssessment = assessment
            errorMessage = sentinelMessage(for: assessment)
            return
        }

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

    private func inspectRecentMessages() async {
        var highest: SentinelAssessment?

        for message in messages.suffix(20) {
            let assessment = await sentinel.analyzeMessage(message.body)
            if assessment.riskScore > (highest?.riskScore ?? 0) {
                highest = assessment
            }
        }

        guard let highest, highest.riskScore >= 20 else {
            sentinelAssessment = nil
            return
        }

        sentinelAssessment = highest
        errorMessage = sentinelMessage(for: highest)
    }

    private func sentinelMessage(for assessment: SentinelAssessment) -> String {
        let reason = assessment.signals.first?.summary ?? "Sentinel detected suspicious activity."
        switch assessment.recommendedAction {
        case .allow:
            return reason
        case .warn:
            return "OneWay Sentinel warning: \(reason) Review the message before continuing."
        case .requireTrustedDeviceApproval:
            return "OneWay Sentinel blocked this action pending trusted-device verification. \(reason)"
        case .quarantine:
            return "OneWay Sentinel quarantined this content. \(reason)"
        case .humanReview:
            return "OneWay Sentinel stopped this high-risk action. \(reason)"
        }
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
