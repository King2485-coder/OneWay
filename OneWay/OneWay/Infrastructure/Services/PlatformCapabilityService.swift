import Foundation

protocol PlatformCapabilityService {
    func fetchReadiness() async throws -> OneWayPlatformReadiness
    func fetchPrivacySettings() async throws -> PlatformPrivacySettings
    func updatePrivacySettings(_ settings: PlatformPrivacySettings) async throws -> PlatformPrivacySettings
    func fetchAILogs() async throws -> [PlatformAILogEntry]
    func createAILog(action: String, contentScope: String, requiresDecryptedContent: Bool) async throws -> PlatformAILogEntry
    func fetchCloudFiles() async throws -> [PlatformCloudFile]
    func createCloudFile(name: String, byteCount: Int) async throws -> PlatformCloudFile
    func fetchWorkspaceItems() async throws -> [PlatformWorkspaceItem]
    func createWorkspaceItem(type: String, title: String) async throws -> PlatformWorkspaceItem
    func updateWorkspaceItemStatus(id: String, status: String) async throws
    func fetchChannelPosts() async throws -> [PlatformChannelPost]
    func createChannelPost(body: String) async throws -> PlatformChannelPost
    func fetchScheduledMessages() async throws -> [PlatformScheduledMessage]
    func createScheduledMessage(body: String, scheduledFor: String) async throws -> PlatformScheduledMessage
}

final class NetworkPlatformCapabilityService: PlatformCapabilityService {
    private struct Response: Decodable {
        let updatedAt: String
        let headline: String
        let summary: String
        let groups: [OneWayPlatformCapabilityGroup]
    }

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchReadiness() async throws -> OneWayPlatformReadiness {
        let response: Response = try await client.get("api/platform/capabilities")
        return OneWayPlatformReadiness(
            updatedAt: ISO8601DateFormatter().date(from: response.updatedAt) ?? Date(),
            headline: response.headline,
            summary: response.summary,
            groups: response.groups
        )
    }

    func fetchPrivacySettings() async throws -> PlatformPrivacySettings {
        let response: PrivacyResponse = try await client.get("api/platform/privacy")
        return response.settings
    }

    func updatePrivacySettings(_ settings: PlatformPrivacySettings) async throws -> PlatformPrivacySettings {
        let response: PrivacyResponse = try await client.put("api/platform/privacy", body: settings)
        return response.settings
    }

    func fetchAILogs() async throws -> [PlatformAILogEntry] {
        let response: AILogsResponse = try await client.get("api/platform/ai/logs")
        return response.logs
    }

    func createAILog(action: String, contentScope: String, requiresDecryptedContent: Bool) async throws -> PlatformAILogEntry {
        let response: AILogResponse = try await client.post(
            "api/platform/ai/logs",
            body: AILogRequest(action: action, contentScope: contentScope, requiresDecryptedContent: requiresDecryptedContent)
        )
        return response.log
    }

    func fetchCloudFiles() async throws -> [PlatformCloudFile] {
        let response: CloudFilesResponse = try await client.get("api/platform/cloud/files")
        return response.files
    }

    func createCloudFile(name: String, byteCount: Int) async throws -> PlatformCloudFile {
        let response: CloudFileResponse = try await client.post(
            "api/platform/cloud/files",
            body: CloudFileRequest(name: name, mimeType: "application/octet-stream", byteCount: byteCount)
        )
        return response.file
    }

    func fetchWorkspaceItems() async throws -> [PlatformWorkspaceItem] {
        let response: WorkspaceItemsResponse = try await client.get("api/platform/workspace/items")
        return response.items
    }

    func createWorkspaceItem(type: String, title: String) async throws -> PlatformWorkspaceItem {
        let response: WorkspaceItemResponse = try await client.post(
            "api/platform/workspace/items",
            body: WorkspaceItemRequest(type: type, title: title)
        )
        return response.item
    }

    func updateWorkspaceItemStatus(id: String, status: String) async throws {
        let _: EmptyAPIResponse = try await client.patch(
            "api/platform/workspace/items/\(id)",
            body: WorkspaceStatusRequest(status: status)
        )
    }

    func fetchChannelPosts() async throws -> [PlatformChannelPost] {
        let response: ChannelPostsResponse = try await client.get("api/platform/channels/posts")
        return response.posts
    }

    func createChannelPost(body: String) async throws -> PlatformChannelPost {
        let response: ChannelPostResponse = try await client.post(
            "api/platform/channels/posts",
            body: ChannelPostRequest(body: body)
        )
        return response.post
    }

    func fetchScheduledMessages() async throws -> [PlatformScheduledMessage] {
        let response: ScheduledMessagesResponse = try await client.get("api/platform/messages/scheduled")
        return response.messages
    }

    func createScheduledMessage(body: String, scheduledFor: String) async throws -> PlatformScheduledMessage {
        let response: ScheduledMessageResponse = try await client.post(
            "api/platform/messages/scheduled",
            body: ScheduledMessageRequest(body: body, scheduledFor: scheduledFor)
        )
        return response.message
    }
}

final class FallbackPlatformCapabilityService: PlatformCapabilityService {
    func fetchReadiness() async throws -> OneWayPlatformReadiness {
        OneWayPlatformReadiness.localFallback
    }

    func fetchPrivacySettings() async throws -> PlatformPrivacySettings { .defaults }
    func updatePrivacySettings(_ settings: PlatformPrivacySettings) async throws -> PlatformPrivacySettings { settings }
    func fetchAILogs() async throws -> [PlatformAILogEntry] { [] }
    func createAILog(action: String, contentScope: String, requiresDecryptedContent: Bool) async throws -> PlatformAILogEntry {
        PlatformAILogEntry(id: UUID().uuidString, action: action, contentScope: contentScope, requiresDecryptedContent: requiresDecryptedContent, createdAt: Date().ISO8601Format())
    }
    func fetchCloudFiles() async throws -> [PlatformCloudFile] { [] }
    func createCloudFile(name: String, byteCount: Int) async throws -> PlatformCloudFile {
        PlatformCloudFile(id: UUID().uuidString, name: name, mimeType: "application/octet-stream", byteCount: byteCount, storageKey: "local/\(name)", encrypted: true, createdAt: Date().ISO8601Format(), updatedAt: Date().ISO8601Format())
    }
    func fetchWorkspaceItems() async throws -> [PlatformWorkspaceItem] { [] }
    func createWorkspaceItem(type: String, title: String) async throws -> PlatformWorkspaceItem {
        PlatformWorkspaceItem(id: UUID().uuidString, workspaceId: "local", type: type, title: title, status: "open", metadataJson: nil, createdAt: Date().ISO8601Format(), updatedAt: Date().ISO8601Format())
    }
    func updateWorkspaceItemStatus(id: String, status: String) async throws {}
    func fetchChannelPosts() async throws -> [PlatformChannelPost] { [] }
    func createChannelPost(body: String) async throws -> PlatformChannelPost {
        PlatformChannelPost(id: UUID().uuidString, channelId: "local", authorId: "local", body: body, reactionCount: 0, createdAt: Date().ISO8601Format(), updatedAt: Date().ISO8601Format())
    }
    func fetchScheduledMessages() async throws -> [PlatformScheduledMessage] { [] }
    func createScheduledMessage(body: String, scheduledFor: String) async throws -> PlatformScheduledMessage {
        PlatformScheduledMessage(id: UUID().uuidString, conversationId: "local", senderId: "local", body: body, scheduledFor: scheduledFor, status: "scheduled", createdAt: Date().ISO8601Format())
    }
}

private struct PrivacyResponse: Decodable { let settings: PlatformPrivacySettings }
private struct AILogsResponse: Decodable { let logs: [PlatformAILogEntry] }
private struct AILogResponse: Decodable { let log: PlatformAILogEntry }
private struct CloudFilesResponse: Decodable { let files: [PlatformCloudFile] }
private struct CloudFileResponse: Decodable { let file: PlatformCloudFile }
private struct WorkspaceItemsResponse: Decodable { let items: [PlatformWorkspaceItem] }
private struct WorkspaceItemResponse: Decodable { let item: PlatformWorkspaceItem }
private struct ChannelPostsResponse: Decodable { let posts: [PlatformChannelPost] }
private struct ChannelPostResponse: Decodable { let post: PlatformChannelPost }
private struct ScheduledMessagesResponse: Decodable { let messages: [PlatformScheduledMessage] }
private struct ScheduledMessageResponse: Decodable { let message: PlatformScheduledMessage }

private struct AILogRequest: Encodable {
    let action: String
    let contentScope: String
    let requiresDecryptedContent: Bool
}

private struct CloudFileRequest: Encodable {
    let name: String
    let mimeType: String
    let byteCount: Int
}

private struct WorkspaceItemRequest: Encodable {
    let workspaceId = "personal"
    let type: String
    let title: String
}

private struct WorkspaceStatusRequest: Encodable {
    let status: String
}

private struct ChannelPostRequest: Encodable {
    let channelId = "personal-channel"
    let body: String
}

private struct ScheduledMessageRequest: Encodable {
    let conversationId = "personal-draft"
    let body: String
    let scheduledFor: String
}
