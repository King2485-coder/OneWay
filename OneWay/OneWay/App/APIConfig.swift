import Foundation

struct APIConfig {
    private static let productionBaseURL = "https://api.oneway.app"

    static let baseURL: String = {
        if let plistOverride = Bundle.main.object(forInfoDictionaryKey: "OneWayAPIBaseURL") as? String,
           !plistOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plistOverride
        }

        if let environmentOverride = ProcessInfo.processInfo.environment["ONEWAY_API_BASE_URL"],
           !environmentOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environmentOverride
        }

        return productionBaseURL
    }()

    static let callBaseURL = baseURL
}
