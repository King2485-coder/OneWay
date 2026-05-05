import SwiftUI
import PhotosUI
import Photos
import UIKit
import UniformTypeIdentifiers

struct UpdatesView: View {
    private enum Route: Hashable {
        case createStatus
        case channels
        case createChannel
    }

    private struct Channel: Identifiable {
        let id = UUID()
        let name: String
        let followers: String
        let isVerified: Bool
    }

    private let channels: [Channel] = [
        Channel(name: "One Way News", followers: "124K followers", isVerified: true),
        Channel(name: "Security Digest", followers: "89K followers", isVerified: true),
        Channel(name: "iOS Builders", followers: "41K followers", isVerified: false),
        Channel(name: "Community Drops", followers: "15K followers", isVerified: false)
    ]

    @State private var path: [Route] = []
    @State private var followedChannelIDs: Set<UUID> = []
    @State private var isShowingCameraCapture = false
    @State private var isShowingOverflowMenu = false
    @State private var isShowingStatusPrivacySheet = false
    @State private var isShowingMyStoryViewer = false
    @State private var pendingComposerMedia: StoryMedia?
    @State private var myStory: StoryItem?
    @State private var friendStories: [StoryItem] = []
    @State private var selectedFriendStory: StoryItem?
    @AppStorage("updates.viewedStoryIDs") private var viewedStoryIDsRaw = ""
    private let storyService: StoryService
    private let safetyService: SafetyService

    init(storyService: StoryService, safetyService: SafetyService) {
        self.storyService = storyService
        self.safetyService = safetyService
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        searchBar
                        statusSection
                        viewedUpdatesSection
                        channelsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
                }
                .background { SideMenuBackground() }
                .oneWayMenuBar()
                .navigationBarHidden(true)

                if isShowingOverflowMenu {
                    Rectangle()
                        .fill(Color.black.opacity(0.34))
                        .ignoresSafeArea()
                        .onTapGesture { isShowingOverflowMenu = false }

                    updatesOverflowMenu
                        .padding(.leading, 16)
                        .padding(.top, 82)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .createStatus:
                    UpdateStatusComposerView(
                        storyService: storyService,
                        safetyService: safetyService,
                        initialMedia: pendingComposerMedia
                    )
                case .channels:
                    ChannelsDirectoryView()
                case .createChannel:
                    CreateChannelView()
                }
            }
            .fullScreenCover(isPresented: $isShowingCameraCapture) {
                CameraCaptureView { image in
                    guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                    pendingComposerMedia = StoryMedia(
                        mediaType: .photo,
                        fileName: "status-camera.jpg",
                        byteCount: data.count,
                        payload: data
                    )
                    path.append(.createStatus)
                }
            }
            .sheet(isPresented: $isShowingStatusPrivacySheet) {
                StatusPrivacySheetView(safetyService: safetyService)
            }
            .sheet(isPresented: $isShowingMyStoryViewer) {
                if let myStory {
                    StoryViewerSheetView(story: myStory)
                }
            }
            .sheet(item: $selectedFriendStory) { story in
                StoryViewerSheetView(story: story)
            }
            .task {
                await refreshStories()
            }
            .onChange(of: path) { _, newPath in
                if newPath.isEmpty {
                    Task { await refreshStories() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .oneWayStoryDidChange)) { _ in
                Task { await refreshStories() }
            }
        }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(Theme.glassSurface)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                }
                .onTapGesture {
                    isShowingOverflowMenu.toggle()
                }

            Spacer()

            Text("Updates")
                .font(.system(size: 58, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Circle()
                .fill(Theme.primaryBlue)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .shadow(color: Theme.primaryBlue.opacity(0.28), radius: 8, x: 0, y: 3)
                .onTapGesture {
                    pendingComposerMedia = nil
                    path.append(.createStatus)
                }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            Text("Search")
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.glassSurface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.divider, lineWidth: 1))
        )
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 12) {
                Button {
                    if myStory != nil {
                        isShowingMyStoryViewer = true
                    } else {
                        pendingComposerMedia = nil
                        path.append(.createStatus)
                    }
                } label: {
                    Circle()
                        .fill(Theme.glassSurface)
                        .frame(width: 62, height: 62)
                        .overlay {
                            if let myStory, let media = myStory.media, media.mediaType == .photo, let image = UIImage(data: media.payload) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .clipShape(Circle())
                            } else {
                                Text(myStory == nil ? "Y" : String(myStory!.authorDisplayName.prefix(1)))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        .overlay {
                            Circle()
                                .stroke(myStory == nil ? Color.clear : Theme.primaryBlue, lineWidth: 2)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if myStory == nil {
                                Circle()
                                    .fill(Theme.primaryBlue)
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        Image(systemName: "plus")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                    }
                            }
                        }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(myStory == nil ? "Add status" : "Your status")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(myStory == nil ? "Disappears after 24 hours" : relativeTimeString(from: myStory!.createdAt))
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Circle()
                    .fill(Theme.glassSurface)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "camera.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .onTapGesture {
                        isShowingCameraCapture = true
                    }

                Circle()
                    .fill(Theme.glassSurface)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "pencil")
                            .font(.headline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .onTapGesture {
                        pendingComposerMedia = nil
                        path.append(.createStatus)
                    }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var viewedUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if friendStories.isEmpty {
                Text("No friend updates yet.")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)
            } else {
                if !unviewedFriendStories.isEmpty {
                    sectionHeader("Recent updates")
                    ForEach(unviewedFriendStories) { story in
                        Button {
                            openFriendStory(story)
                        } label: {
                            storyRow(story)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !viewedFriendStories.isEmpty {
                    sectionHeader("Viewed updates")
                    ForEach(viewedFriendStories) { story in
                        Button {
                            openFriendStory(story)
                        } label: {
                            storyRow(story, viewed: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Channels")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            Text("Stay updated on topics that matter to you. Find channels to follow below.")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)

            Text("Find channels to follow")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)

            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Theme.glassSurface)
                        .frame(width: 58, height: 58)
                        .overlay {
                            Text(String(channel.name.prefix(1)))
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(channel.name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)

                            if channel.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.cyan)
                                    .font(.caption)
                            }
                        }

                        Text(channel.followers)
                            .font(.title3)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()

                    Button(followedChannelIDs.contains(channel.id) ? "Following" : "Follow") {
                        if followedChannelIDs.contains(channel.id) {
                            followedChannelIDs.remove(channel.id)
                        } else {
                            followedChannelIDs.insert(channel.id)
                        }
                    }
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.green.opacity(0.3), in: Capsule())
                        .overlay(Capsule().stroke(Color.green.opacity(0.45), lineWidth: 1))
                }

                if index < channels.count - 1 {
                    Divider().overlay(Theme.divider).padding(.leading, 72)
                }
            }

            Button {
                path.append(.channels)
            } label: {
                HStack {
                    Image(systemName: "square.grid.2x2")
                    Text("Explore more")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .foregroundStyle(Theme.textPrimary)

            Button {
                path.append(.createChannel)
            } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("Create channel")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .foregroundStyle(Theme.textPrimary)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Theme.glassSurface)
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.divider, lineWidth: 1))
    }

    private func refreshStories() async {
        let my = try? await storyService.fetchMyStory()
        let friends = (try? await storyService.fetchFriendStories()) ?? []
        await MainActor.run {
            myStory = my
            friendStories = friends
        }
    }
    
    private var viewedStoryIDs: Set<String> {
        Set(viewedStoryIDsRaw.split(separator: ",").map(String.init))
    }

    private var unviewedFriendStories: [StoryItem] {
        friendStories.filter { !viewedStoryIDs.contains($0.id.uuidString) }
    }

    private var viewedFriendStories: [StoryItem] {
        friendStories.filter { viewedStoryIDs.contains($0.id.uuidString) }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.title.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }

    private func storyRow(_ story: StoryItem, viewed: Bool = false) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.glassSurface)
                .frame(width: 54, height: 54)
                .overlay {
                    if let media = story.media, media.mediaType == .photo, let image = UIImage(data: media.payload) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                    } else {
                        Text(String(story.authorDisplayName.prefix(1)))
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .overlay {
                    Circle()
                        .stroke(viewed ? Theme.divider : Theme.primaryBlue, lineWidth: 2)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(story.authorDisplayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(relativeTimeString(from: story.createdAt))
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func openFriendStory(_ story: StoryItem) {
        var ids = viewedStoryIDs
        ids.insert(story.id.uuidString)
        viewedStoryIDsRaw = ids.sorted().joined(separator: ",")
        selectedFriendStory = story
    }

    private func relativeTimeString(from date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }

    private var updatesOverflowMenu: some View {
        VStack(spacing: 0) {
            overflowMenuRow(title: "Create channel", icon: "bubble.left.and.bubble.right.badge.plus", action: {
                isShowingOverflowMenu = false
                path.append(.createChannel)
            })

            Divider().overlay(Theme.divider)

            overflowMenuRow(title: "Status privacy", icon: "lock", action: {
                isShowingOverflowMenu = false
                isShowingStatusPrivacySheet = true
            })
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1.2)
                )
        )
        .shadow(color: Color.black.opacity(0.6), radius: 22, x: 0, y: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.appBackground.opacity(0.28))
        )
    }

    private func overflowMenuRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.98))
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.98))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .buttonStyle(.plain)
    }
}

private struct StatusPrivacySheetView: View {
    @Environment(\.dismiss) private var dismiss
    let safetyService: SafetyService

    @State private var selectedScope: StoryAudienceScope = .friends
    @State private var blockedHandles: [String] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Who can see your status") {
                    Button {
                        selectedScope = .friends
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("My friends")
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Only friends can view your status.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if selectedScope == .friends {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                            }
                        }
                    }

                    Button {
                        selectedScope = .everyone
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Everyone")
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Anyone can view your status except blocked users.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if selectedScope == .everyone {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                            }
                        }
                    }
                }

                Section("Blocked") {
                    Text(blockedHandles.isEmpty ? "No blocked users." : blockedHandles.joined(separator: ", "))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background { SideMenuBackground() }
            .navigationTitle("Status privacy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
            .task {
                selectedScope = (try? await safetyService.fetchStoryAudienceScope()) ?? .friends
                blockedHandles = (try? await safetyService.fetchBlockedHandles()) ?? []
            }
            .alert("Status privacy", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await safetyService.setStoryAudienceScope(selectedScope)
            dismiss()
        } catch {
            errorMessage = "Could not save status privacy."
        }
    }
}

private struct UpdateStatusComposerView: View {
    private let storyService: StoryService
    private let safetyService: SafetyService
    private let initialMedia: StoryMedia?
    @State private var text = ""
    @State private var selectedMediaItem: PhotosPickerItem?
    @State private var selectedMedia: StoryMedia?
    @State private var isLoadingMedia = false
    @State private var didPost = false
    @State private var errorMessage: String?
    @State private var shouldOfferOpenSettings = false
    @State private var audienceScope: StoryAudienceScope = .friends
    @State private var blockedHandles: [String] = []
    
    private var blockedUsersText: String {
        let handles = blockedHandles.isEmpty ? "none" : blockedHandles.joined(separator: ", ")
        return "Blocked users are always excluded: \(handles)"
    }

    init(storyService: StoryService, safetyService: SafetyService, initialMedia: StoryMedia? = nil) {
        self.storyService = storyService
        self.safetyService = safetyService
        self.initialMedia = initialMedia
    }

    var body: some View {
        Form {
            newStatusSection
            audienceSection
            postSection
        }
        .navigationTitle("Add Status")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
        .task {
            audienceScope = (try? await safetyService.fetchStoryAudienceScope()) ?? .friends
            blockedHandles = (try? await safetyService.fetchBlockedHandles()) ?? []
            if selectedMedia == nil {
                selectedMedia = initialMedia
            }
        }
        .onChange(of: selectedMediaItem) { _, item in
            guard let item else { return }
            Task {
                isLoadingMedia = true
                defer { isLoadingMedia = false }

                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    selectedMedia = nil
                    errorMessage = "Could not load selected media."
                    return
                }

                let isVideo = item.supportedContentTypes.contains {
                    $0.conforms(to: .movie) || $0.conforms(to: .video)
                }

                selectedMedia = StoryMedia(
                    mediaType: isVideo ? .video : .photo,
                    fileName: isVideo ? "story-video.mov" : "story-photo.jpg",
                    byteCount: data.count,
                    payload: data
                )
            }
        }
        .alert("Story posted.", isPresented: $didPost) {
            Button("OK") {}
        }
        .alert("Story", isPresented: Binding(
            get: { errorMessage != nil },
            set: { value in
                if !value {
                    errorMessage = nil
                    shouldOfferOpenSettings = false
                }
            }
        )) {
            if shouldOfferOpenSettings {
                Button("Open Settings") {
                    openAppSettings()
                    errorMessage = nil
                    shouldOfferOpenSettings = false
                }
            }
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    private var newStatusSection: some View {
        Section("New Status") {
            TextField("What's new?", text: $text, axis: .vertical)
                .lineLimit(3...5)

            PhotosPicker(selection: $selectedMediaItem, matching: .any(of: [.images, .videos])) {
                Label("Add photo or video", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(isLoadingMedia)
            .buttonStyle(.plain)

            if isLoadingMedia {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading media...")
                        .foregroundStyle(.secondary)
                }
            }

            if let selectedMedia {
                StoryComposerPreview(media: selectedMedia)

                Button(role: .destructive) {
                    self.selectedMedia = nil
                    selectedMediaItem = nil
                } label: {
                    Label("Remove attachment", systemImage: "trash")
                }
            }
        }
    }

    private var audienceSection: some View {
        Section("Audience") {
            LabeledContent("Story visibility", value: audienceScope.rawValue)
            Text(blockedUsersText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var postSection: some View {
        Section {
            Button("Post Status") {
                Task { await publishStory() }
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedMedia == nil)
        }
    }

    private func publishStory() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || selectedMedia != nil else {
            errorMessage = "Add text, photo, or video first."
            return
        }

        do {
            try await storyService.publishMyStory(
                caption: trimmed,
                media: selectedMedia,
                visibility: audienceScope.storyVisibility
            )
            text = ""
            selectedMedia = nil
            selectedMediaItem = nil
            didPost = true
            NotificationCenter.default.post(name: .oneWayStoryDidChange, object: nil)
        } catch {
            errorMessage = "Could not publish story."
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct StoryComposerPreview: View {
    let media: StoryMedia

    var body: some View {
        switch media.mediaType {
        case .photo:
            if let image = UIImage(data: media.payload) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        case .video:
            VStack(alignment: .leading, spacing: 6) {
                TransientVideoPlayerView(videoData: media.payload)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("Video attached: \(media.fileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChannelsDirectoryView: View {
    var body: some View {
        List {
            Section("Suggested Channels") {
                Label("One Way Product", systemImage: "checkmark.seal")
                Label("Security Weekly", systemImage: "lock.shield")
                Label("Creator Hub", systemImage: "sparkles")
            }
        }
        .navigationTitle("Channels")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}

private struct CreateChannelView: View {
    @State private var name = ""
    @State private var about = ""

    var body: some View {
        Form {
            Section("Channel Info") {
                TextField("Name", text: $name)
                TextField("About", text: $about, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Button("Create") {
                    name = ""
                    about = ""
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("New Channel")
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .oneWayMenuBar()
    }
}
