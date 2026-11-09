import SwiftUI

/// Top-level container for the OneWay browser tab. Mirrors the pattern used
/// by `ChatHomeView` / `BusinessHomeView`: hold the navigation stack, expose
/// services from `AppEnvironment` to children.
struct BrowserHostView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var pendingInitialURL: URL?
    let asksForStartupPortal: Bool

    init(initialURL: URL? = nil, asksForStartupPortal: Bool = false) {
        _pendingInitialURL = State(initialValue: initialURL)
        self.asksForStartupPortal = asksForStartupPortal
    }

    var body: some View {
        NavigationStack {
            BrowserHomeView(
                domainService: environment.domainService,
                siteService: environment.siteService,
                initialURL: pendingInitialURL,
                asksForStartupPortal: asksForStartupPortal,
                onInitialURLConsumed: {
                    pendingInitialURL = nil
                }
            )
        }
        .tint(Theme.primaryBlue)
    }
}
