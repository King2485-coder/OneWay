import AppIntents
import Foundation

struct OpenOneWaySmartActionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open OneWay Smart Actions"
    static var description = IntentDescription("Open the safe OneWay Smart Action Menu.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        OneWayActionRouter.shared.requestPrimaryAction()
        return .result()
    }
}

struct StartOneWayChirpIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Chirp"
    static var description = IntentDescription("Open Chirp push-to-talk controls without transmitting audio automatically.")
    static var openAppWhenRun = true

    @Parameter(title: "Recipient", description: "Optional Chirp recipient or OneWay ID.")
    var recipient: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[OneWayRoute] StartChirpIntent performed")
        #endif
        OneWayActionRouter.shared.requestDestination(.chirp)
        return .result()
    }
}

struct OpenOneWayCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Open OneWay Camera"
    static var description = IntentDescription("Open OneWay camera capture without taking a photo automatically.")
    static var openAppWhenRun = true

    @Parameter(title: "Camera Mode", description: "Optional camera mode.")
    var cameraMode: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[OneWayRoute] OpenOneWayCameraIntent performed")
        #endif
        OneWayActionRouter.shared.requestDestination(.camera)
        return .result()
    }
}

struct CallOneWayContactIntent: AppIntent {
    static var title: LocalizedStringResource = "Call OneWay Contact"
    static var description = IntentDescription("Prepare a OneWay contact call. Confirmation may be required by your settings.")
    static var openAppWhenRun = true

    @Parameter(title: "Contact", description: "Contact name, phone number, or OneWay ID.")
    var contact: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        OneWayActionRouter.shared.request(.callFavorite)
        return .result()
    }
}

struct OpenQuantumIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Quantum"
    static var description = IntentDescription("Open OneWay Quantum.")
    static var openAppWhenRun = true

    @Parameter(title: "Search Query", description: "Optional Quantum search query.")
    var searchQuery: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        OneWayActionRouter.shared.request(.openQuantum)
        return .result()
    }
}

struct OpenOneWayWalletIntent: AppIntent {
    static var title: LocalizedStringResource = "Open OneWay Wallet"
    static var description = IntentDescription("Open the OneWay Wallet.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        OneWayActionRouter.shared.request(.openWallet)
        return .result()
    }
}

struct OpenOneWayAIIntent: AppIntent {
    static var title: LocalizedStringResource = "Open OneWay AI"
    static var description = IntentDescription("Open the OneWay AI assistant.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        OneWayActionRouter.shared.request(.openAI)
        return .result()
    }
}

struct OpenOneWayNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open OneWay Navigation"
    static var description = IntentDescription("Open OneWay navigation options.")
    static var openAppWhenRun = true

    @Parameter(title: "Destination", description: "Optional destination.")
    var destination: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        OneWayActionRouter.shared.request(.openNavigation)
        return .result()
    }
}

struct ActivateOneWayEmergencyModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Activate OneWay Emergency Mode"
    static var description = IntentDescription("Open OneWay emergency controls. Emergency actions require user confirmation.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        OneWayActionRouter.shared.request(.emergencyMode)
        return .result()
    }
}

struct OneWayActionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenOneWaySmartActionsIntent(),
            phrases: ["Open \(.applicationName) Smart Actions", "Run \(.applicationName) Action Button"],
            shortTitle: "Smart Actions",
            systemImageName: "square.grid.2x2.fill"
        )
        AppShortcut(
            intent: StartOneWayChirpIntent(),
            phrases: [
                "Start Chirp in \(.applicationName)",
                "Open Chirp in \(.applicationName)",
                "Chirp with \(.applicationName)",
                "Start \(.applicationName) Chirp"
            ],
            shortTitle: "Start Chirp",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: OpenOneWayCameraIntent(),
            phrases: ["Open \(.applicationName) Camera"],
            shortTitle: "Camera",
            systemImageName: "camera.fill"
        )
        AppShortcut(
            intent: CallOneWayContactIntent(),
            phrases: ["Call with \(.applicationName)"],
            shortTitle: "Call Contact",
            systemImageName: "phone.fill"
        )
        AppShortcut(
            intent: OpenQuantumIntent(),
            phrases: ["Open \(.applicationName) Quantum"],
            shortTitle: "Quantum",
            systemImageName: "globe"
        )
        AppShortcut(
            intent: OpenOneWayWalletIntent(),
            phrases: ["Open \(.applicationName) Wallet"],
            shortTitle: "Wallet",
            systemImageName: "wallet.pass.fill"
        )
        AppShortcut(
            intent: OpenOneWayAIIntent(),
            phrases: ["Open \(.applicationName) AI"],
            shortTitle: "OneWay AI",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenOneWayNavigationIntent(),
            phrases: ["Open \(.applicationName) Navigation"],
            shortTitle: "Navigation",
            systemImageName: "location.north.fill"
        )
        AppShortcut(
            intent: ActivateOneWayEmergencyModeIntent(),
            phrases: ["Open \(.applicationName) Emergency Mode"],
            shortTitle: "Emergency",
            systemImageName: "sos.circle.fill"
        )
    }
}
