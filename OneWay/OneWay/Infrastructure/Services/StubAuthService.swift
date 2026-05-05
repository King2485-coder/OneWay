import Foundation

final class StubAuthService: AuthService {
    private var signedInUser: UserProfile? = UserProfile(userID: UUID(), displayName: "You")
    private var dummyCounter = 1

    func currentUser() async throws -> UserProfile? {
        signedInUser
    }

    func signInAnonymously() async throws -> UserProfile {
        let user = UserProfile(userID: UUID(), displayName: "Dummy User \(dummyCounter)")
        dummyCounter += 1
        signedInUser = user
        return user
    }

    func signOut() async throws {
        signedInUser = nil
    }
}
