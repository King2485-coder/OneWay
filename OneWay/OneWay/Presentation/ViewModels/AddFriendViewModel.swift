import Foundation
import Combine

@MainActor
final class AddFriendViewModel: ObservableObject {
    @Published var handleInput = ""
    @Published var inviteInput = ""
    @Published private(set) var searchResults: [OneWayUserSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var generatedInviteLink: URL?
    @Published private(set) var recentResult: String?
    @Published var errorMessage: String?

    private let friendService: FriendService

    init(friendService: FriendService) {
        self.friendService = friendService
    }

    func requestByHandle() async {
        do {
            let friend = try await friendService.sendFriendRequest(handle: handleInput)
            recentResult = friend.status == .connected
                ? "Connected with \(friend.displayName)"
                : "Request sent to \(friend.handle)"
            handleInput = ""
            errorMessage = nil
        } catch FriendServiceError.invalidHandle {
            errorMessage = "Enter a valid handle or Chirp ID."
        } catch {
            errorMessage = "Could not send request."
        }
    }

    func search() async {
        let query = handleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            searchResults = try await friendService.searchUsers(query: query)
            errorMessage = nil
        } catch {
            errorMessage = "Could not search OneWay users."
        }
    }

    func request(_ result: OneWayUserSearchResult) async {
        do {
            if result.friendshipState == "pendingIncoming" {
                let pending = try await friendService.fetchFriends()
                    .first {
                        $0.userID.caseInsensitiveCompare(result.id) == .orderedSame &&
                        $0.status == .pending &&
                        $0.isIncomingRequest
                    }
                guard let pending else {
                    throw FriendServiceError.notFound
                }

                let friend = try await friendService.acceptFriendRequest(id: pending.id)
                recentResult = "Connected with \(friend.displayName)"
                errorMessage = nil
                await search()
                return
            }

            let friend = try await friendService.sendFriendRequest(to: result.id)
            recentResult = friend.status == .connected
                ? "Connected with \(friend.displayName)"
                : "Request sent to \(friend.handle)"
            errorMessage = nil
            await search()
        } catch {
            errorMessage = "Could not send request."
        }
    }

    func generateInvite() async {
        do {
            generatedInviteLink = try await friendService.createInviteLink()
            recentResult = "Invite link generated"
            errorMessage = nil
        } catch {
            errorMessage = "Could not generate invite link."
        }
    }

    func redeemInvite() async {
        guard let url = URL(string: inviteInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Paste a valid invite URL."
            return
        }

        do {
            let friend = try await friendService.redeemInviteLink(url)
            recentResult = "Connected with \(friend.displayName)"
            inviteInput = ""
            errorMessage = nil
        } catch FriendServiceError.invalidInvite {
            errorMessage = "Invite link is invalid or expired."
        } catch {
            errorMessage = "Could not redeem invite."
        }
    }
}
