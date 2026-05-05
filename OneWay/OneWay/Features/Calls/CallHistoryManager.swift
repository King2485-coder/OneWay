import Foundation
import Combine
/// Mirrors the wire shape returned by `/api/history/*`.
struct CallHistoryEntry: Identifiable, Equatable, Codable, Sendable {
    enum Direction: String, Codable, Sendable { case incoming, outgoing }
    enum Status: String, Codable, Sendable { case completed, missed, declined, failed }

    let id: String
    let callId: String
    let callerId: String
    let calleeId: String
    let direction: Direction
    let status: Status
    let durationSeconds: Int
    let startedAt: Int64        // unix ms
    let endedAt: Int64
    let hasVideo: Bool
    let voicemailId: String?

    /// Convenience for binding into SwiftUI's `Text(_:formatter:)`.
    var startedAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startedAt) / 1000.0)
    }
}

/// Fetches and caches call history. Designed for the SwiftUI list — exposes
/// an `@Published`-style `entries` snapshot via an `AsyncSequence` of arrays.
/// Wraps the actor in a `@MainActor`-friendly facade so views can bind
/// directly without manual hops.
@MainActor
final class CallHistoryManager: ObservableObject {
    @Published private(set) var entries: [CallHistoryEntry] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private let baseURL: URL
    private let userID: String
    private let session: URLSession

    init(baseURL: URL, userID: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.userID = userID
        self.session = session
    }

    /// Pull `/api/history/recent`. Replaces the in-memory snapshot.
    func refresh(limit: Int = 100) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("history")
                .appendingPathComponent("recent")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
            var request = URLRequest(url: components.url ?? url, timeoutInterval: 10)
            request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder.history.decode(Envelope.self, from: data)
            self.entries = decoded.entries
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Whether the local user missed this entry — useful for a red dot in
    /// the list. Outgoing entries can be `failed`/`declined` too; we treat
    /// only incoming `missed` as "needs attention".
    func needsAttention(_ entry: CallHistoryEntry) -> Bool {
        entry.direction == .incoming && entry.status == .missed
    }

    /// Counterparty's id for this entry, from the local user's perspective.
    func otherParty(_ entry: CallHistoryEntry) -> String {
        entry.direction == .incoming ? entry.callerId : entry.calleeId
    }

    private struct Envelope: Decodable {
        let entries: [CallHistoryEntry]
    }
}

private extension JSONDecoder {
    static let history: JSONDecoder = {
        let d = JSONDecoder()
        // Server returns camelCase already; no key conversion needed.
        return d
    }()
}
