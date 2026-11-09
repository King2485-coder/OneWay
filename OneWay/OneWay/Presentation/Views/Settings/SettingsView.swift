import SwiftUI
import Combine
import PhotosUI
import UIKit
import UserNotifications

struct SettingsView: View {
    enum Destination: Hashable {
        case profile
        case identityDetails
        case lists
        case broadcastMessages
        case starred
        case linkedDevices
        case account
        case oneWayButtonAutomations
        case walletShortcut
        case privacy
        case spamProtection
        case chats
        case notifications
        case storageAndData
        case platformReadiness
        case helpAndFeedback
        case inviteFriend
        case importedPages
        case diagnostics
        case developerQA
        case myNumbers
        case walkiePermissions
    }

    @StateObject private var viewModel: SettingsViewModel
    @State private var selectedProfilePhotoItem: PhotosPickerItem?
    @State private var isShowingPhotoPicker = false
    @State private var profilePhotoData: Data?
    @State private var myStory: StoryItem?
    @State private var isShowingMyStoryViewer = false
    @State private var didUpdateProfilePhoto = false
    @State private var isShowingProfileCamera = false
    @State private var apiHealthStatus: String = "Unknown"
    @State private var navigationPath: [Destination] = []

    private let authService: AuthService
    private let keyService: KeyService
    private let cryptoService: CryptoService
    private let notificationService: NotificationService
    private let storageService: StorageService
    private let messagingService: MessagingService
    private let localPersistence: LocalPersistence
    private let storyService: StoryService
    private let groupService: GroupService
    private let communityService: CommunityService
    private let contactImportService: ContactImportService
    private let importedContactsStore: ImportedContactsStore
    private let accountDeletionScheduler: AccountDeletionScheduler
    private let friendService: FriendService
    private let deviceSessionService: DeviceSessionService
    private let backupService: BackupService
    private let safetyService: SafetyService
    private let callService: CallService
    private let systemHealthManager: SystemHealthManager
    private let onBack: () -> Void
    private let onSignOut: () async -> Void

    init(
        authService: AuthService,
        keyService: KeyService,
        cryptoService: CryptoService,
        notificationService: NotificationService,
        storageService: StorageService,
        messagingService: MessagingService,
        localPersistence: LocalPersistence,
        storyService: StoryService,
        groupService: GroupService,
        communityService: CommunityService,
        contactImportService: ContactImportService,
        importedContactsStore: ImportedContactsStore,
        accountDeletionScheduler: AccountDeletionScheduler,
        friendService: FriendService,
        deviceSessionService: DeviceSessionService,
        backupService: BackupService,
        safetyService: SafetyService,
        callService: CallService,
        systemHealthManager: SystemHealthManager,
        onBack: @escaping () -> Void,
        onSignOut: @escaping () async -> Void
    ) {
        self.authService = authService
        self.keyService = keyService
        self.cryptoService = cryptoService
        self.notificationService = notificationService
        self.storageService = storageService
        self.messagingService = messagingService
        self.localPersistence = localPersistence
        self.storyService = storyService
        self.groupService = groupService
        self.communityService = communityService
        self.contactImportService = contactImportService
        self.importedContactsStore = importedContactsStore
        self.accountDeletionScheduler = accountDeletionScheduler
        self.friendService = friendService
        self.deviceSessionService = deviceSessionService
        self.backupService = backupService
        self.safetyService = safetyService
        self.callService = callService
        self.systemHealthManager = systemHealthManager
        self.onBack = onBack
        self.onSignOut = onSignOut
        _viewModel = StateObject(
            wrappedValue: SettingsViewModel(
                authService: authService,
                keyService: keyService,
                localPersistence: localPersistence
            )
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    profileCard

                    adaptivePrimarySections

                    settingsSection(title: "SYSTEM / TOOLS", rows: systemToolRows)

                    settingsSection(
                        title: "SUPPORT",
                        rows: [
                            row(icon: "questionmark.circle", title: "Help and feedback", subtitle: "Get help or share feedback", destination: .helpAndFeedback),
                            row(icon: "person.2", title: "Invite a friend", subtitle: "Invite friends to join OneWay", destination: .inviteFriend),
                            row(icon: "square.stack.3d.up", title: "Imported clone pages", subtitle: "View and manage imported pages", destination: .importedPages)
                        ]
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 36)
            }
            .background { SettingsReferenceBackground() }
            .safeAreaPadding(.bottom, 16)
            .navigationDestination(for: Destination.self) { destination in
                destinationView(for: destination)
            }
            .task {
                await viewModel.load()
                await loadProfilePhoto()
                await loadMyStory()
            }
            .onReceive(NotificationCenter.default.publisher(for: .oneWayStoryDidChange)) { _ in
                Task { await loadMyStory() }
            }
            .onChange(of: selectedProfilePhotoItem) { _, item in
                guard let item else { return }
                Task { await applySelectedProfilePhoto(item) }
            }
            .photosPicker(isPresented: $isShowingPhotoPicker, selection: $selectedProfilePhotoItem, matching: .images)
            .alert("Settings", isPresented: errorAlertBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("Profile photo updated.", isPresented: $didUpdateProfilePhoto) {
                Button("OK") {}
            }
            .fullScreenCover(isPresented: $isShowingProfileCamera) {
                CameraCaptureView { image in
                    guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                    profilePhotoData = data
                    Task {
                        do {
                            try await storyService.saveMyProfilePhoto(data)
                            didUpdateProfilePhoto = true
                        } catch {
                            viewModel.errorMessage = "Failed to save profile photo."
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingMyStoryViewer) {
                if let myStory {
                    StoryViewerSheetView(story: myStory)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            MarketplaceBackButton(action: onBack)

            Text("Settings")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var adaptivePrimarySections: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                profileCoreSection
                    .frame(minWidth: 300)
                privacyCommunicationSection
                    .frame(minWidth: 300)
            }

            VStack(alignment: .leading, spacing: 16) {
                profileCoreSection
                privacyCommunicationSection
            }
        }
    }

    private var profileCoreSection: some View {
        settingsSection(
            title: "PROFILE / CORE",
            rows: [
                row(icon: "lock.shield", title: "Account", subtitle: "Manage your account and security", destination: .account),
                row(icon: "button.programmable", title: "OneWay Button & Automations", subtitle: "Customize actions and automations", destination: .oneWayButtonAutomations),
                row(icon: "number.circle.fill", title: "My Numbers", subtitle: "Manage your phone numbers", destination: .myNumbers),
                row(icon: "wallet.pass.fill", title: "Wallet", subtitle: "Secure payments and balance", destination: .walletShortcut)
            ]
        )
    }

    private var privacyCommunicationSection: some View {
        settingsSection(
            title: "PRIVACY / COMMUNICATION",
            rows: [
                row(icon: "lock.shield", title: "Privacy & Identity", subtitle: "Control your privacy and identity", destination: .privacy),
                row(icon: "dot.radiowaves.left.and.right", title: "Chirp Permissions", subtitle: "Manage device and app permissions", destination: .walkiePermissions),
                row(icon: "checkmark.shield", title: "Spam Protection", subtitle: "Keep your inbox safe", destination: .spamProtection),
                row(icon: "bubble.left.and.bubble.right", title: "Chats", subtitle: "Manage your conversations", destination: .chats),
                row(icon: "bell", title: "Notifications", subtitle: "Manage alerts and preferences", destination: .notifications)
            ]
        )
    }

    private var systemToolRows: [SettingsRow] {
        let rows = [
            row(icon: "arrow.up.arrow.down", title: "Storage and data", subtitle: "Manage storage and data usage", destination: .storageAndData),
            row(icon: "waveform.path.ecg", title: "Diagnostics", subtitle: "Monitor app health and performance", destination: .diagnostics)
        ]
        return rows
    }

    private var profileCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 17) {
                Button {
                        if myStory != nil {
                            isShowingMyStoryViewer = true
                        } else {
                            isShowingPhotoPicker = true
                        }
                    } label: {
                        Circle()
                            .fill(OneWayDesignSystem.Colors.panelElevated)
                            .frame(width: 65, height: 65)
                            .overlay {
                                if let data = profilePhotoData, let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .clipShape(Circle())
                                } else {
                                    Text(initials(for: viewModel.profileText))
                                        .font(.system(size: 27, weight: .black, design: .rounded))
                                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                                }
                            }
                            .overlay(Circle().stroke(OneWayDesignSystem.Colors.purpleGlow, lineWidth: 1))
                            .overlay(alignment: .bottomTrailing) {
                                Circle()
                                    .fill(OneWayDesignSystem.Colors.deepPurple)
                                    .frame(width: 29, height: 29)
                                    .overlay {
                                        OneWayResolvedIcon(systemName: "camera.fill")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)
                                    }
                                    .overlay(Circle().stroke(Color.blue, lineWidth: 1))
                            }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(myStory == nil ? "Choose profile photo" : "View my story")

                NavigationLink(value: Destination.identityDetails) {
                    HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.profileText)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(OneWayDesignSystem.Colors.text)
                            .lineLimit(1)
                        Text(viewModel.profileSubtitle)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    OneWayResolvedIcon(systemName: "chevron.right")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.profile")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)

            Divider()
                .overlay(OneWayDesignSystem.Colors.border.opacity(0.55))
                .padding(.leading, 100)

            HStack(spacing: 0) {
                Button { isShowingProfileCamera = true } label: {
                    profilePhotoAction("Take Photo", icon: "camera.fill")
                }
                .buttonStyle(.plain)

                Rectangle()
                    .fill(OneWayDesignSystem.Colors.border.opacity(0.45))
                    .frame(width: 1, height: 25)

                Button { isShowingPhotoPicker = true } label: {
                    profilePhotoAction("Choose Photo", icon: "photo.on.rectangle")
                }
                .buttonStyle(.plain)
            }
            .frame(height: 45)
        }
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(OneWayDesignSystem.Colors.panelGlass)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(OneWayDesignSystem.Colors.purpleGlow.opacity(0.7), lineWidth: 1)
                )
                .shadow(color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.14), radius: 20, y: 10)
        )
    }

    private func profilePhotoAction(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)
            Text(title)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadProfilePhoto() async {
        do {
            profilePhotoData = try await storyService.loadMyProfilePhoto()
        } catch {
            viewModel.errorMessage = "Failed to load profile photo."
        }
    }

    private func loadMyStory() async {
        myStory = try? await storyService.fetchMyStory()
    }

    private func applySelectedProfilePhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            viewModel.errorMessage = "Could not read selected image."
            return
        }

        profilePhotoData = data
        do {
            try await storyService.saveMyProfilePhoto(data)
            didUpdateProfilePhoto = true
        } catch {
            viewModel.errorMessage = "Failed to save profile photo."
        }
    }

    private func settingsSection(title: String, rows: [SettingsRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(OneWayDesignSystem.Colors.purplePrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.leading, 10)

            settingsGroup(rows)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func settingsGroup(_ rows: [SettingsRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                NavigationLink(value: item.destination) {
                    HStack(spacing: 10) {
                        OneWayResolvedIcon(systemName: item.icon)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)
                            .frame(width: 38, height: 38)
                            .background(OneWayDesignSystem.Colors.deepPurple.opacity(0.74), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(OneWayDesignSystem.Colors.border.opacity(0.7), lineWidth: 0.7)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(OneWayDesignSystem.Colors.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Text(item.subtitle)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }

                        Spacer(minLength: 3)

                        OneWayResolvedIcon(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(item.accessibilityIdentifier)

                if index < rows.count - 1 {
                    Divider()
                        .overlay(OneWayDesignSystem.Colors.border.opacity(0.5))
                        .padding(.leading, 52)
                        .padding(.trailing, 12)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OneWayDesignSystem.Colors.panelGlass)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OneWayDesignSystem.Colors.border.opacity(0.72), lineWidth: 1)
                )
        )
    }

    private func row(icon: String, title: String, subtitle: String, destination: Destination) -> SettingsRow {
        SettingsRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            destination: destination,
            accessibilityIdentifier: destination == .account ? "settings.account" : "settings.row.\(title)"
        )
    }

    @ViewBuilder
    private func destinationView(for destination: Destination) -> some View {
        switch destination {
        case .identityDetails:
            OneWayContactIdentitiesView()
        case .profile:
            ProfileView(
                authService: authService,
                keyService: keyService,
                localPersistence: localPersistence,
                storyService: storyService,
                accountDeletionScheduler: accountDeletionScheduler
            )
        case .lists:
            ListsView()
        case .broadcastMessages:
            BroadcastMessagesView()
        case .starred:
            StarredMessagesView()
        case .linkedDevices:
            DeviceSessionsView(service: deviceSessionService)
        case .account:
            AccountView(
                storyService: storyService,
                safetyService: safetyService,
                onSignOut: onSignOut
            )
        case .oneWayButtonAutomations:
            OneWayAutomationSettingsView()
        case .myNumbers:
            MyNumbersView()
        case .walletShortcut:
            WalletShortcutSettingsView()
        case .privacy:
            PrivacyIdentityView()
        case .walkiePermissions:
            WalkiePermissionsView()
        case .spamProtection:
            SpamProtectionView(service: safetyService)
        case .chats:
            ChatSettingsDetailView(cachePolicyText: viewModel.cachePolicyText)
        case .notifications:
            NotificationsDetailView()
        case .storageAndData:
            StorageDataDetailView(
                cachePolicyText: viewModel.cachePolicyText,
                onClearLocalData: { viewModel.clearLocalData() },
                backupService: backupService
            )
        case .platformReadiness:
            OneWayPlatformReadinessView()
        case .helpAndFeedback:
            HelpFeedbackView()
        case .inviteFriend:
            AddFriendView(friendService: friendService, ownsNavigationStack: false)
        case .importedPages:
            ImportedClonePagesView(
                messagingService: messagingService,
                friendService: friendService,
                groupService: groupService,
                contactImportService: contactImportService,
                importedContactsStore: importedContactsStore,
                callService: callService,
                communityService: communityService,
                cryptoService: cryptoService,
                authService: authService,
                keyService: keyService,
                localPersistence: localPersistence,
                accountDeletionScheduler: accountDeletionScheduler
            )
        case .diagnostics:
            DiagnosticsView(systemHealthManager: systemHealthManager)
        case .developerQA:
            DeveloperQAView(communityService: communityService)
        }
    }

    private func initials(for name: String) -> String {
        let comps = name.split(separator: " ")
        let chars = comps.prefix(2).compactMap { $0.first }
        return chars.isEmpty ? "U" : String(chars)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )
    }

#if DEBUG
    private var debugAPIDiagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Diagnostics")
                .font(.headline)
            HStack {
                Text("Base URL")
                Spacer()
                Text(APIConfig.baseURL)
                    .font(.footnote)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Health")
                Spacer()
                Text(apiHealthStatus)
                    .font(.footnote)
                    .multilineTextAlignment(.trailing)
            }
            Button("Ping /health") {
                Task { await pingHealth() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .font(.footnote.weight(.semibold))
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pingHealth() async {
        let url = URL(string: APIConfig.baseURL)!.appendingPathComponent("health")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 200 {
                let body = String(data: data, encoding: .utf8) ?? "{}"
                apiHealthStatus = "OK \(http.statusCode) \(body)"
            } else {
                apiHealthStatus = "Fail \(http.statusCode)"
            }
        } catch {
            apiHealthStatus = "Error: \(error.localizedDescription)"
        }
    }
#endif
}

private struct SettingsRow {
    let icon: String
    let title: String
    let subtitle: String
    let destination: SettingsView.Destination
    let accessibilityIdentifier: String
}

private struct SettingsReferenceBackground: View {
    var body: some View {
        ZStack {
            Color(hex: 0x040611)

            LinearGradient(
                colors: [
                    Color(hex: 0x050713),
                    Color(hex: 0x08091C),
                    Color(hex: 0x0C0925),
                    Color(hex: 0x12082F)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    OneWayDesignSystem.Colors.purplePrimary.opacity(0.16),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 330
            )

            RadialGradient(
                colors: [
                    Color(hex: 0x5030C8).opacity(0.12),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 30,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

private struct OneWayContactIdentitiesView: View {
    @State private var identity: OneWayIdentity?
    @State private var numbers: [OneWayNumber] = []
    @State private var accountEmail: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your OneWay Contact IDs")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                    Text("Every address and number people can use to reach you on OneWay.")
                        .font(.body.weight(.medium))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                }

                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                            .tint(OneWayDesignSystem.Colors.purpleGlow)
                        Text("Loading your contact IDs…")
                            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                    }
                    .identityCard()
                } else {
                    identitySection(
                        title: "OneWay IDs",
                        icon: "person.text.rectangle.fill",
                        values: oneWayIDs
                    )
                    identitySection(
                        title: "Numbers",
                        icon: "number.circle.fill",
                        values: numberValues
                    )
                    identitySection(
                        title: "Chirp",
                        icon: "dot.radiowaves.left.and.right",
                        values: chirpValues
                    )
                    identitySection(
                        title: "Email",
                        icon: "envelope.fill",
                        values: emailValues
                    )
                }

                if let errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(errorMessage)
                            .foregroundStyle(Color.red.opacity(0.9))
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                            .tint(OneWayDesignSystem.Colors.purplePrimary)
                    }
                    .identityCard()
                }
            }
            .padding(18)
            .padding(.bottom, 44)
        }
        .background { SettingsReferenceBackground() }
        .navigationTitle("My Contact IDs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var oneWayIDs: [(String, String)] {
        guard let identity else { return [] }
        var values = [("OneWay ID", identity.onewayId)]
        if let username = identity.username, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(("Username", username.hasPrefix("@") ? username : "@\(username)"))
        }
        return values
    }

    private var numberValues: [(String, String)] {
        numbers.map { number in
            let label = number.isPrimary ? "Primary OneWay number" : (number.label ?? "OneWay number")
            return (label, number.number)
        }
    }

    private var chirpValues: [(String, String)] {
        guard let chirp = identity?.chirpId.trimmingCharacters(in: .whitespacesAndNewlines), !chirp.isEmpty else { return [] }
        return [("Chirp number", chirp)]
    }

    private var emailValues: [(String, String)] {
        var values: [(String, String)] = []
        if let alias = identity?.emailAlias.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            values.append(("OneWay email", alias))
        }
        if let accountEmail = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountEmail.isEmpty,
           !values.contains(where: { $0.1.caseInsensitiveCompare(accountEmail) == .orderedSame }) {
            values.append(("Account email", accountEmail))
        }
        return values
    }

    @ViewBuilder
    private func identitySection(title: String, icon: String, values: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            OneWayResolvedLabel(title, systemImage: icon)
                .font(.title3.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)

            if values.isEmpty {
                Text("No \(title.lowercased()) assigned yet.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    if index > 0 {
                        Divider().overlay(OneWayDesignSystem.Colors.border.opacity(0.55))
                    }
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(value.0)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                            Text(value.1)
                                .font(.system(.body, design: .rounded, weight: .bold))
                                .foregroundStyle(OneWayDesignSystem.Colors.text)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Button {
                            UIPasteboard.general.string = value.1
                        } label: {
                            OneWayResolvedIcon(systemName: "doc.on.doc")
                                .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)
                                .frame(width: 44, height: 44)
                                .background(OneWayDesignSystem.Colors.deepPurple.opacity(0.75), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Copy \(value.0)")
                    }
                }
            }
        }
        .identityCard()
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let identityRequest = OneWayIdentityService.shared.fetchMyIdentity()
            async let numbersRequest = OneWayNumberService.shared.fetchMyNumbers()
            async let userRequest = AuthAPIService.shared.currentAuthenticatedUser()
            let (loadedIdentity, loadedNumbers, loadedUser) = try await (identityRequest, numbersRequest, userRequest)
            identity = loadedIdentity
            numbers = loadedNumbers.numbers
            accountEmail = loadedUser.email
        } catch {
            errorMessage = "We couldn't load all of your OneWay contact IDs. Check your connection and try again."
        }
        isLoading = false
    }
}

private extension View {
    func identityCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                OneWayDesignSystem.Colors.panelGlass,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(OneWayDesignSystem.Colors.purpleGlow.opacity(0.55), lineWidth: 1)
            )
    }
}

private struct ListsView: View {
    @State private var customLists: [String] = []

    var body: some View {
        List {
            Section("Smart Lists") {
                OneWayResolvedLabel("Unread", systemImage: "envelope.badge")
                OneWayResolvedLabel("Groups", systemImage: "person.3")
                OneWayResolvedLabel("Pinned", systemImage: "pin")
            }
            if !customLists.isEmpty {
                Section("Custom") {
                    ForEach(customLists, id: \.self) { list in
                        Text(list)
                    }
                }
            }
            Section("Create") {
                Button("New Custom List") {
                    customLists.append("Custom \(customLists.count + 1)")
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .navigationTitle("Lists")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

private struct BroadcastMessagesView: View {
    @State private var message = ""
    @State private var didSend = false

    var body: some View {
        Form {
            Section("Compose") {
                TextField("Broadcast message", text: $message, axis: .vertical)
                    .lineLimit(3...6)
            }
            Section("Audience") {
                OneWayResolvedLabel("Friends only", systemImage: "person.2")
                OneWayResolvedLabel("No pending contacts", systemImage: "checkmark.seal")
            }
            Section {
                Button("Send Broadcast") {
                    didSend = true
                    message = ""
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Broadcast")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .alert("Broadcast sent to friends.", isPresented: $didSend) {
            Button("OK") {}
        }
    }
}

private struct StarredMessagesView: View {
    var body: some View {
        List {
            Section("Starred") {
                OneWayResolvedLabel("No starred messages yet.", systemImage: "star")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Starred")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

private struct HelpFeedbackView: View {
    @State private var feedback = ""

    var body: some View {
        Form {
            Section("Help") {
                OneWayResolvedLabel("FAQ", systemImage: "questionmark.circle")
                OneWayResolvedLabel("Contact Support", systemImage: "headphones")
                OneWayResolvedLabel("Safety Report", systemImage: "exclamationmark.shield")
            }
            Section("Feedback") {
                TextField("Tell us what to improve...", text: $feedback, axis: .vertical)
                    .lineLimit(3...5)
                Button("Send Feedback") {
                    feedback = ""
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Help & Feedback")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

private struct DiagnosticsView: View {
    let systemHealthManager: SystemHealthManager
    @State private var statuses: [ServiceHealthStatus] = []
    @State private var bridgePreflight: PSTNBridgePreflight?
    @State private var bridgeStatusError: String?
    @State private var isRefreshingBridge = false

    var body: some View {
        List {
            Section("OneWay Bridge Status") {
                if let preflight = bridgePreflight {
                    diagnosticRow("Provider", value: preflight.provider)
                    diagnosticRow("Mode", value: preflight.mode)
                    diagnosticRow("LiveKit Configured", value: yesNo(preflight.liveKitConfigured))
                    diagnosticRow("SIP Trunk Configured", value: yesNo(preflight.sipTrunkConfigured))
                    diagnosticRow("Provider Configured", value: yesNo(preflight.providerConfigured))
                    diagnosticRow("Webhook Configured", value: yesNo(preflight.webhookBaseUrlConfigured))
                    diagnosticRow("Media Bridge Enabled", value: yesNo(preflight.mediaBridgeEnabled))

                    if !preflight.missing.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Missing Env")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(preflight.missing, id: \.self) { item in
                                Text("• \(item)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if !preflight.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Warnings")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(preflight.warnings, id: \.self) { warning in
                                Text("• \(warning)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else if let bridgeStatusError {
                    Text("Bridge status unavailable: \(bridgeStatusError)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text("Loading OneWay Bridge status…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(isRefreshingBridge ? "Refreshing Bridge Status…" : "Refresh Bridge Status") {
                    Task { await refreshBridgeStatus() }
                }
                .disabled(isRefreshingBridge)
            }

            Section("Service Health") {
                if statuses.isEmpty {
                    Text("No verified service checks are available.")
                        .foregroundStyle(.secondary)
                }
                ForEach(statuses.filter { !$0.serviceName.lowercased().contains("stub") }) { status in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(status.serviceName)
                                .font(.headline)
                            Spacer()
                            Circle()
                                .fill(status.isActive ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                        }
                        Text("Last check: \(status.lastCheckedAt.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = status.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if let sync = status.lastSyncAt {
                            Text("Last sync: \(sync.formatted())")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if !status.dependencies.isEmpty {
                            let deps = status.dependencies.joined(separator: ", ")
                            Text("Depends on: \(deps)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Application") {
                diagnosticRow("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                diagnosticRow("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")
                diagnosticRow("Environment", value: Self.environmentName)
            }
        }
        .navigationTitle("Diagnostics")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .task {
            await refreshDiagnostics()
        }
    }

    private func refreshDiagnostics() async {
        async let serviceStatuses = systemHealthManager.runStartupChecks()
        statuses = await serviceStatuses
        await refreshBridgeStatus()
    }

    private func refreshBridgeStatus() async {
        guard !isRefreshingBridge else { return }
        isRefreshingBridge = true
        defer { isRefreshingBridge = false }

        do {
            let preflight = try await PSTNBridgePreflightService.shared.fetchStatus()
            bridgePreflight = preflight
            bridgeStatusError = nil
        } catch {
            bridgePreflight = nil
            bridgeStatusError = error.localizedDescription
        }
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private static var environmentName: String {
        #if DEBUG
        return "Development"
        #else
        return "Production"
        #endif
    }
}

private struct AccountSettingsDetailView: View {
    let cachePolicyText: String
    let onAccountDeleted: () -> Void

    var body: some View {
        Form {
            Section("Local Storage") {
                LabeledContent("Message cache policy", value: cachePolicyText)
            }

        }
        .navigationTitle("Account")
        .scrollContentBackground(.hidden)
        .background {
            SideMenuBackground()
        }
    }
}

private struct SpamProtectionView: View {
    let service: SafetyService

    @State private var suspectHandle = ""
    @State private var reportReason = "Spam / scam"
    @State private var alsoReport = true
    @State private var blockedHandles: [String] = []
    @State private var infoMessage: String?
    @State private var isSaving = false
    @State private var isLoading = false

    var body: some View {
        Form {
            Section("Instant Cutoff") {
                TextField("@handle", text: $suspectHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Toggle("Also report this account", isOn: $alsoReport)
                if alsoReport {
                    TextField("Report reason", text: $reportReason)
                }

                Button("Block Immediately", role: .destructive) {
                    Task { await blockNow() }
                }
                .disabled(isSaving || suspectHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text("This instantly blocks the account from communicating with you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Blocked Accounts") {
                if blockedHandles.isEmpty {
                    Text("No blocked accounts yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(blockedHandles, id: \.self) { handle in
                        Text(handle)
                    }
                }
            }

            if let infoMessage {
                Section("Status") {
                    Text(infoMessage)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Spam Protection")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .task {
            await refreshBlocked()
        }
    }

    private func blockNow() async {
        let handle = suspectHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            try await service.block(handle: handle)
            if alsoReport {
                try await service.report(handle: handle, reason: reportReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Spam / scam" : reportReason)
            }
            infoMessage = "Blocked \(handle) immediately."
            suspectHandle = ""
            await refreshBlocked()
        } catch {
            infoMessage = "Unable to block this account right now."
        }
    }

    private func refreshBlocked() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            blockedHandles = try await service.fetchBlockedHandles()
        } catch {
            infoMessage = "Unable to load blocked accounts. Pull back and retry when connected."
        }
    }
}

private struct ChatSettingsDetailView: View {
    let cachePolicyText: String

    var body: some View {
        Form {
            Section("Chats") {
                LabeledContent("Message cache policy", value: cachePolicyText)
                Text("Additional chat defaults are unavailable until they are enforced by the messaging service.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Chats")
        .scrollContentBackground(.hidden)
        .background {
            SideMenuBackground()
        }
    }
}

private struct NotificationsDetailView: View {
    @AppStorage(OneWayNotificationPreferences.enabledKey) private var messagesEnabled = true
    @AppStorage(OneWayNotificationPreferences.previewsKey) private var previews = true
    @AppStorage(OneWayNotificationPreferences.soundsKey) private var sounds = true
    @AppStorage(OneWayNotificationPreferences.vibrationKey) private var vibration = true
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section("iOS Permission") {
                LabeledContent("System notifications", value: authorizationLabel)
                if authorizationStatus == .denied {
                    Button("Open iPhone Settings") { openSystemSettings() }
                }
            }
            Section("Notifications") {
                Toggle("Message Notifications", isOn: $messagesEnabled)
                Toggle("Message Previews", isOn: $previews)
                    .disabled(!messagesEnabled)
                Toggle("Sounds", isOn: $sounds)
                    .disabled(!messagesEnabled)
                Toggle("Vibration", isOn: $vibration)
                    .disabled(!messagesEnabled)
            }
        }
        .navigationTitle("Notifications")
        .scrollContentBackground(.hidden)
        .background {
            SideMenuBackground()
        }
        .onChange(of: messagesEnabled) { _, _ in AppDelegate.shared.refreshAlertNotificationPreferences() }
        .onChange(of: previews) { _, _ in AppDelegate.shared.refreshAlertNotificationPreferences() }
        .onChange(of: sounds) { _, _ in AppDelegate.shared.refreshAlertNotificationPreferences() }
        .task { await refreshAuthorizationStatus() }
    }

    private var authorizationLabel: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Disabled in iOS"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    private func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct WalletShortcutSettingsView: View {
    @AppStorage("oneway.walletShortcut.visible") private var showEverywhere = true
    @AppStorage("oneway.walletShortcut.hideDuringCalls") private var hideDuringCalls = true

    var body: some View {
        Form {
            Section("Global Wallet Shortcut") {
                Toggle("Show on every page", isOn: $showEverywhere)
            }

            Section("Safety") {
                Toggle("Hide during calls", isOn: $hideDuringCalls)
            }

            Section {
                Text("The global shortcut loads only lightweight status and never exposes balances before Wallet authentication.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Wallet")
        .scrollContentBackground(.hidden)
        .background {
            SideMenuBackground()
        }
    }
}

private struct StorageDataDetailView: View {
    let cachePolicyText: String
    let onClearLocalData: () -> Void
    let backupService: BackupService

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Cache policy", value: cachePolicyText)
                Button("Clear Cache") {
                    onClearLocalData()
                }
                Text("Removes reproducible in-memory chat summaries and encrypted payload cache only. Account credentials and keys are preserved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Availability") {
                Text("Media management, cellular download controls, and encrypted backup are hidden until their storage services enforce them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Storage and Data")
        .scrollContentBackground(.hidden)
        .background {
            SideMenuBackground()
        }
    }
}
