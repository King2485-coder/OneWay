import Foundation
import Combine

@MainActor
final class PrivacyOnboardingViewModel: ObservableObject {
    @Published var draft = OnboardingIdentityDraft()
    @Published var step: Int = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var claimedNumbers: [OneWayNumber] = []
    @Published var importedContacts: [ContactEntry] = []
    @Published var isShowingContactPicker = false

    private let importedContactsStore: ImportedContactsStore

    init(importedContactsStore: ImportedContactsStore) {
        self.importedContactsStore = importedContactsStore
        self.importedContacts = importedContactsStore.loadContacts()
    }

    func next() {
        step += 1
    }

    func back() {
        step = max(0, step - 1)
    }

    func createIdentity() async {
        isLoading = true
        defer { isLoading = false }

        do {
            print("📤 Identity payload:", [
                "hasDisplayName": (!draft.displayName.isEmpty).description,
                "hasUsername": (!draft.username.isEmpty).description,
                "usernameHidden": draft.usernameHidden.description,
                "hasOneWayId": (!draft.onewayId.isEmpty).description,
                "hasEmailAlias": (!draft.emailAlias.isEmpty).description,
                "showEmailAlias": draft.showEmailAlias.description,
                "showOneWayId": draft.showOneWayId.description,
                "showNumbers": draft.showNumbers.description,
                "preferredCallerIdentity": draft.preferredCallerIdentity
            ])
            _ = try await OneWayIdentityService.shared.updateIdentity(
                displayName: draft.displayName,
                walkieName: draft.displayName,
                username: draft.username,
                usernameHidden: draft.usernameHidden,
                onewayId: draft.onewayId,
                emailAlias: draft.emailAlias,
                showEmailAlias: draft.showEmailAlias,
                showOneWayId: draft.showOneWayId,
                showNumbers: draft.showNumbers,
                preferredCallerIdentity: draft.preferredCallerIdentity == "number" ? .number : .onewayId
            )
            next()
        } catch {
            print("❌ Identity creation failed:", PrivacyLog.redact(error.localizedDescription))
            errorMessage = error.localizedDescription
        }
    }

    func claimFreeNumbers() async {
        isLoading = true
        defer { isLoading = false }

        do {
            claimedNumbers = try await OneWayNumberService.shared.claimFreeNumbers()
        } catch {
            errorMessage = "Could not claim free numbers."
        }
    }

    func importSelectedContacts(_ contacts: [ContactEntry]) {
        guard !contacts.isEmpty else { return }

        var merged: [String: ContactEntry] = Dictionary(uniqueKeysWithValues: importedContacts.map { ($0.id, $0) })
        for contact in contacts {
            merged[contact.id] = contact
        }
        importedContacts = merged.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        importedContactsStore.saveContacts(importedContacts)
    }

    func skipContacts() {
        next()
    }
}
