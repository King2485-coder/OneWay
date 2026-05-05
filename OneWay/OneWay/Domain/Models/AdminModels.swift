import Foundation

enum GroupRole: String, CaseIterable, Codable {
    case owner
    case admin
    case moderator
    case member
}

struct GroupMember: Identifiable, Equatable {
    let id: UUID
    let name: String
    let handle: String
    let role: GroupRole
}

enum PrivacyPreset: String, CaseIterable, Identifiable {
    case open = "Open"
    case contactsOnly = "Contacts Only"
    case lockedDown = "Locked Down"

    var id: String { rawValue }
}

struct DeviceSession: Identifiable, Equatable {
    let id: UUID
    let deviceName: String
    let lastSeenAt: Date
    let isCurrent: Bool
}
