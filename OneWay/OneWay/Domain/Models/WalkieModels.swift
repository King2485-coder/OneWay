import Foundation

struct WalkieSessionResponse: Codable, Equatable {
    let sessionId: String
    let channelId: String?
    let roomName: String
    let liveKitUrl: String?
    let token: String?
    let target: String?
    let groupName: String?
    let participants: [WalkieParticipant]?
    let isGroup: Bool?
    let status: String?
    let liveKitConfigured: Bool?
    let message: String?
}

struct WalkieParticipant: Codable, Identifiable, Equatable {
    let userId: String
    let displayName: String
    let onewayId: String?
    let chirpId: String?

    var id: String { userId }
}

struct WalkieChannel: Codable, Identifiable, Equatable {
    let id: String
    let sessionId: String?
    let channelId: String
    let roomName: String
    let target: String?
    let groupName: String?
    let participants: [WalkieParticipant]?
    let participantCount: Int?
    let isGroup: Bool?
    let isIncoming: Bool?
    let fromWalkieName: String?
    let fromDisplayName: String?
    let fromOneWayId: String?
    let fromNumber: String?
    let startedAt: String
    let status: String
}

struct WalkieChannelsResponse: Codable, Equatable {
    let channels: [WalkieChannel]
    let liveKitConfigured: Bool
}

struct WalkiePrivacySettings: Codable, Equatable {
    let allowFriends: Bool
    let allowFriendsOfFriends: Bool
    let allowAnyone: Bool
    let allowDirectChirp: Bool
    let directChirpAudience: String
    let askBeforeConnecting: Bool
    let allowRepeatChirps: Bool
    let silenceUnknownChirps: Bool
    let requireVerifiedAccount: Bool
    let hideProfilePhotoFromUnknownUsers: Bool
    let blockUnknownDuringDnd: Bool
    let autoBlockRepeatedAbuse: Bool

    init(
        allowFriends: Bool = true,
        allowFriendsOfFriends: Bool = false,
        allowAnyone: Bool = true,
        allowDirectChirp: Bool = true,
        directChirpAudience: String = "everyone",
        askBeforeConnecting: Bool = true,
        allowRepeatChirps: Bool = false,
        silenceUnknownChirps: Bool = true,
        requireVerifiedAccount: Bool = false,
        hideProfilePhotoFromUnknownUsers: Bool = false,
        blockUnknownDuringDnd: Bool = true,
        autoBlockRepeatedAbuse: Bool = true
    ) {
        self.allowFriends = allowFriends
        self.allowFriendsOfFriends = allowFriendsOfFriends
        self.allowAnyone = allowAnyone
        self.allowDirectChirp = allowDirectChirp
        self.directChirpAudience = directChirpAudience
        self.askBeforeConnecting = askBeforeConnecting
        self.allowRepeatChirps = allowRepeatChirps
        self.silenceUnknownChirps = silenceUnknownChirps
        self.requireVerifiedAccount = requireVerifiedAccount
        self.hideProfilePhotoFromUnknownUsers = hideProfilePhotoFromUnknownUsers
        self.blockUnknownDuringDnd = blockUnknownDuringDnd
        self.autoBlockRepeatedAbuse = autoBlockRepeatedAbuse
    }
}

struct WalkieContact: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let userId: String
    let contactId: String
    let displayName: String
    let handle: String
    let chirpId: String?
    let status: String
    let availability: String
    let isOnline: Bool
    let isFavorite: Bool
}

struct WalkieContactsResponse: Codable, Equatable {
    let contacts: [WalkieContact]
}

struct WalkieTransmitResponse: Codable, Equatable {
    let status: String
    let sessionId: String
    let transmitterUserId: String?
    let message: String?
}

struct DirectChirpLookupResponse: Codable, Equatable {
    let found: Bool
    let user: DirectChirpUser?
}

struct DirectChirpUser: Codable, Equatable, Identifiable {
    let userId: String
    let displayName: String
    let handle: String?
    let chirpId: String?
    let avatarURL: String?
    let verified: Bool
    let directChirpAvailability: String

    var id: String { userId }
}

struct DirectChirpRequestResponse: Codable, Equatable {
    let request: DirectChirpRequest
    let session: WalkieSessionResponse?
}

struct DirectChirpRequestsResponse: Codable, Equatable {
    let requests: [DirectChirpRequest]
}

struct DirectChirpRequest: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let requestId: String
    let senderUserId: String
    let recipientUserId: String
    let senderChirpId: String
    let recipientChirpId: String
    let status: String
    let direction: String
    let displayName: String
    let handle: String?
    let chirpId: String?
    let channelId: String?
    let createdAt: String?
    let expiresAt: String?
    let acceptedAt: String?
    let declinedAt: String?
    let ignoredAt: String?
    let blockedAt: String?
    let cancelledAt: String?
}

enum PushToTalkState: Equatable {
    case idle
    case requestingPermission
    case requestingChannel
    case connectingMedia
    case publishing
    case ready
    case readyToTransmit
    case transmitting
    case stopping
    case receiving
    case releasing
    case reconnecting
    case unavailable
    case failed(String)
}

enum WalkieState: Equatable {
    case unavailable
    case ready
    case connecting
    case listening
    case talking
    case ended
    case error(String)
}
