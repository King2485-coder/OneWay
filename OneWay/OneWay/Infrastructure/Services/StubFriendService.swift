import Foundation

final class StubFriendService: FriendService {
    func fetchFriends() async throws -> [FriendConnection] {
        []
    }

    func sendFriendRequest(handle: String) async throws -> FriendConnection {
        FriendConnection(
            id: UUID(),
            displayName: handle,
            handle: handle,
            status: .pending
        )
    }

    func acceptFriendRequest(id: UUID) async throws -> FriendConnection {
        FriendConnection(
            id: id,
            displayName: "Friend",
            handle: "friend",
            status: .connected
        )
    }

    func createInviteLink() async throws -> URL {
        URL(string: "https://oneway.app/invite/stub")!
    }

    func redeemInviteLink(_ url: URL) async throws -> FriendConnection {
        FriendConnection(
            id: UUID(),
            displayName: "Invited Friend",
            handle: url.lastPathComponent.isEmpty ? "invite" : url.lastPathComponent,
            status: .connected
        )
    }

    func wipeAllData() async {}
}
