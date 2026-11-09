import Foundation

enum OneWayButtonAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case smartActionMenu
    case startChirp
    case openCamera
    case callFavorite
    case openQuantum
    case openWallet
    case openAI
    case openNavigation
    case emergencyMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartActionMenu: return "Smart Action Menu"
        case .startChirp: return "Start Chirp"
        case .openCamera: return "Open Camera"
        case .callFavorite: return "Call Favorite"
        case .openQuantum: return "Open Quantum"
        case .openWallet: return "Open Wallet"
        case .openAI: return "Open AI Assistant"
        case .openNavigation: return "Open Navigation"
        case .emergencyMode: return "Emergency Mode"
        }
    }

    var symbolName: String {
        switch self {
        case .smartActionMenu: return "square.grid.2x2.fill"
        case .startChirp: return "dot.radiowaves.left.and.right"
        case .openCamera: return "camera.fill"
        case .callFavorite: return "phone.fill"
        case .openQuantum: return "globe"
        case .openWallet: return "wallet.pass.fill"
        case .openAI: return "sparkles"
        case .openNavigation: return "location.north.fill"
        case .emergencyMode: return "sos.circle.fill"
        }
    }

    var requiresConfirmationPreference: OneWayAutomationFeature? {
        switch self {
        case .startChirp: return .chirpPushToTalk
        case .callFavorite: return .favoriteContact
        case .openNavigation: return .navigation
        case .emergencyMode: return .emergencyMode
        default: return nil
        }
    }
}

enum AutomationPermissionState: String, CaseIterable, Codable, Identifiable, Sendable {
    case on
    case askFirst
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .on: return "On"
        case .askFirst: return "Ask First"
        case .off: return "Off"
        }
    }
}

enum OneWayAutomationFeature: String, CaseIterable, Codable, Identifiable, Sendable {
    case drivingMode
    case currentCallControls
    case quantumVoiceSearch
    case cameraQuickLaunch
    case favoriteContact
    case chirpPushToTalk
    case navigation
    case emergencyMode
    case lockScreenAccess
    case hapticConfirmation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drivingMode: return "Driving Mode"
        case .currentCallControls: return "Current Call Controls"
        case .quantumVoiceSearch: return "Quantum Voice Search"
        case .cameraQuickLaunch: return "Camera Quick Launch"
        case .favoriteContact: return "Favorite Contact"
        case .chirpPushToTalk: return "Chirp Push-to-Talk"
        case .navigation: return "Navigation"
        case .emergencyMode: return "Emergency Mode"
        case .lockScreenAccess: return "Lock Screen Access"
        case .hapticConfirmation: return "Haptic Confirmation"
        }
    }

    var summary: String {
        switch self {
        case .drivingMode:
            return "Prepare large hands-free controls after a permitted vehicle signal."
        case .currentCallControls:
            return "Offer mute, speaker, and return-to-call actions while a OneWay call is active."
        case .quantumVoiceSearch:
            return "Offer voice search when Quantum is the active surface."
        case .cameraQuickLaunch:
            return "Open the camera surface without taking a photo automatically."
        case .favoriteContact:
            return "Prepare favorite-contact calling, with confirmation when required."
        case .chirpPushToTalk:
            return "Open Chirp controls. Microphone transmission still requires press-and-hold."
        case .navigation:
            return "Prepare destination and driving options when location use is permitted."
        case .emergencyMode:
            return "Show emergency controls. OneWay will not trigger emergency actions silently."
        case .lockScreenAccess:
            return "Allow selected OneWay shortcuts to be exposed from lock-screen capable surfaces."
        case .hapticConfirmation:
            return "Play a subtle haptic after successful shortcut actions."
        }
    }

    var defaultState: AutomationPermissionState {
        switch self {
        case .currentCallControls, .quantumVoiceSearch, .cameraQuickLaunch, .hapticConfirmation:
            return .on
        case .drivingMode, .favoriteContact, .chirpPushToTalk, .navigation, .emergencyMode, .lockScreenAccess:
            return .askFirst
        }
    }
}

struct OneWayAutomationPreference: Codable, Equatable, Sendable {
    let feature: OneWayAutomationFeature
    var state: AutomationPermissionState
}

enum VehicleAutomationBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    case showDrivingDashboard
    case openNavigation
    case askForDestination
    case resumeAudio
    case doNothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .showDrivingDashboard: return "Show Driving Dashboard"
        case .openNavigation: return "Open Navigation"
        case .askForDestination: return "Ask for Destination"
        case .resumeAudio: return "Resume Audio"
        case .doNothing: return "Do Nothing Automatically"
        }
    }
}

struct RecognizedVehicle: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var behavior: VehicleAutomationBehavior
    var drivingModeEnabled: Bool
    var rememberChoice: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        behavior: VehicleAutomationBehavior = .doNothing,
        drivingModeEnabled: Bool = false,
        rememberChoice: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.behavior = behavior
        self.drivingModeEnabled = drivingModeEnabled
        self.rememberChoice = rememberChoice
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct OneWayActionContext: Equatable, Sendable {
    var hasActiveCall: Bool = false
    var isChirpActive: Bool = false
    var isQuantumActive: Bool = false
    var isDrivingModeActive: Bool = false
}
