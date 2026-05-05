import Foundation

protocol StoryService {
    func fetchFriendStories() async throws -> [StoryItem]
    func fetchMyStory() async throws -> StoryItem?
    func publishMyStory(caption: String, media: StoryMedia?, visibility: StoryVisibility) async throws
    func clearMyStory() async throws
    func saveMyProfilePhoto(_ data: Data?) async throws
    func loadMyProfilePhoto() async throws -> Data?
}
