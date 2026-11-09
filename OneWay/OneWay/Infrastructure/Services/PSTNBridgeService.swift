import Foundation

struct PSTNCalleeDisclosure: Codable, Equatable {
    let enabled: Bool
    let requireAccept: Bool
    let accepted: Bool
    let status: String?
}

struct PSTNCallStartResponse: Codable {
    let callSessionId: String
    let roomName: String?
    let networkType: String
    let provider: String
    let status: String
    let providerCallId: String?
    let sipParticipantId: String?
    let participantIdentity: String?
    let liveKitUrl: String?
    let token: String?
    let participantToken: String?
    let mediaBridgeStatus: String?
    let message: String?
    let calleeDisclosure: PSTNCalleeDisclosure?
}

struct PSTNCallStatusResponse: Codable {
    let ok: Bool?
    let callSessionId: String
    let status: String
    let provider: String
    let providerCallId: String?
    let sipParticipantId: String?
    let participantIdentity: String?
    let mediaBridgeStatus: String?
    let failureReason: String?
    let roomName: String?
    let startedAt: String?
    let answeredAt: String?
    let endedAt: String?
    let message: String?
    let calleeDisclosure: PSTNCalleeDisclosure?
}

private struct PSTNCallEndResponse: Decodable {
    let ok: Bool
    let callSessionId: String
}

final class PSTNBridgeService {
    static let shared = PSTNBridgeService()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func startPSTNCall(to phoneNumber: String, fromNumber: String?, callerCallKitUUID: UUID? = nil) async throws -> PSTNCallStartResponse {
        struct Request: Encodable {
            let toPhoneNumber: String
            let fromOneWayNumber: String?
            let idempotencyKey: String
            let callerCallKitUUID: String?
        }

        return try await client.post(
            "api/pstn/calls/start",
            body: Request(
                toPhoneNumber: phoneNumber,
                fromOneWayNumber: fromNumber,
                idempotencyKey: "pstn-\(phoneNumber)-\(fromNumber ?? "default")-\(Int(Date().timeIntervalSince1970 / 30))",
                callerCallKitUUID: callerCallKitUUID?.uuidString.lowercased()
            )
        )
    }

    func fetchPSTNCallStatus(callSessionId: String) async throws -> PSTNCallStatusResponse {
        do {
            return try await client.get(
                "api/pstn/calls/status",
                queryItems: [URLQueryItem(name: "callSessionId", value: callSessionId)]
            )
        } catch {
            guard isNotFound(error) else { throw error }
        }

        do {
            return try await client.get("api/pstn/calls/\(callSessionId)")
        } catch {
            guard isNotFound(error) else { throw error }
        }

        return try await client.get("api/pstn/calls/status/\(callSessionId)")
    }

    func endPSTNCall(callSessionId: String) async throws {
        struct Request: Encodable {
            let callSessionId: String
        }

        let _: PSTNCallEndResponse = try await client.post(
            "api/pstn/calls/end",
            body: Request(callSessionId: callSessionId)
        )
    }

    private func isNotFound(_ error: Error) -> Bool {
        guard case let APIClientError.server(statusCode, _) = error else {
            return false
        }
        return statusCode == 404
    }
}
