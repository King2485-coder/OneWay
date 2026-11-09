import SwiftUI
import Combine
import UIKit

@MainActor
struct RootView: View {
    let onSignOut: () async -> Void

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("oneway.tabOrder") private var storedTabOrderRaw = ""
    @AppStorage("oneway.tabOrderVersion") private var storedTabOrderVersion = 0
    @AppStorage("oneway.walletShortcut.visible") private var walletShortcutVisible = true
    @AppStorage("oneway.walletShortcut.hideDuringCalls") private var hideWalletShortcutDuringCalls = true
    @AppStorage("oneway.debugIdentityBanner.visible") private var debugIdentityBannerVisible = false
    @StateObject private var tabVisibilityManager = TabVisibilityManager()
    @StateObject private var liveKitManager = LiveKitManager.shared
    @StateObject private var callKitManager = CallKitManager.shared
    @StateObject private var walkieMonitor = AppWalkieMonitor.shared
    @StateObject private var walletCoordinator = WalletPresentationCoordinator()
    @StateObject private var chirpRequestCoordinator = ChirpRequestPresentationCoordinator()
    @StateObject private var toolbarPreferences: OneWayToolbarPreferencesStore

    @State private var selectedTab: RootTab = .quantum
    @State private var previousNonCallsTab: RootTab = .quantum
    @State private var initialPhoneSection: PhoneSection = .recents
    @State private var phoneRootIdentity = 0
    @State private var tabOrder: [RootTab] = RootTab.defaultToolbar
    @State private var hasLoadedTabOrder = false
    @State private var presentedIncomingCall: CallSession?
    @State private var showQuickActions = false
    @State private var showOneWayShops = false
    @State private var oneWayShopsInitialTab: OneWayShopsView.Tab = .home
    @State private var oneWayShopsInitialRoute: MarketplaceRoute?
    @State private var showOneWaySites = false
    @State private var showCreateSiteFlow = false
    @State private var showOneWayAds = false
    @State private var showOneWayEmail = false
    @State private var emailInitialThreadID: String?
    @State private var emailStartsCompose = false
    @State private var emailStartsSettings = false
    @State private var showBrowser = false
    @State private var quantumInitialURL: URL?
    @State private var quantumStartupDecision: PortalStartupDecision
    @State private var showSettings = false
    @State private var settingsReturnTab: RootTab = .quantum
    @State private var showSignOutConfirmation = false
    @State private var isSigningOut = false
    @State private var preparedIncomingWalkieSessionIds = Set<String>()
    @State private var isShowingAutomationCamera = false
    @State private var automationNotice: OneWayAutomationNotice?

    init(onSignOut: @escaping () async -> Void = {}) {
        self.onSignOut = onSignOut
        _toolbarPreferences = StateObject(
            wrappedValue: OneWayToolbarPreferencesStore(userID: AppEnvironment.currentUserID())
        )
        _quantumStartupDecision = State(
            initialValue: OneWayStartupExperienceService().resolve()
        )
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-qa-seller-plans")
            || arguments.contains("-qa-my-shops")
            || arguments.contains("-qa-shops-home")
            || arguments.contains("-qa-shop-category")
            || arguments.contains("-qa-shop-categories")
            || arguments.contains("-qa-shop-messages")
            || arguments.contains("-qa-message-settings")
            || arguments.contains("-qa-manage-shop")
            || arguments.contains("-qa-shop-account") {
            _selectedTab = State(initialValue: .shops)
            _previousNonCallsTab = State(initialValue: .shops)
        } else if arguments.contains("-qa-settings-sheet-back") {
            _selectedTab = State(initialValue: .chats)
            _previousNonCallsTab = State(initialValue: .chats)
            _showSettings = State(initialValue: true)
        } else if arguments.contains("-qa-chat-composer") || arguments.contains("-qa-new-message") {
            _selectedTab = State(initialValue: .chats)
            _previousNonCallsTab = State(initialValue: .chats)
        } else if arguments.contains("-qa-keypad") {
            _selectedTab = State(initialValue: .calls)
            _previousNonCallsTab = State(initialValue: .quantum)
        } else if arguments.contains("-qa-settings-back") {
            _selectedTab = State(initialValue: .settings)
            _previousNonCallsTab = State(initialValue: .chats)
            _settingsReturnTab = State(initialValue: .chats)
        } else if arguments.contains("-qa-delete-account") || arguments.contains("-qa-hub-icons") {
            _showQuickActions = State(initialValue: true)
        }
#endif
    }

    var body: some View {
        ZStack {
            OneWayLightBackground()
                .contentShape(Rectangle())
                .onTapGesture { OneWayKeyboard.dismiss() }

            BrowserHostView(
                initialURL: quantumInitialURL ?? quantumStartupDecision.initialURL,
                asksForStartupPortal: quantumInitialURL == nil && quantumStartupDecision == .askEveryLaunch
            )
            .id(quantumBrowserIdentity)
            .opacity(selectedTab == .quantum ? 1 : 0)
            .allowsHitTesting(selectedTab == .quantum)
            .accessibilityHidden(selectedTab != .quantum)

            Group {
                switch selectedTab {
                case .calls:
                    PhoneRootView(
                        friendService: environment.friendService,
                        contactImportService: environment.contactImportService,
                        importedContactsStore: environment.importedContactsStore,
                        callService: environment.callService,
                        toolbarPreferences: toolbarPreferences,
                        onBack: {
                            selectedTab = previousNonCallsTab
                        },
                        onBackToHome: {
                            selectedTab = .quantum
                            previousNonCallsTab = .quantum
                        },
                        onOpenFeature: { feature in
                            handleToolbarFeature(feature)
                        },
                        onOpenHub: {
                            showQuickActions = true
                        },
                        initialSection: initialPhoneSection
                    )
                    .id(phoneRootIdentity)
                case .communities:
                    CommunitiesView(
                        communityService: environment.communityService,
                        messagingService: environment.messagingService,
                        cryptoService: environment.cryptoService
                    )
                case .quantum:
                    Color.clear.allowsHitTesting(false)
                case .chats:
                    ChatsListView(
                        messagingService: environment.messagingService,
                        friendService: environment.friendService,
                        storyService: environment.storyService,
                        groupService: environment.groupService,
                        callService: environment.callService
                    )
                case .create:
                    Color.clear
                case .wallet:
                    WalletView()
                case .shops:
                    OneWayShopsView(
                        toolbarPreferences: toolbarPreferences,
                        onOpenCommunity: {
                            selectedTab = .communities
                        },
                        onOpenFeature: { feature in
                            handleToolbarFeature(feature)
                        },
                        onOpenHub: {
                            showQuickActions = true
                        }
                    )
                case .sites:
                    OneWaySitesDashboardView()
                case .ai:
                    BrowserHostView()
                case .settings:
                    settingsSurface
                }
            }

            if callKitManager.isIncomingCall,
               let activeCallUUID = callKitManager.activeCallUUID,
               presentedIncomingCall == nil,
               !liveKitManager.isPresentingGroupCall {
                IncomingCallOverlay(
                    callerName: callKitManager.incomingCallerName ?? "Incoming Caller",
                    onAccept: {
                        callKitManager.isIncomingCall = false
                        Task {
                            do {
                                try await environment.callService.answerIncomingCall(sessionID: activeCallUUID, source: .inApp)
                                presentedIncomingCall = CallSession(
                                    id: activeCallUUID,
                                    chatID: activeCallUUID,
                                    type: .video,
                                    state: .connecting,
                                    startedAt: Date(),
                                    participants: [],
                                    muted: false,
                                    speakerOn: true,
                                    cameraOn: true,
                                    isLocal: false
                                )
                            } catch {
                                #if DEBUG
                                print("❌ Incoming overlay answer failed:", PrivacyLog.shortID(activeCallUUID.uuidString), PrivacyLog.redact(error.localizedDescription))
                                #endif
                            }
                        }
                    },
                    onDecline: {
                        Task {
                            try? await environment.callService.declineCall(sessionID: activeCallUUID)
                            CallKitManager.shared.endCall(uuid: activeCallUUID)
                        }
                    }
                )
                .zIndex(10)
            }

            if let incoming = walkieMonitor.incomingChannel,
               callKitManager.isIncomingCall == false,
               !liveKitManager.isPresentingGroupCall {
                IncomingWalkieBanner(
                    incoming: incoming,
                    onJoin: {
                        let sessionId = incoming.sessionId ?? incoming.id
                        walkieMonitor.ignoreCurrent()
                        WalkieJoinCoordinator.shared.requestJoin(sessionId: sessionId)
                        selectedTab = .calls
                    },
                    onIgnore: {
                        walkieMonitor.ignoreCurrent()
                    }
                )
                .zIndex(9)
            }

            if let request = chirpRequestCoordinator.activeRequest {
                ChirpRequestPromptView(
                    request: request,
                    isResolving: chirpRequestCoordinator.isResolving,
                    onAccept: {
                        Task { await chirpRequestCoordinator.accept(request) }
                    },
                    onDeny: {
                        Task { await chirpRequestCoordinator.deny(request) }
                    },
                    onIgnore: {
                        Task { await chirpRequestCoordinator.ignore(request) }
                    },
                    onBlock: {
                        Task { await chirpRequestCoordinator.block(request) }
                    }
                )
                .zIndex(12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if shouldShowGlobalWalletShortcut {
                GlobalWalletShortcut(placement: walletShortcutPlacement) {
                    walletCoordinator.openCompactWallet()
                }
                .padding(.top, walletShortcutTopPadding)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: walletShortcutAlignment)
                .zIndex(8)
                .transition(.scale(scale: 0.82).combined(with: .opacity))
            }

            #if DEBUG
            if debugIdentityBannerVisible,
               !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-qa-shop") || $0 == "-qa-message-settings" || $0 == "-qa-manage-shop" || $0 == "-qa-keypad" }) {
                DebugIdentityDiagnosticsBanner()
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .zIndex(30)
            }
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            if !tabVisibilityManager.isTabBarHidden, selectedTab != .calls, selectedTab != .shops {
                CustomTabBar(
                    selection: $selectedTab,
                    preferencesStore: toolbarPreferences,
                    onQuickAction: {
                        showQuickActions = true
                    },
                    onSelectFeature: { feature in
                        handleToolbarFeature(feature)
                    }
                )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .environmentObject(tabVisibilityManager)
            }
        }
        .onAppear {
            loadTabOrderIfNeeded()
            toolbarPreferences.importLegacyMainLayout(tabOrder)
        }
        .onChange(of: tabOrder) { _, newOrder in
            persistTabOrder(newOrder)
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == .settings {
                if oldValue != .settings {
                    settingsReturnTab = oldValue
                }
            } else if newValue != .calls {
                previousNonCallsTab = newValue
            } else if oldValue != .calls {
                previousNonCallsTab = oldValue
            }
        }
        .onChange(of: walkieMonitor.incomingChannel?.id) { _, _ in
            prepareIncomingWalkieAudio(walkieMonitor.incomingChannel)
        }
        .task {
            await environment.accountDeletionScheduler.processIfNeeded()
        }
        .task {
            chirpRequestCoordinator.start(friendService: environment.friendService)
        }
        .task {
            for await session in environment.callService.observeActiveCalls() {
                guard !session.isLocal else { continue }
                switch session.state {
                case .waitingForAudioActivation, .joining, .connecting, .connected, .reconnecting:
                    presentedIncomingCall = session
                case .ringing:
                    break
                case .ended, .failed, .missed:
                    if presentedIncomingCall?.id == session.id {
                        presentedIncomingCall = nil
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            Task {
                await environment.accountDeletionScheduler.processIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await environment.accountDeletionScheduler.processIfNeeded()
            }
        }
        .oneWayKeyboardManaged()
        .fullScreenCover(isPresented: $liveKitManager.isPresentingGroupCall) {
            if let roomName = liveKitManager.currentRoomName {
                GroupCallView(
                    roomName: roomName,
                    userId: environment.currentUserID,
                    callUUID: liveKitManager.activeCallUUID
                )
            }
        }
        .sheet(item: $presentedIncomingCall) { session in
            CallSessionSheet(
                callID: session.id,
                callType: session.type,
                displayName: session.type == .video ? "Incoming Video Call" : "Incoming Call",
                routeLabel: "OneWay Signal",
                callService: environment.callService
            ) {
                presentedIncomingCall = nil
            }
            .presentationDetents([.medium, .large])
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OneWayQuantumURLRequested"))) { notification in
            guard let url = notification.object as? URL, OneWayBrowserPolicy.isAllowed(url) else { return }
            showOneWaySites = false; showCreateSiteFlow = false
            selectedTab = .quantum
        }
        .onReceive(NotificationCenter.default.publisher(for: OneWayHubPreferencesStore.openRequested)) { _ in showQuickActions = true }
        .onReceive(NotificationCenter.default.publisher(for: OneWayHubPreferencesStore.routeRequested)) { notification in
            guard let route = notification.object as? OneWayHubRoute else { return }
            switch route {
            case .feature(let feature): handleToolbarFeature(feature)
            case .action(let action): handleQuickAction(action)
            }
        }
        .sheet(isPresented: $showQuickActions) {
            OneWayQuickActionsView { action in
                handleQuickAction(action)
            } onSelectFeature: { feature in
                showQuickActions = false
                handleToolbarFeature(feature)
            } onDeleteAccount: {
                try await environment.accountLifecycleService.deleteAccountBestEffort()
            } onClose: {
                showQuickActions = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(34)
            .presentationBackground(OneWayDesignSystem.Colors.backgroundPrimary)
        }
        .sheet(isPresented: $showOneWayShops) {
            OneWayShopsView(
                initialTab: oneWayShopsInitialTab,
                initialRoute: oneWayShopsInitialRoute,
                toolbarPreferences: toolbarPreferences,
                onManage: { showOneWayShops = false },
                onOpenFeature: { feature in
                    showOneWayShops = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        handleToolbarFeature(feature)
                    }
                },
                onOpenHub: {
                    showOneWayShops = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        showQuickActions = true
                    }
                }
            )
        }
        .sheet(isPresented: $showOneWaySites) {
            OneWaySitesDashboardView()
        }
        .sheet(isPresented: $showCreateSiteFlow) {
            OneWaySitesDashboardView(startOnCreate: true, returnToDashboardAfterCreate: true)
        }
        .sheet(isPresented: $showOneWayAds) {
            OneWayAdsManagerView {
                showOneWayAds = false
            }
        }
        .sheet(isPresented: $showOneWayEmail, onDismiss: {
            emailInitialThreadID = nil
            emailStartsCompose = false
            emailStartsSettings = false
        }) {
            OneWayEmailView(initialThreadID: emailInitialThreadID, startsCompose: emailStartsCompose, startsSettings: emailStartsSettings)
        }
        .sheet(isPresented: $showBrowser) {
            BrowserHostView(
                initialURL: quantumInitialURL ?? quantumStartupDecision.initialURL,
                asksForStartupPortal: quantumInitialURL == nil && quantumStartupDecision == .askEveryLaunch
            )
        }
        .sheet(isPresented: $showSettings) {
            settingsSurface
        }
        .sheet(isPresented: $showSignOutConfirmation) {
            SignOutConfirmationSheet(
                isSigningOut: isSigningOut,
                onCancel: {
                    showSignOutConfirmation = false
                },
                onConfirm: {
                    Task { await confirmSignOut() }
                }
            )
            .presentationDetents([.height(310)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $walletCoordinator.presentation) { presentation in
            switch presentation {
            case .compact:
                CompactWalletSheet {
                    walletCoordinator.openFullWallet()
                } onClose: {
                    walletCoordinator.dismiss()
                }
                .presentationDetents([.medium, .large])
            case .full:
                WalletView {
                    walletCoordinator.dismiss()
                }
            }
        }
        .fullScreenCover(isPresented: $isShowingAutomationCamera) {
            CameraCaptureView { _ in
                automationNotice = OneWayAutomationNotice(
                    title: "Camera Ready",
                    message: "OneWay camera capture completed."
                )
            }
        }
        .alert(item: $automationNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .environmentObject(tabVisibilityManager)
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .oneWayDeepLinkRequested)) { notification in
            if let url = notification.userInfo?["url"] as? URL { handleDeepLink(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .oneWayActionRequested)) { notification in
            if let raw = notification.object as? String,
               let action = OneWayButtonAction(rawValue: raw) {
                handleOneWayButtonAction(action)
            } else if let action = OneWayActionRouter.shared.consumePendingAction() {
                handleOneWayButtonAction(action)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .oneWayDestinationRequested)) { notification in
            if let raw = notification.object as? String,
               let destination = OneWayLaunchDestination(rawValue: raw) {
                _ = OneWayActionRouter.shared.consumePendingDestination()
                routeApp(to: destination, source: "notification")
            } else if let destination = OneWayActionRouter.shared.consumePendingDestination() {
                routeApp(to: destination, source: "notification-consumed")
            }
        }
        .onAppear {
            consumePendingLaunchDestination(source: "RootView.onAppear")
            if let action = OneWayActionRouter.shared.consumePendingAction() {
                handleOneWayButtonAction(action)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            consumePendingLaunchDestination(source: "scenePhase.active")
        }
    }

    private var shouldShowGlobalWalletShortcut: Bool {
        guard walletShortcutVisible else { return false }
        guard selectedTab != .quantum else { return false }
        guard selectedTab != .communities else { return false }
        guard selectedTab != .chats else { return false }
        guard selectedTab != .wallet else { return false }
        if selectedTab == .calls,
           toolbarPreferences.contains(.wallet, in: .calls) {
            return false
        }
        if selectedTab == .shops,
           toolbarPreferences.contains(.wallet, in: .shops) {
            return false
        }
        if selectedTab != .calls,
           selectedTab != .shops,
           toolbarPreferences.contains(.wallet, in: .main) {
            return false
        }
        guard !showQuickActions else { return false }
        guard presentedIncomingCall == nil else { return false }
        guard !liveKitManager.isPresentingGroupCall else { return false }
        guard !callKitManager.isIncomingCall else { return false }
        if hideWalletShortcutDuringCalls && selectedTab == .calls {
            return false
        }
        return true
    }

    private var quantumBrowserIdentity: String {
        if let quantumInitialURL {
            return "deep-link:\(quantumInitialURL.absoluteString)"
        }
        switch quantumStartupDecision {
        case .quantumHome:
            return "startup:quantum-home"
        case .askEveryLaunch:
            return "startup:chooser"
        case .portal(let id, let url):
            return "startup:\(id):\(url.absoluteString)"
        }
    }

    private var walletShortcutPlacement: WalletShortcutPlacement {
        switch selectedTab {
        case .calls where hideWalletShortcutDuringCalls:
            return .hidden
        case .wallet, .create, .shops:
            return .hidden
        default:
            return .topTrailing
        }
    }

    private var walletShortcutAlignment: Alignment {
        switch walletShortcutPlacement {
        case .topLeading, .floatingLeading:
            return .topLeading
        default:
            return .topTrailing
        }
    }

    private var walletShortcutTopPadding: CGFloat {
        switch selectedTab {
        case .quantum:
            return 52
        case .communities, .chats, .shops, .settings:
            return 44
        case .calls:
            return 18
        default:
            return 28
        }
    }

    private var settingsSurface: some View {
        SettingsView(
            authService: environment.authService,
            keyService: environment.keyService,
            cryptoService: environment.cryptoService,
            notificationService: environment.notificationService,
            storageService: environment.storageService,
            messagingService: environment.messagingService,
            localPersistence: environment.localPersistence,
            storyService: environment.storyService,
            groupService: environment.groupService,
            communityService: environment.communityService,
            contactImportService: environment.contactImportService,
            importedContactsStore: environment.importedContactsStore,
            accountDeletionScheduler: environment.accountDeletionScheduler,
            friendService: environment.friendService,
            deviceSessionService: environment.deviceSessionService,
            backupService: environment.backupService,
            safetyService: environment.safetyService,
            callService: environment.callService,
            systemHealthManager: environment.systemHealthManager,
            onBack: closeSettings,
            onSignOut: {
                await onSignOut()
            }
        )
    }

    private func closeSettings() {
        if showSettings {
            showSettings = false
        } else if selectedTab == .settings {
            selectedTab = settingsReturnTab
        }
    }

    private func handleQuickAction(_ action: OneWayQuickAction) {
        showQuickActions = false
        switch action {
        case .newMessage:
            selectedTab = .chats
        case .newCommunity, .createPost, .events:
            selectedTab = .communities
        case .newCall:
            routeToPhone(section: .keypad, source: "quick-action:newCall")
        case .newSite:
            showCreateSiteFlow = true
        case .mySites:
            showOneWaySites = true
        case .uploadFile:
            selectedTab = .quantum
        case .createShop:
            openOneWayShops(tab: .home, route: .createShop)
        case .myShops:
            openOneWayShops(tab: .account, route: .myShops)
        case .editShop:
            openOneWayShops(tab: .account, route: .editStore)
        case .shopPolicies:
            openOneWayShops(tab: .account, route: .shopPolicies(nil))
        case .manageProducts:
            openOneWayShops(tab: .account, route: .manageProducts)
        case .addProduct:
            openOneWayShops(tab: .account, route: .addProduct)
        case .shopOrders:
            openOneWayShops(tab: .account, route: .sellerOrders)
        case .shopMessages:
            openOneWayShops(tab: .messages, route: .sellerMessages)
        case .sellerPayments:
            openOneWayShops(tab: .account, route: .sellerPayments)
        case .shopAnalytics, .shopLifecycle, .deleteShop:
            openOneWayShops(tab: .account, route: .manageShop)
        case .siteAnalytics:
            showOneWaySites = true
        case .oneWayAds:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                showOneWayAds = true
            }
        case .wallet:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                walletCoordinator.openCompactWallet()
            }
        case .askAI:
            selectedTab = .quantum
        case .appSettings:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                showSettings = true
            }
        case .signOut:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                showSignOutConfirmation = true
            }
        }
    }

    private func handleToolbarFeature(_ feature: OneWayFeature) {
        if feature == .email {
            showOneWayEmail = true
            return
        }
        switch feature.navigationDestination {
        case .rootTab(let tab):
            withAnimation(.spring(response: 0.36, dampingFraction: 0.76)) {
                selectedTab = tab
            }
        case .quickAction(let action):
            handleQuickAction(action)
        case .phoneSection:
            if case .phoneSection(let section) = feature.navigationDestination {
                routeToPhone(section: section, source: "universal-hub:\(feature.rawValue)")
            }
        case .shopsTab:
            if case .shopsTab(let tab) = feature.navigationDestination {
                openOneWayShops(tab: tab)
            }
        }
    }

    private func prepareIncomingWalkieAudio(_ incoming: WalkieChannel?) {
        guard let incoming,
              callKitManager.isIncomingCall == false,
              !liveKitManager.isPresentingGroupCall,
              !MediaModeCoordinator.shared.isCallActive else {
            #if DEBUG
            if incoming != nil {
                print(
                    "CHIRP_SOUND_BLOCKED_FOR_CALL",
                    "sound=foreground_walkie_auto_join",
                    "category=legacyWalkie",
                    "communicationMode=\(MediaModeCoordinator.shared.currentMode.rawValue)",
                    "callId=\(PrivacyLog.shortID(MediaModeCoordinator.shared.currentSessionId?.uuidString))",
                    "sourceFile=RootView.swift",
                    "function=prepareIncomingWalkieAudio",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
            }
            #endif
            return
        }

        let sessionId = incoming.sessionId ?? incoming.id
        guard !preparedIncomingWalkieSessionIds.contains(sessionId) else { return }

        preparedIncomingWalkieSessionIds.insert(sessionId)
        WalkieJoinCoordinator.shared.requestJoin(sessionId: sessionId)
        selectedTab = .calls

#if DEBUG
        print(
            "🎙 CHIRP MEDIA event=chirp.incoming.foreground_prepare " +
            "sessionId=\(PrivacyLog.shortID(sessionId)) " +
            "roomName=\(PrivacyLog.shortID(incoming.roomName))"
        )
#endif
    }

    private func confirmSignOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        await onSignOut()
        isSigningOut = false
        showSignOutConfirmation = false
        showSettings = false
        showQuickActions = false
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "oneway" else { return }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let route = [host, path].filter { !$0.isEmpty }.joined(separator: "/")

        switch route {
        case "hub", "create":
            showQuickActions = true
        case "quantum", "browser":
            handleToolbarFeature(.quantum)
        case "messages", "personal-messages", "chats":
            handleToolbarFeature(.messages)
        case "communities", "community":
            handleToolbarFeature(.communities)
        case "calls", "phone":
            handleToolbarFeature(.calls)
        case "contacts":
            handleToolbarFeature(.contacts)
        case "keypad":
            handleToolbarFeature(.keypad)
        case "voicemail":
            handleToolbarFeature(.voicemail)
        case "email", "mail", "inbox":
            handleToolbarFeature(.email)
        case "shops", "shop":
            handleToolbarFeature(.shops)
        case "shops/messages", "shop/messages", "shop-messages", "seller-messages":
            handleToolbarFeature(.shopMessages)
        case "shops/account", "shop/account":
            handleToolbarFeature(.shopAccount)
        case "shops/categories", "shop/categories":
            handleToolbarFeature(.shopCategories)
        case "creator-hub", "creator", "workspace":
            handleToolbarFeature(.workspace)
        case "wallet":
            handleToolbarFeature(.wallet)
        case "settings":
            showSettings = true
        case "actions", "actions/smartactionmenu":
            handleOneWayButtonAction(.smartActionMenu)
        case "chirp", "walkie", "actions/startchirp":
            routeApp(to: .chirp, source: "deeplink:\(route)")
        case "camera", "actions/opencamera":
            routeApp(to: .camera, source: "deeplink:\(route)")
        case "actions/callfavorite":
            handleOneWayButtonAction(.callFavorite)
        case "actions/openquantum":
            handleOneWayButtonAction(.openQuantum)
        case "actions/openwallet":
            handleOneWayButtonAction(.openWallet)
        case "actions/openai":
            handleOneWayButtonAction(.openAI)
        case "actions/opennavigation":
            handleOneWayButtonAction(.openNavigation)
        case "actions/emergencymode":
            handleOneWayButtonAction(.emergencyMode)
        case "account/signout":
            showSignOutConfirmation = true
        default:
            if route.hasPrefix("email/thread/") {
                emailInitialThreadID = String(route.dropFirst("email/thread/".count))
                showOneWayEmail = true
                return
            }
            if route == "email/compose" {
                emailStartsCompose = true
                showOneWayEmail = true
                return
            }
            if route == "email/settings" {
                emailStartsSettings = true
                showOneWayEmail = true
                return
            }
            if let siteURL = oneWaySiteURL(from: url) {
                print("QUANTUM_ONEWAY_DEEP_LINK_RECEIVED url=\(url.absoluteString)")
                quantumInitialURL = siteURL
                selectedTab = .quantum
                showBrowser = false
            }
        }
    }

    private func handleOneWayButtonAction(_ action: OneWayButtonAction) {
        let safeAction = OneWayActionRouter.shared.safeAction(for: action)
        switch safeAction {
        case .smartActionMenu:
            showQuickActions = true
            automationNotice = OneWayAutomationNotice(
                title: "OneWay Smart Actions",
                message: action == .smartActionMenu ? "Choose a OneWay action." : "\(action.title) is set to Ask First or Off. Choose an action to continue."
            )
        case .startChirp:
            routeApp(to: .chirp, source: "legacy-action")
        case .openCamera:
            routeApp(to: .camera, source: "legacy-action")
        case .callFavorite:
            selectedTab = .calls
            automationNotice = OneWayAutomationNotice(
                title: "Call Favorite",
                message: "Choose or confirm a contact before OneWay starts a call."
            )
        case .openQuantum:
            selectedTab = .quantum
        case .openWallet:
            walletCoordinator.openCompactWallet()
        case .openAI:
            selectedTab = .quantum
            automationNotice = OneWayAutomationNotice(
                title: "OneWay AI",
                message: "AI tools are available from the OneWay creation hub."
            )
        case .openNavigation:
            automationNotice = OneWayAutomationNotice(
                title: "OneWay Navigation",
                message: "Navigation will activate only after you choose a destination and grant required location access."
            )
        case .emergencyMode:
            automationNotice = OneWayAutomationNotice(
                title: "Emergency Mode",
                message: "Emergency actions require explicit confirmation. OneWay will not trigger them silently."
            )
        }
    }

    private func consumePendingLaunchDestination(source: String) {
        guard let destination = OneWayActionRouter.shared.consumePendingDestination() else { return }
        routeApp(to: destination, source: source)
    }

    private func routeApp(to destination: OneWayLaunchDestination, source: String) {
        #if DEBUG
        print("[OneWayRoute] RootView received route destination=\(destination.rawValue) source=\(source)")
        #endif

        switch destination {
        case .chirp:
            routeToChirp(source: source)
        case .camera:
            routeToCamera(source: source)
        case .keypad:
            routeToPhone(section: .keypad, source: source)
        case .contacts:
            routeToPhone(section: .contacts, source: source)
        case .messages:
            isShowingAutomationCamera = false
            selectedTab = .chats
        case .quantum:
            isShowingAutomationCamera = false
            selectedTab = .quantum
        }
    }

    private func routeToChirp(source: String) {
        if isShowingAutomationCamera {
            #if DEBUG
            print("[OneWayRoute] camera startup route skipped because explicit Chirp route exists source=\(source)")
            #endif
        }
        isShowingAutomationCamera = false
        initialPhoneSection = .walkie
        phoneRootIdentity += 1
        selectedTab = .calls
        #if DEBUG
        print("[OneWayRoute] selected root tab changed to Calls")
        print("[OneWayRoute] PhoneRootView selected tab changed to Chirp")
        #endif
        automationNotice = OneWayAutomationNotice(
            title: "Chirp Ready",
            message: "Chirp controls are open. Press and hold the on-screen push-to-talk control to transmit."
        )
    }

    private func routeToPhone(section: PhoneSection, source: String) {
        isShowingAutomationCamera = false
        initialPhoneSection = section
        phoneRootIdentity += 1
        selectedTab = .calls
        #if DEBUG
        print("[OneWayRoute] selected root tab changed to Calls")
        print("[OneWayRoute] PhoneRootView selected tab changed to \(section.rawValue)")
        #endif
    }

    private func routeToCamera(source: String) {
        #if DEBUG
        print("[OneWayRoute] camera route explicitly requested source=\(source)")
        #endif
        isShowingAutomationCamera = true
    }

    private func oneWaySiteURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "oneway" else { return nil }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let raw = host == "site" ? path : host
        let slug = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return nil }
        return URL(string: "https://sites.oneway.app/\(slug)")
    }

    private func openOneWayShops(tab: OneWayShopsView.Tab, route: MarketplaceRoute? = nil) {
        oneWayShopsInitialTab = tab
        oneWayShopsInitialRoute = route
        showOneWayShops = true
    }

    private func loadTabOrderIfNeeded() {
        guard !hasLoadedTabOrder else { return }
        hasLoadedTabOrder = true

        let parts = storedTabOrderRaw
            .split(separator: ",")
            .map { String($0) }
        let parsed = parts.compactMap { RootTab.fromStoredValue($0) }

        if storedTabOrderVersion < 2 {
            let normalizedStored = CustomTabBar.validToolbarOrder(parsed.isEmpty ? RootTab.legacyWalletDefaultToolbar : parsed)
            if storedTabOrderRaw.isEmpty || normalizedStored == RootTab.legacyWalletDefaultToolbar {
                tabOrder = RootTab.defaultToolbar
                storedTabOrderVersion = 2
                persistTabOrder(tabOrder)
                return
            }
            storedTabOrderVersion = 2
        }

        let merged = parsed + RootTab.defaultToolbar.filter { !parsed.contains($0) }
        tabOrder = CustomTabBar.validToolbarOrder(merged.isEmpty ? RootTab.defaultToolbar : merged)
    }

    private func persistTabOrder(_ order: [RootTab]) {
        storedTabOrderRaw = CustomTabBar.validToolbarOrder(order).map(\.rawValue).joined(separator: ",")
    }
}

#if DEBUG
private struct DebugIdentityDiagnosticsBanner: View {
    @State private var isExpanded = false
    @State private var verifiedUser: AuthenticatedUserDTO?
    @State private var verificationError: String?

    private var storedUserID: String {
        AuthTokenStore.shared.storedUserID() ?? "none"
    }

    private var tokenSubject: String {
        AuthTokenStore.shared.tokenSubject() ?? "none"
    }

    private var lastLoginText: String {
        guard let date = AuthTokenStore.shared.lastLoginAt else { return "none" }
        return date.formatted(date: .omitted, time: .standard)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(identityMatches ? Color.green : Color.red)
                        .frame(width: 8, height: 8)

                    Text("ID \(displayHandle)")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    OneWayResolvedIcon(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.74), in: Capsule())
                .overlay(Capsule().stroke(identityMatches ? Color.green.opacity(0.4) : Color.red.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Debug identity diagnostics")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    diagnosticsRow("device", UIDevice.current.name)
                    diagnosticsRow("environment", APIConfig.baseURL)
                    diagnosticsRow("storedUserId", PrivacyLog.shortID(storedUserID))
                    diagnosticsRow("tokenSubject", PrivacyLog.shortID(tokenSubject))
                    diagnosticsRow("profileUserId", PrivacyLog.shortID(verifiedUser?.userId ?? "none"))
                    diagnosticsRow("handle", verifiedUser?.handle ?? "none")
                    diagnosticsRow("socketUserId", PrivacyLog.shortID(storedUserID))
                    diagnosticsRow("chirpIdentity", PrivacyLog.shortID(chirpIdentity))
                    diagnosticsRow("cache", PrivacyLog.shortID(AuthTokenStore.shared.diagnosticsCacheNamespace))
                    diagnosticsRow("keychain", AuthTokenStore.shared.diagnosticsKeychainService)
                    diagnosticsRow("sync", AuthTokenStore.shared.diagnosticsKeychainSynchronizable ? "true" : "false")
                    diagnosticsRow("session", PrivacyLog.shortID(AuthTokenStore.shared.sessionVersion))
                    diagnosticsRow("lastLogin", lastLoginText)

                    if let verificationError {
                        Text(verificationError)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Copy Redacted Identity Diagnostics") {
                        UIPasteboard.general.string = diagnosticsText
                    }
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .buttonStyle(.plain)

                    Button("Reset Local Account State") {
                        resetLocalAccountState()
                    }
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(Color.red.opacity(0.72), in: Capsule())
                    .buttonStyle(.plain)
                }
                .padding(12)
                .frame(maxWidth: 310, alignment: .leading)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
        .task {
            await refreshVerifiedIdentity()
        }
        .onReceive(NotificationCenter.default.publisher(for: AuthTokenStore.tokenDidChangeNotification)) { _ in
            Task { await refreshVerifiedIdentity() }
        }
    }

    private var displayHandle: String {
        verifiedUser?.handle ?? PrivacyLog.shortID(storedUserID)
    }

    private var chirpIdentity: String {
        storedUserID == "none" ? "none" : "chirp-user-\(storedUserID)"
    }

    private var identityMatches: Bool {
        guard storedUserID != "none", tokenSubject != "none" else { return false }
        guard storedUserID.caseInsensitiveCompare(tokenSubject) == .orderedSame else { return false }
        if let verifiedUser {
            return verifiedUser.userId.caseInsensitiveCompare(storedUserID) == .orderedSame
        }
        return verificationError == nil
    }

    private var diagnosticsText: String {
        [
            "device=\(UIDevice.current.name)",
            "environment=\(APIConfig.baseURL)",
            "storedUserId=\(storedUserID)",
            "tokenSubject=\(tokenSubject)",
            "profileUserId=\(verifiedUser?.userId ?? "none")",
            "handle=\(verifiedUser?.handle ?? "none")",
            "socketUserId=\(storedUserID)",
            "chirpIdentity=\(chirpIdentity)",
            "cacheNamespace=\(AuthTokenStore.shared.diagnosticsCacheNamespace)",
            "keychainService=\(AuthTokenStore.shared.diagnosticsKeychainService)",
            "keychainSynchronizable=\(AuthTokenStore.shared.diagnosticsKeychainSynchronizable)",
            "sessionVersion=\(AuthTokenStore.shared.sessionVersion)",
            "lastLogin=\(lastLoginText)",
            "verificationError=\(verificationError ?? "none")",
        ].joined(separator: "\n")
    }

    private func diagnosticsRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @MainActor
    private func refreshVerifiedIdentity() async {
        guard AuthTokenStore.shared.token() != nil else {
            verifiedUser = nil
            verificationError = "No token"
            return
        }

        do {
            verifiedUser = try await AuthAPIService.shared.currentAuthenticatedUser()
            verificationError = nil
        } catch {
            verifiedUser = nil
            verificationError = PrivacyLog.redact(error.localizedDescription)
        }
    }

    private func resetLocalAccountState() {
        let userID = AuthTokenStore.shared.storedUserID()
        AppWalkieMonitor.shared.stop()
        NetworkFriendService.disconnectRealtime()
        NetworkMessagingService.disconnectRealtime()
        CommunityRealtimeClient.shared.disconnect()
        URLCache.shared.removeAllCachedResponses()

        let defaults = UserDefaults.standard
        if let userID, !userID.isEmpty {
            [
                "OneWay.WalkieContacts.\(userID)",
                "oneway.profileCompleteHint.\(userID)",
                "OneWay.BrowserRecentSites.\(userID)",
                "OneWay.BrowserHistory.\(userID)",
                "OneWay.Sites.\(userID)",
                "OneWay.SiteSubmissions.\(userID)",
            ].forEach { defaults.removeObject(forKey: $0) }
        }
        defaults.removeObject(forKey: "OneWay.LastLoginIdentifier")
        defaults.set(true, forKey: "OneWay.SessionExplicitlySignedOut")

        AuthTokenStore.shared.clearDebugAccountOverrides()
        AuthTokenStore.shared.clearSession()
        verifiedUser = nil
        verificationError = "Local account state reset"
    }
}
#endif

private struct OneWayAutomationNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct SignOutConfirmationSheet: View {
    let isSigningOut: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            OneWayScreenBackground()

            VStack(alignment: .leading, spacing: 18) {
                Text("Sign Out of OneWay?")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text("You'll need to sign in again to access your messages, calls, Chirp contacts, wallet, sites, and shops on this device.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                    .buttonStyle(.plain)
                    .disabled(isSigningOut)

                    Button(role: .destructive) {
                        onConfirm()
                    } label: {
                        Group {
                            if isSigningOut {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Sign Out")
                            }
                        }
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .background(Color.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .buttonStyle(.plain)
                    .disabled(isSigningOut)
                }
            }
            .padding(22)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sign Out of OneWay")
    }
}

@MainActor
private final class ChirpRequestPresentationCoordinator: ObservableObject {
    @Published private(set) var activeRequest: FriendConnection?
    @Published private(set) var isResolving = false
    @Published private(set) var pendingIncomingCount = 0

    private var friendService: FriendService?
    private var eventTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var queuedRequests: [FriendConnection] = []
    private var presentedRequestIds: Set<String> = []
    private var ignoredRequestIds: Set<String> = []

    func start(friendService: FriendService) {
        self.friendService = friendService
        startAuthObserverIfNeeded()
        loadIgnoredRequestIds()
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshIncomingRequests(shouldPresent: true)
            for await event in friendService.observeFriendEvents() {
                switch event {
                case .requestReceived:
                    await self.refreshIncomingRequests(shouldPresent: true)
                case .requestAccepted, .requestDenied, .requestBlocked, .removed:
                    await self.refreshIncomingRequests(shouldPresent: false)
                case .requestIgnored, .online, .offline:
                    await self.refreshIncomingRequests(shouldPresent: false)
                }
            }
        }
    }

    func accept(_ request: FriendConnection) async {
        await resolve(request) { service, id in
            _ = try await service.acceptFriendRequest(id: id)
        }
    }

    func deny(_ request: FriendConnection) async {
        await resolve(request) { service, id in
            try await service.declineFriendRequest(id: id)
        }
    }

    func ignore(_ request: FriendConnection) async {
        guard let service = friendService else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            try await service.ignoreFriendRequest(id: request.id)
            let requestId = key(for: request)
            ignoredRequestIds.insert(requestId)
            presentedRequestIds.insert(requestId)
            saveIgnoredRequestIds()
            removePresentedRequest(request)
            await refreshIncomingRequests(shouldPresent: false)
        } catch {
            #if DEBUG
            print("chirp.request.ignored failed", PrivacyLog.redact(error.localizedDescription))
            #endif
        }
    }

    func block(_ request: FriendConnection) async {
        await resolve(request) { service, id in
            try await service.blockFriendRequest(id: id)
        }
    }

    private func resolve(
        _ request: FriendConnection,
        operation: (FriendService, UUID) async throws -> Void
    ) async {
        guard let service = friendService else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            try await operation(service, request.id)
            ignoredRequestIds.remove(key(for: request))
            saveIgnoredRequestIds()
            removePresentedRequest(request)
            await refreshIncomingRequests(shouldPresent: false)
        } catch {
            #if DEBUG
            print("chirp.request.resolve failed", PrivacyLog.redact(error.localizedDescription))
            #endif
        }
    }

    private func refreshIncomingRequests(shouldPresent: Bool) async {
        guard let service = friendService else { return }
        do {
            let friends = try await service.fetchFriends()
            let incoming = friends
                .filter { $0.status == .pending && $0.isIncomingRequest }
                .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            pendingIncomingCount = incoming.count

            let liveRequestIds = Set(incoming.map(key))
            queuedRequests.removeAll { !liveRequestIds.contains(key(for: $0)) }
            if let activeRequest, !liveRequestIds.contains(key(for: activeRequest)) {
                self.activeRequest = nil
            }

            guard shouldPresent else {
                presentNextRequest()
                return
            }

            for request in incoming {
                let requestId = key(for: request)
                guard !ignoredRequestIds.contains(requestId),
                      !presentedRequestIds.contains(requestId),
                      activeRequest.map({ key(for: $0) != requestId }) ?? true,
                      !queuedRequests.contains(where: { key(for: $0) == requestId }) else {
                    continue
                }
                presentedRequestIds.insert(requestId)
                queuedRequests.append(request)
                #if DEBUG
                print("chirp.request.realtime.received", PrivacyLog.shortID(requestId), PrivacyLog.redact(request.displayName))
                #endif
            }
            presentNextRequest()
        } catch {
            #if DEBUG
            print("chirp.request.refresh failed", PrivacyLog.redact(error.localizedDescription))
            #endif
        }
    }

    private func presentNextRequest() {
        guard activeRequest == nil else { return }
        while !queuedRequests.isEmpty {
            let next = queuedRequests.removeFirst()
            guard !ignoredRequestIds.contains(key(for: next)) else { continue }
            activeRequest = next
            #if DEBUG
            print("chirp.request.presented", PrivacyLog.shortID(key(for: next)), PrivacyLog.redact(next.displayName))
            #endif
            return
        }
    }

    private func removePresentedRequest(_ request: FriendConnection) {
        let requestId = key(for: request)
        queuedRequests.removeAll { key(for: $0) == requestId }
        if activeRequest.map({ key(for: $0) == requestId }) ?? false {
            activeRequest = nil
        }
        presentNextRequest()
    }

    private func key(for request: FriendConnection) -> String {
        request.friendshipID ?? request.contactID ?? request.id.uuidString
    }

    private func startAuthObserverIfNeeded() {
        guard authTask == nil else { return }
        authTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AuthTokenStore.tokenDidChangeNotification) {
                await self?.resetForCurrentUser()
            }
        }
    }

    private func resetForCurrentUser() async {
        activeRequest = nil
        isResolving = false
        pendingIncomingCount = 0
        queuedRequests.removeAll()
        presentedRequestIds.removeAll()
        loadIgnoredRequestIds()
        await refreshIncomingRequests(shouldPresent: true)
    }

    private func loadIgnoredRequestIds() {
        let raw = UserDefaults.standard.stringArray(forKey: ignoredStorageKey) ?? []
        ignoredRequestIds = Set(raw)
    }

    private func saveIgnoredRequestIds() {
        UserDefaults.standard.set(Array(ignoredRequestIds), forKey: ignoredStorageKey)
    }

    private var ignoredStorageKey: String {
        "OneWay.Chirp.IgnoredRequestIDs.\(AuthTokenStore.shared.currentUserID())"
    }
}

private struct ChirpRequestPromptView: View {
    let request: FriendConnection
    let isResolving: Bool
    let onAccept: () -> Void
    let onDeny: () -> Void
    let onIgnore: () -> Void
    let onBlock: () -> Void

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    avatar
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Chirp Request")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                        Text("\(request.displayName) wants to connect with you on Chirp.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(request.handle) \(request.chirpID.map { "- \($0)" } ?? "")")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    actionButton("Accept", systemImage: "checkmark", color: Color.green, action: onAccept)
                    actionButton("Deny", systemImage: "xmark", color: Color(hex: 0x8D5CFF), action: onDeny)
                    actionButton("Ignore", systemImage: "moon.fill", color: Color.white.opacity(0.22), action: onIgnore)
                    actionButton("Block", systemImage: "hand.raised.fill", color: Color.red.opacity(0.82), action: onBlock)
                }
                .disabled(isResolving)
                .opacity(isResolving ? 0.55 : 1)
            }
            .padding(18)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x1D1B26).opacity(0.96), Color(hex: 0x111018).opacity(0.98)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color(hex: 0x8D5CFF).opacity(0.38), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 22, x: 0, y: 16)
            .padding(.horizontal, 18)
            .padding(.top, 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.18).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chirp request from \(request.displayName)")
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x8D5CFF), Color(hex: 0x37D98B)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initials(for: request.displayName))
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
        }
        .frame(width: 54, height: 54)
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

    private func actionButton(_ title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedLabel(title, systemImage: systemImage)
                .font(.subheadline.weight(.black))
                .foregroundStyle(title == "Accept" ? Color(hex: 0x07120C) : .white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(color, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func initials(for value: String) -> String {
        let parts = value.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "C" : letters.uppercased()
    }
}

#Preview("Chirp Request Prompt") {
    ChirpRequestPromptView(
        request: FriendConnection(
            id: UUID(uuidString: "ED7C62DB-B50E-459F-AEF1-4919A31BC8AC") ?? UUID(),
            userID: "05aab177-f981-4b3a-9e07-fbd16ab41530",
            friendshipID: "ed7c62db-b50e-459f-aef1-4919a31bc8ac",
            displayName: "King",
            handle: "@king",
            chirpID: "OW-920-809",
            status: .pending,
            isIncomingRequest: true,
            createdAt: "2026-07-20T17:30:16.316Z"
        ),
        isResolving: false,
        onAccept: {},
        onDeny: {},
        onIgnore: {},
        onBlock: {}
    )
    .preferredColorScheme(.dark)
}
