import Foundation

struct TurnCredentials: Codable, Sendable {
    let username: String
    let credential: String
    let ttl: Int
    let urls: [String]
}

enum TurnService {
    private struct CoturnBundle: Decodable {
        struct ICEServer: Decodable {
            let urls: [String]
            let username: String?
            let credential: String?
        }

        let iceServers: [ICEServer]
        let ttl: Int
        let expiresAt: Int?
    }

    /// Fetch TURN credentials from the OneWay backend.
    ///
    /// Supports both response shapes:
    /// 1) `{ username, credential, ttl, urls }` (legacy/simple)
    /// 2) `{ iceServers: [{ urls, username, credential }], ttl, expiresAt }` (coturn-style)
    static func fetch(baseURL: URL = URL(string: APIConfig.callBaseURL)!, session: URLSession = .shared) async -> TurnCredentials? {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("turn-credentials")

        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(AuthTokenStore.shared.currentUserID(), forHTTPHeaderField: "x-dev-user-id")
            request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")

            let (data, _) = try await session.data(for: request)

            // Try the simple/legacy shape first.
            if let creds = try? JSONDecoder().decode(TurnCredentials.self, from: data) {
                #if DEBUG
                print("✅ TURN creds (simple):", creds)
                #endif
                return creds
            }

            // Fall back to the coturn-style shape (`iceServers`).
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let bundle = try decoder.decode(CoturnBundle.self, from: data)
            guard let first = bundle.iceServers.first,
                  let username = first.username,
                  let credential = first.credential else {
                #if DEBUG
                print("❌ TURN response missing username/credential.")
                #endif
                return nil
            }

            let creds = TurnCredentials(
                username: username,
                credential: credential,
                ttl: bundle.ttl,
                urls: first.urls
            )
            #if DEBUG
            print("✅ TURN creds (iceServers):", creds)
            #endif
            return creds
        } catch {
            #if DEBUG
            print("❌ TURN fetch/decode error:", error)
            #endif
            return nil
        }
    }
}
