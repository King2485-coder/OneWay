import SwiftUI

enum PlatformCommandRoute: Hashable {
    case messaging(OneWayPlatformCapabilityGroup)
    case calls(OneWayPlatformCapabilityGroup)
    case privacy(OneWayPlatformCapabilityGroup)
    case business(OneWayPlatformCapabilityGroup)
    case cloud(OneWayPlatformCapabilityGroup)
    case ai(OneWayPlatformCapabilityGroup)
    case workspace(OneWayPlatformCapabilityGroup)

    static func route(for group: OneWayPlatformCapabilityGroup) -> PlatformCommandRoute {
        switch group.title {
        case "Messaging": return .messaging(group)
        case "Voice and Video": return .calls(group)
        case "Privacy and Identity": return .privacy(group)
        case "Business, Sites, and Shops": return .business(group)
        case "Cloud, AI, and Workspace": return .cloud(group)
        default: return .messaging(group)
        }
    }
}

struct MessagingDetailView: View {
    let group: OneWayPlatformCapabilityGroup
    @State private var scheduled: [PlatformScheduledMessage] = []
    @State private var posts: [PlatformChannelPost] = []
    @State private var newScheduledText = ""
    @State private var newPostText = ""
    @State private var isLoading = false
    @State private var message: String?
    private let service: PlatformCapabilityService = NetworkPlatformCapabilityService()

    var body: some View {
        PlatformDetailScaffold(title: "Messaging Command", group: group, status: statusText, message: message, isLoading: isLoading) {
            PlatformActionCard(title: "Scheduled Messages", subtitle: "Create and review messages queued for later delivery.", icon: "calendar.badge.clock") {
                TextField("Write a message to schedule", text: $newScheduledText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Create Scheduled Message") { Task { await createScheduled() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.backgroundHighlight)
                PlatformList(items: scheduled.map { "\($0.body) • \($0.status)" }, empty: "No scheduled messages yet.")
            }

            PlatformActionCard(title: "Channel Posts", subtitle: "Start the public/private channel posting workflow.", icon: "megaphone.fill") {
                TextField("Write a channel post", text: $newPostText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Create Channel Post") { Task { await createPost() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.backgroundHighlight)
                PlatformList(items: posts.map { $0.body }, empty: "No channel posts yet.")
            }

            PlatformTodoCard(items: ["Message drafts", "Message pins", "Starred messages", "Polls", "Events"])
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var statusText: String { "\(scheduled.count) scheduled • \(posts.count) channel posts" }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let scheduledMessages = service.fetchScheduledMessages()
            async let channelPosts = service.fetchChannelPosts()
            scheduled = try await scheduledMessages
            posts = try await channelPosts
            message = nil
        } catch {
            message = "Messaging starter data is using local empty state until the backend is reachable."
        }
    }

    private func createScheduled() async {
        let text = newScheduledText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let created = try await service.createScheduledMessage(body: text, scheduledFor: Date().addingTimeInterval(3600).ISO8601Format())
            scheduled.insert(created, at: 0)
            newScheduledText = ""
            message = "Scheduled message created."
        } catch {
            message = "Could not create scheduled message yet."
        }
    }

    private func createPost() async {
        let text = newPostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let created = try await service.createChannelPost(body: text)
            posts.insert(created, at: 0)
            newPostText = ""
            message = "Channel post created."
        } catch {
            message = "Could not create channel post yet."
        }
    }
}

struct CallsDetailView: View {
    let group: OneWayPlatformCapabilityGroup

    var body: some View {
        PlatformDetailScaffold(title: "Calls Command", group: group, status: "LiveKit + PSTN + Chirp foundation active", message: nil, isLoading: false) {
            PlatformActionCard(title: "Call Stack", subtitle: "HD voice/video, CallKit, PSTN bridge, voicemail, recordings, and Chirp are routed through existing Calls screens.", icon: "phone.connection.fill") {
                PlatformList(items: ["Open Calls tab for keypad and recents", "Chirp is available in phone navigation", "Voicemail and recordings have dedicated screens"], empty: "")
            }
            PlatformTodoCard(items: ["Screen sharing requires provider support", "Live captions/transcription require AI media pipeline", "Virtual backgrounds require video effects pipeline"])
        }
    }
}

struct PrivacyDetailView: View {
    let group: OneWayPlatformCapabilityGroup
    @State private var settings = PlatformPrivacySettings.defaults
    @State private var isLoading = false
    @State private var message: String?
    private let service: PlatformCapabilityService = NetworkPlatformCapabilityService()

    var body: some View {
        PlatformDetailScaffold(title: "Privacy Center", group: group, status: "Privacy settings connected", message: message, isLoading: isLoading) {
            PlatformActionCard(title: "Private Identity", subtitle: "These controls persist through /api/platform/privacy.", icon: "lock.shield.fill") {
                Toggle("End-to-end encryption roadmap", isOn: $settings.endToEndEncryptionEnabled)
                    .disabled(true)
                Toggle("Chat Lock", isOn: $settings.chatLockEnabled)
                Toggle("Hide online status", isOn: $settings.hideOnlineStatus)
                Toggle("Hide last seen", isOn: $settings.hideLastSeen)
                Toggle("Hide read receipts", isOn: $settings.hideReadReceipts)
                Toggle("Hide typing indicators", isOn: $settings.hideTypingIndicators)
                Toggle("Hide phone number", isOn: $settings.hidePhoneNumber)
                Picker("Disappearing messages", selection: $settings.disappearingMessageTimer) {
                    Text("Off").tag("Off")
                    Text("24 hours").tag("24h")
                    Text("7 days").tag("7d")
                    Text("90 days").tag("90d")
                }
                Button("Save Privacy Settings") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.backgroundHighlight)
            }
            PlatformTodoCard(items: ["Linked device management detail", "Blocked users list", "Report history", "Security code verification", "Key rotation review"])
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await service.fetchPrivacySettings()
            message = nil
        } catch {
            message = "Using local privacy defaults until backend is reachable."
        }
    }

    private func save() async {
        do {
            settings = try await service.updatePrivacySettings(settings)
            message = "Privacy settings saved."
        } catch {
            message = "Could not save privacy settings yet."
        }
    }
}

struct BusinessSitesShopsDetailView: View {
    let group: OneWayPlatformCapabilityGroup

    var body: some View {
        PlatformDetailScaffold(title: "Business Center", group: group, status: "Shops and Sites connected in Business tab", message: nil, isLoading: false) {
            PlatformActionCard(title: "Revenue Tools", subtitle: "OneWay Shops, Sites, Shop Management, domains, orders, and AI builder now share the platform map.", icon: "briefcase.fill") {
                PlatformList(items: ["Business profile placeholder", "Product catalog placeholder", "Orders placeholder", "OneWay Sites dashboard", "AI site builder", "Storefront manager", "Custom domain settings"], empty: "")
            }
            PlatformTodoCard(items: ["Business verification provider", "Tax/shipping/payment provider abstraction", "Team inbox roles"])
        }
    }
}

struct CloudDetailView: View {
    let group: OneWayPlatformCapabilityGroup
    @State private var files: [PlatformCloudFile] = []
    @State private var newFileName = ""
    @State private var isLoading = false
    @State private var message: String?
    private let service: PlatformCapabilityService = NetworkPlatformCapabilityService()

    var body: some View {
        PlatformDetailScaffold(title: "OneWay Cloud", group: group, status: "\(files.count) file records", message: message, isLoading: isLoading) {
            OneWayCinematicAssetView(
                asset: .cloudCube,
                motion: .drift,
                intensity: 0.9
            )
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .padding(.horizontal, 18)
            .oneWayCinematicGlass(cornerRadius: 28)
            .accessibilityHidden(true)

            PlatformActionCard(title: "File Metadata", subtitle: "Create metadata now; encrypted binary upload is a future layer.", icon: "externaldrive.fill.badge.checkmark") {
                TextField("File name placeholder", text: $newFileName)
                    .textFieldStyle(.roundedBorder)
                Button("Create File Metadata") { Task { await createFile() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.backgroundHighlight)
                PlatformList(items: files.map { "\($0.name) • \($0.byteCount) bytes • metadata only" }, empty: "No cloud files yet.")
            }
            PlatformTodoCard(items: ["Upload binary object storage", "Folders", "Shared files", "Storage usage", "Secure expiring links"])
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            files = try await service.fetchCloudFiles()
            message = nil
        } catch {
            message = "Cloud file metadata is using an empty state until backend is reachable."
        }
    }

    private func createFile() async {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let file = try await service.createCloudFile(name: name, byteCount: 0)
            files.insert(file, at: 0)
            newFileName = ""
            message = "File metadata created."
        } catch {
            message = "Could not create file metadata yet."
        }
    }
}

struct AIDetailView: View {
    let group: OneWayPlatformCapabilityGroup
    @State private var logs: [PlatformAILogEntry] = []
    @State private var isLoading = false
    @State private var message: String?
    private let service: PlatformCapabilityService = NetworkPlatformCapabilityService()

    var body: some View {
        PlatformDetailScaffold(title: "AI Center", group: group, status: "\(logs.count) AI actions logged", message: message, isLoading: isLoading) {
            PlatformActionCard(title: "AI Permissions", subtitle: "OneWay AI must warn users whenever decrypted content is needed.", icon: "sparkles") {
                Text("AI can summarize chats, calls, websites, stores, and support requests only when the feature has permission to process the needed content.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                Button("Log Chat Summary Placeholder") { Task { await createLog() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.backgroundHighlight)
                PlatformList(items: logs.map { "\($0.action) • \($0.contentScope)" }, empty: "No AI actions logged yet.")
            }
            PlatformTodoCard(items: ["Chat summary", "Call summary", "Website builder handoff", "Storefront builder handoff", "Customer support AI", "Clear AI logs"])
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            logs = try await service.fetchAILogs()
            message = nil
        } catch {
            message = "AI logs are using an empty state until backend is reachable."
        }
    }

    private func createLog() async {
        do {
            let log = try await service.createAILog(action: "Chat summary placeholder", contentScope: "chat", requiresDecryptedContent: true)
            logs.insert(log, at: 0)
            message = "AI action logged."
        } catch {
            message = "Could not create AI log yet."
        }
    }
}

struct WorkspaceDetailView: View {
    let group: OneWayPlatformCapabilityGroup
    @State private var items: [PlatformWorkspaceItem] = []
    @State private var newTitle = ""
    @State private var selectedType = "task"
    @State private var isLoading = false
    @State private var message: String?
    private let service: PlatformCapabilityService = NetworkPlatformCapabilityService()

    var body: some View {
        PlatformDetailScaffold(title: "Workspace Center", group: group, status: "\(items.count) workspace items", message: message, isLoading: isLoading) {
            PlatformActionCard(title: "Team Work", subtitle: "Tasks, projects, notes, and announcements are backed by WorkspaceItem.", icon: "person.3.sequence.fill") {
                Picker("Type", selection: $selectedType) {
                    Text("Task").tag("task")
                    Text("Project").tag("project")
                    Text("Note").tag("note")
                    Text("Announcement").tag("announcement")
                }
                .pickerStyle(.segmented)
                TextField("New workspace item", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                Button("Create Workspace Item") { Task { await createItem() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.backgroundHighlight)
                PlatformList(items: items.map { "\($0.title) • \($0.type) • \($0.status)" }, empty: "No workspace items yet.")
            }
            PlatformTodoCard(items: ["Customer pipeline", "Shared calendar", "Whiteboard placeholder", "Department channels"])
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.fetchWorkspaceItems()
            message = nil
        } catch {
            message = "Workspace is using an empty state until backend is reachable."
        }
    }

    private func createItem() async {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let item = try await service.createWorkspaceItem(type: selectedType, title: title)
            items.insert(item, at: 0)
            newTitle = ""
            message = "Workspace item created."
        } catch {
            message = "Could not create workspace item yet."
        }
    }
}

struct PlatformDetailScaffold<Content: View>: View {
    let title: String
    let group: OneWayPlatformCapabilityGroup
    let status: String
    let message: String?
    let isLoading: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        OneWayResolvedIcon(systemName: group.icon)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Theme.accentGradient))
                        Spacer()
                        if isLoading {
                            ProgressView().tint(.white)
                        }
                    }
                    Text(group.promise)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(status)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.accentGold)
                    Text("\(group.completedCount)/\(group.totalCount) capabilities live or beta")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(18)
                .background(PlatformGlassBackground(cornerRadius: 28))

                if let message {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PlatformGlassBackground(cornerRadius: 18))
                }

                PlatformActionCard(title: "Feature Checklist", subtitle: "What this command center owns.", icon: "checklist") {
                    ForEach(group.capabilities) { capability in
                        HStack(alignment: .top, spacing: 10) {
                            OneWayResolvedIcon(systemName: capability.status == .planned ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(capability.status == .planned ? Theme.textMuted : Color.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(capability.title)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(capability.summary)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }

                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
        }
        .background { SideMenuBackground() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlatformActionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.backgroundHighlight)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.backgroundHighlight.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            content
        }
        .padding(16)
        .background(PlatformGlassBackground(cornerRadius: 24))
    }
}

struct PlatformList: View {
    let items: [String]
    let empty: String

    var body: some View {
        if items.isEmpty {
            Text(empty)
                .font(.callout)
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
                }
            }
        }
    }
}

struct PlatformTodoCard: View {
    let items: [String]

    var body: some View {
        PlatformActionCard(title: "Provider TODOs", subtitle: "Clearly gated work, not broken UX.", icon: "wrench.and.screwdriver.fill") {
            PlatformList(items: items.map { "TODO: \($0)" }, empty: "No external TODOs.")
        }
    }
}

struct PlatformGlassBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Theme.backgroundHighlight.opacity(0.75), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Theme.backgroundHighlight.opacity(0.16), radius: 16, x: 0, y: 8)
    }
}
