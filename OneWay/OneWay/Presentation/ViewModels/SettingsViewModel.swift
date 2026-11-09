import Foundation
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var profileText = "Not signed in"
    @Published private(set) var profileSubtitle = "Hello. I'm using OneWay."
    @Published private(set) var fingerprint = "Unavailable"
    @Published var infoMessage: String?
    @Published var errorMessage: String?

    private let authService: AuthService
    private let keyService: KeyService
    private let localPersistence: LocalPersistence
    private let identityService: OneWayIdentityService

    init(authService: AuthService, keyService: KeyService, localPersistence: LocalPersistence, identityService: OneWayIdentityService = .shared) {
        self.authService = authService
        self.keyService = keyService
        self.localPersistence = localPersistence
        self.identityService = identityService
    }

    var cachePolicyText: String {
        localPersistence.cachePolicy.rawValue
    }

    func load() async {
        do {
            if let user = try await authService.currentUser() {
                profileText = user.displayName
                if let identity = try? await identityService.fetchMyIdentity() {
                    profileText = identity.displayName
                    if identity.showOneWayId {
                        profileSubtitle = identity.onewayId
                    } else if identity.showEmailAlias {
                        profileSubtitle = identity.emailAlias
                    } else {
                        profileSubtitle = "Hello. I'm using OneWay."
                    }
                }
            } else {
                profileText = "Not signed in"
                profileSubtitle = "Hello. I'm using OneWay."
            }

            try await keyService.ensureIdentityKeys()
            fingerprint = try await keyService.localIdentityFingerprint()
        } catch {
            profileText = "Unavailable"
            profileSubtitle = "Hello. I'm using OneWay."
            fingerprint = "Unavailable"
        }
    }

    func clearLocalData() {
        localPersistence.clear()
        infoMessage = "Cache cleared."
    }

    func createDummyAccount() async {
        do {
            let user = try await authService.signInAnonymously()
            profileText = user.displayName
            profileSubtitle = "Hello. I'm using OneWay."
            infoMessage = "Signed in as \(user.displayName)."
            errorMessage = nil
        } catch {
            errorMessage = "Could not create dummy account."
        }
    }
}
