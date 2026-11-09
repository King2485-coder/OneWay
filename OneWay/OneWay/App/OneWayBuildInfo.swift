import Foundation

enum OneWayBuildInfo {
    static let siteRouterVersion = "v3-native-fallback"
    static let buildTimestamp = "2026-07-24T05:10:00Z"

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    static var environment: String {
        APIConfig.baseURL.contains("api.oneway.is") ? "production" : "development"
    }

    static var commitSuffix: String {
        "local"
    }

    static var summary: String {
        "\(appVersion)(\(buildNumber)) commit=\(commitSuffix) built=\(buildTimestamp) env=\(environment) siteRouter=\(siteRouterVersion) siteResolver=\(APIConfig.publicSiteResolverAPIBaseURL)"
    }
}
