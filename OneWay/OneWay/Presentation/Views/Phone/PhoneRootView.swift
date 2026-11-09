import SwiftUI
import Combine

struct PhoneRootView: View {
    @StateObject private var manager: CallManager
    @State private var selectedPhoneSection: PhoneSection
    @StateObject private var joinCoordinator = WalkieJoinCoordinator.shared

    private let callService: CallService
    @ObservedObject private var toolbarPreferences: OneWayToolbarPreferencesStore
    private let onBack: () -> Void
    private let onBackToHome: () -> Void
    private let onOpenFeature: (OneWayFeature) -> Void
    private let onOpenHub: () -> Void

    init(
        friendService: FriendService,
        contactImportService: ContactImportService,
        importedContactsStore: ImportedContactsStore,
        callService: CallService,
        toolbarPreferences: OneWayToolbarPreferencesStore,
        onBack: @escaping () -> Void,
        onBackToHome: @escaping () -> Void,
        onOpenFeature: @escaping (OneWayFeature) -> Void,
        onOpenHub: @escaping () -> Void,
        initialSection: PhoneSection = .recents
    ) {
        self.callService = callService
        self.toolbarPreferences = toolbarPreferences
        self.onBack = onBack
        self.onBackToHome = onBackToHome
        self.onOpenFeature = onOpenFeature
        self.onOpenHub = onOpenHub
        _selectedPhoneSection = State(initialValue: initialSection)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-qa-keypad") {
            _selectedPhoneSection = State(initialValue: .keypad)
        }
#endif
        _manager = StateObject(
            wrappedValue: CallManager(
                friendService: friendService,
                contactImportService: contactImportService,
                importedContactsStore: importedContactsStore,
                callService: callService
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayCallTheme.background.ignoresSafeArea()

                Group {
                    switch selectedPhoneSection {
                    case .favorites:
                        PhoneFavoritesView(manager: manager)
                            .transition(.opacity)
                    case .recents:
                        PhoneRecentsView(manager: manager)
                            .transition(.opacity)
                        case .walkie:
                            WalkieView(
                                onBack: onBack,
                                onOpenKeypad: { selectedPhoneSection = .keypad }
                            )
                                .transition(.opacity)
                    case .contacts:
                        PhoneContactsView(manager: manager)
                            .transition(.opacity)
                    case .keypad:
                        PhoneKeypadView(
                            manager: manager,
                            onBackToHome: onBackToHome,
                            onOpenChirp: { selectedPhoneSection = .walkie }
                        )
                            .transition(.opacity)
                    case .voicemail:
                        PhoneVoicemailView(manager: manager)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.18), value: selectedPhoneSection)
            }
            .safeAreaInset(edge: .bottom, spacing: 12) {
                if selectedPhoneSection != .walkie && selectedPhoneSection != .keypad {
                    PhoneSubTabBar(
                        selected: $selectedPhoneSection,
                        preferencesStore: toolbarPreferences,
                        voicemailUnreadCount: manager.voicemails.filter { !$0.listened }.count
                    ) { feature in
                        onOpenFeature(feature)
                    } onOpenHub: {
                        onOpenHub()
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if selectedPhoneSection != .keypad && selectedPhoneSection != .walkie {
                    VStack(spacing: 10) {
                        HStack {
                            Button(action: onBack) {
                                OneWayResolvedLabel("Back", systemImage: "chevron.left")
                                    .font((selectedPhoneSection == .contacts ? Font.caption : Font.subheadline).weight(.semibold))
                                    .foregroundStyle(OneWayCallTheme.purple)
                                    .padding(.horizontal, selectedPhoneSection == .contacts ? 11 : 14)
                                    .padding(.vertical, selectedPhoneSection == .contacts ? 8 : 10)
                                    .background(OneWayCallTheme.surface)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }

                        PhoneBackendBanner(state: manager.backendState)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, selectedPhoneSection == .contacts ? 0 : 6)
                }
            }
            .task {
                await manager.runConnectionLifecycle()
            }
            .onAppear {
                if joinCoordinator.pendingSessionId != nil {
                    selectedPhoneSection = .walkie
                }
            }
            .onChange(of: joinCoordinator.pendingSessionId) { _, value in
                if value != nil {
                    selectedPhoneSection = .walkie
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: OneWayConnectivity.didBecomeOnline)) { _ in
                Task { await manager.refreshAll() }
            }
            .alert(
                manager.externalCallConfirmation?.title ?? "External Network Call",
                isPresented: Binding(
                    get: { manager.externalCallConfirmation != nil },
                    set: { if !$0 { manager.dismissExternalCallConfirmation() } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    manager.dismissExternalCallConfirmation()
                }
                Button(manager.externalCallConfirmation?.actionTitle ?? "Use OneWay External Network") {
                    Task { await manager.confirmExternalDial() }
                }
            } message: {
                Text(
                    manager.externalCallConfirmation?.message
                    ?? "This call will use OneWay's external phone network instead of your iPhone carrier."
                )
            }
            .alert(
                "Calls",
                isPresented: Binding(
                    get: {
                        manager.externalCallConfirmation == nil
                        && manager.alertMessage != nil
                    },
                    set: { if !$0 { manager.alertMessage = nil } }
                )
            ) {
                Button("OK") { manager.alertMessage = nil }
            } message: {
                Text(manager.alertMessage ?? "")
            }
            .sheet(item: $manager.activeVoiceCall) { activeCall in
                CallSessionSheet(
                    callID: activeCall.id,
                    callType: activeCall.type,
                    displayName: activeCall.displayName,
                    routeLabel: activeCall.routeLabel,
                    statusText: activeCall.statusText,
                    callService: callService,
                    onEndRequest: {
                        try await manager.endActiveVoiceCall(callID: activeCall.id)
                    },
                    onMuteRequest: { muted in
                        try await manager.setExternalCallMuted(callID: activeCall.id, muted: muted)
                    },
                    onSpeakerRequest: { enabled in
                        try await manager.setExternalCallSpeakerEnabled(callID: activeCall.id, enabled: enabled)
                    }
                ) {
                    manager.dismissCallSheet()
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}
