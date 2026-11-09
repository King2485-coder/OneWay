import Foundation
import Combine

protocol FriendService {
    func fetchFriends() async throws -> [FriendConnection]
    func searchUsers(query: String) async throws -> [OneWayUserSearchResult]
    func sendFriendRequest(handle: String) async throws -> FriendConnection
    func sendFriendRequest(to userID: String) async throws -> FriendConnection
    func acceptFriendRequest(id: UUID) async throws -> FriendConnection
    func declineFriendRequest(id: UUID) async throws
    func ignoreFriendRequest(id: UUID) async throws
    func blockFriendRequest(id: UUID) async throws
    func cancelFriendRequest(id: UUID) async throws
    func updateFriend(_ friend: FriendConnection, displayName: String) async throws -> FriendConnection
    func deleteFriend(_ friend: FriendConnection) async throws
    func createInviteLink() async throws -> URL
    func redeemInviteLink(_ url: URL) async throws -> FriendConnection
    func observeFriendEvents() -> AsyncStream<FriendRealtimeEvent>
}
