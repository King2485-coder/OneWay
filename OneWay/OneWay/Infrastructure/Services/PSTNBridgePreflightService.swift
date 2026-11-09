import Foundation

struct PSTNBridgePreflight: Codable {
    let ok: Bool
    let provider: String
    let mode: String
    let liveKitConfigured: Bool
    let sipTrunkConfigured: Bool
    let providerConfigured: Bool
    let webhookBaseUrlConfigured: Bool
    let mediaBridgeEnabled: Bool
    let missing: [String]
    let warnings: [String]
}

final class PSTNBridgePreflightService {
    static let shared = PSTNBridgePreflightService()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchStatus() async throws -> PSTNBridgePreflight {
        try await client.get("api/pstn/preflight")
    }
}
