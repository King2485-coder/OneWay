import UIKit
import UserNotifications

enum OneWayNotificationPreferences {
    static let enabledKey = "OneWay.Notifications.MessagesEnabled"
    static let previewsKey = "OneWay.Notifications.MessagePreviews"
    static let soundsKey = "OneWay.Notifications.Sounds"
    static let vibrationKey = "OneWay.Notifications.Vibration"
}

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = AppDelegate()
    private static let alertTokenKey = "OneWay.AlertPushToken"

    func bind(environment: AppEnvironment) {
        VoIPPushManager.shared.environment = environment
        VoIPPushManager.shared.registrar = NetworkPushTokenRegistrar(
            baseURL: URL(string: APIConfig.callBaseURL)!,
            userID: AppEnvironment.currentUserID()
        )
        VoIPPushManager.shared.start()
        registerCachedAlertToken()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LaunchTelemetry.shared.configure()

        // Initialize environment safely
        let env = AppEnvironment.shared

        print("🚀 App started with baseURL:", PrivacyLog.redact(env.baseURL))
        print("👤 Current user:", PrivacyLog.shortID(env.currentUserID))
        Task { @MainActor in
            let status = await APIClient.shared.health()
            print("🌐 Backend status:", PrivacyLog.redact(status.message ?? "Connected"))
        }
        VoIPPushManager.shared.start()

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }

        NotificationCenter.default.addObserver(forName: AuthTokenStore.tokenDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppDelegate.shared.registerCachedAlertToken() }
        }

        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: Self.alertTokenKey)
        registerCachedAlertToken()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[push] alert registration failed:", PrivacyLog.redact(error.localizedDescription))
        #endif
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: OneWayNotificationPreferences.enabledKey) as? Bool ?? true
        guard enabled else { return [] }
        let sounds = defaults.object(forKey: OneWayNotificationPreferences.soundsKey) as? Bool ?? true
        var options: UNNotificationPresentationOptions = [.banner, .list, .badge]
        if sounds { options.insert(.sound) }
        return options
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let deepLink = response.notification.request.content.userInfo["deepLink"] as? String,
              let url = URL(string: deepLink) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .oneWayDeepLinkRequested, object: nil, userInfo: ["url": url])
        }
    }

    func unregisterEmailAlertsBeforeSignOut() async {
        guard let token = UserDefaults.standard.string(forKey: Self.alertTokenKey) else { return }
        await alertRegistrar.unregisterAlert(token: token)
    }

    func refreshAlertNotificationPreferences() {
        registerCachedAlertToken()
    }

    private func registerCachedAlertToken() {
        guard AuthTokenStore.shared.authenticatedAuthorizationHeader() != nil,
              let token = UserDefaults.standard.string(forKey: Self.alertTokenKey) else { return }
        Task { await alertRegistrar.registerAlert(token: token, environment: Self.pushEnvironment) }
    }

    private var alertRegistrar: NetworkPushTokenRegistrar {
        NetworkPushTokenRegistrar(baseURL: URL(string: APIConfig.callBaseURL)!, userID: AppEnvironment.currentUserID())
    }

    private static var pushEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}

extension Notification.Name {
    static let oneWayDeepLinkRequested = Notification.Name("OneWay.DeepLinkRequested")
}
