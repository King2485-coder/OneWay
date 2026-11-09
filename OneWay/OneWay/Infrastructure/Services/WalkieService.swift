import Foundation

enum WalkieServiceError: LocalizedError {
    case blockedDuringCall

    var errorDescription: String? {
        switch self {
        case .blockedDuringCall:
            return "Chirp is paused while a OneWay call is active."
        }
    }
}

final class WalkieService {
    static let shared = WalkieService()

    private let client: APIClient
    private let baseURL: URL
    private let decoder = JSONDecoder()

    init(client: APIClient = .shared) {
        self.client = client
        self.baseURL = client.baseURL
    }

    func channels() async throws -> WalkieChannelsResponse {
        try await assertChirpNetworkAllowed(endpoint: "api/walkie/channels")
        return try await perform(
            path: "api/walkie/channels",
            method: "GET",
            body: nil,
            requiresAuth: true
        )
    }

    func contacts() async throws -> WalkieContactsResponse {
        try await assertChirpNetworkAllowed(endpoint: "api/walkie/contacts")
        return try await perform(
            path: "api/walkie/contacts",
            method: "GET",
            body: nil,
            requiresAuth: true
        )
    }

    func setFavorite(_ isFavorite: Bool, userId: String) async throws -> WalkieContactsResponse {
        let method = isFavorite ? "POST" : "DELETE"
        let data = try JSONEncoder().encode(EmptyWalkieRequest())
        return try await perform(
            path: "api/walkie/favorites/\(userId)",
            method: method,
            body: method == "POST" ? data : nil,
            requiresAuth: true
        )
    }

    func startSession(target: String) async throws -> WalkieSessionResponse {
        try await assertChirpNetworkAllowed(endpoint: "api/walkie/sessions")
        let data = try JSONEncoder().encode(StartSessionRequest(target: target))
        return try await perform(
            path: "api/walkie/sessions",
            method: "POST",
            body: data,
            requiresAuth: true
        )
    }

    func requestTransmit(sessionId: String) async throws -> WalkieTransmitResponse {
        try await assertChirpNetworkAllowed(endpoint: "api/walkie/sessions/\(sessionId)/transmit/start")
        let data = try JSONEncoder().encode(EmptyWalkieRequest())
        return try await perform(
            path: "api/walkie/sessions/\(sessionId)/transmit/start",
            method: "POST",
            body: data,
            requiresAuth: true
        )
    }

    func releaseTransmit(sessionId: String) async throws -> WalkieTransmitResponse {
        try await assertChirpNetworkAllowed(endpoint: "api/walkie/sessions/\(sessionId)/transmit/end")
        let data = try JSONEncoder().encode(EmptyWalkieRequest())
        return try await perform(
            path: "api/walkie/sessions/\(sessionId)/transmit/end",
            method: "POST",
            body: data,
            requiresAuth: true
        )
    }

    func startGroupSession(name: String, targets: [String]) async throws -> WalkieSessionResponse {
        try await assertChirpNetworkAllowed(endpoint: "api/walkie/sessions")
        let data = try JSONEncoder().encode(StartSessionRequest(
            target: nil,
            targets: targets,
            groupName: name
        ))
        return try await perform(
            path: "api/walkie/sessions",
            method: "POST",
            body: data,
            requiresAuth: true
        )
    }

    func joinSession(sessionId: String) async throws -> WalkieSessionResponse {
        try await assertChirpNetworkAllowed(endpoint: "api/walkie/sessions/\(sessionId)/join")
        let data = try JSONEncoder().encode(EmptyWalkieRequest())
        return try await perform(
            path: "api/walkie/sessions/\(sessionId)/join",
            method: "POST",
            body: data,
            requiresAuth: true
        )
    }

    func endSession(sessionId: String) async throws {
        try await assertChirpNetworkAllowed(endpoint: "api/walkie/sessions/\(sessionId)/end")
        let data = try JSONEncoder().encode(EmptyWalkieRequest())
        let _: EmptyAPIResponse = try await perform(
            path: "api/walkie/sessions/\(sessionId)/end",
            method: "POST",
            body: data,
            requiresAuth: true
        )
    }

    func privacy() async throws -> WalkiePrivacySettings {
        return try await perform(
            path: "api/walkie/privacy",
            method: "GET",
            body: nil,
            requiresAuth: true
        )
    }

    func updatePrivacy(_ settings: WalkiePrivacySettings) async throws -> WalkiePrivacySettings {
        let data = try JSONEncoder().encode(settings)
        return try await perform(
            path: "api/walkie/privacy",
            method: "PATCH",
            body: data,
            requiresAuth: true
        )
    }

    func directChirpSettings() async throws -> WalkiePrivacySettings {
        return try await perform(
            path: "api/chirp/direct/settings",
            method: "GET",
            body: nil,
            requiresAuth: true
        )
    }

    func updateDirectChirpSettings(_ settings: WalkiePrivacySettings) async throws -> WalkiePrivacySettings {
        let data = try JSONEncoder().encode(settings)
        return try await perform(
            path: "api/chirp/direct/settings",
            method: "PUT",
            body: data,
            requiresAuth: true
        )
    }

    func lookupDirectChirp(chirpId: String) async throws -> DirectChirpLookupResponse {
        let data = try JSONEncoder().encode(DirectChirpLookupRequest(chirpId: chirpId))
        return try await perform(
            path: "api/chirp/direct/lookup",
            method: "POST",
            body: data,
            requiresAuth: true
        )
    }

    func requestDirectChirp(chirpId: String) async throws -> DirectChirpRequestResponse {
        let data = try JSONEncoder().encode(DirectChirpStartRequest(
            recipientChirpId: chirpId,
            clientRequestId: UUID().uuidString,
            mode: "private"
        ))
        return try await perform(
            path: "api/chirp/direct/request",
            method: "POST",
            body: data,
            requiresAuth: true
        )
    }

    func incomingDirectChirpRequests() async throws -> DirectChirpRequestsResponse {
        try await assertChirpNetworkAllowed(endpoint: "api/chirp/direct/incoming")
        return try await perform(
            path: "api/chirp/direct/incoming",
            method: "GET",
            body: nil,
            requiresAuth: true
        )
    }

    func outgoingDirectChirpRequests() async throws -> DirectChirpRequestsResponse {
        try await assertChirpNetworkAllowed(endpoint: "api/chirp/direct/outgoing")
        return try await perform(
            path: "api/chirp/direct/outgoing",
            method: "GET",
            body: nil,
            requiresAuth: true
        )
    }

    func acceptDirectChirpRequest(id: String) async throws -> DirectChirpRequestResponse {
        return try await directChirpAction(id: id, action: "accept")
    }

    func declineDirectChirpRequest(id: String) async throws -> DirectChirpRequestResponse {
        return try await directChirpAction(id: id, action: "decline")
    }

    func ignoreDirectChirpRequest(id: String) async throws -> DirectChirpRequestResponse {
        return try await directChirpAction(id: id, action: "ignore")
    }

    func blockDirectChirpRequest(id: String) async throws -> DirectChirpRequestResponse {
        return try await directChirpAction(id: id, action: "block")
    }

    func cancelDirectChirpRequest(id: String) async throws -> DirectChirpRequestResponse {
        return try await perform(
            path: "api/chirp/direct/\(id)",
            method: "DELETE",
            body: nil,
            requiresAuth: true
        )
    }

    @MainActor
    private func assertChirpNetworkAllowed(endpoint: String) throws {
        guard !MediaModeCoordinator.shared.isCallActive else {
            #if DEBUG
            print(
                "CHIRP_NETWORK_REQUEST_BLOCKED_ACTIVE_CALL",
                "endpoint=\(endpoint)",
                "mode=\(MediaModeCoordinator.shared.currentMode.rawValue)",
                "callSessionId=\(PrivacyLog.shortID(MediaModeCoordinator.shared.currentSessionId?.uuidString))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            throw WalkieServiceError.blockedDuringCall
        }
    }

    private func directChirpAction(id: String, action: String) async throws -> DirectChirpRequestResponse {
        let data = try JSONEncoder().encode(EmptyWalkieRequest())
        return try await perform(
            path: "api/chirp/direct/\(id)/\(action)",
            method: "POST",
            body: data,
            requiresAuth: true
        )
    }

    private func perform<Response: Decodable>(
        path: String,
        method: String,
        body: Data?,
        requiresAuth: Bool
    ) async throws -> Response {
        let sanitized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = baseURL.appendingPathComponent(sanitized)

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresAuth {
            let authorization = DevAuth.authorizationHeader(forPath: sanitized, baseURL: baseURL)
                ?? AuthTokenStore.shared.authorizationHeader()
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let performanceStartedAt = OneWayPerformanceLogger.mark(
            "walkie.\(method).\(sanitized.replacingOccurrences(of: "/", with: "."))"
        )
        let target: OneWayPerformanceTarget? = sanitized.contains("api/walkie/sessions") ? .walkieTransmitStart : nil

#if DEBUG
        let shouldTrace = sanitized != "api/walkie/channels"
        print(
            "CHIRP_NETWORK_REQUEST_STARTED",
            "method=\(method)",
            "path=\(sanitized)",
            "tokenAvailable=\(AuthTokenStore.shared.token() != nil)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        if shouldTrace {
            print("📡 WALKIE BASE:", APIConfig.baseURL)
            print("📡 WALKIE START URL:", PrivacyLog.redactURL(url))
            print("📡 WALKIE METHOD:", request.httpMethod ?? "nil")
        }
#endif

        var data: Data?
        var response: URLResponse?
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
#if DEBUG
            let fallbackRequests = debugLANFallbackRequests(for: request, after: error)
            var lastFallbackError: Error?
            for fallbackRequest in fallbackRequests {
                do {
                    print("📡 WALKIE public API failed, retrying LAN fallback:", PrivacyLog.redactURL(fallbackRequest.url))
                    (data, response) = try await URLSession.shared.data(for: fallbackRequest)
                    lastFallbackError = nil
                    break
                } catch {
                    lastFallbackError = error
                    print("📡 WALKIE LAN fallback failed:", PrivacyLog.redactURL(fallbackRequest.url), PrivacyLog.redact(error.localizedDescription))
                }
            }
            if let lastFallbackError {
                throw lastFallbackError
            }
            if fallbackRequests.isEmpty {
#if DEBUG
                print(
                    "CHIRP_NETWORK_REQUEST_FAILED",
                    "path=\(sanitized)",
                    "error=\(PrivacyLog.redact(error.localizedDescription))",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
#endif
                throw error
            }
#else
            throw error
#endif
        }

        guard let data, let response else {
            throw APIClientError.invalidResponse
        }

#if DEBUG
        if shouldTrace || (response as? HTTPURLResponse)?.statusCode != 200 {
            if let http = response as? HTTPURLResponse {
                print("📡 WALKIE STATUS:", http.statusCode)
            }
            print("📡 WALKIE BODY:", PrivacyLog.redact(String(data: data, encoding: .utf8) ?? ""))
        }
#endif

        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

#if DEBUG
        print(
            "CHIRP_NETWORK_REQUEST_COMPLETED",
            "path=\(sanitized)",
            "status=\(http.statusCode)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
#endif

        // Handle unexpected HTML error pages explicitly.
        if let bodyText = String(data: data, encoding: .utf8),
           bodyText.lowercased().contains("<html") {
            throw NSError(
                domain: "Chirp",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Endpoint not found on current server."]
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            _ = OneWayPerformanceLogger.finish(
                "walkie.\(method).\(sanitized.replacingOccurrences(of: "/", with: "."))",
                startedAt: performanceStartedAt,
                target: target,
                metadata: "status=\(http.statusCode)",
                cause: extractServerMessage(from: data)
            )
            throw APIClientError.server(
                statusCode: http.statusCode,
                message: extractServerMessage(from: data)
            )
        }

        if Response.self == EmptyAPIResponse.self {
            _ = OneWayPerformanceLogger.finish(
                "walkie.\(method).\(sanitized.replacingOccurrences(of: "/", with: "."))",
                startedAt: performanceStartedAt,
                target: target,
                metadata: "status=\(http.statusCode)"
            )
            return EmptyAPIResponse() as! Response
        }

        guard !data.isEmpty else {
            throw APIClientError.emptyResponse
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        _ = OneWayPerformanceLogger.finish(
            "walkie.\(method).\(sanitized.replacingOccurrences(of: "/", with: "."))",
            startedAt: performanceStartedAt,
            target: target,
            metadata: "status=\(http.statusCode)"
        )
        return decoded
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

            var fallbackRequest = request
            fallbackRequest.url = fallbackURL
            return fallbackRequest
        }
    }

    private func shouldUseDebugLANFallback(for request: URLRequest, after error: Error) -> Bool {
        guard let host = request.url?.host?.lowercased(),
              host == "api.oneway.is" else {
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
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
#endif

    private func extractServerMessage(from data: Data) -> String {
        if let envelope = try? decoder.decode(WalkieErrorEnvelope.self, from: data) {
            if let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                return message
            }
            if let code = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines),
               !code.isEmpty {
                return code.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct StartSessionRequest: Encodable {
    let target: String?
    let targets: [String]?
    let groupName: String?

    init(target: String) {
        self.target = target
        self.targets = nil
        self.groupName = nil
    }

    init(target: String?, targets: [String]?, groupName: String?) {
        self.target = target
        self.targets = targets
        self.groupName = groupName
    }
}

private struct EmptyWalkieRequest: Encodable {}

private struct DirectChirpLookupRequest: Encodable {
    let chirpId: String
}

private struct DirectChirpStartRequest: Encodable {
    let recipientChirpId: String
    let clientRequestId: String
    let mode: String
}

private struct WalkieErrorEnvelope: Decodable {
    let error: String?
    let message: String?
}
