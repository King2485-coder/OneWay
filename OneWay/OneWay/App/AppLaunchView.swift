import SwiftUI

struct AppLaunchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = AppLaunchViewModel()
    @State private var canContinueOffline = false

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView("Loading OneWay…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            case .needsOnboarding:
                PrivacyFirstOnboardingView(importedContactsStore: environment.importedContactsStore) {
                    viewModel.finishOnboarding()
                }
            case .ready:
                RootView()
                    .environmentObject(environment)
            case .unableToVerify(let message):
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 18) {
                        Text("Unable to verify session")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text(message)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)

                        Button("Try Again") {
                            Task { await viewModel.load() }
                        }
                        .buttonStyle(.borderedProminent)

                        if canContinueOffline {
                            Button("Continue") {
                                viewModel.continueOfflineIfPreviouslyComplete()
                            }
                            .buttonStyle(.bordered)
                            .tint(.white.opacity(0.85))
                        }
                    }
                    .padding(24)
                }
            }
        }
        .task {
            canContinueOffline = AppLaunchViewModel.hasProfileCompleteHint()
            await viewModel.load()
        }
    }
}
