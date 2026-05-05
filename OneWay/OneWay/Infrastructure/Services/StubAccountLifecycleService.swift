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
        localPersistence.clear()
        await messagingService.wipeAllData()
        await friendService.wipeAllData()
        await storyService.wipeAllData()
        importedContactsStore.clear()
        try await authService.signOut()
    }
}
