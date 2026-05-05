import SwiftUI

@main
@MainActor
struct CipherChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment = AppEnvironment.live
    @AppStorage("did_complete_onboarding") private var didCompleteOnboarding = false

    init() {
        // Bind the env into the AppDelegate so the PushKit registry has
        // somewhere to deliver incoming-call payloads. `bind` is idempotent.
        AppDelegate.shared.bind(environment: environment)
        VoIPPushManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if didCompleteOnboarding {
                    RootView()
                        .environmentObject(environment)
                } else {
                    OnboardingView {
                        didCompleteOnboarding = true
                    }
                }
            }
        }
    }
}
