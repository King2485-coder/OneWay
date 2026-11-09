import Foundation

enum CallNetworkConfiguration {
    static var restBaseURL: URL {
        URL(string: APIConfig.callBaseURL) ?? URL(string: "https://api.oneway.is")!
    }

    static var signalingWebSocketURL: URL {
        URL(string: APIConfig.signalingWebSocketURL) ?? URL(string: "wss://api.oneway.is/ws/calls")!
    }

    static var buildEnvironment: String {
        #if DEBUG
        return "debug"
        #else
        return "production"
        #endif
    }

    static var localOverrideEnabled: Bool {
        #if DEBUG
        return APIConfig.debugLocalOverrideEnabled
        #else
        return false
        #endif
    }

    static func logStartupState() {
        #if DEBUG
        print("📞 Call network REST:", PrivacyLog.redactURL(restBaseURL))
        print("📞 Call network socket:", PrivacyLog.redactURL(signalingWebSocketURL))
        print("📞 Call network build:", buildEnvironment)
        print("📞 Call local override:", localOverrideEnabled)
        print("📞 Call auth token available:", AuthTokenStore.shared.token() != nil)
        #endif
    }
}
