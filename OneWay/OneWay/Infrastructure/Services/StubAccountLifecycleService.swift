import Foundation

@MainActor
final class StubAccountLifecycleService: AccountLifecycleService {
    private let authService: AuthService
    private let localPersistence: LocalPersistence
    private let messagingService: StubMessagingService
    private let friendService: StubFriendService
    private let storyService: StubStoryService
    private let importedContactsStore: ImportedContactsStore

    init(
        authService: AuthService,
        localPersistence: LocalPersistence,
        messagingService: StubMessagingService,
        friendService: StubFriendService,
        storyService: StubStoryService,
        importedContactsStore: ImportedContactsStore
    ) {
        self.authService = authService
        self.localPersistence = localPersistence
        self.messagingService = messagingService
        self.friendService = friendService
        self.storyService = storyService
        self.importedContactsStore = importedContactsStore
    }

    func deleteAccountBestEffort() async throws {
        // Test service mirrors production ordering: a server/auth operation
        // must succeed before any local account data is destroyed.
        try await authService.signOut()
        await MainActor.run {
            localPersistence.clear()
        }
        await messagingService.wipeAllData()
        await friendService.wipeAllData()
        await storyService.wipeAllData()
        await MainActor.run {
            importedContactsStore.clear()
        }
    }
}
