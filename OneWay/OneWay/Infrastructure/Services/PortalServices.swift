import Foundation
import Combine

enum PortalRegistry {
    static let quantumHomeID = "quantum-home"

    static let builtIns: [PortalDefinition] = [
        builtIn(
            id: quantumHomeID,
            name: "Quantum Home",
            iconAssetName: OneWayBrandAsset.appLogoFullBleed.imageName,
            monogram: "Q",
            url: nil,
            hosts: []
        ),
        builtIn(
            id: "youtube",
            name: "YouTube",
            iconAssetName: "PortalYouTube",
            monogram: "YT",
            url: "https://www.youtube.com/",
            hosts: ["youtube.com", "youtu.be", "googlevideo.com"]
        ),
        builtIn(
            id: "google",
            name: "Google",
            iconAssetName: "PortalGoogle",
            monogram: "G",
            url: "https://www.google.com/",
            searchURL: "https://www.google.com/search?q=%@",
            hosts: ["google.com"]
        ),
        builtIn(
            id: "reddit",
            name: "Reddit",
            iconAssetName: "PortalReddit",
            monogram: "R",
            url: "https://www.reddit.com/",
            hosts: ["reddit.com", "redd.it"]
        ),
        builtIn(
            id: "amazon",
            name: "Amazon",
            iconAssetName: "PortalAmazon",
            monogram: "A",
            url: "https://www.amazon.com/",
            hosts: ["amazon.com", "amazonaws.com"]
        ),
        builtIn(
            id: "wikipedia",
            name: "Wikipedia",
            iconAssetName: "PortalWikipedia",
            monogram: "W",
            url: "https://www.wikipedia.org/",
            searchURL: "https://en.wikipedia.org/w/index.php?search=%@",
            hosts: ["wikipedia.org", "wikimedia.org"]
        ),
        builtIn(
            id: "apple",
            name: "Apple",
            iconAssetName: "PortalApple",
            monogram: "A",
            url: "https://www.apple.com/",
            hosts: ["apple.com"]
        ),
        builtIn(
            id: "x",
            name: "X",
            iconAssetName: "PortalX",
            monogram: "X",
            url: "https://x.com/",
            hosts: ["x.com", "twitter.com", "t.co"]
        )
    ]

    static func portal(id: String, in portals: [PortalDefinition]) -> PortalDefinition? {
        portals.first { $0.id == id }
    }

    static func merged(with saved: [PortalDefinition]) -> [PortalDefinition] {
        var savedByID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        var merged = builtIns.map { registryPortal -> PortalDefinition in
            guard let persisted = savedByID.removeValue(forKey: registryPortal.id) else {
                return registryPortal
            }
            var portal = registryPortal
            portal.opensInstalledApp = persisted.opensInstalledApp
            portal.isEnabled = persisted.isEnabled
            portal.isFavorite = persisted.isFavorite
            portal.sortOrder = persisted.sortOrder
            portal.lastOpenedAt = persisted.lastOpenedAt
            portal.createdAt = persisted.createdAt
            portal.updatedAt = persisted.updatedAt
            return portal
        }
        merged.append(contentsOf: savedByID.values.filter { !$0.isBuiltIn })
        return normalizedOrder(merged)
    }

    static func normalizedOrder(_ portals: [PortalDefinition]) -> [PortalDefinition] {
        portals.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        .enumerated()
        .map { index, portal in
            var updated = portal
            updated.sortOrder = index
            return updated
        }
    }

    private static func builtIn(
        id: String,
        name: String,
        iconAssetName: String,
        monogram: String,
        url: String?,
        searchURL: String? = nil,
        hosts: [String]
    ) -> PortalDefinition {
        let now = Date(timeIntervalSince1970: 0)
        return PortalDefinition(
            id: id,
            name: name,
            iconAssetName: iconAssetName,
            iconMonogram: monogram,
            launchURLString: url ?? "",
            homeURLString: url ?? "",
            searchURLString: searchURL,
            allowedHosts: hosts,
            isBuiltIn: true,
            isEnabled: true,
            canBeStartupPortal: true,
            supportsPersistentSession: id != quantumHomeID,
            supportsCustomUserAgent: id != quantumHomeID,
            sortOrder: builtInsOrder[id] ?? 0,
            isFavorite: false,
            lastOpenedAt: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private static let builtInsOrder: [String: Int] = [
        quantumHomeID: 0,
        "youtube": 1,
        "google": 2,
        "reddit": 3,
        "amazon": 4,
        "wikipedia": 5,
        "apple": 6,
        "x": 7
    ]
}

enum PortalURLValidator {
    static func validate(name: String, address: String) throws -> (name: String, url: URL) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw PortalValidationError.emptyName }

        let rawAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawAddress.isEmpty else { throw PortalValidationError.emptyAddress }

        let lowercased = rawAddress.lowercased()
        let dangerousSchemes = ["javascript:", "data:", "file:", "about:", "blob:"]
        guard !dangerousSchemes.contains(where: lowercased.hasPrefix) else {
            throw PortalValidationError.unsupportedScheme
        }

        let candidate = rawAddress.contains("://") ? rawAddress : "https://\(rawAddress)"
        guard var components = URLComponents(string: candidate) else {
            throw PortalValidationError.malformedAddress
        }
        guard components.scheme?.lowercased() == "https" else {
            throw PortalValidationError.insecureAddress
        }
        components.scheme = "https"
        components.fragment = nil
        guard let host = components.host?.lowercased(), !host.isEmpty, host.contains(".") else {
            throw PortalValidationError.missingHost
        }
        components.host = host
        guard let url = components.url, OneWayBrowserPolicy.isAllowed(url) else {
            throw PortalValidationError.malformedAddress
        }
        return (normalizedName, url)
    }
}

@MainActor
final class PortalPreferenceStore: ObservableObject {
    static let storageKey = "oneway.quantum.portals.v1"

    @Published private(set) var configuration: PortalUserConfiguration
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = Self.loadConfiguration(from: defaults)
        save()
    }

    var visiblePortals: [PortalDefinition] {
        configuration.showPortalApps
            ? configuration.portals.filter(\.isEnabled)
            : []
    }

    var enabledStartupPortals: [PortalDefinition] {
        configuration.portals.filter { $0.isEnabled && $0.canBeStartupPortal }
    }

    var startupPortalID: String? {
        configuration.startup.mode == .specificPortal
            ? configuration.startup.selectedPortalID
            : nil
    }

    func portal(id: String) -> PortalDefinition? {
        PortalRegistry.portal(id: id, in: configuration.portals)
    }

    func setStartup(mode: PortalStartupMode, portalID: String? = nil) {
        configuration.startup.mode = mode
        configuration.startup.selectedPortalID = mode == .specificPortal ? portalID : nil
        save()
    }

    func setAppOpening(_ portalID: String, enabled: Bool) {
        guard let index = configuration.portals.firstIndex(where: { $0.id == portalID }) else { return }
        configuration.portals[index].opensInstalledApp = enabled
        configuration.portals[index].updatedAt = Date()
        save()
    }

    func setShowPortalApps(_ value: Bool) {
        configuration.showPortalApps = value
        save()
    }

    func setOpeningBehavior(_ value: PortalOpeningBehavior) {
        configuration.openingBehavior = value
        save()
    }

    func setRememberSessions(_ value: Bool) {
        configuration.rememberSessions = value
        if !value {
            configuration.startup.lastKnownURLString = nil
            configuration.startup.lastSelectedTabID = nil
        }
        save()
    }

    func recordOpen(portalID: String, url: URL?, tabID: UUID?, allowURLRestoration: Bool) {
        guard let index = configuration.portals.firstIndex(where: { $0.id == portalID }) else { return }
        let now = Date()
        configuration.portals[index].lastOpenedAt = now
        configuration.portals[index].updatedAt = now
        configuration.startup.lastPortalID = portalID
        configuration.startup.lastSelectedTabID = configuration.rememberSessions ? tabID : nil
        configuration.startup.lastKnownURLString = configuration.rememberSessions && allowURLRestoration
            ? url?.absoluteString
            : nil
        save()
    }

    func toggleFavorite(_ portalID: String) {
        guard let index = configuration.portals.firstIndex(where: { $0.id == portalID }) else { return }
        configuration.portals[index].isFavorite.toggle()
        configuration.portals[index].updatedAt = Date()
        configuration.portals = PortalRegistry.normalizedOrder(configuration.portals)
        save()
    }

    func setEnabled(_ portalID: String, enabled: Bool) {
        guard let index = configuration.portals.firstIndex(where: { $0.id == portalID }) else { return }
        configuration.portals[index].isEnabled = enabled
        configuration.portals[index].updatedAt = Date()
        if !enabled, configuration.startup.selectedPortalID == portalID {
            configuration.startup = PortalStartupPreference()
        }
        save()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        var portals = configuration.portals
        let moving = offsets.sorted().map { portals[$0] }
        for index in offsets.sorted(by: >) {
            portals.remove(at: index)
        }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = min(max(0, destination - removedBeforeDestination), portals.count)
        portals.insert(contentsOf: moving, at: insertionIndex)
        configuration.portals = portals.enumerated().map { index, portal in
            var updated = portal
            updated.sortOrder = index
            updated.updatedAt = Date()
            return updated
        }
        save(normalize: false)
    }

    @discardableResult
    func addCustom(name: String, address: String) throws -> PortalDefinition {
        let validated = try PortalURLValidator.validate(name: name, address: address)
        guard let host = validated.url.host?.lowercased() else {
            throw PortalValidationError.missingHost
        }
        let now = Date()
        let portal = PortalDefinition(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: validated.name,
            iconAssetName: nil,
            iconMonogram: String(validated.name.prefix(2)).uppercased(),
            launchURLString: validated.url.absoluteString,
            homeURLString: validated.url.absoluteString,
            searchURLString: nil,
            allowedHosts: [host],
            isBuiltIn: false,
            isEnabled: true,
            canBeStartupPortal: true,
            supportsPersistentSession: true,
            supportsCustomUserAgent: true,
            sortOrder: configuration.portals.count,
            isFavorite: false,
            lastOpenedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        configuration.portals.append(portal)
        save()
        return portal
    }

    func updateCustom(id: String, name: String, address: String) throws {
        guard let index = configuration.portals.firstIndex(where: { $0.id == id && !$0.isBuiltIn }) else { return }
        let validated = try PortalURLValidator.validate(name: name, address: address)
        guard let host = validated.url.host?.lowercased() else {
            throw PortalValidationError.missingHost
        }
        configuration.portals[index].name = validated.name
        configuration.portals[index].iconMonogram = String(validated.name.prefix(2)).uppercased()
        configuration.portals[index].launchURLString = validated.url.absoluteString
        configuration.portals[index].homeURLString = validated.url.absoluteString
        configuration.portals[index].allowedHosts = [host]
        configuration.portals[index].updatedAt = Date()
        save()
    }

    func removeCustom(_ id: String) {
        guard configuration.portals.contains(where: { $0.id == id && !$0.isBuiltIn }) else { return }
        configuration.portals.removeAll { $0.id == id }
        if configuration.startup.selectedPortalID == id || configuration.startup.lastPortalID == id {
            configuration.startup = PortalStartupPreference()
        }
        save()
    }

    func reset() {
        configuration = Self.defaultConfiguration
        save()
    }

    static func loadConfiguration(from defaults: UserDefaults = .standard) -> PortalUserConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode(PortalUserConfiguration.self, from: data) else {
            return defaultConfiguration
        }
        decoded.portals = PortalRegistry.merged(with: decoded.portals)
        decoded.version = PortalUserConfiguration.currentVersion
        return decoded
    }

    static var defaultConfiguration: PortalUserConfiguration {
        PortalUserConfiguration(
            portals: PortalRegistry.builtIns,
            startup: PortalStartupPreference(),
            showPortalApps: true,
            openingBehavior: .reusePortalTab,
            rememberSessions: true,
            version: PortalUserConfiguration.currentVersion
        )
    }

    private func save(normalize: Bool = true) {
        if normalize {
            configuration.portals = PortalRegistry.normalizedOrder(configuration.portals)
        }
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

@MainActor
struct OneWayStartupExperienceService {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resolve() -> PortalStartupDecision {
        let configuration = PortalPreferenceStore.loadConfiguration(from: defaults)
        let enabled = configuration.portals.filter(\.isEnabled)

        switch configuration.startup.mode {
        case .quantumHome:
            return .quantumHome
        case .askEveryLaunch:
            return .askEveryLaunch
        case .specificPortal:
            guard let id = configuration.startup.selectedPortalID,
                  let portal = enabled.first(where: { $0.id == id && $0.canBeStartupPortal }) else {
                return .quantumHome
            }
            if id == PortalRegistry.quantumHomeID { return .quantumHome }
            guard let url = portal.homeURL else { return .quantumHome }
            return .portal(id: id, url: url)
        case .resumeLastPortal:
            guard let id = configuration.startup.lastPortalID,
                  let portal = enabled.first(where: { $0.id == id }) else {
                return .quantumHome
            }
            if id == PortalRegistry.quantumHomeID { return .quantumHome }
            if configuration.rememberSessions,
               let saved = configuration.startup.lastKnownURLString.flatMap(URL.init(string:)),
               portal.allows(saved) {
                return .portal(id: id, url: saved)
            }
            guard let home = portal.homeURL else { return .quantumHome }
            return .portal(id: id, url: home)
        }
    }
}
