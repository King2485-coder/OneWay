import Foundation

actor StubStoryService: StoryService {
    private var myStory: StoryItem?
    private var myProfilePhotoData: Data?
    private var friendStories: [StoryItem]

    init() {
        let now = Date()
        friendStories = [
            StoryItem(
                id: UUID(),
                authorDisplayName: "Alex",
                caption: "Morning run.",
                visibility: .friends,
                createdAt: now.addingTimeInterval(-60 * 25),
                expiresAt: now.addingTimeInterval(60 * 60 * 18),
                media: nil
            ),
            StoryItem(
                id: UUID(),
                authorDisplayName: "Priya",
                caption: "Coffee + roadmap planning.",
                visibility: .friends,
                createdAt: now.addingTimeInterval(-60 * 45),
                expiresAt: now.addingTimeInterval(60 * 60 * 20),
                media: nil
            )
        ]
    }

    func fetchFriendStories() async throws -> [StoryItem] {
        let now = Date()
        return friendStories
            .filter { ($0.visibility == .friends || $0.visibility == .everyone) && $0.expiresAt > now }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func fetchMyStory() async throws -> StoryItem? {
        guard let myStory else { return nil }
        if myStory.expiresAt <= Date() {
            self.myStory = nil
            return nil
        }
        return myStory
    }

    func publishMyStory(caption: String, media: StoryMedia?, visibility: StoryVisibility) async throws {
        let now = Date()
        let story = StoryItem(
            id: UUID(),
            authorDisplayName: "You",
            caption: caption,
            visibility: visibility,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60 * 60 * 24),
            media: media
        )
        myStory = story

        // Keep test feed in sync so posted stories become visible in Updates.
        friendStories.removeAll { $0.authorDisplayName == "You" }
        if visibility == .friends || visibility == .everyone {
            friendStories.insert(story, at: 0)
        }
    }

    func clearMyStory() async throws {
        myStory = nil
    }

    func saveMyProfilePhoto(_ data: Data?) async throws {
        myProfilePhotoData = data
    }

    func loadMyProfilePhoto() async throws -> Data? {
        myProfilePhotoData
    }

    func wipeAllData() async {
        myStory = nil
        myProfilePhotoData = nil
        friendStories.removeAll()
    }
}
