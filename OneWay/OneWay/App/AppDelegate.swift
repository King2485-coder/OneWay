import UIKit

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    static let shared = AppDelegate()

    func bind(environment: AppEnvironment) {
        VoIPPushManager.shared.environment = environment
        VoIPPushManager.shared.registrar = NetworkPushTokenRegistrar(
            baseURL: URL(string: APIConfig.callBaseURL)!,
            userID: AppEnvironment.currentUserID()
        )
        VoIPPushManager.shared.start()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LaunchTelemetry.shared.configure()

        // Initialize environment safely
        let env = AppEnvironment.shared

        print("🚀 App started with baseURL:", env.baseURL)
        print("👤 Current user:", env.currentUserID)
        Task { @MainActor in
            let status = await APIClient.shared.health()
            print("🌐 Backend status:", status.message ?? "Connected")
        }
        VoIPPushManager.shared.start()

        return true
    }
}
