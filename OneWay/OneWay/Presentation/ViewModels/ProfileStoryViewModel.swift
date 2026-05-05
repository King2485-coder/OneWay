import Foundation
import Combine

@MainActor
final class ProfileStoryViewModel: ObservableObject {
    private let maxStoryPhotoBytes = 8 * 1024 * 1024
    private let maxStoryVideoBytes = 20 * 1024 * 1024

    @Published var profilePhotoData: Data?
    @Published var storyText = ""
    @Published var storyVisibility: StoryVisibility = .friends
    @Published private(set) var myStory: StoryItem?
    @Published var errorMessage: String?

    private let storyService: StoryService

    init(storyService: StoryService) {
        self.storyService = storyService
    }

    func load() async {
        do {
            profilePhotoData = try await storyService.loadMyProfilePhoto()
            myStory = try await storyService.fetchMyStory()
            errorMessage = nil
        } catch {
            errorMessage = "Unable to load story/profile assets."
        }
    }

    func updateProfilePhoto(with data: Data?) async {
        do {
            try await storyService.saveMyProfilePhoto(data)
            profilePhotoData = try await storyService.loadMyProfilePhoto()
            errorMessage = nil
        } catch {
            errorMessage = "Could not update profile photo."
        }
    }

    func publishStory(media: StoryMedia?) async {
        let trimmed = storyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || media != nil else {
            errorMessage = "Add text, a photo, or a short video to post a story."
            return
        }

        if let media {
            switch media.mediaType {
            case .photo:
                if media.byteCount > maxStoryPhotoBytes {
                    errorMessage = "Story photo is too large (max 8MB)."
                    return
                }
            case .video:
                if media.byteCount > maxStoryVideoBytes {
                    errorMessage = "Story video is too large (max 20MB)."
                    return
                }
            }
        }

        do {
            try await storyService.publishMyStory(caption: trimmed, media: media, visibility: storyVisibility)
            myStory = try await storyService.fetchMyStory()
            storyText = ""
            errorMessage = nil
        } catch {
            errorMessage = "Could not publish story."
        }
    }

    func clearMyStory() async {
        do {
            try await storyService.clearMyStory()
            myStory = nil
            errorMessage = nil
        } catch {
            errorMessage = "Could not remove story."
        }
    }
}
