import Foundation

enum FriendServiceError: Error {
    case notFound
    case invalidRequest
    case networkError
    case unknown
    case invalidHandle
    case invalidInvite
}
