import Combine
import Foundation

@MainActor
final class OneWayAutomationPreferencesStore: ObservableObject {
    static let shared = OneWayAutomationPreferencesStore()

    @Published var actionButtonEnabled: Bool {
        didSet { defaults.set(actionButtonEnabled, forKey: Keys.actionButtonEnabled) }
    }

    @Published var primaryAction: OneWayButtonAction {
        didSet { defaults.set(primaryAction.rawValue, forKey: Keys.primaryAction) }
    }

    @Published var featureStates: [OneWayAutomationFeature: AutomationPermissionState] {
        didSet { persistFeatureStates() }
    }

    @Published var recognizedVehicles: [RecognizedVehicle] {
        didSet { persistVehicles() }
    }

    @Published var didDeferDrivingPrompt: Bool {
        didSet { defaults.set(didDeferDrivingPrompt, forKey: Keys.didDeferDrivingPrompt) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        actionButtonEnabled = defaults.object(forKey: Keys.actionButtonEnabled) as? Bool ?? false
        primaryAction = OneWayButtonAction(rawValue: defaults.string(forKey: Keys.primaryAction) ?? "") ?? .smartActionMenu
        featureStates = Self.loadFeatureStates(defaults: defaults)
        recognizedVehicles = Self.loadVehicles(defaults: defaults)
        didDeferDrivingPrompt = defaults.object(forKey: Keys.didDeferDrivingPrompt) as? Bool ?? false
    }

    func state(for feature: OneWayAutomationFeature) -> AutomationPermissionState {
        featureStates[feature] ?? feature.defaultState
    }

    func setState(_ state: AutomationPermissionState, for feature: OneWayAutomationFeature) {
        featureStates[feature] = state
    }

    func isAllowed(_ feature: OneWayAutomationFeature) -> Bool {
        state(for: feature) == .on
    }

    func requiresConfirmation(_ feature: OneWayAutomationFeature) -> Bool {
        state(for: feature) == .askFirst
    }

    func addVehicle(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        recognizedVehicles.append(
            RecognizedVehicle(name: trimmed.isEmpty ? "My Vehicle" : trimmed)
        )
    }

    func updateVehicle(_ vehicle: RecognizedVehicle) {
        guard let index = recognizedVehicles.firstIndex(where: { $0.id == vehicle.id }) else { return }
        var updated = vehicle
        updated.updatedAt = Date()
        recognizedVehicles[index] = updated
    }

    func forgetVehicle(id: RecognizedVehicle.ID) {
        recognizedVehicles.removeAll { $0.id == id }
    }

    private func persistFeatureStates() {
        let raw = featureStates.reduce(into: [String: String]()) { result, item in
            result[item.key.rawValue] = item.value.rawValue
        }
        defaults.set(raw, forKey: Keys.featureStates)
    }

    private func persistVehicles() {
        guard let data = try? JSONEncoder().encode(recognizedVehicles) else { return }
        defaults.set(data, forKey: Keys.recognizedVehicles)
    }

    private static func loadFeatureStates(defaults: UserDefaults) -> [OneWayAutomationFeature: AutomationPermissionState] {
        let raw = defaults.dictionary(forKey: Keys.featureStates) as? [String: String] ?? [:]
        var states = Dictionary(uniqueKeysWithValues: OneWayAutomationFeature.allCases.map { ($0, $0.defaultState) })
        for (featureRaw, stateRaw) in raw {
            guard let feature = OneWayAutomationFeature(rawValue: featureRaw),
                  let state = AutomationPermissionState(rawValue: stateRaw) else { continue }
            states[feature] = state
        }
        return states
    }

    private static func loadVehicles(defaults: UserDefaults) -> [RecognizedVehicle] {
        guard let data = defaults.data(forKey: Keys.recognizedVehicles),
              let vehicles = try? JSONDecoder().decode([RecognizedVehicle].self, from: data) else {
            return []
        }
        return vehicles
    }

    private enum Keys {
        static let actionButtonEnabled = "oneway.automation.actionButton.enabled"
        static let primaryAction = "oneway.automation.actionButton.primaryAction"
        static let featureStates = "oneway.automation.featureStates"
        static let recognizedVehicles = "oneway.automation.recognizedVehicles"
        static let didDeferDrivingPrompt = "oneway.automation.didDeferDrivingPrompt"
    }
}
