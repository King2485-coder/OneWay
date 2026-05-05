import Foundation
import Combine

@MainActor
final class FriendsListViewModel: ObservableObject {
    @Published private(set) var friends: [FriendConnection] = []
    @Published private(set) var isLoading = false
    @Published var searchQuery = ""
    @Published var errorMessage: String?

    private let friendService: FriendService

    init(friendService: FriendService) {
        self.friendService = friendService
    }

    var connectedFriends: [FriendConnection] {
        filteredFriends.filter { $0.status == .connected }
    }

    var pendingFriends: [FriendConnection] {
        filteredFriends.filter { $0.status == .pending }
    }

    func loadFriends() async {
        isLoading = true
        defer { isLoading = false }

        do {
            friends = try await friendService.fetchFriends()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            errorMessage = nil
        } catch {
            errorMessage = "Unable to load friends list."
        }
    }

    func acceptPendingFriend(_ friend: FriendConnection) async {
        do {
            let accepted = try await friendService.acceptFriendRequest(id: friend.id)
            if let index = friends.firstIndex(where: { $0.id == accepted.id }) {
                friends[index] = accepted
            } else {
                friends.append(accepted)
            }
            friends.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            errorMessage = nil
        } catch {
            errorMessage = "Could not accept friend request."
        }
    }

    private var filteredFriends: [FriendConnection] {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return friends }
        let query = searchQuery.lowercased()
        return friends.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.handle.lowercased().contains(query)
        }
    }
}
