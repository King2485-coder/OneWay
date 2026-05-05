import Foundation
import OSLog

#if canImport(Sentry)
import Sentry
#endif

#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
#endif

@MainActor
final class LaunchTelemetry {
    static let shared = LaunchTelemetry()

    private let logger = Logger(subsystem: "app.oneway.ios", category: "launch")
    private var isConfigured = false

    private init() {}

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true

        #if canImport(Sentry)
        if let dsn = Bundle.main.object(forInfoDictionaryKey: "OneWaySentryDSN") as? String,
           !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SentrySDK.start { options in
                options.dsn = dsn
                options.tracesSampleRate = 1.0
            }
            logger.log("Sentry configured")
        }
        #endif

        #if canImport(FirebaseAnalytics)
        Analytics.setAnalyticsCollectionEnabled(true)
        logger.log("Firebase Analytics enabled")
        #endif

        track("app_launch")
    }

    func track(_ event: String, parameters: [String: String] = [:]) {
        logger.log("event=\(event, privacy: .public) params=\(parameters.description, privacy: .public)")

        #if canImport(FirebaseAnalytics)
        Analytics.logEvent(event, parameters: parameters)
        #endif

        #if canImport(Sentry)
        let crumb = Breadcrumb()
        crumb.category = "analytics"
        crumb.level = .info
        crumb.message = event
        crumb.data = parameters
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    func capture(error: Error, context: String, extras: [String: String] = [:]) {
        logger.error("context=\(context, privacy: .public) error=\(error.localizedDescription, privacy: .public)")

        #if canImport(Sentry)
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: context, key: "context")
            extras.forEach { key, value in
                scope.setExtra(value: value, key: key)
            }
        }
        #endif
    }
}
