import Foundation
import Combine

@MainActor
final class AddFriendViewModel: ObservableObject {
    @Published var handleInput = ""
    @Published var inviteInput = ""
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
            recentResult = "Request sent to \(friend.handle)"
            handleInput = ""
            errorMessage = nil
        } catch FriendServiceError.invalidHandle {
            errorMessage = "Enter a valid handle like @alex."
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
