import SwiftUI

/// Top-level container for the OneWay browser tab. Mirrors the pattern used
/// by `ChatHomeView` / `BusinessHomeView`: hold the navigation stack, expose
/// services from `AppEnvironment` to children.
struct BrowserHostView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            BrowserHomeView(
                domainService: environment.domainService,
                siteService: environment.siteService
            )
        }
        .tint(Theme.primaryBlue)
    }
}
