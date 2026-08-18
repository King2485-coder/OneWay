import Foundation

struct PSTNCallStartResponse: Codable {
    let callSessionId: String
    let networkType: String
    let status: String
    let providerCallId: String?
    let provider: String?
    let externalPhoneNumber: String?
}

struct PSTNBridgeService {
    private struct RequestBody: Encodable {
        let toPhoneNumber: String
        let fromOneWayNumber: String?
    }

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func startPSTNCall(to phoneNumber: String, fromNumber: String?) async throws -> PSTNCallStartResponse {
        try await client.post(
            "api/pstn/calls/start",
            body: RequestBody(toPhoneNumber: phoneNumber, fromOneWayNumber: fromNumber)
        )
    }
}
