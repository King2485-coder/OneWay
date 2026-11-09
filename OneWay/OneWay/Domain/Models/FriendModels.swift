import Foundation

enum FriendshipStatus: String, Codable, Hashable {
    case pending
    case connected
    case blocked
    case removed
}

struct FriendConnection: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let userID: String
    let friendshipID: String?
    let contactID: String?
    let displayName: String
    let handle: String
    let chirpID: String?
    let status: FriendshipStatus
    let isIncomingRequest: Bool
    let createdAt: String?
    let nickname: String?

    init(
        id: UUID,
        userID: String? = nil,
        friendshipID: String? = nil,
        contactID: String? = nil,
        displayName: String,
        handle: String,
        chirpID: String? = nil,
        status: FriendshipStatus,
        isIncomingRequest: Bool = false,
        createdAt: String? = nil,
        nickname: String? = nil
    ) {
        self.id = id
        self.userID = userID ?? id.uuidString
        self.friendshipID = friendshipID
        self.contactID = contactID
        self.displayName = displayName
        self.handle = handle
        self.chirpID = chirpID
        self.status = status
        self.isIncomingRequest = isIncomingRequest
        self.createdAt = createdAt
        self.nickname = nickname
    }
}

enum FriendRealtimeEvent: Codable, Hashable {
    case requestReceived
    case requestAccepted
    case requestDenied
    case requestIgnored
    case requestBlocked
    case removed
    case online
    case offline

    init?(wireValue: String) {
        switch wireValue {
        case "chirp.request.received", "friend.request.received":
            self = .requestReceived
        case "chirp.request.accepted", "friend.request.accepted":
            self = .requestAccepted
        case "chirp.request.denied", "friend.request.declined":
            self = .requestDenied
        case "chirp.request.ignored":
            self = .requestIgnored
        case "chirp.request.blocked", "friend.blocked":
            self = .requestBlocked
        case "chirp.friend.removed", "friend.removed":
            self = .removed
        case "chirp.friend.online":
            self = .online
        case "chirp.friend.offline":
            self = .offline
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .requestReceived:
            return "chirp.request.received"
        case .requestAccepted:
            return "chirp.request.accepted"
        case .requestDenied:
            return "chirp.request.denied"
        case .requestIgnored:
            return "chirp.request.ignored"
        case .requestBlocked:
            return "chirp.request.blocked"
        case .removed:
            return "chirp.friend.removed"
        case .online:
            return "chirp.friend.online"
        case .offline:
            return "chirp.friend.offline"
        }
    }
}
