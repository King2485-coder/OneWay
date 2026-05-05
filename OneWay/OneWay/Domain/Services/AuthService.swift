import Foundation

protocol AuthService {
    func currentUser() async throws -> UserProfile?
    func signInAnonymously() async throws -> UserProfile
    func signOut() async throws
}
