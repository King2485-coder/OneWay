import Foundation
import Combine

@MainActor
final class PrivacyIdentityViewModel: ObservableObject {
    @Published var displayName = ""
    @Published var walkieName = ""
    @Published var username = ""
    @Published var onewayId = ""
    @Published var emailAlias = ""
    @Published var usernameHidden = true
    @Published var showEmailAlias = false
    @Published var showOneWayId = true
    @Published var showNumbers = false
    @Published var preferredCallerIdentity: OneWayIdentity.PreferredCallerIdentity = .onewayId
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var saveMessage: String?

    private let service: OneWayIdentityService
    private(set) var identity: OneWayIdentity?

    init(service: OneWayIdentityService = .shared) {
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let identity = try await service.fetchMyIdentity()
            apply(identity)
        } catch {
            errorMessage = "Could not load Privacy & Identity."
        }
    }

    func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let identity = try await service.updateIdentity(
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                walkieName: walkieName.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                usernameHidden: usernameHidden,
                onewayId: onewayId.trimmingCharacters(in: .whitespacesAndNewlines),
                emailAlias: emailAlias.trimmingCharacters(in: .whitespacesAndNewlines),
                showEmailAlias: showEmailAlias,
                showOneWayId: showOneWayId,
                showNumbers: showNumbers,
                preferredCallerIdentity: preferredCallerIdentity
            )
            apply(identity)
            saveMessage = "Privacy & Identity updated."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ identity: OneWayIdentity) {
        self.identity = identity
        displayName = identity.displayName
        walkieName = identity.walkieName
        username = identity.username ?? ""
        onewayId = identity.onewayId
        emailAlias = identity.emailAlias
        usernameHidden = identity.usernameHidden
        showEmailAlias = identity.showEmailAlias
        showOneWayId = identity.showOneWayId
        showNumbers = identity.showNumbers
        preferredCallerIdentity = identity.preferredCallerIdentity
    }
}
