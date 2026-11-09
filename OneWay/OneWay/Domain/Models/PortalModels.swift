import Foundation

struct PortalDefinition: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var iconAssetName: String?
    var iconMonogram: String
    var launchURLString: String
    var homeURLString: String
    var searchURLString: String?
    var allowedHosts: [String]
    var isBuiltIn: Bool
    var isEnabled: Bool
    var canBeStartupPortal: Bool
    var supportsPersistentSession: Bool
    var supportsCustomUserAgent: Bool
    var sortOrder: Int
    var isFavorite: Bool
    var lastOpenedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var opensInstalledApp: Bool? = nil

    var launchURL: URL? { URL(string: launchURLString) }
    var homeURL: URL? { URL(string: homeURLString) }

    func allows(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains { allowedHost in
            host == allowedHost || host.hasSuffix(".\(allowedHost)")
        }
    }
}

enum PortalStartupMode: String, Codable, CaseIterable, Identifiable {
    case quantumHome
    case resumeLastPortal
    case specificPortal
    case askEveryLaunch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quantumHome: return "Quantum Home"
        case .resumeLastPortal: return "Resume Last Portal"
        case .specificPortal: return "Specific Portal"
        case .askEveryLaunch: return "Ask Every Launch"
        }
    }
}

struct PortalStartupPreference: Codable, Equatable {
    var mode: PortalStartupMode = .quantumHome
    var selectedPortalID: String?
    var lastPortalID: String?
    var lastKnownURLString: String?
    var lastSelectedTabID: UUID?
}

enum PortalOpeningBehavior: String, Codable, CaseIterable, Identifiable {
    case currentTab
    case reusePortalTab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentTab: return "Open in Current Tab"
        case .reusePortalTab: return "Reuse Matching Portal Tab"
        }
    }
}

struct PortalUserConfiguration: Codable, Equatable {
    var portals: [PortalDefinition]
    var startup: PortalStartupPreference
    var showPortalApps: Bool
    var openingBehavior: PortalOpeningBehavior
    var rememberSessions: Bool
    var version: Int

    static let currentVersion = 1
}

enum PortalStartupDecision: Equatable {
    case quantumHome
    case portal(id: String, url: URL)
    case askEveryLaunch

    var initialURL: URL? {
        guard case let .portal(_, url) = self else { return nil }
        return url
    }
}

enum PortalValidationError: LocalizedError, Equatable {
    case emptyName
    case emptyAddress
    case malformedAddress
    case unsupportedScheme
    case missingHost
    case insecureAddress

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a portal name."
        case .emptyAddress: return "Enter a web address."
        case .malformedAddress: return "That web address is malformed."
        case .unsupportedScheme: return "Portal Apps support secure web addresses only."
        case .missingHost: return "The address must include a valid website host."
        case .insecureAddress: return "Portal Apps require HTTPS."
        }
    }
}
