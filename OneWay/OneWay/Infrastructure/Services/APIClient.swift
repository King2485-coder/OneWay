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
            if (400..<500).contains(statusCode), !message.isEmpty {
                return message
            }
            return message.isEmpty ? "Server error (\(statusCode))." : "Server error (\(statusCode)): \(message)"
        case .emptyResponse:
            return "The server returned an empty response."
        }
    }
}

struct EmptyAPIResponse: Decodable {}

private struct APIErrorEnvelope: Decodable {
    let error: String?
    let message: String?
    let checklist: [String]?
}

enum DevAuth {
#if DEBUG
    static var enabled: Bool {
        let environmentValue = ProcessInfo.processInfo.environment["ONEWAY_DEV_AUTH_ENABLED"]
        let defaultsValue = UserDefaults.standard.object(forKey: "OneWay.DevAuthEnabled") as? Bool
        let requested: Bool
        if let defaultsValue {
            requested = defaultsValue
        } else if let environmentValue {
            requested = environmentValue == "1" || environmentValue.lowercased() == "true"
        } else {
            requested = APIConfig.debugLocalOverrideEnabled
        }

        guard requested,
              let baseURL = URL(string: APIConfig.baseURL)
        else {
            return false
        }

        // Never attach development identity headers to the production API.
        // Simulator builds use production by default, so a real JWT is
        // required unless the developer explicitly selects a local backend.
        return isDevelopmentBaseURL(baseURL)
    }
    static var token: String {
        // A stable per-install identity keeps backend-owned test data attached
        // to the same simulator user across every launch.
        "dev:\(AuthTokenStore.shared.currentUserID())"
    }
#else
    static let enabled = false
    static let token = ""
#endif

    static func authorizationHeader(forPath path: String, baseURL: URL) -> String? {
        guard enabled,
              isDevelopmentAuthPath(path),
              isDevelopmentBaseURL(baseURL),
              !token.isEmpty else {
            return nil
        }

        return "Bearer \(token)"
    }

    static func supportsDevelopmentBearer(forPath path: String, baseURL: URL) -> Bool {
#if DEBUG
        return isDevelopmentAuthPath(path) && isDevelopmentBaseURL(baseURL)
#else
        return false
#endif
    }

    private static func isDevelopmentAuthPath(_ path: String) -> Bool {
        let sanitized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return sanitized.hasPrefix("api/pstn/")
            || sanitized.hasPrefix("api/calls/")
            || sanitized.hasPrefix("api/livekit/")
            || sanitized.hasPrefix("ws/calls")
            || sanitized.hasPrefix("ws/communities")
            || sanitized.hasPrefix("ws/messages")
            || sanitized.hasPrefix("api/messages/")
            || sanitized.hasPrefix("api/communities")
            || sanitized.hasPrefix("api/contacts")
            || sanitized.hasPrefix("api/friends")
            || sanitized.hasPrefix("api/users/search")
            || sanitized.hasPrefix("api/business/")
            || sanitized.hasPrefix("api/wallet")
            || sanitized.hasPrefix("api/ads")
            || sanitized.hasPrefix("api/numbers/")
            || sanitized.hasPrefix("api/subscriptions/")
            || sanitized.hasPrefix("api/platform/")
            || sanitized.hasPrefix("api/email/")
            || sanitized.hasPrefix("api/sites")
            || sanitized.hasPrefix("api/stores")
            || sanitized.hasPrefix("api/storefronts")
            || sanitized.hasPrefix("api/admin/")
    }

    private static func isDevelopmentBaseURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "api.oneway.app" || host == "api.oneway.is" {
            return false
        }
        return url.scheme?.lowercased() == "http"
            || host == "localhost"
            || host == "127.0.0.1"
            || host.hasSuffix(".local")
            || host.hasSuffix(".trycloudflare.com")
    }
}

enum PrivacyLog {
    static func redact(_ value: Any?) -> String {
        guard let value else { return "nil" }
        return redact(String(describing: value))
    }

    static func redact(_ value: String) -> String {
        var output = value
        output = replace(output, pattern: #"Bearer\s+[A-Za-z0-9._~+/\-=]+"#, with: "Bearer [REDACTED]")
        output = replace(output, pattern: #"Basic\s+[A-Za-z0-9+/=]+"#, with: "Basic [REDACTED]")
        output = replace(output, pattern: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, with: "[REDACTED_TOKEN]")
        output = replace(output, pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, with: "[REDACTED_CONTACT]", options: [.caseInsensitive])
        output = replace(output, pattern: #"(?:\+?1[\s.-]?)?(?:\(?\d{3}\)?[\s.-]?)\d{3}[\s.-]?\d{4}\b"#, with: "[REDACTED_CONTACT]")
        output = replace(output, pattern: #"https?://[^\s"'<>]*(?:checkout|buy|pay|payment|stripe|square|paypal|venmo|cash\.app|token|client_secret)[^\s"'<>]*"#, with: "[REDACTED_PAYMENT_LINK]", options: [.caseInsensitive])
        output = replace(output, pattern: #"\b(token|secret|api[_-]?key|client_secret)=([^,\s&]+)"#, with: "$1=[REDACTED]", options: [.caseInsensitive])
        return output
    }

    static func redactURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return redact(url.absoluteString)
        }
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.map { item in
                let name = item.name.lowercased()
                if name.contains("token") || name.contains("secret") || name.contains("key") || name.contains("session") || name.contains("payment") {
                    return URLQueryItem(name: item.name, value: "[REDACTED]")
                }
                return URLQueryItem(name: item.name, value: item.value.map(redact))
            }
        }
        return redact(components.string ?? url.absoluteString)
    }

    static func shortID(_ value: String?, visible: Int = 6) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        if value.count <= visible * 2 + 1 { return value }
        return "\(value.prefix(visible))…\(value.suffix(visible))"
    }

    private static func replace(
        _ value: String,
        pattern: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }
}

enum AdminDebugAuth {
#if DEBUG
    static func applyAdminHeader(to request: inout URLRequest, path: String, baseURL: URL) {
        let sanitized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard sanitized.hasPrefix("api/admin/"),
              DevAuth.authorizationHeader(forPath: sanitized, baseURL: baseURL) == nil,
              let token = adminToken else {
            return
        }
        request.setValue(token, forHTTPHeaderField: "x-oneway-admin-token")
    }

    private static var adminToken: String? {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let value = env["ONEWAY_SECURITY_ADMIN_TOKEN"]
            ?? env["ONEWAY_PRIVACY_ADMIN_TOKEN"]
            ?? env["ONEWAY_AUDIT_ADMIN_TOKEN"]
            ?? defaults.string(forKey: "OneWay.SecurityAdminToken")
            ?? defaults.string(forKey: "OneWay.PrivacyAdminToken")
            ?? defaults.string(forKey: "OneWay.AuditAdminToken")
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
#else
    static func applyAdminHeader(to request: inout URLRequest, path: String, baseURL: URL) {}
#endif
}

final class APIClient {
    static let shared = APIClient(baseURLString: APIConfig.baseURL)

    let baseURL: URL

    private let session: URLSession
    private let logger = Logger(subsystem: "app.oneway.ios", category: "api")
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURLString: String, session: URLSession? = nil) {
        guard let url = URL(string: baseURLString) else {
            fatalError("Invalid APIConfig.baseURL: \(baseURLString)")
        }
        self.baseURL = url
        self.session = session ?? Self.makeSession()
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        _ = OneWayConnectivity.shared
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
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
            let redactedError = PrivacyLog.redact(error.localizedDescription)
            logger.error("Backend health check failed: \(redactedError, privacy: .public)")
            return .unreachable(redactedError)
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

    func download(_ path: String, requiresAuth: Bool = true) async throws -> Data {
        let request = try makeRequest(path: path, method: "GET", queryItems: [], body: nil, requiresAuth: requiresAuth)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
            throw APIClientError.server(statusCode: http.statusCode, message: envelope?.message ?? envelope?.error ?? "Download failed.")
        }
        return data
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        requiresAuth: Bool = true,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let encodedBody = try encoder.encode(body)
        let request = try makeRequest(
            path: path,
            method: "POST",
            queryItems: [],
            body: encodedBody,
            requiresAuth: requiresAuth,
            extraHeaders: headers
        )
        return try await send(request)
    }

    func put<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let encodedBody = try encoder.encode(body)
        let request = try makeRequest(
            path: path,
            method: "PUT",
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

    func delete<Response: Decodable>(
        _ path: String,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let request = try makeRequest(
            path: path,
            method: "DELETE",
            queryItems: [],
            body: nil,
            requiresAuth: requiresAuth
        )
        return try await send(request)
    }

    func delete<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        requiresAuth: Bool = true
    ) async throws -> Response {
        let request = try makeRequest(
            path: path,
            method: "DELETE",
            queryItems: [],
            body: try encoder.encode(body),
            requiresAuth: requiresAuth
        )
        return try await send(request)
    }

    func uploadMultipart<Response: Decodable>(
        _ path: String,
        fileFieldName: String = "image",
        fileName: String,
        mimeType: String,
        data: Data,
        fields: [String: String] = [:],
        requiresAuth: Bool = true
    ) async throws -> Response {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try makeRequest(
            path: path,
            method: "POST",
            queryItems: [],
            body: nil,
            requiresAuth: requiresAuth
        )
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            fieldName: fileFieldName,
            fileName: fileName,
            mimeType: mimeType,
            data: data,
            fields: fields,
            boundary: boundary
        )
        return try await send(request)
    }

    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?,
        requiresAuth: Bool,
        extraHeaders: [String: String] = [:]
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

        var request = URLRequest(
            url: finalURL,
            cachePolicy: method == "GET" ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
            timeoutInterval: timeoutInterval(for: sanitizedPath, method: method)
        )
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "GET" {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresAuth {
            let authorization = DevAuth.authorizationHeader(forPath: sanitizedPath, baseURL: baseURL)
                ?? AuthTokenStore.shared.authenticatedAuthorizationHeader()
            guard let authorization else {
#if DEBUG
                print("[Auth] protected request deferred path=/\(sanitizedPath) reason=missing_session")
#endif
                throw OneWayNetworkError.unauthorized
            }
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            AdminDebugAuth.applyAdminHeader(to: &request, path: sanitizedPath, baseURL: baseURL)
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let prefix = logPrefix(for: request.url?.path ?? "")
        let method = request.httpMethod ?? "GET"
        let startedAt = Date()
        var lastError: Error?

        for attempt in 0...2 {
#if DEBUG
            print(
                "\(prefix) request.start",
                "method=\(method)",
                "url=\(PrivacyLog.redactURL(request.url))",
                "route=\(request.url?.path ?? "/")",
                "authAttached=\(request.value(forHTTPHeaderField: "Authorization") != nil)",
                "attempt=\(attempt + 1)",
                "network=\(OneWayConnectivity.shared.state.rawValue)",
                "startedAt=\(ISO8601DateFormatter().string(from: Date()))"
            )
#endif

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
#if DEBUG
                var fallbackResult: (Data, URLResponse)?
                var fallbackError: Error?
                for fallbackRequest in debugLANFallbackRequests(for: request, after: error) {
                    do {
                        print("\(prefix) retrying explicit local fallback url=\(PrivacyLog.redactURL(fallbackRequest.url))")
                        fallbackResult = try await session.data(for: fallbackRequest)
                        fallbackError = nil
                        break
                    } catch {
                        fallbackError = error
                    }
                }
                if let fallbackResult {
                    data = fallbackResult.0
                    response = fallbackResult.1
                } else {
                    let resolvedError = fallbackError ?? error
                    lastError = resolvedError
                    logFailure(
                        prefix: prefix,
                        request: request,
                        error: resolvedError,
                        attempt: attempt,
                        startedAt: startedAt
                    )
                    if attempt < 2, isTransient(resolvedError) {
                        try await retryDelay(afterAttempt: attempt)
                        continue
                    }
                    throw resolvedError
                }
#else
                lastError = error
                if attempt < 2, isTransient(error) {
                    try await retryDelay(afterAttempt: attempt)
                    continue
                }
                throw error
#endif
            }

            guard let http = response as? HTTPURLResponse else {
                throw APIClientError.invalidResponse
            }

#if DEBUG
            print(
                "\(prefix) request.end",
                "method=\(method)",
                "route=\(request.url?.path ?? "/")",
                "status=\(http.statusCode)",
                "attempt=\(attempt + 1)",
                "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
#endif

            if [502, 503, 504].contains(http.statusCode), attempt < 2 {
                try await retryDelay(afterAttempt: attempt)
                continue
            }

#if DEBUG
            if let path = request.url?.path, path.contains("/auth/") {
                print(
                    "[Auth] response",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))",
                    "method=\(method)",
                    "path=\(path)",
                    "status=\(http.statusCode)",
                    "retryAfter=\(http.value(forHTTPHeaderField: "Retry-After") ?? "nil")"
                )
            }
#endif

            guard (200..<300).contains(http.statusCode) else {
#if DEBUG
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                print("\(prefix) response.error status=\(http.statusCode) body=\(PrivacyLog.redact(bodyText))")
#endif
                throw APIClientError.server(
                    statusCode: http.statusCode,
                    message: extractServerMessage(from: data)
                )
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
                logger.error("Decoding failed: \(PrivacyLog.redact(error.localizedDescription), privacy: .public)")
                throw error
            }
        }

        throw lastError ?? OneWayNetworkError.unknown
    }

    private func retryDelay(afterAttempt attempt: Int) async throws {
        let baseDelay = attempt == 0 ? 0.5 : 1.5
        let jitter = Double.random(in: 0...0.2)
        try await Task.sleep(nanoseconds: UInt64((baseDelay + jitter) * 1_000_000_000))
    }

    private func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func logPrefix(for path: String) -> String {
        if path.contains("/communities") { return "[CommunitiesAPI]" }
        if path.contains("/contacts") || path.contains("/friends") || path.contains("/users/search") {
            return "[ContactsAPI]"
        }
        if path.contains("/auth/") { return "[Auth]" }
        if path == "/health" || path == "/api/health" { return "[BackendHealth]" }
        return "[Network]"
    }

    private func logFailure(
        prefix: String,
        request: URLRequest,
        error: Error,
        attempt: Int,
        startedAt: Date
    ) {
#if DEBUG
        let urlError = error as? URLError
        print(
            "\(prefix) request.failed",
            "method=\(request.httpMethod ?? "GET")",
            "route=\(request.url?.path ?? "/")",
            "attempt=\(attempt + 1)",
            "timedOut=\(urlError?.code == .timedOut)",
            "urlError=\(urlError?.errorCode ?? 0)",
            "network=\(OneWayConnectivity.shared.state.rawValue)",
            "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
            "message=\(PrivacyLog.redact(error.localizedDescription))"
        )
#endif
    }

#if DEBUG
    private func debugLANFallbackRequests(for request: URLRequest, after error: Error) -> [URLRequest] {
        guard shouldUseDebugLANFallback(for: request, after: error),
              let requestURL = request.url,
              var requestComponents = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        else {
            return []
        }

        return APIConfig.debugLANAPIBaseURLs.compactMap { rawBaseURL in
            guard let fallbackBaseURL = URL(string: rawBaseURL),
                  let fallbackComponents = URLComponents(url: fallbackBaseURL, resolvingAgainstBaseURL: false),
                  let fallbackHost = fallbackComponents.host
            else {
                return nil
            }

            requestComponents.scheme = fallbackComponents.scheme
            requestComponents.host = fallbackHost
            requestComponents.port = fallbackComponents.port

            guard let fallbackURL = requestComponents.url else {
                return nil
            }

            guard fallbackURL != requestURL else {
                return nil
            }

            var fallbackRequest = request
            fallbackRequest.url = fallbackURL
            return fallbackRequest
        }
    }

    private func shouldUseDebugLANFallback(for request: URLRequest, after error: Error) -> Bool {
        guard APIConfig.debugLocalOverrideEnabled else {
            return false
        }
        guard let url = request.url,
              let host = url.host?.lowercased() else {
            return false
        }

        let isKnownDebugHost = APIConfig.debugLANAPIBaseURLs.contains { rawBaseURL in
            guard let candidate = URL(string: rawBaseURL),
                  candidate.scheme?.lowercased() == url.scheme?.lowercased(),
                  candidate.host?.lowercased() == host else {
                return false
            }
            return (candidate.port ?? defaultPort(for: candidate.scheme)) == (url.port ?? defaultPort(for: url.scheme))
        }

        guard isKnownDebugHost || host == "api.oneway.is" else {
            return false
        }

        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed,
             .badServerResponse,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
#endif

    private func timeoutInterval(for path: String, method: String) -> TimeInterval {
        let sanitized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if sanitized == "health" {
            return 5
        }

        if sanitized == "api/pstn/preflight" {
            return 3
        }

        if sanitized.hasPrefix("api/pstn/calls/status") || sanitized.range(of: #"^api/pstn/calls/[^/]+$"#, options: .regularExpression) != nil {
            return 3
        }

        if sanitized == "api/pstn/calls/start"
            || sanitized == "api/livekit/token"
            || sanitized == "api/calls/invite"
            || sanitized == "api/calls/accept"
            || sanitized == "api/calls/decline"
            || sanitized == "api/calls/hangup" {
            return 5
        }

        if sanitized.hasPrefix("api/history") || sanitized.hasPrefix("api/voicemail") {
            return 5
        }

        if sanitized == "api/auth/login" || sanitized == "api/auth/register" {
            return 5
        }

        if sanitized == "api/account/profile-status" {
            return 3
        }

        if sanitized == "api/storefronts" && method == "POST" {
            return 10
        }

        return 15
    }

    private func extractServerMessage(from data: Data) -> String {
        if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
            if let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                let requirements = envelope.checklist?.filter { !$0.isEmpty } ?? []
                return requirements.isEmpty ? message : "\(message) \(requirements.joined(separator: "; "))."
            }
            if let error = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines),
               !error.isEmpty {
                return error.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !body.isEmpty else {
            return ""
        }

        let lower = body.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype html") {
            return "Endpoint not found on current server."
        }

        return PrivacyLog.redact(body)
    }

    private func multipartBody(
        fieldName: String,
        fileName: String,
        mimeType: String,
        data: Data,
        fields: [String: String] = [:],
        boundary: String
    ) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8) ?? Data())
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
