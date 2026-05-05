import Foundation
import OSLog

struct BackendHealthResponse: Codable, Equatable {
    let status: String?
    let ok: Bool?
    let app: String?
    let time: String?
}

enum BackendConnectionState: Equatable {
    case checking
    case connected
    case unreachable(String)

    var message: String? {
        switch self {
        case .checking:
            return "Checking backend connection…"
        case .connected:
            return nil
        case .unreachable(let reason):
            return "Backend unavailable: \(reason)"
        }
    }
}

enum APIClientError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case server(statusCode: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "Invalid API base URL: \(value)"
        case .invalidResponse:
            return "The server returned an invalid response."
        case .server(let statusCode, let message):
            return message.isEmpty ? "Server error (\(statusCode))." : "Server error (\(statusCode)): \(message)"
        case .emptyResponse:
            return "The server returned an empty response."
        }
    }
}

struct EmptyAPIResponse: Decodable {}

final class APIClient {
    static let shared = APIClient(baseURLString: APIConfig.baseURL)

    let baseURL: URL

    private let session: URLSession
    private let logger = Logger(subsystem: "app.oneway.ios", category: "api")
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURLString: String, session: URLSession = .shared) {
        guard let url = URL(string: baseURLString) else {
            fatalError("Invalid APIConfig.baseURL: \(baseURLString)")
        }
        self.baseURL = url
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    func health() async -> BackendConnectionState {
        do {
            let response: BackendHealthResponse = try await get("health", requiresAuth: false)
            if response.ok == true || response.status == "ok" || response.status == "live" {
                logger.log("Backend health check passed")
                return .connected
            }
            return .unreachable("Unexpected health payload.")
        } catch {
            logger.error("Backend health check failed: \(error.localizedDescription, privacy: .public)")
            return .unreachable(error.localizedDescription)
        }
    }

    func get<Response: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        requiresAuth: Bool = true
    ) async throws -> Response {
        let request = try makeRequest(
            path: path,
            method: "GET",
            queryItems: queryItems,
            body: nil,
            requiresAuth: requiresAuth
        )
        return try await send(request)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let encodedBody = try encoder.encode(body)
        let request = try makeRequest(
            path: path,
            method: "POST",
            queryItems: [],
            body: encodedBody,
            requiresAuth: requiresAuth
        )
        return try await send(request)
    }

    func patch<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let encodedBody = try encoder.encode(body)
        let request = try makeRequest(
            path: path,
            method: "PATCH",
            queryItems: [],
            body: encodedBody,
            requiresAuth: requiresAuth
        )
        return try await send(request)
    }

    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?,
        requiresAuth: Bool
    ) throws -> URLRequest {
        let sanitizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = baseURL.appendingPathComponent(sanitizedPath)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidBaseURL(baseURL.absoluteString)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let finalURL = components.url else {
            throw APIClientError.invalidBaseURL(baseURL.absoluteString)
        }

        var request = URLRequest(url: finalURL, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresAuth {
            request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        logger.log("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "", privacy: .public)")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIClientError.server(statusCode: http.statusCode, message: body)
        }

        if Response.self == EmptyAPIResponse.self {
            return EmptyAPIResponse() as! Response
        }

        guard !data.isEmpty else {
            throw APIClientError.emptyResponse
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            logger.error("Decoding failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
