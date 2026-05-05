import SwiftUI
import Combine
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct ProfileView: View {
    private enum DeletionPreset: String, CaseIterable, Identifiable {
        case oneHour = "1 Hour"
        case oneDay = "24 Hours"
        case sevenDays = "7 Days"

        var id: String { rawValue }

        var interval: TimeInterval {
            switch self {
            case .oneHour:
                return 60 * 60
            case .oneDay:
                return 60 * 60 * 24
            case .sevenDays:
                return 60 * 60 * 24 * 7
            }
        }
    }

    @StateObject private var viewModel: SettingsViewModel
    @StateObject private var storyViewModel: ProfileStoryViewModel
    @ObservedObject private var accountDeletionScheduler: AccountDeletionScheduler

    @State private var selectedPreset: DeletionPreset = .oneDay
    @State private var selectedProfilePhotoItem: PhotosPickerItem?
    @State private var selectedStoryMediaItem: PhotosPickerItem?
    @State private var selectedStoryMedia: StoryMedia?
    @State private var isShowingProfileCamera = false
    @State private var isShowingStoryCamera = false

    init(
        authService: AuthService,
        keyService: KeyService,
        localPersistence: LocalPersistence,
        storyService: StoryService,
        accountDeletionScheduler: AccountDeletionScheduler
    ) {
        _viewModel = StateObject(
            wrappedValue: SettingsViewModel(
                authService: authService,
                keyService: keyService,
                localPersistence: localPersistence
            )
        )
        _storyViewModel = StateObject(wrappedValue: ProfileStoryViewModel(storyService: storyService))
        _accountDeletionScheduler = ObservedObject(wrappedValue: accountDeletionScheduler)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    HStack(spacing: 14) {
                        profilePhotoView

                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Display Name", value: viewModel.profileText)
                            LabeledContent("Fingerprint", value: viewModel.fingerprint)
                        }
                    }

                    PhotosPicker(selection: $selectedProfilePhotoItem, matching: .images) {
                        Label("Upload Profile Photo", systemImage: "photo")
                    }

                    Button {
                        isShowingProfileCamera = true
                    } label: {
                        Label("Take Profile Photo", systemImage: "camera.fill")
                    }
                }

                Section("My Story") {
                    TextField("Share an update...", text: $storyViewModel.storyText, axis: .vertical)
                        .lineLimit(2...4)

                    Picker("Visibility", selection: $storyViewModel.storyVisibility) {
                        ForEach(StoryVisibility.allCases) { visibility in
                            Text(visibility.rawValue).tag(visibility)
                        }
                    }

                    PhotosPicker(selection: $selectedStoryMediaItem, matching: .any(of: [.images, .videos])) {
                        Label("Add Story Photo or Video", systemImage: "photo.on.rectangle.angled")
                    }

                    Button {
                        isShowingStoryCamera = true
                    } label: {
                        Label("Take Story Photo", systemImage: "camera.fill")
                    }

                    if let selectedStoryMedia {
                        StoryComposerPreview(media: selectedStoryMedia)
                    }

                    Button("Post Story") {
                        Task {
                            await storyViewModel.publishStory(media: selectedStoryMedia)
                            selectedStoryMedia = nil
                            selectedStoryMediaItem = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if let story = storyViewModel.myStory {
                        Text("Current Story: \(story.visibility.rawValue)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Remove My Story", role: .destructive) {
                            Task {
                                await storyViewModel.clearMyStory()
                                selectedStoryMedia = nil
                                selectedStoryMediaItem = nil
                            }
                        }
                    }
                }

                Section("Privacy") {
                    LabeledContent("Message Cache", value: viewModel.cachePolicyText)
                    Text("Plaintext messages are not cached locally by default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Timed Account Deletion") {
                    Picker("Delete After", selection: $selectedPreset) {
                        ForEach(DeletionPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }

                    Button("Schedule Deletion Timer", role: .destructive) {
                        accountDeletionScheduler.schedule(after: selectedPreset.interval)
                    }

                    if let date = accountDeletionScheduler.scheduledDeletionDate {
                        LabeledContent("Scheduled For") {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                        }

                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Time Remaining: \(remainingText(until: date, now: context.date))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Button("Cancel Timer", role: .cancel) {
                            accountDeletionScheduler.cancel()
                        }
                    }

                    Text("Deletion is best-effort in-app. External copies such as screenshots or backups may still exist.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Profile")
            .oneWayMenuBar()
            .scrollContentBackground(.hidden)
            .background {
                SideMenuBackground()
            }
            .task {
                await viewModel.load()
                await storyViewModel.load()
            }
            .onChange(of: selectedProfilePhotoItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    await storyViewModel.updateProfilePhoto(with: data)
                    selectedProfilePhotoItem = nil
                }
            }
            .onChange(of: selectedStoryMediaItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        selectedStoryMedia = nil
                        return
                    }

                    let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                    selectedStoryMedia = StoryMedia(
                        mediaType: isVideo ? .video : .photo,
                        fileName: isVideo ? "story-video.mov" : "story-photo.jpg",
                        byteCount: data.count,
                        payload: data
                    )
                }
            }
            .alert("Timer Error", isPresented: errorAlertBinding) {
                Button("OK") {
                    accountDeletionScheduler.clearError()
                }
            } message: {
                Text(accountDeletionScheduler.lastError ?? "")
            }
            .alert("Story Error", isPresented: storyErrorAlertBinding) {
                Button("OK") {
                    storyViewModel.errorMessage = nil
                }
            } message: {
                Text(storyViewModel.errorMessage ?? "")
            }
            .fullScreenCover(isPresented: $isShowingProfileCamera) {
                CameraCaptureView { image in
                    let data = image.jpegData(compressionQuality: 0.85)
                    Task { await storyViewModel.updateProfilePhoto(with: data) }
                }
            }
            .fullScreenCover(isPresented: $isShowingStoryCamera) {
                CameraCaptureView { image in
                    guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                    selectedStoryMedia = StoryMedia(
                        mediaType: .photo,
                        fileName: "story-camera.jpg",
                        byteCount: data.count,
                        payload: data
                    )
                }
            }
        }
    }

    private var profilePhotoView: some View {
        Group {
            if let data = storyViewModel.profilePhotoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.blue.opacity(0.18))
                    .overlay {
                        Text(initials(for: viewModel.profileText))
                            .font(.headline)
                    }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(Circle())
    }

    private func initials(for name: String) -> String {
        let components = name.split(separator: " ")
        let chars = components.prefix(2).compactMap { $0.first }
        return chars.isEmpty ? "U" : String(chars)
    }

    private func remainingText(until date: Date, now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        return String(format: "%02dh %02dm %02ds", hours, minutes, seconds)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { accountDeletionScheduler.lastError != nil },
            set: { newValue in
                if !newValue {
                    accountDeletionScheduler.clearError()
                }
            }
        )
    }

    private var storyErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { storyViewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    storyViewModel.errorMessage = nil
                }
            }
        )
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

                Text("Short video attached: \(media.fileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
