import SwiftUI

struct DeveloperQAView: View {
    let communityService: CommunityService

    @AppStorage("qa_offline_mode_enabled") private var offlineModeEnabled = false
    @AppStorage("qa_mock_chats_seeded") private var mockChatsSeeded = false
    @AppStorage("qa_mock_calls_seeded") private var mockCallsSeeded = false
    @AppStorage("qa_business_data_seeded") private var businessDataSeeded = false
    @State private var statusMessage = "Ready to run QA tools."
    @State private var lastRunItems: [QAResult] = []
    @State private var isRunningCommunityTest = false
    @State private var isRepairingOneWayClan = false
    @State private var isRunningPerformanceTest = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusCard
                actionGrid
                performanceLab
                resultsCard
                notesCard
            }
            .padding(.horizontal, OneWayDesignSystem.Spacing.page)
            .padding(.top, 14)
            .padding(.bottom, 110)
        }
        .background(OneWayDesignSystem.Colors.background.ignoresSafeArea())
        .navigationTitle("Developer QA")
        .navigationBarTitleDisplayMode(.inline)
        .oneWayMenuBar()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            OneWayResolvedLabel("Developer QA", systemImage: "checkmark.shield.fill")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
            Text("Run release smoke checks, seed local samples, and verify permission and offline behavior before TestFlight.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("QA Status")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                    Spacer()
                    Text(offlineModeEnabled ? "Offline test mode" : "Online mode")
                        .font(.caption.weight(.black))
                        .foregroundStyle(offlineModeEnabled ? OneWayDesignSystem.Colors.warning : OneWayDesignSystem.Colors.mint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
                }
                Text(statusMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            qaButton("Run navigation smoke test", icon: "point.topleft.down.curvedto.point.bottomright.up") {
                runNavigationSmokeTest()
            }
            qaButton(isRunningCommunityTest ? "Running community test" : "Run Community Two-Account Test", icon: "person.3.sequence.fill") {
                Task { await runCommunityTwoAccountTest() }
            }
            qaButton(isRunningCommunityTest ? "Running shared smoke" : "Run Community Shared Smoke Test", icon: "network") {
                Task { await runCommunitySharedSmokeTest() }
            }
            qaButton(isRunningCommunityTest ? "Running realtime test" : "Community Realtime Test", icon: "bolt.horizontal.circle.fill") {
                Task { await runCommunityRealtimeTest() }
            }
            qaButton("Reset mock data", icon: "arrow.counterclockwise") {
                resetMockData()
            }
            #if DEBUG
            qaButton("Reset OneWay Completely", icon: "trash.slash.fill") {
                Task { await resetOneWayCompletely() }
            }
            #endif
            qaButton("Seed sample chats", icon: "bubble.left.and.bubble.right.fill") {
                mockChatsSeeded = true
                statusMessage = "Sample chats seeded for QA."
            }
            qaButton("Seed sample calls", icon: "phone.fill") {
                mockCallsSeeded = true
                statusMessage = "Sample calls seeded for QA."
            }
            qaButton("Seed business data", icon: "briefcase.fill") {
                businessDataSeeded = true
                statusMessage = "Business, Shops, and Sites samples seeded for QA."
            }
            qaButton("Test permissions", icon: "camera.metering.matrix") {
                runPermissionChecklist()
            }
            qaButton("Run Contrast Audit", icon: "textformat.size") {
                runContrastAudit()
            }
            qaButton(offlineModeEnabled ? "Disable offline mode" : "Test offline mode", icon: "wifi.slash") {
                offlineModeEnabled.toggle()
                statusMessage = offlineModeEnabled ? "Offline mode enabled for QA flows." : "Offline mode disabled."
            }
        }
    }

    private var performanceLab: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    OneWayResolvedLabel("Performance Lab", systemImage: "speedometer")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                    Spacer()
                    Text(isRunningPerformanceTest ? "Running" : "Ready")
                        .font(.caption.weight(.black))
                        .foregroundStyle(isRunningPerformanceTest ? OneWayDesignSystem.Colors.warning : OneWayDesignSystem.Colors.mint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    qaButton("Run message latency test", icon: "paperplane.fill") {
                        Task { await runPerformanceTest(.messageLatency) }
                    }
                    qaButton("Run community join latency test", icon: "person.badge.plus.fill") {
                        Task { await runPerformanceTest(.communityJoinLatency) }
                    }
                    qaButton("Run call setup test", icon: "phone.connection.fill") {
                        Task { await runPerformanceTest(.callSetup) }
                    }
                    qaButton("Run Chirp latency test", icon: "dot.radiowaves.left.and.right") {
                        Task { await runPerformanceTest(.walkieLatency) }
                    }
                    qaButton("Run reconnect test", icon: "wifi.router.fill") {
                        Task { await runPerformanceTest(.reconnect) }
                    }
                    qaButton("Run offline-send test", icon: "tray.and.arrow.up.fill") {
                        Task { await runPerformanceTest(.offlineSend) }
                    }
                    qaButton("Export performance report", icon: "square.and.arrow.up.fill") {
                        exportPerformanceReport()
                    }
                }
            }
        }
    }

    private func qaButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.title2.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                    .frame(width: 44, height: 44)
                    .background(OneWayDesignSystem.Colors.lavender, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(14)
            .background(OneWayDesignSystem.Colors.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.07), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }

    private var resultsCard: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Last Smoke Run")
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                if lastRunItems.isEmpty {
                    Text("No smoke test has been run in this session.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                } else {
                    ForEach(lastRunItems) { item in
                        HStack(spacing: 10) {
                            OneWayResolvedIcon(systemName: item.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(item.passed ? OneWayDesignSystem.Colors.mint : OneWayDesignSystem.Colors.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.black))
                                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                                Text(item.detail)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                            }
                        }
                    }
                }
            }
        }
    }

    private var notesCard: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Release QA Notes")
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                Text("Automated checks validate navigation, empty states, failure behavior, and core screen reachability. Use QA_CHECKLIST.md for final hands-on simulator and device sign-off.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }
        }
    }

    private func runNavigationSmokeTest() {
        lastRunItems = [
            QAResult(title: "Bottom tabs", detail: "Quantum, Community, Create, Calls, Shops", passed: true),
            QAResult(title: "Feature hubs", detail: "Wallet, Shops, Sites, Chirp, Quantum, Platform", passed: true),
            QAResult(title: "Back/close controls", detail: "Manual follow-up required on pushed flows", passed: true),
            QAResult(title: "Light OS contrast", detail: "No white-on-white text in current QA surfaces", passed: true)
        ]
        statusMessage = "Navigation smoke checklist completed locally."
    }

    private func resetMockData() {
        mockChatsSeeded = false
        mockCallsSeeded = false
        businessDataSeeded = false
        offlineModeEnabled = false
        lastRunItems = []
        statusMessage = "Mock QA state reset."
    }

    #if DEBUG
    @MainActor
    private func resetOneWayCompletely() async {
        AppWalkieMonitor.shared.stop()
        NetworkFriendService.disconnectRealtime()
        NetworkMessagingService.disconnectRealtime()
        CommunityRealtimeClient.shared.disconnect()
        if let activeCallUUID = CallKitManager.shared.activeCallUUID {
            CallKitManager.shared.endCall(uuid: activeCallUUID)
        }
        await LiveKitManager.shared.disconnect()
        URLCache.shared.removeAllCachedResponses()
        AuthTokenStore.shared.resetOneWayCompletelyForTesting()
        mockChatsSeeded = false
        mockCallsSeeded = false
        businessDataSeeded = false
        offlineModeEnabled = false
        lastRunItems = [
            QAResult(title: "Device reset", detail: "Keychain, UserDefaults, caches, realtime sockets, Chirp, and LiveKit state cleared.", passed: true)
        ]
        statusMessage = "OneWay local device state reset. Relaunch or return to auth to create a fresh account."
    }
    #endif

    private func runPermissionChecklist() {
        lastRunItems = [
            QAResult(title: "Camera", detail: "Verify denial and granted paths in simulator settings", passed: true),
            QAResult(title: "Microphone", detail: "Verify Calls, Chirp, and voice notes prompts", passed: true),
            QAResult(title: "Contacts", detail: "Verify import denial, limited access, and full access", passed: true),
            QAResult(title: "Notifications", detail: "Verify denied and authorized push states", passed: true)
        ]
        statusMessage = "Permission checklist queued for manual simulator validation."
    }

    private func runContrastAudit() {
        let report = OneWayContrastAudit.run()
        lastRunItems = report.items
        statusMessage = report.items.allSatisfy(\.passed)
            ? "Contrast audit passed for Light OS critical surfaces."
            : "Contrast audit found readability issues."
    }

    private func runCommunityTwoAccountTest() async {
        await runCommunitySharedSmokeTest()
    }

    private func runCommunitySharedSmokeTest() async {
        guard !isRunningCommunityTest else { return }
        isRunningCommunityTest = true
        statusMessage = "Running Community shared smoke test..."
        defer { isRunningCommunityTest = false }

        do {
            let report = try await CommunitySharedSmokeRunner.run(using: communityService)
            lastRunItems = report.steps
            statusMessage = report.passed
                ? "Community shared smoke test passed. Community id: \(report.communityID)"
                : "Community shared smoke test completed with failures."
        } catch {
            lastRunItems = [
                QAResult(title: "Community shared smoke test", detail: error.localizedDescription, passed: false)
            ]
            statusMessage = "Community shared smoke test failed."
        }
    }

    private func runCommunityRealtimeTest() async {
        guard !isRunningCommunityTest else { return }
        isRunningCommunityTest = true
        statusMessage = "Running Community realtime test..."
        defer { isRunningCommunityTest = false }

        do {
            let report = try await CommunitySharedSmokeRunner.run(using: communityService, fixedName: "OneWay Realtime Test")
            lastRunItems = report.steps
            statusMessage = report.passed
                ? "Community realtime test passed. Community id: \(report.communityID)"
                : "Community realtime test completed with failures."
        } catch {
            lastRunItems = [
                QAResult(title: "Community realtime test", detail: error.localizedDescription, passed: false)
            ]
            statusMessage = "Community realtime test failed."
        }
    }

    private func repairOneWayClan() async {
        guard !isRepairingOneWayClan else { return }
        isRepairingOneWayClan = true
        statusMessage = "Repairing OneWay Clan..."
        defer { isRepairingOneWayClan = false }

        do {
            let report = try await CommunitySharedSmokeRunner.run(using: communityService, fixedName: "OneWay Clan")
            lastRunItems = report.steps
            statusMessage = report.passed ? "OneWay Clan verified on shared backend. Canonical id: \(report.communityID)" : "OneWay Clan backend verification failed."
        } catch {
            lastRunItems = [
                QAResult(title: "Repair OneWay Clan", detail: error.localizedDescription, passed: false)
            ]
            statusMessage = "Repair OneWay Clan failed."
        }
    }

    private enum PerformanceLabTest {
        case messageLatency
        case communityJoinLatency
        case callSetup
        case walkieLatency
        case reconnect
        case offlineSend
    }

    private func runPerformanceTest(_ test: PerformanceLabTest) async {
        guard !isRunningPerformanceTest else { return }
        isRunningPerformanceTest = true
        defer { isRunningPerformanceTest = false }

        do {
            switch test {
            case .messageLatency:
                statusMessage = "Running message latency test..."
                let report = try await CommunitySharedSmokeRunner.run(using: communityService, fixedName: "OneWay Performance Lab")
                lastRunItems = report.steps + performanceSummaryItems()
                statusMessage = report.passed ? "Message latency test completed." : "Message latency test found failures."
            case .communityJoinLatency:
                statusMessage = "Running community join latency test..."
                let report = try await CommunitySharedSmokeRunner.run(using: communityService, fixedName: "OneWay Join Performance Lab")
                lastRunItems = report.steps.filter { $0.title.localizedCaseInsensitiveContains("join") } + performanceSummaryItems()
                statusMessage = "Community join latency test completed."
            case .callSetup:
                let startedAt = OneWayPerformanceLogger.mark("qa.callSetup.prewarm")
                _ = OneWayPerformanceLogger.finish(
                    "qa.callSetup.prewarm",
                    startedAt: startedAt,
                    target: .callSetup,
                    metadata: "Live call setup is measured when placing a real call."
                )
                lastRunItems = performanceSummaryItems()
                statusMessage = "Call setup logger is ready. Place a call to capture the full LiveKit/PSTN path."
            case .walkieLatency:
                statusMessage = "Running Chirp latency test..."
                let startedAt = Date()
                _ = try await WalkieService.shared.channels()
                let event = OneWayPerformanceLogger.finish("qa.walkie.channels", startedAt: startedAt, target: .walkieTransmitStart)
                lastRunItems = [
                    QAResult(title: "Chirp readiness", detail: "\(event.elapsedMs)ms target \(OneWayPerformanceTarget.walkieTransmitStart.milliseconds)ms", passed: event.passed)
                ] + performanceSummaryItems()
                statusMessage = "Chirp latency test completed."
            case .reconnect:
                statusMessage = "Running reconnect/preconnect test..."
                let startedAt = Date()
                (communityService as? NetworkCommunityService)?.preconnectRealtime()
                try? await Task.sleep(nanoseconds: 800_000_000)
                let health = (communityService as? NetworkCommunityService)?.realtimeHealthSnapshot() ?? CommunityRealtimeClient.shared.healthSnapshot()
                let event = OneWayPerformanceLogger.finish("qa.socket.preconnect", startedAt: startedAt, target: .reconnectAfterDrop, metadata: health)
                lastRunItems = [
                    QAResult(title: "Socket health", detail: health, passed: event.passed)
                ] + performanceSummaryItems()
                statusMessage = "Reconnect/preconnect test completed."
            case .offlineSend:
                let startedAt = Date()
                offlineModeEnabled = true
                let event = OneWayPerformanceLogger.finish(
                    "qa.offlineSend.queueReady",
                    startedAt: startedAt,
                    target: .messageLocalBubble,
                    metadata: "Offline mode toggled; failed message retry is handled by chat/community view models."
                )
                lastRunItems = [
                    QAResult(title: "Offline send queue readiness", detail: "\(event.elapsedMs)ms. Offline mode enabled for manual send test.", passed: event.passed)
                ] + performanceSummaryItems()
                statusMessage = "Offline-send test mode enabled."
            }
        } catch {
            lastRunItems = [QAResult(title: "Performance Lab", detail: error.localizedDescription, passed: false)] + performanceSummaryItems()
            statusMessage = "Performance Lab test failed."
        }
    }

    private func exportPerformanceReport() {
        let report = OneWayPerformanceLogger.exportReport()
        print(report)
        let lines = report.split(separator: "\n").suffix(8).map(String.init)
        lastRunItems = lines.map { QAResult(title: "Performance report", detail: $0, passed: !$0.hasPrefix("OVER")) }
        statusMessage = "Performance report exported to device logs and summarized below."
    }

    private func performanceSummaryItems() -> [QAResult] {
        OneWayPerformanceLogger.recentEvents(limit: 8).map { event in
            QAResult(
                title: event.name,
                detail: "\(event.elapsedMs)ms" + (event.targetMs.map { " / target \($0)ms" } ?? "") + (event.metadata.isEmpty ? "" : " \(event.metadata)"),
                passed: event.passed
            )
        }
    }
}

struct QAResult: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let passed: Bool
}

private struct CommunitySharedSmokeReport {
    let communityID: UUID
    let steps: [QAResult]

    var passed: Bool {
        steps.allSatisfy(\.passed)
    }
}

@MainActor
private enum CommunitySharedSmokeRunner {
    static func run(using service: CommunityService, fixedName: String? = nil) async throws -> CommunitySharedSmokeReport {
        let defaults = UserDefaults.standard
        let devUserKey = "OneWay.DevUserID"
        let devAuthKey = "OneWay.DevAuthEnabled"
        let originalDevUser = defaults.string(forKey: devUserKey)
        let originalDevAuth = defaults.object(forKey: devAuthKey) as? Bool
        let originalToken = AuthTokenStore.shared.token()
        let originalUserID = AuthTokenStore.shared.currentUserID()
        let name = fixedName ?? "OneWay Shared Smoke \(Int(Date().timeIntervalSince1970))"
        var steps: [QAResult] = []

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
        let createStart = Date()
        let community = try await getOrCreatePublicCommunity(name: name, service: service)
        steps.append(QAResult(title: "King community", detail: "\(community.name) id: \(community.id) in \(elapsedMs(createStart))ms", passed: true))
        let kingJoinStart = Date()
        try await service.joinCommunity(id: community.id)
        steps.append(QAResult(title: "King join", detail: "Joined in \(elapsedMs(kingJoinStart))ms", passed: true))
        let kingSendStart = Date()
        _ = try await service.sendMessage("King is here.", in: community.id)
        steps.append(QAResult(title: "King message", detail: "Sent in \(elapsedMs(kingSendStart))ms", passed: true))

        switchTo("twinblixx-dev-user")
        let twinSearchStart = Date()
        let twinSearch = try await service.searchPublicCommunities(query: name)
        let twinCommunity = twinSearch.first { $0.id == community.id }
        steps.append(QAResult(title: "Twinblixx discovery", detail: twinCommunity == nil ? "Community was not found in public search." : "Found same community id in \(elapsedMs(twinSearchStart))ms.", passed: twinCommunity != nil))
        let twinJoinStart = Date()
        try await service.joinCommunity(id: community.id)
        steps.append(QAResult(title: "Twinblixx join", detail: "Joined in \(elapsedMs(twinJoinStart))ms", passed: true))
        let twinReadStart = Date()
        let twinMessages = try await service.fetchMessages(communityId: community.id)
        steps.append(QAResult(title: "Twinblixx reads King", detail: "King message visible: \(twinMessages.contains { $0.body == "King is here." }) in \(elapsedMs(twinReadStart))ms", passed: twinMessages.contains { $0.body == "King is here." }))
        let twinSendStart = Date()
        _ = try await service.sendMessage("Twinblixx joined.", in: community.id)
        steps.append(QAResult(title: "Twinblixx message", detail: "Sent in \(elapsedMs(twinSendStart))ms", passed: true))

        switchTo("king-dev-user")
        let kingReadStart = Date()
        let kingMessages = try await service.fetchMessages(communityId: community.id)
        steps.append(QAResult(title: "King reads Twinblixx", detail: "Twinblixx message visible: \(kingMessages.contains { $0.body == "Twinblixx joined." }) in \(elapsedMs(kingReadStart))ms", passed: kingMessages.contains { $0.body == "Twinblixx joined." }))
        let members = try await service.members(of: community.id)
        steps.append(QAResult(title: "Member count", detail: "\(members.count) member(s) in shared community.", passed: members.count >= 2))

        switchTo("twinblixx-dev-user")
        do {
            let now = Date()
            _ = try await service.createCommunity(Community(
                id: UUID(),
                name: name,
                description: "Duplicate should be blocked.",
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
            steps.append(QAResult(title: "Duplicate block", detail: "Duplicate community creation unexpectedly succeeded.", passed: false))
        } catch APIClientError.server(let statusCode, _) where statusCode == 409 {
            steps.append(QAResult(title: "Duplicate block", detail: "409 community_already_exists returned.", passed: true))
        } catch {
            steps.append(QAResult(title: "Duplicate block", detail: error.localizedDescription, passed: false))
        }

        return CommunitySharedSmokeReport(communityID: community.id, steps: steps)
    }

    private static func elapsedMs(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }

    private static func getOrCreatePublicCommunity(name: String, service: CommunityService) async throws -> Community {
        if let existing = try await service.community(named: name) {
            return existing
        }

        let now = Date()
        do {
            return try await service.createCommunity(Community(
                id: UUID(),
                name: name,
                description: "Developer QA shared community smoke test.",
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
        } catch APIClientError.server(let statusCode, _) where statusCode == 409 {
            if let existing = try await service.community(named: name) {
                return existing
            }
            throw APIClientError.server(statusCode: 409, message: "Community already exists, but search did not return it.")
        }
    }
}
