import Foundation

final class OneWayNumberService {
    static let shared = OneWayNumberService()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchMyNumbers() async throws -> OneWayNumbersResponse {
        try await client.get("api/numbers/me")
    }

    func createNumber(label: String? = nil) async throws -> OneWayNumber {
        struct Request: Encodable {
            let label: String?
        }

        do {
            return try await client.post("api/numbers/create", body: Request(label: label))
        } catch APIClientError.server(let statusCode, _) where statusCode == 402 {
            throw OneWayNumberError.subscriptionRequired
        } catch {
            throw error
        }
    }

    func claimFreeNumbers() async throws -> [OneWayNumber] {
        struct EmptyRequest: Encodable {}
        return try await client.post("api/numbers/claim-free", body: EmptyRequest())
    }

    func setPrimary(id: String) async throws -> OneWayNumber {
        struct Request: Encodable {
            let isPrimary = true
        }

        return try await client.patch("api/numbers/\(id)/primary", body: Request())
    }

    func deleteNumber(id: String) async throws {
        let request = try makeRawRequest(path: "api/numbers/\(id)", method: "DELETE")
        let _ = try await sendRaw(request)
    }

    func searchUsers(query: String) async throws -> [OneWayUserSearchResult] {
        let response: OneWayUserSearchResponse = try await client.get(
            "api/users/search",
            queryItems: [URLQueryItem(name: "q", value: query)]
        )
        return response.users
    }

    func startOneWayNetworkCall(
        fromIdentity: String?,
        fromNumber: String?,
        to: String,
        hasVideo: Bool
    ) async throws -> OneWayStartCallResponse {
        struct Request: Encodable {
            let fromIdentity: String?
            let fromNumber: String?
            let to: String
            let hasVideo: Bool
        }

        return try await client.post(
            "calls/start",
            body: Request(
                fromIdentity: fromIdentity,
                fromNumber: fromNumber,
                to: to,
                hasVideo: hasVideo
            )
        )
    }

    private func makeRawRequest(path: String, method: String) throws -> URLRequest {
        let sanitizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = client.baseURL.appendingPathComponent(sanitizedPath)
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        return request
    }

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIClientError.server(statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
