import Foundation

enum OneWayGrowthEventName: String, Codable, CaseIterable {
    case appOpen = "app_open"
    case signupStarted = "signup_started"
    case signupCompleted = "signup_completed"
    case loginCompleted = "login_completed"
    case sessionStarted = "session_started"
    case sessionEnded = "session_ended"
    case profileCreated = "profile_created"
    case firstMessageSent = "first_message_sent"
    case firstMessageReceived = "first_message_received"
    case firstChirpSent = "first_chirp_sent"
    case firstChirpReceived = "first_chirp_received"
    case firstCallStarted = "first_call_started"
    case firstCallCompleted = "first_call_completed"
    case communityJoined = "community_joined"
    case communityCreated = "community_created"
    case shopCreated = "shop_created"
    case siteCreated = "site_created"
    case inviteCreated = "invite_created"
    case inviteClicked = "invite_clicked"
    case referralSignup = "referral_signup"
    case referralActivated = "referral_activated"
    case activationCompleted = "activation_completed"
    case accountDeleted = "account_deleted"
}

struct OneWayGrowthEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let eventName: OneWayGrowthEventName
    let anonymousUserKey: String
    let sessionKey: String?
    let occurredAt: Date
    let platform: String
    let appVersion: String?
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        eventName: OneWayGrowthEventName,
        anonymousUserKey: String,
        sessionKey: String? = nil,
        occurredAt: Date = Date(),
        platform: String = "ios",
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.eventName = eventName
        self.anonymousUserKey = anonymousUserKey
        self.sessionKey = sessionKey
        self.occurredAt = occurredAt
        self.platform = platform
        self.appVersion = appVersion
        self.metadata = metadata.filter { key, _ in
            let lowercased = key.lowercased()
            return !lowercased.contains("content")
                && !lowercased.contains("message")
                && !lowercased.contains("call")
                && !lowercased.contains("contact")
                && !lowercased.contains("phone")
                && !lowercased.contains("email")
                && !lowercased.contains("token")
                && !lowercased.contains("secret")
                && !lowercased.contains("key")
        }
    }
}

final class OneWayGrowthEventReporter {
    static let shared = OneWayGrowthEventReporter()

    private let queueURL: URL
    private let stateURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let session: URLSession
    private let maxQueueSize = 500
    private let activationRuleVersion = "activation_rule_v1"
    private let qualifyingActivationEvents: Set<OneWayGrowthEventName> = [.firstMessageSent, .firstChirpSent, .firstCallCompleted, .communityJoined, .inviteCreated]

    init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.queueURL = supportDirectory.appendingPathComponent("OneWayGrowthEventQueue.json")
        self.stateURL = supportDirectory.appendingPathComponent("OneWayGrowthEventState.json")
    }

    func enqueue(_ event: OneWayGrowthEvent) {
        var queue = loadQueue()
        guard !queue.contains(where: { $0.id == event.id }) else { return }
        queue.append(event)
        if queue.count > maxQueueSize {
            queue.removeFirst(queue.count - maxQueueSize)
        }
        saveQueue(queue)
    }

    func record(_ eventName: OneWayGrowthEventName, anonymousUserKey: String, sessionKey: String? = nil, metadata: [String: String] = [:]) {
        enqueue(OneWayGrowthEvent(eventName: eventName, anonymousUserKey: anonymousUserKey, sessionKey: sessionKey, metadata: metadata))
        updateActivationIfNeeded(after: eventName, anonymousUserKey: anonymousUserKey, sessionKey: sessionKey)
    }

    func recordFirst(_ eventName: OneWayGrowthEventName, anonymousUserKey: String, sessionKey: String? = nil, metadata: [String: String] = [:]) {
        var state = loadState()
        let key = "\(anonymousUserKey):\(eventName.rawValue)"
        guard !state.firstEvents.contains(key) else { return }
        state.firstEvents.insert(key)
        saveState(state)
        record(eventName, anonymousUserKey: anonymousUserKey, sessionKey: sessionKey, metadata: metadata)
    }

    func sessionStarted(anonymousUserKey: String, sessionKey: String) {
        record(.sessionStarted, anonymousUserKey: anonymousUserKey, sessionKey: sessionKey)
    }

    func sessionEnded(anonymousUserKey: String, sessionKey: String, durationSeconds: TimeInterval) {
        let bucket: String
        switch durationSeconds {
        case ..<10: bucket = "0_9s"
        case ..<60: bucket = "10_59s"
        case ..<300: bucket = "1_5m"
        default: bucket = "5m_plus"
        }
        record(.sessionEnded, anonymousUserKey: anonymousUserKey, sessionKey: sessionKey, metadata: ["duration_bucket": bucket])
    }

    func flush(endpoint: URL, ingestionToken: String) async {
        var queue = loadQueue()
        guard !queue.isEmpty else { return }
        var deliveredIDs = Set<UUID>()

        for event in queue {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(ingestionToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? encoder.encode(APIEvent(event))

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    deliveredIDs.insert(event.id)
                }
            } catch {
                break
            }
        }

        if !deliveredIDs.isEmpty {
            queue.removeAll { deliveredIDs.contains($0.id) }
            saveQueue(queue)
        }
    }

    func flushToProductionRelay(client: APIClient = .shared) async {
        var queue = loadQueue()
        guard !queue.isEmpty else { return }
        var deliveredIDs = Set<UUID>()
        var delay: UInt64 = 250_000_000

        for event in queue {
            do {
                let _: EmptyAPIResponse = try await client.post(
                    "api/growth/events",
                    body: APIEvent(event),
                    requiresAuth: true
                )
                deliveredIDs.insert(event.id)
                delay = 250_000_000
            } catch {
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 8_000_000_000)
                break
            }
        }

        if !deliveredIDs.isEmpty {
            queue.removeAll { deliveredIDs.contains($0.id) }
            saveQueue(queue)
        }
    }

    private func loadQueue() -> [OneWayGrowthEvent] {
        guard let data = try? Data(contentsOf: queueURL) else { return [] }
        return (try? decoder.decode([OneWayGrowthEvent].self, from: data)) ?? []
    }

    private func saveQueue(_ queue: [OneWayGrowthEvent]) {
        try? FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? encoder.encode(queue) else { return }
        try? data.write(to: queueURL, options: [.atomic])
    }

    private func updateActivationIfNeeded(after eventName: OneWayGrowthEventName, anonymousUserKey: String, sessionKey: String?) {
        guard qualifyingActivationEvents.contains(eventName) else { return }
        var state = loadState()
        guard !state.activatedUsers.contains(anonymousUserKey) else { return }
        state.qualifyingActions[anonymousUserKey, default: []].insert(eventName.rawValue)
        if state.qualifyingActions[anonymousUserKey, default: []].count >= 2 {
            state.activatedUsers.insert(anonymousUserKey)
            saveState(state)
            enqueue(OneWayGrowthEvent(eventName: .activationCompleted, anonymousUserKey: anonymousUserKey, sessionKey: sessionKey, metadata: [
                "activation_rule_version": activationRuleVersion,
                "signup_age_bucket": "CALCULATED_SERVER_SIDE",
                "qualifying_action_count": "2"
            ]))
        } else {
            saveState(state)
        }
    }

    private func loadState() -> ReporterState {
        guard let data = try? Data(contentsOf: stateURL) else { return ReporterState() }
        return (try? decoder.decode(ReporterState.self, from: data)) ?? ReporterState()
    }

    private func saveState(_ state: ReporterState) {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic])
    }

    private struct ReporterState: Codable {
        var firstEvents: Set<String> = []
        var qualifyingActions: [String: Set<String>] = [:]
        var activatedUsers: Set<String> = []
    }

    private struct APIEvent: Encodable {
        let eventName: String
        let eventId: String
        let subjectKey: String
        let sessionKey: String?
        let occurredAt: Date
        let sourcePlatform: String
        let appVersion: String?
        let build: String?
        let schemaVersion: String
        let metadata: [String: String]

        init(_ event: OneWayGrowthEvent) {
            self.eventName = event.eventName.rawValue
            self.eventId = event.id.uuidString
            self.subjectKey = event.anonymousUserKey
            self.sessionKey = event.sessionKey
            self.occurredAt = event.occurredAt
            self.sourcePlatform = event.platform
            self.appVersion = event.appVersion
            self.build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            self.schemaVersion = "1"
            self.metadata = event.metadata
        }
    }
}
