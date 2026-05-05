import Foundation

/// `PushTokenRegistering` implementation that POSTs to `/api/push/register`.
/// Two-shot retry on transient failure; otherwise silent — token registration
/// is best-effort, the push service can survive a missed call. The next
/// foreground will re-fire `didUpdate pushCredentials` if the registry has
/// fresh material, which kicks the registrar again.
struct NetworkPushTokenRegistrar: PushTokenRegistering {
    let baseURL: URL
    let userID: String
    var session: URLSession = .shared

    func register(voipToken: String, environment: String) async {
        let body: [String: Any] = ["voipToken": voipToken, "environment": environment]
        await postIgnoringErrors(path: "api/push/register", body: body, retries: 2)
    }

    func unregister() async {
        await deleteIgnoringErrors(path: "api/push/register")
    }

    private func postIgnoringErrors(path: String, body: [String: Any], retries: Int) async {
        var attempt = 0
        while attempt <= retries {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent(path))
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch {
                #if DEBUG
                print("[push] register attempt \(attempt + 1) failed: \(error)")
                #endif
            }
            attempt += 1
            if attempt <= retries {
                let backoff = UInt64(min(8, 1 << attempt)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
    }

    private func deleteIgnoringErrors(path: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }
}
