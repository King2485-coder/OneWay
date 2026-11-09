import Foundation

final class NetworkFriendService: FriendService {
    private struct ContactsResponse: Decodable {
        let contacts: [OneWayContactDTO]
    }

    private struct FriendRequestsResponse: Decodable {
        let requests: [FriendRequestDTO]
    }

    private struct FriendsOverviewResponse: Decodable {
        let contacts: [OneWayContactDTO]
        let incomingRequests: [FriendRequestDTO]
        let outgoingRequests: [FriendRequestDTO]
    }

    private struct ContactEnvelope: Decodable {
        let contact: OneWayContactDTO
    }

    private struct FriendshipResponse: Decodable {
        let success: Bool
        let code: String?
    }

    private struct OneWayContactDTO: Decodable {
        let contactId: String
        let id: String
        let displayName: String
        let handle: String
        let chirpId: String?
        let status: String
        let isIncoming: Bool
        let nickname: String?
    }

    private struct FriendRequestDTO: Decodable {
        let id: String
        let requestId: String?
        let friendshipId: String
        let contactId: String?
        let requesterUserId: String
        let recipientUserId: String
        let peerUserId: String?
        let direction: String?
        let displayName: String
        let handle: String
        let chirpId: String?
        let status: String
        let isIncoming: Bool
        let nickname: String?
        let createdAt: String?
    }

    private struct AddContactRequest: Encodable {
        let handle: String
    }

    private struct FriendRequestBody: Encodable {
        let recipientUserId: String
    }

    private struct UpdateContactRequest: Encodable {
        let displayName: String
    }

    private struct EmptyRequest: Encodable {}

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchFriends() async throws -> [FriendConnection] {
        do {
            let overview: FriendsOverviewResponse = try await client.get("api/friends/overview")
            let accepted = try overview.contacts
                .filter { $0.status == "connected" }
                .map(map)
            let pending = try (overview.incomingRequests + overview.outgoingRequests).map(mapRequest)
            return deduplicated(accepted + pending)
        } catch APIClientError.server(let statusCode, _) where statusCode == 404 {
            // Backward compatibility during a rolling backend deployment.
        }

        async let contactsTask: ContactsResponse = client.get("api/contacts")
        async let incomingTask: FriendRequestsResponse = client.get("api/friends/requests/incoming")
        async let outgoingTask: FriendRequestsResponse = client.get("api/friends/requests/outgoing")

        let contacts = try await contactsTask.contacts
        let incoming = try await incomingTask.requests
        let outgoing = try await outgoingTask.requests

        let accepted = try contacts
            .filter { $0.status == "connected" }
            .map(map)
        let pending = try (incoming + outgoing).map(mapRequest)
        return deduplicated(accepted + pending)
    }

    func searchUsers(query: String) async throws -> [OneWayUserSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response: OneWayUserSearchResponse = try await client.get(
            "api/users/search",
            queryItems: [URLQueryItem(name: "q", value: trimmed)]
        )
        return response.users
    }

    func sendFriendRequest(handle: String) async throws -> FriendConnection {
        let sanitized = sanitizeLookup(handle)
        guard sanitized != nil else { throw FriendServiceError.invalidHandle }

        let results = try await searchUsers(query: sanitized ?? handle)
        guard let target = bestSearchResult(for: sanitized ?? handle, results: results) else {
            throw FriendServiceError.notFound
        }
        return try await sendFriendRequest(to: target.id)
    }

    func sendFriendRequest(to userID: String) async throws -> FriendConnection {
        let _: FriendshipResponse = try await client.post(
            "api/friends/request",
            body: FriendRequestBody(recipientUserId: userID)
        )

        let refreshed = try await fetchFriends()
        if let match = refreshed.first(where: { $0.userID.caseInsensitiveCompare(userID) == .orderedSame }) {
            return match
        }
        throw FriendServiceError.invalidResponse
    }

    func acceptFriendRequest(id: UUID) async throws -> FriendConnection {
        guard let friend = try await fetchFriends().first(where: { $0.id == id }),
              let friendshipID = friend.friendshipID ?? friend.contactID else {
            throw FriendServiceError.notFound
        }

        let _: FriendshipResponse = try await client.post(
            "api/friends/\(friendshipID)/accept",
            body: EmptyRequest()
        )

        let refreshed = try await fetchFriends()
        if let match = refreshed.first(where: { $0.userID.caseInsensitiveCompare(friend.userID) == .orderedSame && $0.status == .connected }) {
            return match
        }
        throw FriendServiceError.invalidResponse
    }

    func declineFriendRequest(id: UUID) async throws {
        guard let friend = try await fetchFriends().first(where: { $0.id == id }),
              let friendshipID = friend.friendshipID ?? friend.contactID else {
            throw FriendServiceError.notFound
        }

        let _: FriendshipResponse = try await client.post(
            "api/friends/\(friendshipID)/decline",
            body: EmptyRequest()
        )
    }

    func ignoreFriendRequest(id: UUID) async throws {
        guard let friend = try await fetchFriends().first(where: { $0.id == id }),
              let friendshipID = friend.friendshipID ?? friend.contactID else {
            throw FriendServiceError.notFound
        }

        let _: FriendshipResponse = try await client.post(
            "api/friends/\(friendshipID)/ignore",
            body: EmptyRequest()
        )
    }

    func blockFriendRequest(id: UUID) async throws {
        guard let friend = try await fetchFriends().first(where: { $0.id == id }),
              let friendshipID = friend.friendshipID ?? friend.contactID else {
            throw FriendServiceError.notFound
        }

        let _: FriendshipResponse = try await client.post(
            "api/friends/\(friendshipID)/block",
            body: EmptyRequest()
        )
    }

    func cancelFriendRequest(id: UUID) async throws {
        guard let friend = try await fetchFriends().first(where: { $0.id == id }),
              let friendshipID = friend.friendshipID ?? friend.contactID else {
            throw FriendServiceError.notFound
        }

        let _: FriendshipResponse = try await client.delete("api/friends/\(friendshipID)")
    }

    func updateFriend(_ friend: FriendConnection, displayName: String) async throws -> FriendConnection {
        guard let contactID = friend.contactID else { throw FriendServiceError.notFound }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FriendServiceError.invalidRequest }

        let response: ContactEnvelope = try await client.patch(
            "api/contacts/\(contactID)",
            body: UpdateContactRequest(displayName: trimmed)
        )
        return try map(response.contact)
    }

    func deleteFriend(_ friend: FriendConnection) async throws {
        guard let contactID = friend.contactID else { throw FriendServiceError.notFound }
        let _: EmptyAPIResponse = try await client.delete("api/contacts/\(contactID)")
    }

    func createInviteLink() async throws -> URL {
        guard let url = URL(string: "https://oneway.app/invite") else {
            throw FriendServiceError.invalidInvite
        }
        return url
    }

    func redeemInviteLink(_ url: URL) async throws -> FriendConnection {
        throw FriendServiceError.invalidInvite
    }

    func observeFriendEvents() -> AsyncStream<FriendRealtimeEvent> {
        FriendRealtimeClient.shared.subscribe(baseURL: client.baseURL)
    }

    static func disconnectRealtime() {
        FriendRealtimeClient.shared.disconnect()
    }

    private func map(_ dto: OneWayContactDTO) throws -> FriendConnection {
        return FriendConnection(
            id: stableFriendUUID(from: dto.id),
            userID: dto.id,
            contactID: dto.contactId,
            displayName: dto.displayName,
            handle: dto.handle,
            chirpID: dto.chirpId,
            status: FriendshipStatus(rawValue: dto.status) ?? .pending,
            isIncomingRequest: dto.isIncoming,
            nickname: dto.nickname
        )
    }

    private func mapRequest(_ dto: FriendRequestDTO) throws -> FriendConnection {
        let currentUserID = AuthTokenStore.shared.currentUserID()
        let normalizedDirection = dto.direction?.lowercased()
        let isIncoming: Bool
        if normalizedDirection == "incoming" {
            guard dto.recipientUserId.caseInsensitiveCompare(currentUserID) == .orderedSame else {
                throw FriendServiceError.invalidResponse
            }
            isIncoming = true
        } else if normalizedDirection == "outgoing" {
            guard dto.requesterUserId.caseInsensitiveCompare(currentUserID) == .orderedSame else {
                throw FriendServiceError.invalidResponse
            }
            isIncoming = false
        } else if dto.recipientUserId.caseInsensitiveCompare(currentUserID) == .orderedSame {
            isIncoming = true
        } else if dto.requesterUserId.caseInsensitiveCompare(currentUserID) == .orderedSame {
            isIncoming = false
        } else {
            throw FriendServiceError.invalidResponse
        }

        let peerUserID = isIncoming ? dto.requesterUserId : dto.recipientUserId
        if let peerUserId = dto.peerUserId,
           peerUserId.caseInsensitiveCompare(peerUserID) != .orderedSame {
            throw FriendServiceError.invalidResponse
        }

        return FriendConnection(
            id: stableFriendUUID(from: dto.requestId ?? dto.friendshipId),
            userID: peerUserID,
            friendshipID: dto.friendshipId,
            contactID: dto.contactId,
            displayName: dto.displayName,
            handle: dto.handle,
            chirpID: dto.chirpId,
            status: .pending,
            isIncomingRequest: isIncoming,
            createdAt: dto.createdAt,
            nickname: dto.nickname
        )
    }

    private func deduplicated(_ friends: [FriendConnection]) -> [FriendConnection] {
        var seen = Set<String>()
        var result: [FriendConnection] = []
        for friend in friends {
            let key = "\(friend.userID.lowercased())-\(friend.status.rawValue)-\(friend.friendshipID ?? friend.contactID ?? "")"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(friend)
        }
        return result
    }

    private func bestSearchResult(for query: String, results: [OneWayUserSearchResult]) -> OneWayUserSearchResult? {
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedChirp = query
            .uppercased()
            .replacingOccurrences(of: #"[^A-Z0-9]"#, with: "", options: .regularExpression)

        return results.first { result in
            result.id.caseInsensitiveCompare(query) == .orderedSame
            || result.onewayId?.lowercased() == normalizedQuery
            || result.chirpId?.uppercased().replacingOccurrences(of: #"[^A-Z0-9]"#, with: "", options: .regularExpression) == normalizedChirp
        } ?? results.first
    }

    private func sanitizeLookup(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let chirp = trimmed
            .uppercased()
            .replacingOccurrences(of: #"[^A-Z0-9]"#, with: "", options: .regularExpression)
        if chirp.range(of: #"^(OW)?[0-9]{6,9}$"#, options: .regularExpression) != nil {
            return trimmed.uppercased()
        }

        if trimmed.contains("@"), trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil {
            return trimmed.lowercased()
        }

        let digits = trimmed.filter(\.isNumber)
        if digits.count >= 10,
           trimmed.range(of: #"^[+()0-9.\-\s]{10,24}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        let compactHandle = trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !trimmed.isEmpty else { return nil }
        let prefixed = compactHandle.hasPrefix("@") ? compactHandle : "@\(compactHandle)"
        guard prefixed.range(of: #"^@[a-z0-9._-]{2,32}$"#, options: .regularExpression) != nil else {
            if trimmed.range(of: #"^[A-Za-z0-9_.\-\s]{2,64}$"#, options: .regularExpression) != nil {
                return trimmed
            }
            return nil
        }
        return prefixed
    }

    private func stableFriendUUID(from value: String) -> UUID {
        if let uuid = UUID(uuidString: value) {
            return uuid
        }

        let bytes = Array(value.utf8)
        var hash = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.enumerated() {
            hash[index % 16] = hash[index % 16] &+ byte &+ UInt8(truncatingIfNeeded: index &* 31)
        }
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80

        let tuple = (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5],
            hash[6], hash[7],
            hash[8], hash[9],
            hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
        )
        return UUID(uuid: tuple)
    }
}

private struct FriendRealtimeEnvelope: Decodable {
    let type: String
    let payload: FriendRealtimePayload?
}

private struct FriendRealtimePayload: Decodable {
    let requestId: String?
    let friendshipId: String?
    let requesterUserId: String?
    let recipientUserId: String?
}

private struct FriendRealtimeWireMessage: Encodable {
    let type: String
    let payload: [String: String]
}

private final class FriendRealtimeClient {
    static let shared = FriendRealtimeClient()

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var authObserverTask: Task<Void, Never>?
    private var isConnecting = false
    private var continuations: [UUID: AsyncStream<FriendRealtimeEvent>.Continuation] = [:]
    private var baseURL: URL?
    private var authenticatedUserID: String?
    private var authenticatedAuthorization: String?

    private init() {}

    func subscribe(baseURL: URL) -> AsyncStream<FriendRealtimeEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
            }
            startAuthObserverIfNeeded()
            connectIfNeeded(baseURL: baseURL)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock {
                    self.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func connectIfNeeded(baseURL: URL) {
        let currentUserID = AuthTokenStore.shared.currentUserID()
        let authorization = DevAuth.authorizationHeader(forPath: "ws/friends", baseURL: baseURL)
            ?? AuthTokenStore.shared.authorizationHeader()
        var staleTask: URLSessionWebSocketTask?

        lock.lock()
        self.baseURL = baseURL
        let shouldResetForAuth = task != nil
            && (authenticatedUserID != currentUserID || authenticatedAuthorization != authorization)
        if shouldResetForAuth {
            staleTask = task
            task = nil
            isConnecting = false
            authenticatedUserID = nil
            authenticatedAuthorization = nil
        }
        let shouldConnect = task == nil && !isConnecting
        if shouldConnect { isConnecting = true }
        lock.unlock()
        if shouldResetForAuth {
            staleTask?.cancel(with: .goingAway, reason: nil)
            receiveTask?.cancel()
            heartbeatTask?.cancel()
            #if DEBUG
            print("chirp.request.socket.auth_changed", PrivacyLog.shortID(currentUserID))
            #endif
        }
        guard shouldConnect else { return }

        guard let url = Self.webSocketURL(baseURL: baseURL) else {
            finishAll()
            return
        }

        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let nextTask = URLSession.shared.webSocketTask(with: request)
        lock.withLock {
            task = nextTask
            isConnecting = false
            authenticatedUserID = currentUserID
            authenticatedAuthorization = authorization
        }
        #if DEBUG
        print("chirp.request.socket.connected", PrivacyLog.shortID(currentUserID))
        #endif
        nextTask.resume()
        send(FriendRealtimeWireMessage(
            type: "auth",
            payload: ["token": authorization.replacingOccurrences(of: "Bearer ", with: "")]
        ))
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        startHeartbeat()
    }

    private func receiveLoop() async {
        let decoder = JSONDecoder()
        while !Task.isCancelled {
            do {
                guard let task = lock.withLock({ task }) else { return }
                let received = try await task.receive()
                lock.withLock {
                    reconnectAttempt = 0
                    reconnectTask = nil
                }
                let data: Data
                switch received {
                case .data(let raw):
                    data = raw
                case .string(let text):
                    data = Data(text.utf8)
                @unknown default:
                    continue
                }

                let envelope = try decoder.decode(FriendRealtimeEnvelope.self, from: data)
                guard let event = FriendRealtimeEvent(wireValue: envelope.type) else {
                    continue
                }
                #if DEBUG
                if envelope.type.hasPrefix("chirp.request") {
                    print(
                        "chirp.request.realtime.received",
                        PrivacyLog.shortID(envelope.payload?.requestId ?? envelope.payload?.friendshipId ?? "unknown"),
                        PrivacyLog.shortID(envelope.payload?.requesterUserId ?? "unknown"),
                        PrivacyLog.shortID(envelope.payload?.recipientUserId ?? "unknown")
                    )
                }
                #endif
                yield(event)
            } catch {
                scheduleReconnect()
                return
            }
        }
    }

    private func yield(_ event: FriendRealtimeEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    private func send(_ message: FriendRealtimeWireMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.withLock { task }?.send(.string(text)) { _ in }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.send(FriendRealtimeWireMessage(type: "ping", payload: [:]))
            }
        }
    }

    private func scheduleReconnect() {
        let reconnect = lock.withLock { () -> (URL?, Task<Void, Never>?, TimeInterval) in
            let existing = reconnectTask
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            isConnecting = false
            authenticatedUserID = nil
            authenticatedAuthorization = nil
            reconnectAttempt = min(reconnectAttempt + 1, 6)
            let delay = min(pow(2, Double(reconnectAttempt - 1)), 30)
            return (baseURL, existing, delay)
        }
        reconnect.1?.cancel()
        guard let baseURL = reconnect.0 else {
            finishAll()
            return
        }
        let scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(reconnect.2 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connectIfNeeded(baseURL: baseURL)
        }
        lock.withLock { reconnectTask = scheduled }
    }

    private func finishAll() {
        let all = lock.withLock {
            let values = Array(continuations.values)
            continuations.removeAll()
            task = nil
            isConnecting = false
            authenticatedUserID = nil
            authenticatedAuthorization = nil
            return values
        }
        for continuation in all {
            continuation.finish()
        }
    }

    func disconnect() {
        let all = lock.withLock {
            let values = Array(continuations.values)
            continuations.removeAll()
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            receiveTask?.cancel()
            receiveTask = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            authObserverTask?.cancel()
            authObserverTask = nil
            baseURL = nil
            isConnecting = false
            authenticatedUserID = nil
            authenticatedAuthorization = nil
            return values
        }
        for continuation in all {
            continuation.finish()
        }
    }

    private func startAuthObserverIfNeeded() {
        let shouldStart = lock.withLock { () -> Bool in
            guard authObserverTask == nil else { return false }
            return true
        }
        guard shouldStart else { return }

        let observer = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AuthTokenStore.tokenDidChangeNotification) {
                self?.reconnectForAuthChange()
            }
        }
        lock.withLock {
            authObserverTask = observer
        }
    }

    private func reconnectForAuthChange() {
        let baseURL = lock.withLock { () -> URL? in
            let value = self.baseURL
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            isConnecting = false
            authenticatedUserID = nil
            authenticatedAuthorization = nil
            return value
        }
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        reconnectTask = nil
        lock.withLock { reconnectAttempt = 0 }
        guard let baseURL else { return }
        connectIfNeeded(baseURL: baseURL)
    }

    private static func webSocketURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            return nil
        }
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "ws/friends"
        return components.url
    }
}
