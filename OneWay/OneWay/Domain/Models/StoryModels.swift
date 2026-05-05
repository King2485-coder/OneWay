import Foundation

enum StoryVisibility: String, CaseIterable, Identifiable {
    case onlyMe = "Only Me"
    case friends = "Friends"
    case everyone = "Everyone"

    var id: String { rawValue }
}

enum StoryAudienceScope: String, CaseIterable, Identifiable {
    case friends = "Friends"
    case everyone = "Everyone"

    var id: String { rawValue }

    var storyVisibility: StoryVisibility {
        switch self {
        case .friends:
            return .friends
        case .everyone:
            return .everyone
        }
    }
}

enum StoryMediaType: String, Equatable {
    case photo
    case video
}

struct StoryMedia: Equatable {
    let mediaType: StoryMediaType
    let fileName: String
    let byteCount: Int
    let payload: Data
}

struct StoryItem: Identifiable, Equatable {
    let id: UUID
    let authorDisplayName: String
    let caption: String
    let visibility: StoryVisibility
    let createdAt: Date
    let expiresAt: Date
    let media: StoryMedia?
}
