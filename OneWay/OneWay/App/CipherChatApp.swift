import SwiftUI

@main
@MainActor
struct CipherChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment = AppEnvironment.live

    init() {
        print("APP_BUILD_IDENTIFIER \(OneWayBuildInfo.summary)")
        print("QUANTUM_ROUTER_VERSION \(OneWayBuildInfo.siteRouterVersion)")
        print("QUANTUM_API_ENVIRONMENT \(OneWayBuildInfo.environment) baseURL=\(APIConfig.baseURL)")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--oneway-reset-local-state") {
            AuthTokenStore.shared.resetOneWayCompletelyForTesting()
            URLCache.shared.removeAllCachedResponses()
        }
        #endif
        // Bind the env into the AppDelegate so the PushKit registry has
        // somewhere to deliver incoming-call payloads. `bind` is idempotent.
        AppDelegate.shared.bind(environment: environment)
        VoIPPushManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            AppSessionGateView()
                .environmentObject(environment)
                .preferredColorScheme(.dark)
                .tint(OneWayDesignSystem.Colors.purple)
                .fontDesign(.rounded)
        }
    }
}
