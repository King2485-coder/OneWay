import Foundation
import Combine

@MainActor
final class AppEnvironment: ObservableObject {
    let authService: AuthService
    let keyService: KeyService
    let cryptoService: CryptoService
    let notificationService: NotificationService
    let storageService: StorageService
    let messagingService: MessagingService
    let friendService: FriendService
    let storyService: StoryService
    let groupService: GroupService
    let communityService: CommunityService
    let contactImportService: ContactImportService
    let importedContactsStore: ImportedContactsStore
    let deviceSessionService: DeviceSessionService
    let backupService: BackupService
    let safetyService: SafetyService
    let accountLifecycleService: AccountLifecycleService
    let accountDeletionScheduler: AccountDeletionScheduler
    let localPersistence: LocalPersistence
    let callService: CallService
    let businessService: BusinessService
    let aiStorefrontService: AIStorefrontService
    let businessSearchService: BusinessSearchService
    let systemHealthManager: SystemHealthManager
    let domainService: DomainService
    let siteService: SiteService

    var baseURL: String { APIConfig.baseURL }
    var currentUserID: String { Self.currentUserID() }

    static let shared: AppEnvironment = makeLive()
    static var live: AppEnvironment { shared }

    init(
        authService: AuthService,
        keyService: KeyService,
        cryptoService: CryptoService,
        notificationService: NotificationService,
        storageService: StorageService,
        messagingService: MessagingService,
        friendService: FriendService,
        storyService: StoryService,
        groupService: GroupService,
        communityService: CommunityService,
        contactImportService: ContactImportService,
        importedContactsStore: ImportedContactsStore,
        deviceSessionService: DeviceSessionService,
        backupService: BackupService,
        safetyService: SafetyService,
        accountLifecycleService: AccountLifecycleService,
        accountDeletionScheduler: AccountDeletionScheduler,
        localPersistence: LocalPersistence,
        callService: CallService,
        businessService: BusinessService,
        aiStorefrontService: AIStorefrontService,
        businessSearchService: BusinessSearchService,
        systemHealthManager: SystemHealthManager,
        domainService: DomainService,
        siteService: SiteService
    ) {
        self.authService = authService
        self.keyService = keyService
        self.cryptoService = cryptoService
        self.notificationService = notificationService
        self.storageService = storageService
        self.messagingService = messagingService
        self.friendService = friendService
        self.storyService = storyService
        self.groupService = groupService
        self.communityService = communityService
        self.contactImportService = contactImportService
        self.importedContactsStore = importedContactsStore
        self.deviceSessionService = deviceSessionService
        self.backupService = backupService
        self.safetyService = safetyService
        self.accountLifecycleService = accountLifecycleService
        self.accountDeletionScheduler = accountDeletionScheduler
        self.localPersistence = localPersistence
        self.callService = callService
        self.businessService = businessService
        self.aiStorefrontService = aiStorefrontService
        self.businessSearchService = businessSearchService
        self.systemHealthManager = systemHealthManager
        self.domainService = domainService
        self.siteService = siteService
    }

    static func currentUserID() -> String {
        AuthTokenStore.shared.currentUserID()
    }

    private static func makeLive() -> AppEnvironment {
        let localPersistence = LocalPersistence(cachePolicy: .metadataOnly)
        let authService = StubAuthService()
        let keyService = StubKeyService()
        let cryptoService = UnavailableCryptoService()
        let notificationService = StubNotificationService()
        let storageService = StubStorageService()
        let stubMessagingService = StubMessagingService(
            localPersistence: localPersistence,
            cryptoService: cryptoService,
            storageService: storageService
        )
        #if DEBUG
        let usesUITestServices = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        let usesUITestServices = false
        #endif
        let messagingService: MessagingService = usesUITestServices
            ? stubMessagingService
            : NetworkMessagingService(client: .shared)
        let stubFriendService = StubFriendService()
        let stubStoryService = StubStoryService()
        let stubGroupService = StubGroupService()
        let communityService: CommunityService = NetworkCommunityService(client: .shared)
        let contactImportService = DeviceContactImportService()
        let importedContactsStore = UserDefaultsImportedContactsStore()
        let stubDeviceSessionService = StubDeviceSessionService()
        let backupService = UnavailableBackupService()
        let safetyService: SafetyService = NetworkSafetyService(client: .shared)
        let accountLifecycleService = NetworkAccountLifecycleService(
            client: .shared,
            localPersistence: localPersistence,
            importedContactsStore: importedContactsStore,
            messagingCache: stubMessagingService,
            friendCache: stubFriendService,
            storyCache: stubStoryService
        )
        let accountDeletionScheduler = AccountDeletionScheduler(
            accountLifecycleService: accountLifecycleService
        )
        let apiBaseURL = URL(string: APIConfig.baseURL)!
        CallNetworkConfiguration.logStartupState()
        let callBaseURL = CallNetworkConfiguration.restBaseURL
        let signalingWebSocketURL = CallNetworkConfiguration.signalingWebSocketURL
        let signalingClient: any CallSignalingClient = NetworkCallSignalingClient(
            baseURL: callBaseURL,
            webSocketURL: signalingWebSocketURL,
            userID: currentUserID()
        )
        let callService: CallService = LiveKitCallService(
            transport: LiveKitTransport(),
            signaling: signalingClient,
            bridge: .shared
        )

        let businessService = NetworkBusinessService(baseURL: apiBaseURL)
        let friendService: any FriendService = usesUITestServices
            ? stubFriendService
            : NetworkFriendService(client: .shared)
        let aiStorefrontService: AIStorefrontService = NetworkAIStorefrontService(
            baseURL: apiBaseURL,
            mapper: businessService.mapStorefront
        )
        let businessSearchService: BusinessSearchService = businessService
        let systemHealthManager = NetworkSystemHealthManager()
        let domainService: DomainService = StubDomainService()
        let siteService: SiteService = NetworkSiteService(client: .shared)

        let environment = AppEnvironment(
            authService: authService,
            keyService: keyService,
            cryptoService: cryptoService,
            notificationService: notificationService,
            storageService: storageService,
            messagingService: messagingService,
            friendService: friendService,
            storyService: stubStoryService as any StoryService,
            groupService: stubGroupService as any GroupService,
            communityService: communityService,
            contactImportService: contactImportService,
            importedContactsStore: importedContactsStore,
            deviceSessionService: stubDeviceSessionService as any DeviceSessionService,
            backupService: backupService as any BackupService,
            safetyService: safetyService,
            accountLifecycleService: accountLifecycleService,
            accountDeletionScheduler: accountDeletionScheduler,
            localPersistence: localPersistence,
            callService: callService,
            businessService: businessService,
            aiStorefrontService: aiStorefrontService,
            businessSearchService: businessSearchService,
            systemHealthManager: systemHealthManager,
            domainService: domainService,
            siteService: siteService
        )

        VoIPPushManager.shared.environment = environment
        VoIPPushManager.shared.registrar = NetworkPushTokenRegistrar(
            baseURL: callBaseURL,
            userID: currentUserID()
        )

        return environment
    }
}
