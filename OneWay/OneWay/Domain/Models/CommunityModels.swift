import Foundation

enum CommunityVisibility: String, CaseIterable, Codable, Hashable {
    case `public`
    case `private`
    case hidden

    var displayName: String {
        switch self {
        case .public: return "Public"
        case .private: return "Private"
        case .hidden: return "Hidden"
        }
    }
}

struct Community: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var normalizedName: String
    var description: String
    var creatorUserId: String
    var creatorHandle: String
    var visibility: CommunityVisibility
    var coverImageURL: URL?
    var avatarURL: URL?
    var ownerID: UUID
    var admins: [UUID]
    var moderators: [UUID]
    var members: [UUID]
    var blockedUserIds: [String]
    var bannedUserIds: [String]
    var messages: [CommunityMessage]
    var linkedGroupIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID,
        name: String,
        normalizedName: String? = nil,
        description: String,
        creatorUserId: String,
        creatorHandle: String,
        visibility: CommunityVisibility,
        coverImageURL: URL?,
        avatarURL: URL?,
        ownerID: UUID,
        admins: [UUID],
        moderators: [UUID],
        members: [UUID],
        blockedUserIds: [String],
        bannedUserIds: [String],
        messages: [CommunityMessage],
        linkedGroupIDs: [UUID],
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName ?? Community.normalizedName(for: name)
        self.description = description
        self.creatorUserId = creatorUserId
        self.creatorHandle = creatorHandle
        self.visibility = visibility
        self.coverImageURL = coverImageURL
        self.avatarURL = avatarURL
        self.ownerID = ownerID
        self.admins = admins
        self.moderators = moderators
        self.members = members
        self.blockedUserIds = blockedUserIds
        self.bannedUserIds = bannedUserIds
        self.messages = messages
        self.linkedGroupIDs = linkedGroupIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        normalizedName = try container.decodeIfPresent(String.self, forKey: .normalizedName) ?? Community.normalizedName(for: name)
        description = try container.decode(String.self, forKey: .description)
        creatorUserId = try container.decodeIfPresent(String.self, forKey: .creatorUserId) ?? ""
        creatorHandle = try container.decodeIfPresent(String.self, forKey: .creatorHandle) ?? "@king"
        visibility = try container.decodeIfPresent(CommunityVisibility.self, forKey: .visibility) ?? .public
        coverImageURL = try container.decodeIfPresent(URL.self, forKey: .coverImageURL)
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        ownerID = try container.decode(UUID.self, forKey: .ownerID)
        admins = try container.decodeIfPresent([UUID].self, forKey: .admins) ?? []
        moderators = try container.decodeIfPresent([UUID].self, forKey: .moderators) ?? []
        members = try container.decodeIfPresent([UUID].self, forKey: .members) ?? []
        blockedUserIds = try container.decodeIfPresent([String].self, forKey: .blockedUserIds) ?? []
        bannedUserIds = try container.decodeIfPresent([String].self, forKey: .bannedUserIds) ?? []
        messages = try container.decodeIfPresent([CommunityMessage].self, forKey: .messages) ?? []
        linkedGroupIDs = try container.decodeIfPresent([UUID].self, forKey: .linkedGroupIDs) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    static func normalizedName(for value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

struct CommunityMember: Identifiable, Equatable, Codable {
    let id: UUID
    let displayName: String
    let handle: String
    let role: GroupRole
    var isMuted: Bool?
}

struct CommunityMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let clientMessageId: UUID?
    let communityID: UUID
    let senderID: UUID
    let senderName: String
    let senderHandle: String
    let body: String
    let sentAt: Date
    let deliveryStatus: MessageDeliveryStatus

    var voiceAttachment: MessageAttachment? {
        guard body.hasPrefix("{\"onewayVoice\":"),
              let data = body.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(CommunityVoiceEnvelope.self, from: data),
              let payload = Data(base64Encoded: envelope.payloadBase64) else { return nil }
        return MessageAttachment(mediaType: .audio, fileName: "voice-message.m4a", byteCount: payload.count, payload: payload, mimeType: "audio/mp4")
    }

    init(
        id: UUID,
        clientMessageId: UUID? = nil,
        communityID: UUID,
        senderID: UUID,
        senderName: String,
        senderHandle: String,
        body: String,
        sentAt: Date,
        deliveryStatus: MessageDeliveryStatus
    ) {
        self.id = id
        self.clientMessageId = clientMessageId
        self.communityID = communityID
        self.senderID = senderID
        self.senderName = senderName
        self.senderHandle = senderHandle
        self.body = body
        self.sentAt = sentAt
        self.deliveryStatus = deliveryStatus
    }
}

private struct CommunityVoiceEnvelope: Codable {
    let onewayVoice: Bool
    let payloadBase64: String
    let disappearing: String
    let expirationDurationSeconds: Int?
}

struct GroupChat: Identifiable, Equatable, Codable {
    let id: UUID
    let communityID: UUID
    var name: String
    var topic: String?
    var memberIDs: [UUID]
    var lastMessageAt: Date?
    var lastMessagePreview: String?
    var isMuted: Bool
    var isArchived: Bool
    var disappearingAfterSeconds: TimeInterval?
}
