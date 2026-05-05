import Foundation

enum FriendshipStatus: String {
    case pending
    case connected
}

struct FriendConnection: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let handle: String
    let status: FriendshipStatus
}
