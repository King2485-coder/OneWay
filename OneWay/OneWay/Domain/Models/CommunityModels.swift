import Foundation

struct Community: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var description: String
    var coverImageURL: URL?
    var avatarURL: URL?
    var ownerID: UUID
    var admins: [UUID]
    var moderators: [UUID]
    var members: [UUID]
    var linkedGroupIDs: [UUID]
}

struct CommunityMember: Identifiable, Equatable, Codable {
    let id: UUID
    let displayName: String
    let handle: String
    let role: GroupRole
    var isMuted: Bool?
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
