import SwiftUI
import Combine
import UIKit

@MainActor
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("burn_button_enabled") private var burnButtonEnabled = false
    @AppStorage("oneway.tabOrder") private var storedTabOrderRaw = ""
    @StateObject private var tabVisibilityManager = TabVisibilityManager()
    @StateObject private var liveKitManager = LiveKitManager.shared
    @StateObject private var callKitManager = CallKitManager.shared

    @State private var selectedTab: RootTab = .chats
    @State private var tabOrder: [RootTab] = RootTab.allCases
    @State private var hasLoadedTabOrder = false
    @State private var isSentinelPresented = false
    @State private var isSentinelLockingDown = false

    var body: some View {
        ZStack {
            SideMenuBackground()

            Group {
                switch selectedTab {
                case .calls:
                    PhoneRootView(
                        friendService: environment.friendService,
                        contactImportService: environment.contactImportService,
                        importedContactsStore: environment.importedContactsStore,
                        callService: environment.callService
                    )
                case .communities:
                    CommunitiesView(
                        communityService: environment.communityService,
                        messagingService: environment.messagingService,
                        cryptoService: environment.cryptoService
                    )
                case .chats:
                    ChatsListView(
                        messagingService: environment.messagingService,
                        friendService: environment.friendService,
                        storyService: environment.storyService,
                        groupService: environment.groupService,
                        callService: environment.callService
                    )
                case .business:
                    BusinessHomeView(
                        businessService: environment.businessService,
                        aiStorefrontService: environment.aiStorefrontService,
                        searchService: environment.businessSearchService
                    )
                case .browser:
                    BrowserHostView()
                case .settings:
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
                        systemHealthManager: environment.systemHealthManager
                    )
                }
            }

            BurnButtonOverlay(isEnabled: burnButtonEnabled) {
                try await environment.accountLifecycleService.deleteAccountBestEffort()
                environment.accountDeletionScheduler.cancel()
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isSentinelPresented = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 48, height: 48)
                                .overlay(Circle().stroke(Theme.divider, lineWidth: 1))
                            Image(systemName: "shield.checkered")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    }
                    .accessibilityLabel("Open OneWay Sentinel")
                    .padding(.trailing, 14)
                    .padding(.top, 8)
                }
                Spacer()
            }
            .zIndex(8)

            if isSentinelLockingDown {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 14) {
                            ProgressView()
                            Text("Securing your OneWay account…")
                                .font(.headline)
                        }
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .zIndex(20)
            }

            if callKitManager.isIncomingCall,
               let activeCallUUID = callKitManager.activeCallUUID,
               !liveKitManager.isPresentingGroupCall {
                IncomingCallOverlay(
                    callerName: callKitManager.incomingCallerName ?? "Incoming Caller",
                    onAccept: {
                        callKitManager.isIncomingCall = false
                        Task {
                            try? await environment.callService.answerCall(sessionID: activeCallUUID)
                            try? await LiveKitManager.shared.acceptIncomingCall()
                        }
                    },
                    onDecline: {
                        CallKitManager.shared.endCall(uuid: activeCallUUID)
                    }
                )
                .zIndex(10)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !tabVisibilityManager.isTabBarHidden {
                CustomTabBar(selection: $selectedTab, tabOrder: $tabOrder)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .environmentObject(tabVisibilityManager)
            }
        }
        .onAppear {
            loadTabOrderIfNeeded()
        }
        .onChange(of: tabOrder) { _, newOrder in
            persistTabOrder(newOrder)
        }
        .task {
            await environment.accountDeletionScheduler.processIfNeeded()
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            Task {
                await environment.accountDeletionScheduler.processIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .oneWaySentinelLockdownRequested)) { _ in
            Task { await performSentinelLockdown() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await environment.accountDeletionScheduler.processIfNeeded()
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissKeyboard()
            }
        )
        .sheet(isPresented: $isSentinelPresented) {
            NavigationStack {
                SentinelSecurityCenterView()
            }
        }
        .fullScreenCover(isPresented: $liveKitManager.isPresentingGroupCall) {
            if let roomName = liveKitManager.currentRoomName {
                GroupCallView(
                    roomName: roomName,
                    userId: environment.currentUserID,
                    callUUID: liveKitManager.activeCallUUID
                )
            }
        }
        .environmentObject(tabVisibilityManager)
        .preferredColorScheme(.dark)
    }

    private func performSentinelLockdown() async {
        guard !isSentinelLockingDown else { return }
        isSentinelLockingDown = true
        defer { isSentinelLockingDown = false }

        environment.accountDeletionScheduler.cancel()
        try? await environment.authService.signOut()
        isSentinelPresented = false
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func loadTabOrderIfNeeded() {
        guard !hasLoadedTabOrder else { return }
        hasLoadedTabOrder = true

        let parts = storedTabOrderRaw
            .split(separator: ",")
            .map { String($0) }
        let parsed = parts.compactMap { RootTab(rawValue: $0) }

        let merged = parsed + RootTab.allCases.filter { !parsed.contains($0) }
        tabOrder = merged.isEmpty ? RootTab.allCases : merged
    }

    private func persistTabOrder(_ order: [RootTab]) {
        storedTabOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }
}
