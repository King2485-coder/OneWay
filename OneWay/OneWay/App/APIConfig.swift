import Foundation

enum APIConfig {

    // MARK: - Defaults

    private static let productionPublicBaseURL = "https://oneway.is"
    // Keep the App Store binary on the provider-independent production domain.
    // DNS can move between hosts without requiring another Apple submission.
    private static let productionAPIBaseURL = "https://api.oneway.is"
    private static let productionSignalingWebSocketURL = "wss://api.oneway.is/ws/calls"
    static let productionLiveKitURL = "wss://rtc.oneway.app"
    static let publicSiteResolverAPIBaseURL = productionAPIBaseURL
#if DEBUG
    #if targetEnvironment(simulator)
    // The iOS Simulator shares the Mac's network stack. Loopback is more
    // stable than a DHCP-assigned LAN address and nginx owns the public API
    // gateway on port 80.
    private static let debugSelectedAPIBaseURL = "http://127.0.0.1"
    #else
    // This address is available only when explicitly opting into local
    // development. Physical devices otherwise use the production HTTPS API so
    // Wi-Fi changes and cellular launches never depend on this Mac.
    private static let debugSelectedAPIBaseURL = "http://Antonios-MacBook-Pro.local"
    #endif
    private static let bundledDebugLANAPIBaseURLs = [
        debugSelectedAPIBaseURL,
        "http://Antonios-MacBook-Pro.local",
        "http://192.168.0.204",
        "http://127.0.0.1",
    ]

    static var debugLocalOverrideEnabled: Bool {
        let env = ProcessInfo.processInfo.environment["ONEWAY_ENABLE_LOCAL_NETWORK_FALLBACK"]?.lowercased()
        let defaults = UserDefaults.standard.object(forKey: "OneWay.EnableLocalNetworkFallback") as? Bool
        if let defaults { return defaults }
        return env == "1" || env == "true" || env == "yes"
    }

    static var debugLANAPIBaseURLs: [String] {
        var candidates: [String] = []
        if let env = normalizedBaseURL(ProcessInfo.processInfo.environment["ONEWAY_DEBUG_LAN_API_BASE_URL"]) {
            candidates.append(env)
        }
        if let defaults = normalizedBaseURL(UserDefaults.standard.string(forKey: "OneWay.DebugLANAPIBaseURL")) {
            candidates.append(defaults)
        }
        candidates.append(contentsOf: bundledDebugLANAPIBaseURLs)
        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    static var debugLANAPIBaseURL: String {
        debugLANAPIBaseURLs.first ?? productionAPIBaseURL
    }

    static var debugLANSignalingWebSocketURLs: [String] {
        debugLANAPIBaseURLs.compactMap { websocketURLString(for: $0)?.replacingOccurrences(of: "/ws/calls/ws/calls", with: "/ws/calls") }
    }

    static var debugLANSignalingWebSocketURL: String {
        debugLANSignalingWebSocketURLs.first ?? productionSignalingWebSocketURL
    }
#endif

    // MARK: - API Base URL

    static let baseURL: String = {

#if DEBUG
        if let env = canonicalAPIBaseURL(
            ProcessInfo.processInfo.environment["ONEWAY_API_BASE_URL"]
        ) {
            logResolvedEnvironment(name: "debug-override", baseURL: env)
            return env
        }
        if debugLocalOverrideEnabled {
            logResolvedEnvironment(name: "debug-local-opt-in", baseURL: debugSelectedAPIBaseURL)
            return debugSelectedAPIBaseURL
        }
        logResolvedEnvironment(name: "debug-production", baseURL: productionAPIBaseURL)
        return productionAPIBaseURL
#else
        return productionAPIBaseURL
#endif
    }()

    static let callBaseURL = baseURL
    static let signalingWebSocketURL: String = {
#if DEBUG
        if let env = websocketURLString(for: ProcessInfo.processInfo.environment["ONEWAY_CALL_SIGNALING_URL"]) {
            print("🌐 SIGNALING URL (env):", PrivacyLog.redact(env))
            return env
        }
        if let debugURL = websocketURLString(for: baseURL) {
            print("🌐 SIGNALING URL (debug selected):", PrivacyLog.redact(debugURL))
            return debugURL
        }
        print("🌐 SIGNALING URL (production):", PrivacyLog.redact(productionSignalingWebSocketURL))
#endif
        return productionSignalingWebSocketURL
    }()

    // MARK: - Signaling

    static let liveKitURL = productionLiveKitURL

    // MARK: - Public Website

    static let publicWebBaseURL: String = {

        if let env = normalizedBaseURL(
            ProcessInfo.processInfo.environment["PUBLIC_WEB_BASE_URL"]
        ) {
#if DEBUG
            print("🌐 PUBLIC WEB BASE URL (env):", PrivacyLog.redact(env))
#endif
            return env
        }

#if DEBUG
        print("🌐 PUBLIC WEB BASE URL:", PrivacyLog.redact(productionPublicBaseURL))
#endif

        return productionPublicBaseURL
    }()

    // MARK: - Storefront URLs

    static func storefrontPublicURLString(for handleOrSlug: String) -> String {
        let trimmed = handleOrSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(publicWebBaseURL)/shop/\(trimmed)"
    }

    static func storefrontPublicURL(for handleOrSlug: String) -> URL? {
        URL(string: storefrontPublicURLString(for: handleOrSlug))
    }

    // MARK: - Helpers

    private static func canonicalAPIBaseURL(_ raw: String?) -> String? {
        guard let normalized = normalizedBaseURL(raw) else {
            return nil
        }

        guard let url = URL(string: normalized),
              let host = url.host?.lowercased()
        else {
            return normalized
        }

        if host == "oneway.is" || host == "www.oneway.is" {
            return "https://api.oneway.is"
        }

        return normalized
    }

    private static func websocketURLString(for raw: String?) -> String? {
        guard let normalized = normalizedWebSocketURL(raw),
              let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased()
        else {
            return nil
        }

        switch scheme {
        case "ws", "wss":
            return normalized
        default:
            return nil
        }
    }

    private static func websocketURLString(for apiBaseURLString: String) -> String? {
        guard let apiBaseURL = URL(string: apiBaseURLString),
              var components = URLComponents(
                url: apiBaseURL.appendingPathComponent("ws/calls"),
                resolvingAgainstBaseURL: false
              ),
              let scheme = components.scheme?.lowercased()
        else {
            return nil
        }

        switch scheme {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            return nil
        }

        return components.url?.absoluteString
    }

    private static func normalizedWebSocketURL(_ raw: String?) -> String? {

        guard let raw else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "ws" || scheme == "wss",
            url.host != nil
        else {
            return nil
        }

        return trimmed.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )
    }

    private static func normalizedBaseURL(_ raw: String?) -> String? {

        guard let raw else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            return nil
        }

        return trimmed.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )
    }

#if DEBUG
    private static func logResolvedEnvironment(name: String, baseURL: String) {
        let host = URL(string: baseURL)?.host ?? "invalid"
        print("[Network] environment=\(name) apiHost=\(host)")
    }
#endif
}

enum OneWayEnvironment {
    static var apiBaseURL: URL {
        guard let url = URL(string: APIConfig.baseURL) else {
            preconditionFailure("Invalid OneWay API base URL")
        }
        return url
    }

    static var webSocketURL: URL {
        guard let url = URL(string: APIConfig.signalingWebSocketURL) else {
            preconditionFailure("Invalid OneWay WebSocket URL")
        }
        return url
    }
}
