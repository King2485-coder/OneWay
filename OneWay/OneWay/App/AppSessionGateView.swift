import SwiftUI

struct AppSessionGateView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = AppSessionViewModel()

    var body: some View {
        sessionGate
    }

    private var sessionGate: some View {
        Group {
            switch viewModel.state {
            case .loading:
                SplashLoadingView()
            case .unauthenticated:
                LoginView(onAuthed: { Task { await viewModel.refresh() } })
            case .authenticatedComplete:
                RootView(onSignOut: { await viewModel.signOut(environment: environment) })
                    .environmentObject(environment)
                    .onAppear {
                        prewarmAuthenticatedServices()
                    }
            case .authenticatedIncomplete:
                PrivacyFirstOnboardingView(importedContactsStore: environment.importedContactsStore) {
                    viewModel.finishOnboardingAndEnter()
                }
            case .backendUnavailable:
                BackendUnavailableView(
                    onRetry: { Task { await viewModel.refresh() } }
                )
            }
        }
        .task { await viewModel.refresh() }
        .onChange(of: viewModel.state) { _, newState in
            if newState == .authenticatedComplete {
                AppWalkieMonitor.shared.start()
                prewarmAuthenticatedServices()
            } else {
                AppWalkieMonitor.shared.stop()
            }
        }
    }

    private func prewarmAuthenticatedServices() {
        let startedAt = OneWayPerformanceLogger.mark("app.authenticated.prewarm")
        (environment.communityService as? NetworkCommunityService)?.preconnectRealtime()
        environment.messagingService.preconnectRealtime()
        Task {
            async let cachedCommunities = environment.communityService.cachedCommunities()
            async let cachedMemberships = environment.communityService.cachedJoinedCommunityIDs()
            _ = await (cachedCommunities, cachedMemberships)

            async let publicCommunities: Void = {
                _ = try? await environment.communityService.fetchPublicCommunities()
            }()
            async let memberships: Void = {
                _ = try? await environment.communityService.fetchMyMembershipIDs()
            }()
            async let chats: Void = {
                _ = try? await environment.messagingService.fetchChats()
            }()
            _ = await (publicCommunities, memberships, chats)
            _ = OneWayPerformanceLogger.finish(
                "app.authenticated.prewarm",
                startedAt: startedAt,
                target: .coldLaunchUsableUI,
                metadata: "baseURL=\(environment.baseURL)"
            )
        }
    }

    // Login bypass is a local-development tool only. A production API session
    // must always be backed by a server-issued JWT, including Simulator Debug
    // builds, otherwise protected services appear connected while returning
    // authentication failures.
    private static var loginBypassEnabled: Bool {
        #if DEBUG
        let environmentValue = ProcessInfo.processInfo.environment["ONEWAY_LOGIN_BYPASS"]
        let defaultsValue = UserDefaults.standard.object(forKey: "OneWay.LoginBypassEnabled") as? Bool
        if let defaultsValue { return defaultsValue && DevAuth.enabled }
        if let environmentValue {
            let requested = environmentValue == "1" || environmentValue.lowercased() == "true"
            return requested && DevAuth.enabled
        }
        #if targetEnvironment(simulator)
        return DevAuth.enabled
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    private static var communityTwoAccountUITestEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--qa-community-two-account")
        #else
        false
        #endif
    }
}

private struct CommunityTwoAccountQATestOverlay: View {
    @State private var status = "Running Community two-account test..."
    @State private var results: [CommunityTwoAccountTestStep] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Community Two-Account Test")
                .font(.title2.weight(.black))
            Text(status)
                .font(.subheadline.weight(.bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        HStack(alignment: .top, spacing: 8) {
                            OneWayResolvedIcon(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.passed ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(.caption.weight(.black))
                                Text(result.detail)
                                    .font(.caption2)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .foregroundStyle(.black)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.96))
        .task {
            await run()
        }
        .accessibilityIdentifier("community-two-account-test-overlay")
    }

    private func run() async {
        do {
            let reportSteps = try await AppSessionCommunitySmokeRunner.run()
            results = reportSteps
            status = reportSteps.allSatisfy(\.passed)
                ? "Community two-account test passed."
                : "Community two-account test failed."
        } catch {
            status = "Community two-account test failed."
            results = [
                CommunityTwoAccountTestStep(title: "Community two-account test", detail: error.localizedDescription, passed: false)
            ]
        }
    }
}

@MainActor
private enum AppSessionCommunitySmokeRunner {
    static func run() async throws -> [CommunityTwoAccountTestStep] {
        let service: CommunityService = NetworkCommunityService(client: .shared)
        let defaults = UserDefaults.standard
        let devUserKey = "OneWay.DevUserID"
        let devAuthKey = "OneWay.DevAuthEnabled"
        let originalDevUser = defaults.string(forKey: devUserKey)
        let originalDevAuth = defaults.object(forKey: devAuthKey) as? Bool
        let originalToken = AuthTokenStore.shared.token()
        let originalUserID = AuthTokenStore.shared.currentUserID()
        let name = "OneWay Shared Smoke \(Int(Date().timeIntervalSince1970))"
        var steps: [CommunityTwoAccountTestStep] = []

        func switchTo(_ userID: String) {
            defaults.set(userID, forKey: devUserKey)
            defaults.set(false, forKey: devAuthKey)
            AuthTokenStore.shared.setToken(nil)
            AuthTokenStore.shared.setUserID(userID)
        }

        func restoreAuth() {
            if let originalDevUser {
                defaults.set(originalDevUser, forKey: devUserKey)
            } else {
                defaults.removeObject(forKey: devUserKey)
            }
            if let originalDevAuth {
                defaults.set(originalDevAuth, forKey: devAuthKey)
            } else {
                defaults.removeObject(forKey: devAuthKey)
            }
            AuthTokenStore.shared.setUserID(originalUserID)
            AuthTokenStore.shared.setToken(originalToken)
        }

        defer { restoreAuth() }

        switchTo("king-dev-user")
        let community = try await createCommunity(name: name, service: service)
        try await service.joinCommunity(id: community.id)
        _ = try await service.sendMessage("King is here.", in: community.id)
        steps.append(.init(title: "King created and messaged", detail: community.id.uuidString, passed: true))

        switchTo("twinblixx-dev-user")
        let found = try await service.searchPublicCommunities(query: name).contains { $0.id == community.id }
        steps.append(.init(title: "Twinblixx discovery", detail: found ? "Found same public community." : "Missing from public search.", passed: found))
        try await service.joinCommunity(id: community.id)
        let twinReadsKing = try await service.fetchMessages(communityId: community.id).contains { $0.body == "King is here." }
        steps.append(.init(title: "Twinblixx reads King", detail: "\(twinReadsKing)", passed: twinReadsKing))
        _ = try await service.sendMessage("Twinblixx joined.", in: community.id)

        switchTo("king-dev-user")
        let kingReadsTwin = try await service.fetchMessages(communityId: community.id).contains { $0.body == "Twinblixx joined." }
        let memberCount = try await service.members(of: community.id).count
        steps.append(.init(title: "King reads Twinblixx", detail: "\(kingReadsTwin)", passed: kingReadsTwin))
        steps.append(.init(title: "Shared members", detail: "\(memberCount) member(s)", passed: memberCount >= 2))

        return steps
    }

    private static func createCommunity(name: String, service: CommunityService) async throws -> Community {
        if let existing = try await service.community(named: name) {
            return existing
        }
        let now = Date()
        return try await service.createCommunity(Community(
            id: UUID(),
            name: name,
            description: "App session community smoke test.",
            creatorUserId: "",
            creatorHandle: "",
            visibility: .public,
            coverImageURL: nil,
            avatarURL: nil,
            ownerID: UUID(),
            admins: [],
            moderators: [],
            members: [],
            blockedUserIds: [],
            bannedUserIds: [],
            messages: [],
            linkedGroupIDs: [],
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        ))
    }
}

private struct SplashLoadingView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView("Loading OneWay…")
                .tint(.white)
                .foregroundStyle(.white)
        }
    }
}

private struct BackendUnavailableView: View {
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Unable to reach OneWay")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)

                Text("We couldn’t verify your session right now. Try again when the backend is reachable.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)

                Button("Try Again") { onRetry() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
    }
}
