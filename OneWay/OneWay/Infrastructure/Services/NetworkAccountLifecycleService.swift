import Foundation

@MainActor
final class NetworkAccountLifecycleService: AccountLifecycleService {
    private let client: APIClient
    private let localPersistence: LocalPersistence
    private let importedContactsStore: ImportedContactsStore
    private let messagingCache: StubMessagingService
    private let friendCache: StubFriendService
    private let storyCache: StubStoryService

    init(
        client: APIClient = .shared,
        localPersistence: LocalPersistence,
        importedContactsStore: ImportedContactsStore,
        messagingCache: StubMessagingService,
        friendCache: StubFriendService,
        storyCache: StubStoryService
    ) {
        self.client = client
        self.localPersistence = localPersistence
        self.importedContactsStore = importedContactsStore
        self.messagingCache = messagingCache
        self.friendCache = friendCache
        self.storyCache = storyCache
    }

    func deleteAccountBestEffort() async throws {
        let deletedUserID = AuthTokenStore.shared.storedUserID()

        // The server deletion must succeed before local credentials are
        // destroyed; otherwise the user couldn't retry a failed deletion.
        let _: EmptyAPIResponse = try await client.delete("api/account")

        localPersistence.clear()
        await messagingCache.wipeAllData()
        await friendCache.wipeAllData()
        await storyCache.wipeAllData()
        importedContactsStore.clear()
        clearLocalAccountArtifacts(userID: deletedUserID)
        AuthTokenStore.shared.clearSession()
    }

    private func clearLocalAccountArtifacts(userID: String?) {
        NetworkFriendService.disconnectRealtime()
        NetworkMessagingService.disconnectRealtime()
        CommunityRealtimeClient.shared.disconnect()
        URLCache.shared.removeAllCachedResponses()

        let fileManager = FileManager.default
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            ["OneWayProductPhotos", "OneWayShopArtwork"].forEach { directory in
                try? fileManager.removeItem(at: documents.appendingPathComponent(directory, isDirectory: true))
            }
        }

        let defaults = UserDefaults.standard
        if let userID, !userID.isEmpty {
            defaults.dictionaryRepresentation().keys
                .filter { $0.localizedCaseInsensitiveContains(userID) }
                .forEach(defaults.removeObject(forKey:))
        }
        [
            "OneWay.BrowserRecentSites",
            "OneWay.BrowserHistory",
            "OneWay.BrowserTabs",
            "OneWay.BrowserBookmarks",
            "account_deletion_timestamp",
        ].forEach(defaults.removeObject(forKey:))
        defaults.set(true, forKey: "OneWay.SessionExplicitlySignedOut")
    }
}
