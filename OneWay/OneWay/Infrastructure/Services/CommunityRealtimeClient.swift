import Foundation

enum CommunityRealtimeConnectionState: Equatable {
    case connecting
    case connected
    case disconnected
}

final class CommunityRealtimeClient: @unchecked Sendable {
    static let shared = CommunityRealtimeClient()

    private struct RealtimeEnvelope: Decodable {
        let type: String
        let payload: RealtimePayload?
    }

    private struct RealtimePayload: Decodable {
        let message: CommunityMessageDTO?
        let community: CommunityDTO?
        let code: String?
        let error: String?
        let clientMessageId: String?
        let communityId: String?
        let userId: String?
        let handle: String?
        let displayName: String?
        let messageId: String?
    }

    private struct WireMessage: Encodable {
        let type: String
        let payload: [String: String]
    }

    private struct CommunityDTO: Decodable {
        let id: String
        let name: String
        let normalizedName: String?
        let description: String
        let creatorUserId: String
        let creatorHandle: String
        let visibility: String
        let blockedUserIds: [String]?
        let bannedUserIds: [String]?
        let members: [CommunityMemberDTO]?
        let createdAt: String
        let updatedAt: String
        let deletedAt: String?
    }

    private struct CommunityMemberDTO: Decodable {
        let id: String
        let userId: String?
        let displayName: String
        let handle: String
        let role: String
    }

    private struct CommunityMessageDTO: Decodable {
        let id: String
        let clientMessageId: String?
        let communityId: String
        let senderId: String
        let senderHandle: String
        let senderDisplayName: String
        let body: String
        let status: String
        let createdAt: String
    }

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var discoveryContinuations: [UUID: AsyncThrowingStream<Community, Error>.Continuation] = [:]
    private var messageContinuations: [UUID: [UUID: AsyncThrowingStream<CommunityMessage, Error>.Continuation]] = [:]
    private var stateContinuations: [UUID: AsyncStream<CommunityRealtimeConnectionState>.Continuation] = [:]
    private var typingContinuations: [UUID: [UUID: AsyncStream<CommunityTypingEvent>.Continuation]] = [:]
    private var presenceContinuations: [UUID: [UUID: AsyncStream<CommunityPresenceEvent>.Continuation]] = [:]
    private var readContinuations: [UUID: [UUID: AsyncStream<CommunityReadEvent>.Continuation]] = [:]
    private var pendingMessageSends: [UUID: CheckedContinuation<CommunityMessage, Error>] = [:]
    private var pendingMessageSendStartedAt: [UUID: Date] = [:]
    private var subscribedCommunityIds = Set<UUID>()
    private var isConnecting = false
    private var reconnectAttempt = 0
    private var connectionState: CommunityRealtimeConnectionState = .disconnected
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectionStartedAt: Date?
    private var lastPongAt: Date?
    private var lastReconnectStartedAt: Date?

    private init() {}

    func preconnect(baseURL: URL) {
        OneWayPerformanceLogger.profile("socket.preconnect.requested", metadata: "baseURL=\(PrivacyLog.redactURL(baseURL))")
        connectIfNeeded(baseURL: baseURL)
    }

    func disconnect() {
        finishAll(APIClientError.server(statusCode: 401, message: "Signed out."))
    }

    func healthSnapshot() -> String {
        lock.withLock {
            let pongAge = lastPongAt.map { "\(Int(Date().timeIntervalSince($0) * 1_000))ms" } ?? "never"
            return [
                "state=\(connectionState)",
                "subscribedRooms=\(subscribedCommunityIds.count)",
                "pendingSends=\(pendingMessageSends.count)",
                "reconnectAttempt=\(reconnectAttempt)",
                "lastPongAge=\(pongAge)"
            ].joined(separator: " ")
        }
    }

    func subscribeToDiscovery(baseURL: URL) -> AsyncThrowingStream<Community, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            lock.withLock {
                discoveryContinuations[id] = continuation
            }
            connectIfNeeded(baseURL: baseURL)
            send(WireMessage(type: "community.discovery.subscribe", payload: [:]))
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.discoveryContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func subscribeToMessages(communityId: UUID, baseURL: URL) -> AsyncThrowingStream<CommunityMessage, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            lock.withLock {
                messageContinuations[communityId, default: [:]][id] = continuation
                subscribedCommunityIds.insert(communityId)
            }
            connectIfNeeded(baseURL: baseURL)
            send(WireMessage(type: "community.subscribe", payload: ["communityId": communityId.uuidString.lowercased()]))
            continuation.onTermination = { [weak self] _ in
                self?.removeMessageContinuation(id: id, communityId: communityId)
            }
        }
    }

    func subscribeToConnectionState() -> AsyncStream<CommunityRealtimeConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            let current = lock.withLock { () -> CommunityRealtimeConnectionState in
                stateContinuations[id] = continuation
                return connectionState
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.stateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func subscribeToTyping(communityId: UUID, baseURL: URL) -> AsyncStream<CommunityTypingEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                typingContinuations[communityId, default: [:]][id] = continuation
                subscribedCommunityIds.insert(communityId)
            }
            connectIfNeeded(baseURL: baseURL)
            send(WireMessage(type: "community.joinRoom", payload: ["communityId": communityId.uuidString.lowercased()]))
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.typingContinuations[communityId]?.removeValue(forKey: id)
                    if self?.typingContinuations[communityId]?.isEmpty == true {
                        self?.typingContinuations.removeValue(forKey: communityId)
                    }
                }
            }
        }
    }

    func sendTyping(communityId: UUID, isTyping: Bool, baseURL: URL) {
        connectIfNeeded(baseURL: baseURL)
        send(WireMessage(
            type: isTyping ? "community.typing.started" : "community.typing.stopped",
            payload: ["communityId": communityId.uuidString.lowercased()]
        ))
    }

    func subscribeToPresence(communityId: UUID, baseURL: URL) -> AsyncStream<CommunityPresenceEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                presenceContinuations[communityId, default: [:]][id] = continuation
                subscribedCommunityIds.insert(communityId)
            }
            connectIfNeeded(baseURL: baseURL)
            send(WireMessage(type: "community.joinRoom", payload: ["communityId": communityId.uuidString.lowercased()]))
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.presenceContinuations[communityId]?.removeValue(forKey: id)
                    if self?.presenceContinuations[communityId]?.isEmpty == true {
                        self?.presenceContinuations.removeValue(forKey: communityId)
                    }
                }
            }
        }
    }

    func subscribeToReads(communityId: UUID, baseURL: URL) -> AsyncStream<CommunityReadEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                readContinuations[communityId, default: [:]][id] = continuation
                subscribedCommunityIds.insert(communityId)
            }
            connectIfNeeded(baseURL: baseURL)
            send(WireMessage(type: "community.joinRoom", payload: ["communityId": communityId.uuidString.lowercased()]))
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.readContinuations[communityId]?.removeValue(forKey: id)
                    if self?.readContinuations[communityId]?.isEmpty == true {
                        self?.readContinuations.removeValue(forKey: communityId)
                    }
                }
            }
        }
    }

    func sendRead(communityId: UUID, messageId: UUID, baseURL: URL) {
        connectIfNeeded(baseURL: baseURL)
        send(WireMessage(
            type: "community.read",
            payload: [
                "communityId": communityId.uuidString.lowercased(),
                "messageId": messageId.uuidString.lowercased(),
            ]
        ))
    }

    func sendMessage(
        body: String,
        communityId: UUID,
        clientMessageId: UUID,
        baseURL: URL
    ) async throws -> CommunityMessage {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIClientError.invalidResponse }
        let state = lock.withLock { connectionState }
        guard state == .connected else {
            connectIfNeeded(baseURL: baseURL)
            throw APIClientError.server(statusCode: 503, message: "Realtime socket is not connected.")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let sendStartedAt = Date()
                let shouldSend = lock.withLock { () -> Bool in
                    guard pendingMessageSends[clientMessageId] == nil else { return false }
                    pendingMessageSends[clientMessageId] = continuation
                    pendingMessageSendStartedAt[clientMessageId] = sendStartedAt
                    subscribedCommunityIds.insert(communityId)
                    return true
                }
                guard shouldSend else {
                    continuation.resume(throwing: APIClientError.server(statusCode: 409, message: "Duplicate send in progress."))
                    return
                }
                send(WireMessage(type: "community.joinRoom", payload: ["communityId": communityId.uuidString.lowercased()]))
                send(WireMessage(
                    type: "community.message.send",
                    payload: [
                        "communityId": communityId.uuidString.lowercased(),
                        "clientMessageId": clientMessageId.uuidString.lowercased(),
                        "body": trimmed,
                    ]
                )) { [weak self] error in
                    CommunityPerformanceLogger.profile(
                        "client.websocket.send.writeCallback",
                        clientMessageId: clientMessageId,
                        communityId: communityId,
                        startedAt: sendStartedAt,
                        metadata: error.map { "error=\(PrivacyLog.redact($0.localizedDescription))" } ?? "ok=true"
                    )
                    if let error {
                        self?.finishPendingSend(clientMessageId: clientMessageId, result: .failure(error))
                    }
                }
                CommunityPerformanceLogger.profile(
                    "client.websocket.send.enqueued",
                    clientMessageId: clientMessageId,
                    communityId: communityId,
                    startedAt: sendStartedAt
                )
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self?.finishPendingSend(
                        clientMessageId: clientMessageId,
                        result: .failure(APIClientError.server(statusCode: 504, message: "Realtime send timed out."))
                    )
                }
            }
        } onCancel: {
            finishPendingSend(
                clientMessageId: clientMessageId,
                result: .failure(CancellationError())
            )
        }
    }

    private func connectIfNeeded(baseURL: URL) {
        lock.lock()
        let shouldConnect = task == nil && !isConnecting
        if shouldConnect { isConnecting = true }
        lock.unlock()
        guard shouldConnect else { return }
        publishState(.connecting)
        let connectStartedAt = OneWayPerformanceLogger.mark("socket.connect", metadata: "baseURL=\(PrivacyLog.redactURL(baseURL))")

        guard let url = Self.webSocketURL(baseURL: baseURL) else {
            finishAll(APIClientError.invalidBaseURL(baseURL.absoluteString))
            return
        }

        var request = URLRequest(url: url)
        let authorization = DevAuth.authorizationHeader(forPath: "ws/communities", baseURL: baseURL)
            ?? AuthTokenStore.shared.authorizationHeader()
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let nextTask = URLSession.shared.webSocketTask(with: request)
        lock.withLock {
            task = nextTask
            isConnecting = false
            connectionStartedAt = connectStartedAt
        }
        nextTask.resume()

        send(WireMessage(type: "auth", payload: ["token": authorization.replacingOccurrences(of: "Bearer ", with: "")]))
        send(WireMessage(type: "community.discovery.subscribe", payload: [:]))
        let communityIds = lock.withLock { subscribedCommunityIds }
        for communityId in communityIds {
            send(WireMessage(type: "community.subscribe", payload: ["communityId": communityId.uuidString.lowercased()]))
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(baseURL: baseURL)
        }
        startHeartbeat(baseURL: baseURL)
    }

    private func receiveLoop(baseURL: URL) async {
        let decoder = JSONDecoder()
        while !Task.isCancelled {
            do {
                guard let task = lock.withLock({ task }) else { return }
                let received = try await task.receive()
                let data: Data
                switch received {
                case .data(let raw):
                    data = raw
                case .string(let text):
                    data = Data(text.utf8)
                @unknown default:
                    continue
                }

                let envelope = try decoder.decode(RealtimeEnvelope.self, from: data)
                lock.withLock { lastPongAt = Date() }
                if let message = envelope.payload?.message,
                   let clientMessageId = message.clientMessageId.flatMap(UUID.init(uuidString:)),
                   let communityId = UUID(uuidString: message.communityId) {
                    CommunityPerformanceLogger.profile(
                        "client.websocket.receive.message",
                        clientMessageId: clientMessageId,
                        communityId: communityId,
                        metadata: "event=\(envelope.type)"
                    )
                }
                handle(envelope)
            } catch {
                scheduleReconnect(baseURL: baseURL, error: error)
                return
            }
        }
    }

    private func handle(_ envelope: RealtimeEnvelope) {
        switch envelope.type {
        case "community.subscribed", "community.discovery.subscribed":
            let (connectStartedAt, reconnectStartedAt) = lock.withLock { () -> (Date?, Date?) in
                reconnectAttempt = 0
                let connectStartedAt = connectionStartedAt
                connectionStartedAt = nil
                let reconnectStartedAt = lastReconnectStartedAt
                lastReconnectStartedAt = nil
                lastPongAt = Date()
                return (connectStartedAt, reconnectStartedAt)
            }
            if let connectStartedAt {
                _ = OneWayPerformanceLogger.finish("socket.connect", startedAt: connectStartedAt, target: .reconnectAfterDrop, metadata: "event=\(envelope.type)")
            }
            if let reconnectStartedAt {
                _ = OneWayPerformanceLogger.finish("socket.reconnect", startedAt: reconnectStartedAt, target: .reconnectAfterDrop, metadata: "event=\(envelope.type)")
            }
            publishState(.connected)
        case "community.created", "community.updated", "community.deleted", "community.member.joined", "community.member.left", "community.member.removed", "community.member.blocked":
            guard let dto = envelope.payload?.community, let community = Self.mapCommunity(dto) else { return }
            let continuations = lock.withLock { Array(discoveryContinuations.values) }
            continuations.forEach { $0.yield(community) }
        case "community.message.created", "community.message.updated", "community.message.deleted":
            guard let dto = envelope.payload?.message, let message = Self.mapMessage(dto) else { return }
            if let clientMessageId = message.clientMessageId {
                finishPendingSend(clientMessageId: clientMessageId, result: .success(message))
            }
            let continuations = lock.withLock { Array(messageContinuations[message.communityID]?.values ?? [:].values) }
            continuations.forEach { $0.yield(message) }
        case "community.typing.started", "community.typing.stopped":
            guard let payload = envelope.payload,
                  let communityIdString = payload.communityId,
                  let communityId = UUID(uuidString: communityIdString) else { return }
            let event = CommunityTypingEvent(
                communityId: communityId,
                userId: payload.userId ?? "",
                handle: payload.handle ?? "@oneway",
                displayName: payload.displayName ?? payload.handle ?? "OneWay User",
                isTyping: envelope.type == "community.typing.started"
            )
            let continuations = lock.withLock { Array(typingContinuations[communityId]?.values ?? [:].values) }
            continuations.forEach { $0.yield(event) }
        case "community.user.online", "community.user.offline":
            guard let payload = envelope.payload,
                  let communityIdString = payload.communityId,
                  let communityId = UUID(uuidString: communityIdString),
                  let userId = payload.userId else { return }
            let event = CommunityPresenceEvent(
                communityId: communityId,
                userId: userId,
                isOnline: envelope.type == "community.user.online"
            )
            let continuations = lock.withLock { Array(presenceContinuations[communityId]?.values ?? [:].values) }
            continuations.forEach { $0.yield(event) }
        case "community.message.read":
            guard let payload = envelope.payload,
                  let communityIdString = payload.communityId,
                  let communityId = UUID(uuidString: communityIdString),
                  let messageIdString = payload.messageId,
                  let messageId = UUID(uuidString: messageIdString),
                  let userId = payload.userId else { return }
            let event = CommunityReadEvent(communityId: communityId, messageId: messageId, userId: userId)
            let continuations = lock.withLock { Array(readContinuations[communityId]?.values ?? [:].values) }
            continuations.forEach { $0.yield(event) }
        case "error":
            let message = envelope.payload?.error ?? envelope.payload?.code ?? "Realtime connection failed."
            if let clientMessageId = envelope.payload?.clientMessageId.flatMap(UUID.init(uuidString:)) {
                finishPendingSend(clientMessageId: clientMessageId, result: .failure(APIClientError.server(statusCode: 503, message: message)))
            } else {
                finishAll(APIClientError.server(statusCode: 503, message: message))
            }
        default:
            break
        }
    }

    private func send(_ message: WireMessage) {
        send(message, completion: nil)
    }

    private func send(_ message: WireMessage, completion: ((Error?) -> Void)?) {
        guard let task = lock.withLock({ task }),
              let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            completion?(APIClientError.server(statusCode: 503, message: "Realtime socket is not connected."))
            return
        }
        task.send(.string(text)) { error in
            completion?(error)
        }
    }

    private func scheduleReconnect(baseURL: URL, error: Error) {
        publishState(.disconnected)
        stopHeartbeat()
        lock.withLock {
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            receiveTask = nil
            isConnecting = false
            reconnectAttempt += 1
            lastReconnectStartedAt = Date()
        }
        let attempt = lock.withLock { reconnectAttempt }
        let baseDelay = min(pow(2.0, Double(attempt)), 8.0)
        let jitter = Double.random(in: 0.05...0.45)
        let delay = min(baseDelay + jitter, 8.5)
        OneWayPerformanceLogger.profile(
            "socket.reconnect.scheduled",
            metadata: "attempt=\(attempt) delayMs=\(Int(delay * 1_000)) error=\(PrivacyLog.redact(error.localizedDescription))"
        )
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            let hasListeners = self.lock.withLock {
                !self.discoveryContinuations.isEmpty
                    || !self.messageContinuations.isEmpty
                    || !self.typingContinuations.isEmpty
                    || !self.presenceContinuations.isEmpty
                    || !self.readContinuations.isEmpty
            }
            if hasListeners {
                self.connectIfNeeded(baseURL: baseURL)
            } else {
                self.finishAll(error)
            }
        }
    }

    private func startHeartbeat(baseURL: URL) {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                let currentTask = self.lock.withLock { self.task }
                guard let currentTask else { continue }
                let pingStartedAt = Date()
                currentTask.sendPing { [weak self] error in
                    guard let self else { return }
                    if let error {
                        OneWayPerformanceLogger.profile(
                            "socket.heartbeat.failed",
                            startedAt: pingStartedAt,
                            metadata: "error=\(PrivacyLog.redact(error.localizedDescription))"
                        )
                        self.scheduleReconnect(baseURL: baseURL, error: error)
                    } else {
                        self.lock.withLock { self.lastPongAt = Date() }
                        OneWayPerformanceLogger.profile(
                            "socket.heartbeat.ok",
                            startedAt: pingStartedAt
                        )
                    }
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func finishAll(_ error: Error) {
        let continuations = lock.withLock { () -> (
            [AsyncThrowingStream<Community, Error>.Continuation],
            [AsyncThrowingStream<CommunityMessage, Error>.Continuation],
            [AsyncStream<CommunityTypingEvent>.Continuation],
            [AsyncStream<CommunityPresenceEvent>.Continuation],
            [AsyncStream<CommunityReadEvent>.Continuation]
        ) in
            let communityContinuations = Array(discoveryContinuations.values)
            let messageContinuations = self.messageContinuations.values.flatMap { Array($0.values) }
            let typingContinuations = self.typingContinuations.values.flatMap { Array($0.values) }
            let presenceContinuations = self.presenceContinuations.values.flatMap { Array($0.values) }
            let readContinuations = self.readContinuations.values.flatMap { Array($0.values) }
            let pendingSends = Array(pendingMessageSends.values)
            discoveryContinuations.removeAll()
            self.messageContinuations.removeAll()
            self.typingContinuations.removeAll()
            self.presenceContinuations.removeAll()
            self.readContinuations.removeAll()
            pendingMessageSends.removeAll()
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            receiveTask = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            isConnecting = false
            pendingSends.forEach { $0.resume(throwing: error) }
            return (communityContinuations, messageContinuations, typingContinuations, presenceContinuations, readContinuations)
        }
        publishState(.disconnected)
        for continuation in continuations.0 {
            continuation.finish(throwing: error)
        }
        for continuation in continuations.1 {
            continuation.finish(throwing: error)
        }
        for continuation in continuations.2 {
            continuation.finish()
        }
        for continuation in continuations.3 {
            continuation.finish()
        }
        for continuation in continuations.4 {
            continuation.finish()
        }
    }

    private func publishState(_ state: CommunityRealtimeConnectionState) {
        let continuations = lock.withLock { () -> [AsyncStream<CommunityRealtimeConnectionState>.Continuation] in
            guard connectionState != state else { return [] }
            connectionState = state
            return Array(stateContinuations.values)
        }
        continuations.forEach { $0.yield(state) }
    }

    private func finishPendingSend(clientMessageId: UUID, result: Result<CommunityMessage, Error>) {
        let (continuation, startedAt) = lock.withLock {
            (
                pendingMessageSends.removeValue(forKey: clientMessageId),
                pendingMessageSendStartedAt.removeValue(forKey: clientMessageId)
            )
        }
        guard let continuation else { return }
        switch result {
        case .success(let message):
            CommunityPerformanceLogger.profile(
                "client.websocket.send.confirmed",
                clientMessageId: clientMessageId,
                communityId: message.communityID,
                startedAt: startedAt
            )
            continuation.resume(returning: message)
        case .failure(let error):
            CommunityPerformanceLogger.profile(
                "client.websocket.send.failed",
                clientMessageId: clientMessageId,
                startedAt: startedAt,
                metadata: "error=\(PrivacyLog.redact(error.localizedDescription))"
            )
            continuation.resume(throwing: error)
        }
    }

    private func removeMessageContinuation(id: UUID, communityId: UUID) {
        let shouldUnsubscribe = lock.withLock {
            messageContinuations[communityId]?.removeValue(forKey: id)
            if messageContinuations[communityId]?.isEmpty == true {
                messageContinuations.removeValue(forKey: communityId)
                subscribedCommunityIds.remove(communityId)
                return true
            }
            return false
        }
        if shouldUnsubscribe {
            send(WireMessage(type: "community.unsubscribe", payload: ["communityId": communityId.uuidString.lowercased()]))
        }
    }

    private static func mapCommunity(_ dto: CommunityDTO) -> Community? {
        guard let id = UUID(uuidString: dto.id) else { return nil }
        let members = dto.members?.compactMap(memberUUID) ?? []
        let createdAt = parseDate(dto.createdAt)
        let updatedAt = parseDate(dto.updatedAt)
        let creatorUUID = UUID(uuidString: dto.creatorUserId) ?? id
        return Community(
            id: id,
            name: dto.name,
            normalizedName: dto.normalizedName ?? Community.normalizedName(for: dto.name),
            description: dto.description,
            creatorUserId: dto.creatorUserId,
            creatorHandle: dto.creatorHandle,
            visibility: CommunityVisibility(rawValue: dto.visibility) ?? .public,
            coverImageURL: nil,
            avatarURL: nil,
            ownerID: creatorUUID,
            admins: [creatorUUID],
            moderators: [],
            members: members,
            blockedUserIds: dto.blockedUserIds ?? [],
            bannedUserIds: dto.bannedUserIds ?? [],
            messages: [],
            linkedGroupIDs: [],
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: dto.deletedAt.map(parseDate)
        )
    }

    private static func mapMessage(_ dto: CommunityMessageDTO) -> CommunityMessage? {
        guard let id = UUID(uuidString: dto.id),
              let communityID = UUID(uuidString: dto.communityId) else {
            return nil
        }
        let senderID = UUID(uuidString: dto.senderId) ?? id
        return CommunityMessage(
            id: id,
            clientMessageId: dto.clientMessageId.flatMap(UUID.init(uuidString:)),
            communityID: communityID,
            senderID: senderID,
            senderName: dto.senderDisplayName,
            senderHandle: dto.senderHandle,
            body: dto.body,
            sentAt: parseDate(dto.createdAt),
            deliveryStatus: MessageDeliveryStatus(rawValue: dto.status) ?? .sent
        )
    }

    private static func webSocketURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "ws/communities"
        return components.url
    }

    private static func memberUUID(_ dto: CommunityMemberDTO) -> UUID? {
        if let userId = dto.userId, let uuid = UUID(uuidString: userId) {
            return uuid
        }
        return UUID(uuidString: dto.id)
    }

    private static func parseDate(_ value: String) -> Date {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: value) { return date }
        let relaxed = ISO8601DateFormatter()
        relaxed.formatOptions = [.withInternetDateTime]
        return relaxed.date(from: value) ?? Date()
    }
}

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
