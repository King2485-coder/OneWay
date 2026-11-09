import Foundation

struct SMSBridgePreflightResponse: Codable {
    let ok: Bool
    let provider: String
    let mode: String
    let providerConfigured: Bool
    let fromNumberConfigured: Bool
    let webhookBaseUrlConfigured: Bool
    let registrationRequired: Bool?
    let setupRequiredReason: String?
    let missing: [String]
    let warnings: [String]
}

struct SMSBridgeSendResponse: Codable {
    let ok: Bool
    let networkType: String
    let provider: String
    let status: String
    let providerMessageId: String
    let toPhoneNumber: String?
    let toEmail: String?
    let message: String?
}

struct EmailBridgePreflightResponse: Codable {
    let ok: Bool
    let provider: String
    let mode: String
    let providerConfigured: Bool
    let fromAddressConfigured: Bool
    let missing: [String]
    let warnings: [String]
}

final class SMSBridgeService {
    static let shared = SMSBridgeService()

    private struct ConversationEnvelope: Decodable {
        let conversation: ConversationDTO
    }

    private struct ConversationDTO: Decodable {
        let id: String
        let type: String
        let title: String?
        let peer: PeerDTO
        let lastMessage: MessageDTO?
        let unreadCount: Int
        let updatedAt: String
    }

    private struct PeerDTO: Decodable {
        let id: String
        let displayName: String
        let handle: String
    }

    private struct MessageDTO: Decodable {
        let body: String
        let createdAt: String
    }

    private struct ExternalConversationRequest: Encodable {
        let target: String
    }

    private struct SendRequest: Encodable {
        let target: String
        let body: String
        let fromOneWayNumber: String?
    }

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func preflight() async throws -> SMSBridgePreflightResponse {
        try await client.get("api/messages/external/preflight")
    }

    func emailPreflight() async throws -> EmailBridgePreflightResponse {
        try await client.get("api/messages/external/email/preflight")
    }

    func startExternalConversation(to target: String) async throws -> ChatSummary {
        let response: ConversationEnvelope = try await client.post(
            "api/messages/external/conversations",
            body: ExternalConversationRequest(target: target)
        )
        return mapConversation(response.conversation)
    }

    func sendExternalMessage(to target: String, body: String, fromNumber: String? = nil) async throws -> SMSBridgeSendResponse {
        try await client.post(
            "api/messages/external/send",
            body: SendRequest(target: target, body: body, fromOneWayNumber: fromNumber)
        )
    }

    private func mapConversation(_ dto: ConversationDTO) -> ChatSummary {
        let conversationID = UUID(uuidString: dto.id) ?? UUID()
        let lastMessageAt = parseDate(dto.lastMessage?.createdAt ?? dto.updatedAt)
        return ChatSummary(
            id: conversationID,
            participantName: dto.title ?? dto.peer.displayName,
            participantHandle: dto.peer.handle,
            lastMessagePreview: dto.lastMessage?.body ?? "Text through OneWay external network",
            lastMessageAt: lastMessageAt,
            unreadCount: dto.unreadCount,
            presence: .online,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            isGroup: false,
            isExternal: dto.type == "external_sms" || dto.type == "external_email"
        )
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
