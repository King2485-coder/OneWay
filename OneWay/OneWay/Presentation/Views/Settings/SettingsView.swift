import SwiftUI
import Combine
import PhotosUI
import UIKit

struct SettingsView: View {
    enum Destination: Hashable {
        case profile
        case avatar
        case lists
        case broadcastMessages
        case starred
        case linkedDevices
        case account
        case privacy
        case spamProtection
        case chats
        case notifications
        case storageAndData
        case helpAndFeedback
        case inviteFriend
        case importedPages
        case diagnostics
    }

    @AppStorage("burn_button_enabled") private var burnButtonEnabled = false
    @StateObject private var viewModel: SettingsViewModel
    @State private var selectedProfilePhotoItem: PhotosPickerItem?
    @State private var isShowingPhotoPicker = false
    @State private var profilePhotoData: Data?
    @State private var myStory: StoryItem?
    @State private var isShowingMyStoryViewer = false
    @State private var didUpdateProfilePhoto = false
    @State private var isShowingProfileCamera = false
    @State private var apiHealthStatus: String = "Unknown"

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
        systemHealthManager: SystemHealthManager
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
        _viewModel = StateObject(
            wrappedValue: SettingsViewModel(
                authService: authService,
                keyService: keyService,
                localPersistence: localPersistence
            )
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    profileCard

#if DEBUG
                    debugAPIDiagnostics
#endif

                    settingsGroup([
                        row(icon: "rectangle.stack.badge.person.crop", title: "Lists", destination: .lists),
                        row(icon: "megaphone", title: "Broadcast messages", destination: .broadcastMessages),
                        row(icon: "star", title: "Starred", destination: .starred),
                        row(icon: "laptopcomputer", title: "Linked devices", destination: .linkedDevices)
                    ])

                    settingsGroup([
                        row(icon: "key", title: "Account", destination: .account),
                        row(icon: "lock", title: "Privacy", destination: .privacy),
                        row(icon: "exclamationmark.shield", title: "Spam Protection", destination: .spamProtection),
                        row(icon: "bubble.left", title: "Chats", destination: .chats),
                        row(icon: "app.badge", title: "Notifications", destination: .notifications),
                        row(icon: "arrow.up.arrow.down", title: "Storage and data", destination: .storageAndData),
                        row(icon: "waveform.path.ecg", title: "Diagnostics", destination: .diagnostics)
                    ])

                    settingsGroup([
                        row(icon: "questionmark.circle", title: "Help and feedback", destination: .helpAndFeedback),
                        row(icon: "person.2", title: "Invite a friend", destination: .inviteFriend),
                        row(icon: "square.stack.3d.up", title: "Imported clone pages", destination: .importedPages)
                    ])
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .background { SideMenuBackground() }
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
        HStack {
            Color.clear
                .frame(width: 44, height: 44)

            Spacer()

            Text("Settings")
                .font(.system(size: 58, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.top, 8)
    }

    private var profileCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 10) {
                    Button {
                        if myStory != nil {
                            isShowingMyStoryViewer = true
                        } else {
                            isShowingPhotoPicker = true
                        }
                    } label: {
                        Circle()
                            .fill(Theme.glassSurface)
                            .frame(width: 88, height: 88)
                            .overlay {
                                if let data = profilePhotoData, let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .clipShape(Circle())
                                } else {
                                    Text(initials(for: viewModel.profileText))
                                        .font(.title.weight(.bold))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Circle()
                                    .fill(Theme.primaryBlue)
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        Image(systemName: "camera.fill")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                    .shadow(color: Theme.primaryBlue.opacity(0.3), radius: 5, x: 0, y: 2)
                            }
                    }
                    .buttonStyle(.plain)

                    NavigationLink(value: Destination.profile) {
                        VStack(spacing: 3) {
                            Text(viewModel.profileText)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text("Hello. I'm using OneWay.")
                                .font(.title3)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.plain)

                    Button {
                        isShowingProfileCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        isShowingPhotoPicker = true
                    } label: {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                EmptyView()
            }
            .padding(16)

            Divider().overlay(Theme.divider)

            NavigationLink(value: Destination.avatar) {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.badge.sparkles")
                        .font(.title3)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avatar Studio")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Advanced identity controls")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.divider, lineWidth: 1))
        )
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

    private func settingsGroup(_ rows: [SettingsRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                NavigationLink(value: item.destination) {
                    HStack(spacing: 14) {
                        Image(systemName: item.icon)
                            .font(.title3)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 30)
                        Text(item.title)
                            .font(.system(size: 23, weight: .regular))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.headline)
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < rows.count - 1 {
                    Divider()
                        .overlay(Theme.divider)
                        .padding(.leading, 60)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.divider, lineWidth: 1))
        )
    }

    private func row(icon: String, title: String, destination: Destination) -> SettingsRow {
        SettingsRow(icon: icon, title: title, destination: destination)
    }

    @ViewBuilder
    private func destinationView(for destination: Destination) -> some View {
        switch destination {
        case .profile:
            ProfileView(
                authService: authService,
                keyService: keyService,
                localPersistence: localPersistence,
                storyService: storyService,
                accountDeletionScheduler: accountDeletionScheduler
            )
        case .avatar:
            AvatarStudioView()
        case .lists:
            ListsView()
        case .broadcastMessages:
            BroadcastMessagesView()
        case .starred:
            StarredMessagesView()
        case .linkedDevices:
            DeviceSessionsView(service: deviceSessionService)
        case .account:
            AccountSettingsDetailView(
                burnButtonEnabled: $burnButtonEnabled,
                cachePolicyText: viewModel.cachePolicyText
            )
        case .privacy:
            SafetyCenterView(service: safetyService)
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
        case .helpAndFeedback:
            HelpFeedbackView()
        case .inviteFriend:
            AddFriendView(friendService: friendService)
        case .importedPages:
            ImportedClonePagesView(
                messagingService: messagingService,
                friendService: friendService,
                storyService: storyService,
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
    let destination: SettingsView.Destination
}

private struct ListsView: View {
    @State private var customLists: [String] = []

    var body: some View {
        List {
            Section("Smart Lists") {
                Label("Unread", systemImage: "envelope.badge")
                Label("Groups", systemImage: "person.3")
                Label("Pinned", systemImage: "pin")
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
                Label("Friends only", systemImage: "person.2")
                Label("No pending contacts", systemImage: "checkmark.seal")
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
                Label("No starred messages yet.", systemImage: "star")
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
                Label("FAQ", systemImage: "questionmark.circle")
                Label("Contact Support", systemImage: "headphones")
                Label("Safety Report", systemImage: "exclamationmark.shield")
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

    var body: some View {
        List {
            ForEach(statuses) { status in
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
        .navigationTitle("Diagnostics")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .task {
            statuses = await systemHealthManager.runStartupChecks()
        }
    }
}

private struct AccountSettingsDetailView: View {
    @Binding var burnButtonEnabled: Bool
    let cachePolicyText: String

    var body: some View {
        Form {
            Section("Account") {
                Toggle("Enable Burn Button", isOn: $burnButtonEnabled)
                Text("When enabled, a movable burn button is shown globally across tabs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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
                .disabled(suspectHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
        guard !handle.isEmpty else { return }

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
        blockedHandles = (try? await service.fetchBlockedHandles()) ?? []
    }
}

private struct ChatSettingsDetailView: View {
    let cachePolicyText: String

    var body: some View {
        Form {
            Section("Chats") {
                LabeledContent("Message cache policy", value: cachePolicyText)
                Toggle("Enter to Send", isOn: .constant(true))
                Toggle("Media Auto-Download", isOn: .constant(false))
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
    @State private var previews = true
    @State private var sounds = true
    @State private var vibration = true

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Message Previews", isOn: $previews)
                Toggle("Sounds", isOn: $sounds)
                Toggle("Vibration", isOn: $vibration)
            }
        }
        .navigationTitle("Notifications")
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
                Button("Clear local data") {
                    onClearLocalData()
                }
            }

            Section("Backup") {
                NavigationLink("Backup & Restore") {
                    BackupRestoreView(service: backupService)
                }
            }
        }
        .navigationTitle("Storage and Data")
        .scrollContentBackground(.hidden)
        .background {
            SideMenuBackground()
        }
    }
}
