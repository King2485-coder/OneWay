import Foundation

enum OneWayMessageContentMode: String, Codable {
    case legacyNotE2EE = "LEGACY_NOT_E2EE"
    case e2eeV1 = "E2EE_V1"
}

/// Deterministic future transport shape. It intentionally has no plaintext body
/// or attachment bytes; Phase 2 must supply real ciphertext or fail closed.
struct E2EEMessageEnvelopeV1: Codable, Equatable {
    let contentMode: OneWayMessageContentMode
    let protocolVersion: Int
    let messageID: UUID
    let conversationID: UUID?
    let groupID: UUID?
    let senderUserID: String
    let senderDeviceID: UUID
    let recipientDeviceIDs: [UUID]
    let ciphertext: String
    let encryptedAttachmentManifestReferences: [String]
    let createdAt: Date
    let contentType: String
    let protocolMetadata: [String: String]
    let replayID: String
}

@MainActor
final class NetworkMessagingService: MessagingService {
    private struct ConversationsResponse: Decodable {
        let conversations: [ConversationDTO]
    }

    private struct ConversationEnvelope: Decodable {
        let conversation: ConversationDTO
    }

    private struct MessagesResponse: Decodable {
        let messages: [MessageDTO]
    }

    private struct MessageEnvelope: Decodable {
        let message: MessageDTO
    }

    private struct PrivacyEnvelope: Decodable {
        let privacy: PrivacyDTO
    }

    private struct PrivacyDTO: Codable {
        let expirationMode: String
        let expirationDurationSeconds: Int?
        let allowForwarding: Bool
        let allowCopying: Bool
        let allowSavingAttachments: Bool
        let version: Int?
    }

    private struct ConversationDTO: Decodable {
        let id: String
        let type: String
        let title: String?
        let peer: PeerDTO
        let lastMessage: MessageDTO?
        let unreadCount: Int
        let privacy: PrivacyDTO?
        let updatedAt: String
    }

    private struct PeerDTO: Decodable {
        let id: String
        let displayName: String
        let handle: String
    }

    private struct MessageDTO: Decodable {
        let id: String
        let conversationId: String
        let senderId: String
        let body: String
        let attachment: LegacyInlineAttachmentDTO?
        let replyToMessageId: String?
        let editedAt: String?
        let external: ExternalDTO?
        let isSystemNotice: Bool?
        let expirationMode: String?
        let expirationDurationSeconds: Int?
        let readAt: String?
        let expiresAt: String?
        let deletedAt: String?
        let deletionReason: String?
        let isTombstone: Bool?
        let createdAt: String
        let updatedAt: String
    }

    private struct ExternalDTO: Decodable {
        let networkType: String?
        let phoneNumber: String?
        let email: String?
        let provider: String?
        let providerMessageId: String?
        let providerStatus: String?
        let direction: String?
    }

    /// Compatibility-only. New secure-message work must use an opaque object and
    /// encrypted manifest rather than adding fields to this inline representation.
    private struct LegacyInlineAttachmentDTO: Codable {
        let mediaType: String
        let fileName: String
        let byteCount: Int
        let payloadBase64: String
        let mimeType: String?
    }

    private struct DirectConversationRequest: Encodable {
        let participantUserId: String?
        let handle: String?
    }

    private struct LegacySendMessageRequest: Encodable {
        let contentMode: OneWayMessageContentMode
        let body: String
        let attachment: LegacyInlineAttachmentDTO?
        let replyToMessageId: String?
        let clientMessageId: String
        let disappearing: String
        let expirationDurationSeconds: Int?
    }

    private struct EditMessageRequest: Encodable {
        let body: String
    }

    private struct ReadAcknowledgementRequest: Encodable { let visibleInForeground: Bool }

    private let client: APIClient
    private var conversationIDByChatID: [UUID: String] = [:]

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchChats() async throws -> [ChatSummary] {
        let startedAt = OneWayPerformanceLogger.mark("chat.list.fetch")
        let response: ConversationsResponse = try await client.get("api/messages/conversations")
        let summaries = response.conversations.compactMap { dto -> ChatSummary? in
            guard let peerID = UUID(uuidString: dto.peer.id) else { return nil }
            conversationIDByChatID[peerID] = dto.id
            return mapConversation(dto, peerID: peerID)
        }
        let sorted = summaries.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.lastMessageAt > $1.lastMessageAt
        }
        _ = OneWayPerformanceLogger.finish("chat.list.fetch", startedAt: startedAt, metadata: "count=\(sorted.count)")
        return sorted
    }

    func fetchMessages(chatID: UUID) async throws -> [ChatMessage] {
        let startedAt = OneWayPerformanceLogger.mark("chat.messages.fetch", metadata: "chatId=\(chatID.uuidString.lowercased())")
        let conversationID = try await resolveConversationID(chatID: chatID)
        let response: MessagesResponse = try await client.get("api/messages/conversations/\(conversationID)/messages")
        try? await markRead(conversationID: conversationID)
        let currentUserID = AuthTokenStore.shared.currentUserID().lowercased()
        let messages = response.messages.compactMap { mapMessage($0, chatID: chatID, currentUserID: currentUserID) }
        _ = OneWayPerformanceLogger.finish("chat.messages.fetch", startedAt: startedAt, metadata: "chatId=\(chatID.uuidString.lowercased()) count=\(messages.count)")
        return messages
    }

    func fetchPrivacySettings(chatID: UUID) async throws -> ConversationPrivacySettings {
        let conversationID = try await resolveConversationID(chatID: chatID)
        let envelope: PrivacyEnvelope = try await client.get("api/messages/conversations/\(conversationID)/privacy")
        return mapPrivacy(envelope.privacy)
    }

    func updatePrivacySettings(_ settings: ConversationPrivacySettings, chatID: UUID) async throws -> ConversationPrivacySettings {
        let conversationID = try await resolveConversationID(chatID: chatID)
        let request = PrivacyDTO(
            expirationMode: settings.expirationMode.rawValue,
            expirationDurationSeconds: settings.expirationMode == .afterRead ? settings.expirationDurationSeconds ?? 0 : nil,
            allowForwarding: settings.allowForwarding,
            allowCopying: settings.allowCopying,
            allowSavingAttachments: settings.allowSavingAttachments,
            version: nil
        )
        let envelope: PrivacyEnvelope = try await client.put("api/messages/conversations/\(conversationID)/privacy", body: request)
        return mapPrivacy(envelope.privacy)
    }

    func observeMessages(chatID: UUID) -> AsyncThrowingStream<ChatMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let conversationID = try await self.resolveConversationID(chatID: chatID)
                    let stream = MessageRealtimeClient.shared.subscribe(
                        conversationID: conversationID,
                        baseURL: self.client.baseURL
                    )
                    let currentUserID = AuthTokenStore.shared.currentUserID().lowercased()
                    for try await dto in stream {
                        guard let message = self.mapRealtimeMessage(dto, chatID: chatID, currentUserID: currentUserID) else {
                            continue
                        }
                        continuation.yield(message)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func observeChatUpdates() -> AsyncThrowingStream<ChatRealtimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let stream = MessageRealtimeClient.shared.subscribeAll(baseURL: self.client.baseURL)
                    let currentUserID = AuthTokenStore.shared.currentUserID().lowercased()
                    for try await dto in stream {
                        let chatID = self.chatID(forConversationID: dto.conversationId)
                        let message = chatID.flatMap {
                            self.mapRealtimeMessage(dto, chatID: $0, currentUserID: currentUserID)
                        }
                        continuation.yield(ChatRealtimeEvent(
                            chatID: chatID,
                            conversationID: dto.conversationId,
                            message: message
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func preconnectRealtime() {
        MessageRealtimeClient.shared.preconnect(baseURL: client.baseURL)
    }

    static func disconnectRealtime() {
        MessageRealtimeClient.shared.disconnect()
    }

    func sendMessage(_ text: String, chatID: UUID) async throws -> ChatMessage? {
        try await sendMessage(text, chatID: chatID, disappearing: .inherit)
    }

    func sendMessage(_ text: String, chatID: UUID, disappearing: MessageDisappearingOverride) async throws -> ChatMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try await send(body: trimmed, attachment: nil, replyToMessageID: nil, chatID: chatID, disappearing: disappearing)
    }

    func sendMediaMessage(_ attachment: MessageAttachment, caption: String, chatID: UUID, disappearing: MessageDisappearingOverride) async throws -> ChatMessage? {
        try await send(
            body: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            attachment: mapAttachment(attachment),
            replyToMessageID: nil,
            chatID: chatID,
            disappearing: disappearing
        )
    }

    func retryMessage(messageID: UUID, chatID: UUID) async throws {
        guard let failed = try await fetchMessages(chatID: chatID).first(where: { $0.id == messageID }) else {
            return
        }
        _ = try await send(body: failed.body, attachment: failed.attachment.map(mapAttachment), replyToMessageID: failed.replyToMessageID, chatID: chatID)
    }

    func startCall(chatID: UUID, type: CallType) async throws {
        _ = (chatID, type)
    }

    func react(_ emoji: String, messageID: UUID, chatID: UUID) async throws {
        _ = (emoji, messageID, chatID)
    }

    func deleteForMe(messageID: UUID, chatID: UUID) async throws {
        do {
            try await deleteMessage(messageID: messageID, chatID: chatID)
        } catch APIClientError.server(let statusCode, _) where statusCode == 404 {
            return
        }
    }

    func deleteForEveryone(messageID: UUID, chatID: UUID) async throws {
        try await deleteMessage(messageID: messageID, chatID: chatID)
    }

    func editMessage(messageID: UUID, chatID: UUID, newText: String) async throws {
        let conversationID = try await resolveConversationID(chatID: chatID)
        let _: MessageEnvelope = try await client.patch(
            "api/messages/conversations/\(conversationID)/messages/\(messageID.uuidString.lowercased())",
            body: EditMessageRequest(body: newText)
        )
    }

    func pinMessage(messageID: UUID, chatID: UUID) async throws {
        _ = (messageID, chatID)
    }

    func starMessage(messageID: UUID, chatID: UUID) async throws {
        _ = (messageID, chatID)
    }

    func forwardMessage(messageID: UUID, fromChatID: UUID, toChatID: UUID) async throws {
        guard let message = try await fetchMessages(chatID: fromChatID).first(where: { $0.id == messageID }) else {
            return
        }
        _ = try await send(body: message.body, attachment: message.attachment.map(mapAttachment), replyToMessageID: nil, chatID: toChatID)
    }

    func reply(to messageID: UUID, text: String, chatID: UUID) async throws -> ChatMessage? {
        try await send(
            body: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachment: nil,
            replyToMessageID: messageID,
            chatID: chatID
        )
    }

    private func send(body: String, attachment: LegacyInlineAttachmentDTO?, replyToMessageID: UUID?, chatID: UUID, disappearing: MessageDisappearingOverride = .inherit) async throws -> ChatMessage? {
        guard !body.isEmpty || attachment != nil else { return nil }
        let startedAt = OneWayPerformanceLogger.mark("chat.message.send.network", metadata: "chatId=\(chatID.uuidString.lowercased())")
        let conversationID = try await resolveConversationID(chatID: chatID)
        let envelope: MessageEnvelope = try await client.post(
            "api/messages/conversations/\(conversationID)/messages",
            body: LegacySendMessageRequest(
                contentMode: .legacyNotE2EE,
                body: body,
                attachment: attachment,
                replyToMessageId: replyToMessageID?.uuidString.lowercased(),
                clientMessageId: UUID().uuidString.lowercased(),
                disappearing: disappearing.rawValue,
                expirationDurationSeconds: nil
            )
        )
        _ = OneWayPerformanceLogger.finish(
            "chat.message.send.network",
            startedAt: startedAt,
            target: .messageDeliveredOnline,
            metadata: "chatId=\(chatID.uuidString.lowercased()) conversationId=\(conversationID)"
        )
        let currentUserID = AuthTokenStore.shared.currentUserID().lowercased()
        let mapped = mapMessage(envelope.message, chatID: chatID, currentUserID: currentUserID)
        if mapped?.direction == .outgoing {
            OneWayGrowthEventReporter.shared.recordFirst(.firstMessageSent, anonymousUserKey: currentUserID, metadata: ["transport": attachment == nil ? "text" : "attachment", "success": "true"])
        }
        return mapped
    }

    private func deleteMessage(messageID: UUID, chatID: UUID) async throws {
        let conversationID = try await resolveConversationID(chatID: chatID)
        let _: EmptyAPIResponse = try await client.delete(
            "api/messages/conversations/\(conversationID)/messages/\(messageID.uuidString.lowercased())"
        )
    }

    private func markRead(conversationID: String) async throws {
        let _: EmptyAPIResponse = try await client.patch(
            "api/messages/conversations/\(conversationID)/read",
            body: ReadAcknowledgementRequest(visibleInForeground: true)
        )
    }

    private func resolveConversationID(chatID: UUID) async throws -> String {
        if let cached = conversationIDByChatID[chatID] {
            return cached
        }

        let candidateConversationID = chatID.uuidString.lowercased()
        do {
            let envelope: ConversationEnvelope = try await client.get("api/messages/conversations/\(candidateConversationID)")
            conversationIDByChatID[chatID] = envelope.conversation.id
            return envelope.conversation.id
        } catch APIClientError.server(let statusCode, _) where statusCode == 404 {
            // Not a conversation ID; fall through to normal OneWay direct-chat lookup.
        }

        let envelope: ConversationEnvelope = try await client.post(
            "api/messages/conversations/direct",
            body: DirectConversationRequest(
                participantUserId: chatID.uuidString.lowercased(),
                handle: nil
            )
        )
        conversationIDByChatID[chatID] = envelope.conversation.id
        return envelope.conversation.id
    }

    private func chatID(forConversationID conversationID: String) -> UUID? {
        conversationIDByChatID.first { $0.value.lowercased() == conversationID.lowercased() }?.key
    }

    private func mapConversation(_ dto: ConversationDTO, peerID: UUID) -> ChatSummary {
        let lastMessageAt = parseDate(dto.lastMessage?.createdAt ?? dto.updatedAt)
        let preview = previewText(for: dto.lastMessage)
        return ChatSummary(
            id: peerID,
            participantName: dto.title ?? dto.peer.displayName,
            participantHandle: dto.peer.handle,
            lastMessagePreview: preview,
            lastMessageAt: lastMessageAt,
            unreadCount: dto.unreadCount,
            presence: .online,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            isGroup: dto.type != "direct" && dto.type != "external_sms" && dto.type != "external_email",
            isExternal: dto.type == "external_sms" || dto.type == "external_email",
            disappearingAfterSeconds: dto.privacy?.expirationDurationSeconds.map(TimeInterval.init),
            privacySettings: dto.privacy.map(mapPrivacy) ?? .standard
        )
    }

    private func mapMessage(_ dto: MessageDTO, chatID: UUID, currentUserID: String) -> ChatMessage? {
        guard let messageID = UUID(uuidString: dto.id) else { return nil }
        return ChatMessage(
            id: messageID,
            chatID: chatID,
            body: dto.body,
            sentAt: parseDate(dto.createdAt),
            direction: dto.senderId.lowercased() == currentUserID ? .outgoing : .incoming,
            deliveryStatus: deliveryStatus(for: dto, currentUserID: currentUserID),
            readAt: dto.readAt.map(parseDate),
            attachment: dto.attachment.flatMap(mapAttachment),
            expiresAt: dto.expiresAt.map(parseDate),
            replyToMessageID: dto.replyToMessageId.flatMap(UUID.init(uuidString:)),
            reactions: [],
            editedAt: dto.editedAt.map(parseDate),
            expirationMode: DisappearingMessageMode(rawValue: dto.expirationMode ?? "off") ?? .off,
            deletedAt: dto.deletedAt.map(parseDate),
            deletionReason: dto.deletionReason,
            isTombstone: dto.isTombstone ?? false,
            isSystemNotice: dto.isSystemNotice ?? false
        )
    }

    private func mapRealtimeMessage(_ dto: DirectRealtimeMessageDTO, chatID: UUID, currentUserID: String) -> ChatMessage? {
        guard let messageID = UUID(uuidString: dto.id) else { return nil }
        return ChatMessage(
            id: messageID,
            chatID: chatID,
            body: dto.body,
            sentAt: parseDate(dto.createdAt),
            direction: dto.senderId.lowercased() == currentUserID ? .outgoing : .incoming,
            deliveryStatus: deliveryStatus(for: dto, currentUserID: currentUserID),
            readAt: dto.readAt.map(parseDate),
            attachment: dto.attachment.flatMap(mapRealtimeAttachment),
            expiresAt: dto.expiresAt.map(parseDate),
            replyToMessageID: dto.replyToMessageId.flatMap(UUID.init(uuidString:)),
            reactions: [],
            editedAt: dto.editedAt.map(parseDate),
            expirationMode: DisappearingMessageMode(rawValue: dto.expirationMode ?? "off") ?? .off,
            deletedAt: dto.deletedAt.map(parseDate),
            deletionReason: dto.deletionReason,
            isTombstone: dto.isTombstone ?? false,
            isSystemNotice: dto.isSystemNotice ?? false
        )
    }

    private func mapPrivacy(_ dto: PrivacyDTO) -> ConversationPrivacySettings {
        ConversationPrivacySettings(
            expirationMode: DisappearingMessageMode(rawValue: dto.expirationMode) ?? .off,
            expirationDurationSeconds: dto.expirationDurationSeconds,
            allowForwarding: dto.allowForwarding,
            allowCopying: dto.allowCopying,
            allowSavingAttachments: dto.allowSavingAttachments,
            version: dto.version ?? 1
        )
    }

    private func deliveryStatus(for dto: DirectRealtimeMessageDTO, currentUserID: String) -> MessageDeliveryStatus {
        guard dto.senderId.lowercased() == currentUserID else {
            return .read
        }

        return deliveryStatus(forExternalProviderStatus: dto.external?.providerStatus)
    }

    private func deliveryStatus(for dto: MessageDTO, currentUserID: String) -> MessageDeliveryStatus {
        guard dto.senderId.lowercased() == currentUserID else {
            return .read
        }

        return deliveryStatus(forExternalProviderStatus: dto.external?.providerStatus)
    }

    private func deliveryStatus(forExternalProviderStatus rawStatus: String?) -> MessageDeliveryStatus {
        let status = rawStatus?.lowercased()
        switch status {
        case "failed", "undelivered", "delivery_failed":
            return .failed
        case "sent", "delivered":
            return .delivered
        case "queued", "accepted", "sending":
            return .sent
        default:
            return .delivered
        }
    }

    private func mapAttachment(_ dto: LegacyInlineAttachmentDTO) -> MessageAttachment? {
        guard let mediaType = MediaType(rawValue: dto.mediaType),
              let payload = Data(base64Encoded: dto.payloadBase64) else {
            return nil
        }
        return MessageAttachment(
            mediaType: mediaType,
            fileName: dto.fileName,
            byteCount: dto.byteCount,
            payload: payload,
            mimeType: dto.mimeType
        )
    }

    private func mapRealtimeAttachment(_ dto: DirectRealtimeAttachmentDTO) -> MessageAttachment? {
        guard let mediaType = MediaType(rawValue: dto.mediaType),
              let payload = Data(base64Encoded: dto.payloadBase64) else {
            return nil
        }
        return MessageAttachment(
            mediaType: mediaType,
            fileName: dto.fileName,
            byteCount: dto.byteCount,
            payload: payload,
            mimeType: dto.mimeType
        )
    }

    private func mapAttachment(_ attachment: MessageAttachment) -> LegacyInlineAttachmentDTO {
        LegacyInlineAttachmentDTO(
            mediaType: attachment.mediaType.rawValue,
            fileName: attachment.fileName,
            byteCount: attachment.byteCount,
            payloadBase64: attachment.payload.base64EncodedString(),
            mimeType: attachment.mimeType
        )
    }

    private func previewText(for message: MessageDTO?) -> String {
        guard let message else { return "Start a secure conversation" }
        if !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message.body
        }
        if let attachment = message.attachment {
            return "[\(attachment.mediaType.capitalized)] \(attachment.fileName)"
        }
        return "Message"
    }

    private func parseDate(_ raw: String) -> Date {
        if let date = Self.isoWithFractional.date(from: raw) {
            return date
        }
        if let date = Self.iso.date(from: raw) {
            return date
        }
        return Date()
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso = ISO8601DateFormatter()
}

private struct DirectRealtimeEnvelope: Decodable {
    let type: String
    let payload: DirectRealtimePayload?
}

private struct DirectRealtimePayload: Decodable {
    let message: DirectRealtimeMessageDTO?
}

private struct DirectRealtimeMessageDTO: Decodable {
    let id: String
    let conversationId: String
    let senderId: String
    let body: String
    let attachment: DirectRealtimeAttachmentDTO?
    let replyToMessageId: String?
    let editedAt: String?
    let external: DirectRealtimeExternalDTO?
    let isSystemNotice: Bool?
    let expirationMode: String?
    let expirationDurationSeconds: Int?
    let readAt: String?
    let expiresAt: String?
    let deletedAt: String?
    let deletionReason: String?
    let isTombstone: Bool?
    let createdAt: String
    let updatedAt: String
}

private struct DirectRealtimeExternalDTO: Decodable {
    let networkType: String?
    let phoneNumber: String?
    let email: String?
    let provider: String?
    let providerMessageId: String?
    let providerStatus: String?
    let direction: String?
}

private struct DirectRealtimeAttachmentDTO: Decodable {
    let mediaType: String
    let fileName: String
    let byteCount: Int
    let payloadBase64: String
    let mimeType: String?
}

private struct DirectRealtimeWireMessage: Encodable {
    let type: String
    let payload: [String: String]
}

private final class MessageRealtimeClient {
    static let shared = MessageRealtimeClient()

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isConnecting = false
    private var continuations: [String: [UUID: AsyncThrowingStream<DirectRealtimeMessageDTO, Error>.Continuation]] = [:]
    private var allContinuations: [UUID: AsyncThrowingStream<DirectRealtimeMessageDTO, Error>.Continuation] = [:]
    private var baseURL: URL?

    private init() {}

    func subscribe(conversationID: String, baseURL: URL) -> AsyncThrowingStream<DirectRealtimeMessageDTO, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let normalized = conversationID.lowercased()
            lock.withLock {
                continuations[normalized, default: [:]][id] = continuation
            }
            connectIfNeeded(baseURL: baseURL)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.continuations[normalized]?.removeValue(forKey: id)
                    if self?.continuations[normalized]?.isEmpty == true {
                        self?.continuations.removeValue(forKey: normalized)
                    }
                }
            }
        }
    }

    func subscribeAll(baseURL: URL) -> AsyncThrowingStream<DirectRealtimeMessageDTO, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            lock.withLock {
                allContinuations[id] = continuation
            }
            connectIfNeeded(baseURL: baseURL)
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.allContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func preconnect(baseURL: URL) {
        connectIfNeeded(baseURL: baseURL)
    }

    func disconnect() {
        let error = APIClientError.server(statusCode: 401, message: "Signed out.")
        let all = lock.withLock {
            let values = continuations.values.flatMap { $0.values } + allContinuations.values.map { $0 }
            continuations.removeAll()
            allContinuations.removeAll()
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            receiveTask?.cancel()
            receiveTask = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            baseURL = nil
            isConnecting = false
            return values
        }
        for continuation in all {
            continuation.finish(throwing: error)
        }
    }

    private func connectIfNeeded(baseURL: URL) {
        lock.lock()
        self.baseURL = baseURL
        let shouldConnect = task == nil && !isConnecting
        if shouldConnect { isConnecting = true }
        lock.unlock()
        guard shouldConnect else { return }

        guard let url = Self.webSocketURL(baseURL: baseURL) else {
            finishAll(APIClientError.invalidBaseURL(baseURL.absoluteString))
            return
        }

        var request = URLRequest(url: url)
        let authorization = DevAuth.authorizationHeader(forPath: "ws/messages", baseURL: baseURL)
            ?? AuthTokenStore.shared.authorizationHeader()
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let nextTask = URLSession.shared.webSocketTask(with: request)
        lock.withLock {
            task = nextTask
            isConnecting = false
        }
        nextTask.resume()
        send(DirectRealtimeWireMessage(
            type: "auth",
            payload: ["token": authorization.replacingOccurrences(of: "Bearer ", with: "")]
        ))
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        startHeartbeat()
    }

    private func receiveLoop() async {
        let decoder = JSONDecoder()
        while !Task.isCancelled {
            do {
                guard let task = lock.withLock({ task }) else { return }
                let received = try await task.receive()
                lock.withLock {
                    reconnectAttempt = 0
                    reconnectTask = nil
                }
                let data: Data
                switch received {
                case .data(let raw): data = raw
                case .string(let text): data = Data(text.utf8)
                @unknown default: continue
                }

                let envelope = try decoder.decode(DirectRealtimeEnvelope.self, from: data)
                if (envelope.type == "message.created" || envelope.type == "message.updated"), let message = envelope.payload?.message {
                    yield(message)
                }
            } catch {
                scheduleReconnect(error: error)
                return
            }
        }
    }

    private func yield(_ message: DirectRealtimeMessageDTO) {
        let targets = lock.withLock {
            (continuations[message.conversationId.lowercased()]?.values.map { $0 } ?? [])
            + allContinuations.values.map { $0 }
        }
        for continuation in targets {
            continuation.yield(message)
        }
    }

    private func send(_ message: DirectRealtimeWireMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.withLock { task }?.send(.string(text)) { _ in }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.send(DirectRealtimeWireMessage(type: "ping", payload: [:]))
            }
        }
    }

    private func scheduleReconnect(error: Error) {
        let reconnect = lock.withLock { () -> (URL?, Task<Void, Never>?, TimeInterval) in
            let existing = reconnectTask
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            isConnecting = false
            reconnectAttempt = min(reconnectAttempt + 1, 6)
            let delay = min(pow(2, Double(reconnectAttempt - 1)), 30)
            return (baseURL, existing, delay)
        }
        reconnect.1?.cancel()
        guard let baseURL = reconnect.0 else {
            finishAll(error)
            return
        }
        let scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(reconnect.2 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connectIfNeeded(baseURL: baseURL)
        }
        lock.withLock { reconnectTask = scheduled }
    }

    private func finishAll(_ error: Error) {
        let all = lock.withLock {
            let values = continuations.values.flatMap { $0.values } + allContinuations.values.map { $0 }
            continuations.removeAll()
            allContinuations.removeAll()
            task = nil
            isConnecting = false
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            return values
        }
        for continuation in all {
            continuation.finish(throwing: error)
        }
    }

    private static func webSocketURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "ws/messages"
        return components.url
    }
}
