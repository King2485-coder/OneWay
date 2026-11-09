import Foundation

final class StubFriendService: FriendService {
    func fetchFriends() async throws -> [FriendConnection] {
        [
            FriendConnection(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000654321") ?? UUID(),
                userID: "00000000-0000-0000-0000-000000654321",
                displayName: "King",
                handle: "@king",
                chirpID: "OW-654-321",
                status: .connected
            )
        ]
    }

    func searchUsers(query: String) async throws -> [OneWayUserSearchResult] {
        [
            OneWayUserSearchResult(
                id: "00000000-0000-0000-0000-000000654321",
                displayName: "Marcus Reed",
                onewayId: "@marcus",
                chirpId: "OW-397704",
                emailAlias: nil,
                username: nil,
                primaryNumber: nil,
                isOneWayReachable: true,
                friendshipState: nil
            )
        ]
    }

    func sendFriendRequest(handle: String) async throws -> FriendConnection {
        FriendConnection(
            id: UUID(),
            userID: UUID().uuidString,
            friendshipID: UUID().uuidString,
            displayName: handle,
            handle: handle,
            chirpID: handle.uppercased().hasPrefix("OW") ? handle : nil,
            status: .pending
        )
    }

    func sendFriendRequest(to userID: String) async throws -> FriendConnection {
        FriendConnection(
            id: UUID(uuidString: userID) ?? UUID(),
            userID: userID,
            friendshipID: UUID().uuidString,
            displayName: "OneWay User",
            handle: "@onewayuser",
            chirpID: "OW-111-222",
            status: .pending
        )
    }

    func acceptFriendRequest(id: UUID) async throws -> FriendConnection {
        FriendConnection(
            id: id,
            userID: id.uuidString,
            displayName: "Friend",
            handle: "friend",
            status: .connected
        )
    }

    func declineFriendRequest(id: UUID) async throws {}

    func ignoreFriendRequest(id: UUID) async throws {}

    func blockFriendRequest(id: UUID) async throws {}

    func cancelFriendRequest(id: UUID) async throws {}

    func updateFriend(_ friend: FriendConnection, displayName: String) async throws -> FriendConnection {
        FriendConnection(
            id: friend.id,
            userID: friend.userID,
            friendshipID: friend.friendshipID,
            contactID: friend.contactID,
            displayName: displayName,
            handle: friend.handle,
            chirpID: friend.chirpID,
            status: friend.status,
            isIncomingRequest: friend.isIncomingRequest,
            nickname: displayName
        )
    }

    func deleteFriend(_ friend: FriendConnection) async throws {}

    func createInviteLink() async throws -> URL {
        guard let url = URL(string: "https://oneway.app/invite/stub") else {
            throw FriendServiceError.invalidInvite
        }
        return url
    }

    func redeemInviteLink(_ url: URL) async throws -> FriendConnection {
        FriendConnection(
            id: UUID(),
            userID: UUID().uuidString,
            displayName: "Invited Friend",
            handle: url.lastPathComponent.isEmpty ? "invite" : url.lastPathComponent,
            chirpID: "OW-100-200",
            status: .connected
        )
    }

    func wipeAllData() async {}

    func observeFriendEvents() -> AsyncStream<FriendRealtimeEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
