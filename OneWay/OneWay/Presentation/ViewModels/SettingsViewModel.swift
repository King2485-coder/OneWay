import Foundation
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var profileText = "Not signed in"
    @Published private(set) var fingerprint = "Unavailable"
    @Published var infoMessage: String?
    @Published var errorMessage: String?

    private let authService: AuthService
    private let keyService: KeyService
    private let localPersistence: LocalPersistence

    init(authService: AuthService, keyService: KeyService, localPersistence: LocalPersistence) {
        self.authService = authService
        self.keyService = keyService
        self.localPersistence = localPersistence
    }

    var cachePolicyText: String {
        localPersistence.cachePolicy.rawValue
    }

    func load() async {
        do {
            if let user = try await authService.currentUser() {
                profileText = user.displayName
            } else {
                profileText = "Not signed in"
            }

            try await keyService.ensureIdentityKeys()
            fingerprint = try await keyService.localIdentityFingerprint()
        } catch {
            profileText = "Unavailable"
            fingerprint = "Unavailable"
        }
    }

    func clearLocalData() {
        localPersistence.clear()
        infoMessage = "Local data cleared."
    }

    func createDummyAccount() async {
        do {
            let user = try await authService.signInAnonymously()
            profileText = user.displayName
            infoMessage = "Signed in as \(user.displayName)."
            errorMessage = nil
        } catch {
            errorMessage = "Could not create dummy account."
        }
    }
}
