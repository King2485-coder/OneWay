import Foundation
import Combine

protocol FriendService {
    func fetchFriends() async throws -> [FriendConnection]
    func sendFriendRequest(handle: String) async throws -> FriendConnection
    func acceptFriendRequest(id: UUID) async throws -> FriendConnection
    func createInviteLink() async throws -> URL
    func redeemInviteLink(_ url: URL) async throws -> FriendConnection
}
