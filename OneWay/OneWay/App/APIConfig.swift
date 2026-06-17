import Foundation

struct APIConfig {
    private static let productionBaseURL = "https://oneway.is"
    private static let debugDeviceAPIBaseURL = "http://192.168.0.204:3000"
    private static let localhostHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

    static let baseURL: String = {
        let configured = configuredBaseURL().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return defaultBaseURL }

        // Physical iPhones cannot reach localhost on your Mac. If a localhost URL is
        // configured, automatically promote to a LAN URL from Info.plist when present.
        if isLoopbackURL(configured),
           let lanOverride = Bundle.main.object(forInfoDictionaryKey: "OneWayLANAPIBaseURL") as? String,
           !lanOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizedLANURL(lanOverride.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return normalizedLANURL(configured)
    }()

    static let callBaseURL = baseURL
    static let rawConfiguredBaseURL = configuredBaseURL().trimmingCharacters(in: .whitespacesAndNewlines)

    private static func configuredBaseURL() -> String {
        if let plistOverride = Bundle.main.object(forInfoDictionaryKey: "OneWayAPIBaseURL") as? String,
           !plistOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plistOverride
        }

        if let environmentOverride = ProcessInfo.processInfo.environment["ONEWAY_API_BASE_URL"],
           !environmentOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environmentOverride
        }

        return defaultBaseURL
    }

    private static var defaultBaseURL: String {
#if DEBUG
        return debugDeviceAPIBaseURL
#else
        return productionBaseURL
#endif
    }

    static func normalizedLANURL(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              components.scheme?.lowercased() == "https",
              isIPv4Literal(host) else {
            return value
        }

        // The local nginx certificate is issued for oneway.is, so iOS correctly
        // rejects https://<LAN IP>. Always normalize raw-IP HTTPS overrides to
        // the local Node dev server over HTTP before requests are created.
        components.scheme = "http"
        components.port = 3000
        return components.url?.absoluteString ?? value
    }

    private static func isLoopbackURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let host = url.host?.lowercased() else {
            return false
        }
        return localhostHosts.contains(host)
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty,
                  octet.allSatisfy({ $0.isNumber }),
                  let value = Int(octet) else {
                return false
            }
            return (0...255).contains(value)
        }
    }
}
