import Foundation

actor NetworkSafetyService: SafetyService {
    private struct EmptyBody: Encodable {}
    private struct TargetBody: Encodable { let handle: String }
    private struct ReportBody: Encodable { let handle: String; let reason: String }
    private struct PresetBody: Encodable { let preset: String }
    private struct StoryAudienceBody: Encodable { let scope: String }
    private struct BlockedResponse: Decodable { let handles: [String] }
    private struct StoryAudienceResponse: Decodable { let scope: String }

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func block(handle: String) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "api/safety/block",
            body: TargetBody(handle: normalized(handle))
        )
    }

    func report(handle: String, reason: String) async throws {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedReason.count >= 3 else {
            throw APIClientError.server(statusCode: 400, message: "Please include a brief reason for the report.")
        }
        let _: EmptyAPIResponse = try await client.post(
            "api/safety/report",
            body: ReportBody(handle: normalized(handle), reason: trimmedReason)
        )
    }

    func applyPrivacyPreset(_ preset: PrivacyPreset) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "api/safety/privacy-preset",
            body: PresetBody(preset: preset.rawValue)
        )
    }

    func runSessionKillSwitch() async throws {
        let _: EmptyAPIResponse = try await client.post(
            "api/safety/session-kill-switch",
            body: EmptyBody()
        )
    }

    func fetchBlockedHandles() async throws -> [String] {
        let response: BlockedResponse = try await client.get("api/safety/blocked")
        return response.handles
    }

    func setStoryAudienceScope(_ scope: StoryAudienceScope) async throws {
        let _: EmptyAPIResponse = try await client.post(
            "api/safety/story-audience",
            body: StoryAudienceBody(scope: scope.rawValue)
        )
    }

    func fetchStoryAudienceScope() async throws -> StoryAudienceScope {
        let response: StoryAudienceResponse = try await client.get("api/safety/story-audience")
        return StoryAudienceScope(rawValue: response.scope) ?? .friends
    }

    private func normalized(_ handle: String) -> String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
