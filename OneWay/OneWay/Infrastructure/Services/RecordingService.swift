import Foundation

struct CallRecording: Codable, Identifiable {
    let id: String
    let roomName: String
    let fileUrl: String
    let createdAt: String
}

struct StartRecordingResponse: Codable {
    let ok: Bool
    let egressId: String
}

final class RecordingService {
    static let shared = RecordingService()

    func startRecording(roomName: String) async throws -> String {
        let url = URL(string: "\(APIConfig.baseURL)/recordings/start")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "roomName": roomName
        ])

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(StartRecordingResponse.self, from: data)

        return decoded.egressId
    }

    func stopRecording(egressId: String) async throws {
        let url = URL(string: "\(APIConfig.baseURL)/recordings/stop")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "egressId": egressId
        ])

        _ = try await URLSession.shared.data(for: request)
    }

    func fetchRecordings() async throws -> [CallRecording] {
        let url = URL(string: "\(APIConfig.baseURL)/recordings")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([CallRecording].self, from: data)
    }
}
