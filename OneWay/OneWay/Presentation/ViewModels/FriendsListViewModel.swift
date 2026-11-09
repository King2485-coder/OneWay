import Foundation
import Combine

@MainActor
final class FriendsListViewModel: ObservableObject {
    @Published private(set) var friends: [FriendConnection] = []
    @Published private(set) var isLoading = false
    @Published var searchQuery = ""
    @Published var errorMessage: String?

    private let friendService: FriendService
    private let cache = FriendConnectionCache()
    private var autoRefreshTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?

    init(friendService: FriendService) {
        self.friendService = friendService
    }

    var connectedFriends: [FriendConnection] {
        filteredFriends.filter { $0.status == .connected }
    }

    var pendingFriends: [FriendConnection] {
        filteredFriends.filter { $0.status == .pending }
    }

    func startAutoRefresh(intervalSeconds: Double = 5.0) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                if Task.isCancelled { break }
                await self.loadFriends(showLoading: false)
            }
        }

        realtimeTask?.cancel()
        realtimeTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.friendService.observeFriendEvents() {
                await self.handleRealtimeEvent(event)
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        realtimeTask?.cancel()
        realtimeTask = nil
    }

    func loadFriends(showLoading: Bool = true) async {
        let currentUserID = AuthTokenStore.shared.currentUserID()
        if friends.isEmpty {
            friends = cache.load(userID: currentUserID)
        }

        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading {
                isLoading = false
            }
        }

        do {
            friends = try await friendService.fetchFriends()
                .sorted(by: friendSort)
            cache.save(friends, userID: currentUserID)
            #if DEBUG
            print("👥 Friends store refresh count:", friends.count, "pending:", pendingFriends.count)
            #endif
            errorMessage = nil
        } catch {
            if showLoading || friends.isEmpty {
                errorMessage = "Unable to load friends list."
            }
        }
    }

    func declinePendingFriend(_ friend: FriendConnection) async {
        do {
            try await friendService.declineFriendRequest(id: friend.id)
            friends.removeAll { $0.id == friend.id && $0.status == .pending }
            cache.save(friends, userID: AuthTokenStore.shared.currentUserID())
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t refresh friend requests."
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
            friends.sort(by: friendSort)
            cache.save(friends, userID: AuthTokenStore.shared.currentUserID())
            errorMessage = nil
        } catch {
            errorMessage = "Could not accept friend request."
        }
    }

    func renameFriend(_ friend: FriendConnection, displayName: String) async {
        do {
            let updated = try await friendService.updateFriend(friend, displayName: displayName)
            if let index = friends.firstIndex(where: { $0.id == updated.id }) {
                friends[index] = updated
            }
            friends.sort(by: friendSort)
            cache.save(friends, userID: AuthTokenStore.shared.currentUserID())
            errorMessage = nil
        } catch {
            errorMessage = "Could not update this contact."
        }
    }

    func deleteFriend(_ friend: FriendConnection) async {
        do {
            try await friendService.deleteFriend(friend)
            friends.removeAll { $0.id == friend.id }
            cache.save(friends, userID: AuthTokenStore.shared.currentUserID())
            errorMessage = nil
        } catch {
            errorMessage = "Could not remove this contact."
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

    private func friendSort(_ left: FriendConnection, _ right: FriendConnection) -> Bool {
        if left.status != right.status {
            if left.status == .pending { return true }
            if right.status == .pending { return false }
        }
        return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
    }

    private func handleRealtimeEvent(_ event: FriendRealtimeEvent) async {
        #if DEBUG
        print("👥 Friend realtime event:", event.rawValue)
        #endif
        await loadFriends(showLoading: false)
    }
}

private struct FriendConnectionCache {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "OneWay.FriendConnections."

    func load(userID: String) -> [FriendConnection] {
        guard let data = defaults.data(forKey: keyPrefix + userID) else { return [] }
        let cached = (try? JSONDecoder().decode([FriendConnection].self, from: data)) ?? []
        #if DEBUG
        print("👥 Friends cache load user:", userID, "count:", cached.count, "pending:", cached.filter { $0.status == .pending }.count)
        #endif
        return cached
    }

    func save(_ friends: [FriendConnection], userID: String) {
        guard let data = try? JSONEncoder().encode(friends) else { return }
        defaults.set(data, forKey: keyPrefix + userID)
        #if DEBUG
        print("👥 Friends cache save user:", userID, "count:", friends.count, "pending:", friends.filter { $0.status == .pending }.count)
        #endif
    }
}
