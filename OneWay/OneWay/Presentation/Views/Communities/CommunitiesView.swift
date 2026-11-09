import Combine
import SwiftUI
import AVFoundation

struct CommunitiesView: View {
    private enum Route: Hashable {
        case examples
        case newCommunity
        case detail(UUID)
    }

    @State private var communities: [Community] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var duplicateCommunity: Community?
    @State private var searchText = ""
    @State private var path: [Route] = []
    @State private var joinedCommunityIDs: Set<UUID> = []
    @State private var discoveryRealtimeTask: Task<Void, Never>?
    @State private var discoveryPollingTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @State private var didRunInitialLoad = false
    @State private var lastLoadedQuery = ""
    @State private var lastLoadedAt: Date?
    private let communityService: CommunityService
    private let messagingService: MessagingService
    private let cryptoService: CryptoService

    init(communityService: CommunityService, messagingService: MessagingService, cryptoService: CryptoService) {
        self.communityService = communityService
        self.messagingService = messagingService
        self.cryptoService = cryptoService
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    searchBar
                    if let errorMessage {
                        CommunityRetryCard(message: errorMessage) {
                            Task { await loadCommunities(force: true) }
                        }
                    }
                    primaryAction
                    CommunitySearchResultsSection(
                        title: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Explore Communities" : "Search Results",
                        communities: displayedCommunities,
                        currentHandle: currentHandle,
                        joinedCommunityIDs: joinedCommunityIDs,
                        onOpen: { path.append(.detail($0.id)) },
                        onJoin: { community in
                            Task { await joinExistingCommunity(community) }
                        }
                    )
                    if isLoading {
                        loadingState
                    } else if publicCommunities.isEmpty {
                        CommunityEmptyState(
                            onCreate: { path.append(.newCommunity) },
                            onBrowse: { path.append(.examples) }
                        )
                    }
                }
                .padding(.horizontal, OneWayDesignSystem.Spacing.page)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .background(OneWayDesignSystem.Colors.background.ignoresSafeArea())
            .oneWayMenuBar()
            .navigationBarHidden(true)
            .refreshable {
                await loadCommunities(force: true)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .examples:
                    ExampleCommunitiesView()
                case .newCommunity:
                    NewCommunityView { name, description in
                        Task { await createCommunity(name: name, description: description) }
                    }
                case .detail(let id):
                    CommunityDetailView(
                        communityID: id,
                        communityService: communityService,
                        messagingService: messagingService,
                        cryptoService: cryptoService
                    )
                }
            }
            .task {
                await runInitialLoadIfNeeded()
                startDiscoveryRealtime()
            }
            .onAppear {
                startDiscoveryRealtime()
                Task { await runInitialLoadIfNeeded() }
            }
            .onDisappear {
                stopDiscoveryRealtime()
                searchTask?.cancel()
                searchTask = nil
            }
            .onChange(of: path) { _, newPath in
                guard newPath.isEmpty, shouldRefreshCommunities(minimumAge: 10) else { return }
                Task { await loadCommunities(force: true) }
            }
            .onChange(of: searchText) { _, _ in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    await loadCommunities(force: true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: OneWayConnectivity.didBecomeOnline)) { _ in
                Task { await loadCommunities(force: true) }
            }
            .confirmationDialog(
                "Community already exists",
                isPresented: Binding(
                    get: { duplicateCommunity != nil },
                    set: { if !$0 { duplicateCommunity = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("View Community") {
                    if let duplicateCommunity {
                        path.append(.detail(duplicateCommunity.id))
                    }
                    duplicateCommunity = nil
                }
                Button("Join") {
                    if let duplicateCommunity {
                        Task { await joinExistingCommunity(duplicateCommunity) }
                    }
                    duplicateCommunity = nil
                }
                Button("Cancel", role: .cancel) {
                    duplicateCommunity = nil
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Communities")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .oneWayReadableText(.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                    Text("Groups for families, businesses, schools and creators.")
                        .font(.callout.weight(.semibold))
                        .oneWayReadableText(.subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var searchBar: some View {
        OneWaySearchBar(placeholder: "Search communities…", text: $searchText)
    }

    private var primaryAction: some View {
        Button {
            path.append(.newCommunity)
        } label: {
            OneWayResolvedLabel("New Community", systemImage: "plus")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(OneWayDesignSystem.Colors.purpleGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: OneWayDesignSystem.Colors.purple.opacity(0.24), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }

    private var publicCommunities: [Community] {
        communities
    }

    private var displayedCommunities: [Community] {
        communities
    }

    private var currentHandle: String {
        let candidates = [
            UserDefaults.standard.string(forKey: "OneWay.LastLoginIdentifier"),
            UserDefaults.standard.string(forKey: "OneWay.DebugLoginIdentifierOverride"),
            UserDefaults.standard.string(forKey: "OneWay.DebugLoginIdentifier"),
            ProcessInfo.processInfo.environment["ONEWAY_DEBUG_LOGIN_IDENTIFIER"]
        ]
        let raw = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "king"
        let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        return "@\(handle)"
    }

    private var loadingState: some View {
        OneWayCard {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(OneWayDesignSystem.Colors.purple)
                Text("Loading communities...")
                    .font(.headline.weight(.semibold))
                    .oneWayReadableText(.subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runInitialLoadIfNeeded() async {
        guard !didRunInitialLoad else { return }
        didRunInitialLoad = true
        await loadCachedMembershipsAndCommunities()
        await loadCommunities(force: true)
    }

    private func loadCommunities(force: Bool = false) async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLoading else { return }
        if !force,
           query == lastLoadedQuery,
           !shouldRefreshCommunities(minimumAge: 30) {
            return
        }

        isLoading = communities.isEmpty
        defer { isLoading = false }

        do {
            async let memberships = communityService.fetchMyMembershipIDs()
            communities = query.isEmpty
                ? try await communityService.fetchPublicCommunities()
                : try await communityService.searchPublicCommunities(query: query)
            joinedCommunityIDs = try await memberships
            lastLoadedQuery = query
            lastLoadedAt = Date()
            errorMessage = nil
        } catch {
            if OneWayNetworkError.classify(error) == .cancelled {
                return
            }
            errorMessage = communityErrorMessage(error, fallback: "Unable to load communities.")
        }
    }

    private func shouldRefreshCommunities(minimumAge: TimeInterval) -> Bool {
        guard let lastLoadedAt else { return true }
        return Date().timeIntervalSince(lastLoadedAt) >= minimumAge
    }

    private func loadCachedMembershipsAndCommunities() async {
        let startedAt = CommunityPerformanceLogger.mark("community screen cache hydrate")
        let cachedMemberships = await communityService.cachedJoinedCommunityIDs()
        if !cachedMemberships.isEmpty {
            joinedCommunityIDs = cachedMemberships
        }
        if communities.isEmpty {
            let cachedCommunities = await communityService.cachedCommunities()
            if !cachedCommunities.isEmpty {
                communities = cachedCommunities
            }
        }
        CommunityPerformanceLogger.finish(
            "community screen cache hydrate",
            startedAt: startedAt,
            metadata: "memberships=\(joinedCommunityIDs.count) communities=\(communities.count)"
        )
    }

    private func startDiscoveryRealtime() {
        guard discoveryRealtimeTask == nil else { return }
        discoveryPollingTask?.cancel()
        discoveryPollingTask = nil

            discoveryRealtimeTask = Task {
            do {
                for try await community in communityService.subscribeToCommunityDiscovery() {
                    await MainActor.run {
                        upsertCommunity(community)
                    }
                }
                await MainActor.run {
                    if !Task.isCancelled {
                        startDiscoveryPolling()
                    }
                }
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        startDiscoveryPolling()
                    }
                }
            }
        }
    }

    private func stopDiscoveryRealtime() {
        discoveryRealtimeTask?.cancel()
        discoveryRealtimeTask = nil
        discoveryPollingTask?.cancel()
        discoveryPollingTask = nil
    }

    private func startDiscoveryPolling() {
        guard discoveryPollingTask == nil else { return }
        discoveryPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await loadCommunities(force: true)
            }
        }
    }

    private func upsertCommunity(_ community: Community) {
        guard community.deletedAt == nil else {
            communities.removeAll { $0.id == community.id }
            return
        }
        if let index = communities.firstIndex(where: { $0.id == community.id }) {
            communities[index] = community
        } else {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.isEmpty || community.name.localizedCaseInsensitiveContains(query) else { return }
            communities.insert(community, at: 0)
        }
        errorMessage = nil
    }

    private func createCommunity(name: String, description: String) async {
        if let existing = try? await communityService.community(named: name) {
            duplicateCommunity = existing
            return
        }

        let now = Date()
        let community = Community(
            id: UUID(),
            name: name,
            description: description,
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
        )
        do {
            let created = try await communityService.createCommunity(community)
            upsertCommunity(created)
            joinedCommunityIDs.insert(created.id)
            path.append(.detail(created.id))
            errorMessage = nil
        } catch {
            if let existing = try? await communityService.community(named: name) {
                duplicateCommunity = existing
            } else if case APIClientError.server(let statusCode, _) = error, statusCode == 409 {
                errorMessage = "Community already exists. Search for it to View or Join."
            } else {
                errorMessage = communityErrorMessage(error, fallback: "Failed to create community.")
            }
        }
    }

    private func joinExistingCommunity(_ community: Community) async {
        do {
            try await communityService.joinCommunity(id: community.id)
            joinedCommunityIDs.insert(community.id)
            path.append(.detail(community.id))
            errorMessage = nil
        } catch {
            errorMessage = communityErrorMessage(error, fallback: "Unable to join \(community.name).")
        }
    }

    private func communityErrorMessage(_ error: Error, fallback: String) -> String {
        switch OneWayNetworkError.classify(error) {
        case .offline where OneWayConnectivity.shared.state == .offline:
            return communities.isEmpty
                ? "Communities could not load while you’re offline."
                : "You’re offline. Showing saved communities."
        case .offline, .timeout, .serverUnavailable:
            return communities.isEmpty
                ? "Communities could not load. Retry when the backend is available."
                : "Communities could not refresh. Showing the latest saved results."
        case .unauthorized:
            return "Your session is unavailable. Please sign in again."
        case .cancelled:
            return ""
        default:
            break
        }
        if case APIClientError.server(let statusCode, let message) = error {
            if statusCode == 409 {
                return "Community already exists. Search for it to View or Join."
            }
            if statusCode == 403, message.lowercased().contains("membership") {
                return "Join this community to open the chat."
            }
            return message.isEmpty ? fallback : message
        }
        return fallback
    }
}

private struct CommunityRetryCard: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        OneWayCard {
            HStack(spacing: 12) {
                OneWayResolvedIcon(systemName: "wifi.exclamationmark")
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.warning)
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .oneWayReadableText(.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: onRetry) {
                    OneWayResolvedIcon(systemName: "arrow.clockwise")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(OneWayDesignSystem.Colors.purpleGradient, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry")
            }
        }
    }
}

private struct CommunityQuickActions: View {
    let onCreate: () -> Void
    let onDiscover: () -> Void

    private let actions: [(String, String)] = [
        ("Create", "plus.bubble.fill"),
        ("Discover", "sparkles"),
        ("Invites", "envelope.badge.fill"),
        ("Templates", "square.grid.2x2.fill")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline.weight(.black))
                .oneWayReadableText(.title)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    Button {
                        index == 0 ? onCreate() : onDiscover()
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            OneWayResolvedIcon(systemName: action.1)
                                .font(.title2.weight(.black))
                                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                                .frame(width: 46, height: 46)
                                .background(OneWayDesignSystem.Colors.lavender, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text(action.0)
                                .font(.headline.weight(.black))
                                .oneWayReadableText(.title)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(OneWayDesignSystem.Colors.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.07), radius: 18, x: 0, y: 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct CommunityDiscoverySection: View {
    let communities: [Community]
    let onOpen: (Community) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Explore Communities")
                    .font(.title3.weight(.black))
                    .oneWayReadableText(.title)
                Spacer()
                Text("Public")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(communities.prefix(8).enumerated()), id: \.element.id) { index, community in
                        Button {
                            onOpen(community)
                        } label: {
                            CommunityDiscoveryCard(
                                item: CommunityDiscoveryItem(
                                    title: community.name,
                                    members: "\(community.members.count)",
                                    privacy: community.visibility.displayName,
                                    icon: CommunitySample.cards[index % CommunitySample.cards.count].icon,
                                    colors: CommunitySample.cards[index % CommunitySample.cards.count].colors
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct CommunitySearchResultsSection: View {
    let title: String
    let communities: [Community]
    let currentHandle: String
    let joinedCommunityIDs: Set<UUID>
    let onOpen: (Community) -> Void
    let onJoin: (Community) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.title3.weight(.black))
                    .oneWayReadableText(.title)
                Spacer()
                Text("\(communities.count)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
            }

            if communities.isEmpty {
                OneWayCard {
                    Text("No public communities found.")
                        .font(.subheadline.weight(.semibold))
                        .oneWayReadableText(.subtitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(communities) { community in
                        CommunitySearchResultRow(
                            community: community,
                            isJoined: isJoined(community),
                            onOpen: { onOpen(community) },
                            onJoin: { onJoin(community) }
                        )
                    }
                }
            }
        }
    }

    private func isJoined(_ community: Community) -> Bool {
        if joinedCommunityIDs.contains(community.id) {
            return true
        }
        if community.creatorHandle.caseInsensitiveCompare(currentHandle) == .orderedSame {
            return true
        }
        guard let memberID = memberID(for: currentHandle) else { return false }
        return community.members.contains(memberID)
    }

    private func memberID(for handle: String) -> UUID? {
        switch handle.lowercased() {
        case "@king":
            return UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        case "@twinblixx":
            return UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        default:
            return nil
        }
    }
}

private struct CommunitySearchResultRow: View {
    let community: Community
    let isJoined: Bool
    let onOpen: () -> Void
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(OneWayDesignSystem.Colors.lavender)
                OneWayResolvedIcon(systemName: "person.3.fill")
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text(community.name)
                    .font(.headline.weight(.black))
                    .oneWayReadableText(.title)
                    .lineLimit(1)
                Text("\(community.creatorHandle) • \(community.members.count) members")
                    .font(.caption.weight(.semibold))
                    .oneWayReadableText(.subtitle)
                    .lineLimit(1)
                CommunityStatusBadge(text: community.visibility.displayName)
            }

            Spacer(minLength: 8)

            Button {
                isJoined ? onOpen() : onJoin()
            } label: {
                Text(isJoined ? "View" : "Join")
                    .font(.caption.weight(.black))
                    .foregroundStyle(isJoined ? OneWayDesignSystem.Colors.purple : .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        isJoined
                            ? AnyShapeStyle(OneWayDesignSystem.Colors.lavender)
                            : AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(OneWayDesignSystem.Colors.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
    }
}

private struct CommunityDiscoveryCard: View {
    let item: CommunityDiscoveryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: item.colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                OneWayResolvedIcon(systemName: item.icon)
                    .font(.system(size: 44, weight: .black))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                Text(item.privacy)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.24), in: Capsule())
                    .padding(10)
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.headline.weight(.black))
                    .oneWayReadableText(.title)
                Text("\(item.members) members")
                    .font(.caption.weight(.semibold))
                    .oneWayReadableText(.subtitle)
            }

            Button("Join") {}
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
        }
        .padding(12)
        .frame(width: 180)
        .background(OneWayDesignSystem.Colors.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.07), radius: 18, x: 0, y: 10)
    }
}

private struct CommunityCard: View {
    let community: Community
    let styleIndex: Int
    let onOpen: () -> Void

    private var sample: CommunityCardSample {
        CommunitySample.cards[styleIndex % CommunitySample.cards.count]
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 13) {
                CommunityPhoto(sample: sample)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(community.name.isEmpty ? sample.title : community.name)
                            .font(.headline.weight(.black))
                            .oneWayReadableText(.title)
                            .lineLimit(1)
                        if sample.verified {
                            OneWayResolvedIcon(systemName: "checkmark.seal.fill")
                                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                        }
                    }

                    HStack(spacing: 6) {
                        CommunityStatusBadge(text: community.visibility.displayName)
                        Text("\(community.members.count) members")
                            .font(.caption.weight(.semibold))
                            .oneWayReadableText(.subtitle)
                    }

                    Text("Created by \(community.creatorHandle.isEmpty ? "OneWay" : community.creatorHandle)")
                        .font(.caption.weight(.semibold))
                        .oneWayReadableText(.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(spacing: 10) {
                    if sample.unread > 0 {
                        Text("\(sample.unread)")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(OneWayDesignSystem.Colors.purple, in: Circle())
                    }
                    OneWayResolvedIcon(systemName: "chevron.right")
                        .font(.caption.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.faintText)
                }
            }
            .padding(14)
            .background(OneWayDesignSystem.Colors.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.07), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }
}

private struct CommunityEmptyState: View {
    let onCreate: () -> Void
    let onBrowse: () -> Void

    var body: some View {
        OneWayCard {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(OneWayDesignSystem.Colors.lavender)
                        .frame(width: 86, height: 86)
                    OneWayResolvedIcon(systemName: "person.3.sequence.fill")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(OneWayDesignSystem.Colors.purple)
                }
                Text("You're not part of any communities yet.")
                    .font(.title3.weight(.black))
                    .oneWayReadableText(.title)
                    .multilineTextAlignment(.center)
                Text("Create a private group or browse live communities built for families, schools, teams, and creators.")
                    .font(.subheadline.weight(.semibold))
                    .oneWayReadableText(.subtitle)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("Create Community", action: onCreate)
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(OneWayDesignSystem.Colors.purpleGradient, in: Capsule())
                    Button("Browse", action: onBrowse)
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.purple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
                }
            }
        }
    }
}

private struct CommunityAvatar: View {
    let seed: CommunityAvatarSeed

    var body: some View {
        ZStack {
            LinearGradient(colors: seed.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            OneWayResolvedIcon(systemName: seed.icon)
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
        }
        .frame(width: 42, height: 42)
        .clipShape(Circle())
        .overlay(Circle().stroke(OneWayDesignSystem.Colors.surface, lineWidth: 3))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 5)
    }
}

private struct CommunityPhoto: View {
    let sample: CommunityCardSample

    var body: some View {
        ZStack {
            LinearGradient(colors: sample.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            OneWayResolvedIcon(systemName: sample.icon)
                .font(.title2.weight(.black))
                .foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct CommunityStatusBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.black))
            .foregroundStyle(OneWayDesignSystem.Colors.purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
            .overlay(Capsule().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
    }
}

private struct CommunityDiscoveryItem: Identifiable {
    let id = UUID()
    let title: String
    let members: String
    let privacy: String
    let icon: String
    let colors: [Color]
}

private struct CommunityCardSample {
    let title: String
    let status: String
    let members: Int
    let activity: String
    let unread: Int
    let verified: Bool
    let icon: String
    let colors: [Color]
}

private struct CommunityAvatarSeed: Identifiable {
    let id = UUID()
    let icon: String
    let colors: [Color]
}

private enum CommunitySample {
    static let avatarSeeds: [CommunityAvatarSeed] = [
        .init(icon: "house.fill", colors: [Color(hex: 0x8B5CF6), Color(hex: 0x38BDF8)]),
        .init(icon: "graduationcap.fill", colors: [Color(hex: 0x22C55E), Color(hex: 0x60A5FA)]),
        .init(icon: "gamecontroller.fill", colors: [Color(hex: 0xF59E0B), Color(hex: 0xA855F7)]),
        .init(icon: "briefcase.fill", colors: [Color(hex: 0x7B3FF2), Color(hex: 0xEC4899)])
    ]

    static let discovery: [CommunityDiscoveryItem] = [
        .init(title: "Neighborhood", members: "842", privacy: "Private", icon: "house.fill", colors: [Color(hex: 0x7B3FF2), Color(hex: 0x38BDF8)]),
        .init(title: "School", members: "1.2K", privacy: "Members", icon: "graduationcap.fill", colors: [Color(hex: 0x22C55E), Color(hex: 0x7B3FF2)]),
        .init(title: "Gaming", members: "4.3K", privacy: "Public", icon: "gamecontroller.fill", colors: [Color(hex: 0xF59E0B), Color(hex: 0xA855F7)]),
        .init(title: "Business", members: "628", privacy: "Verified", icon: "briefcase.fill", colors: [Color(hex: 0x111827), Color(hex: 0x7B3FF2)]),
        .init(title: "Family", members: "312", privacy: "Invite", icon: "heart.fill", colors: [Color(hex: 0xEC4899), Color(hex: 0xF59E0B)]),
        .init(title: "Sports", members: "2.1K", privacy: "Live", icon: "sportscourt.fill", colors: [Color(hex: 0x0EA5E9), Color(hex: 0x22C55E)])
    ]

    static let cards: [CommunityCardSample] = [
        .init(title: "Tucson Families", status: "Private", members: 842, activity: "12 online • Family calendar active", unread: 3, verified: false, icon: "house.fill", colors: [Color(hex: 0x7B3FF2), Color(hex: 0x38BDF8)]),
        .init(title: "Gamers", status: "Public", members: 4300, activity: "312 online • Voice room live", unread: 8, verified: false, icon: "gamecontroller.fill", colors: [Color(hex: 0xF59E0B), Color(hex: 0xA855F7)]),
        .init(title: "Cargo King Team", status: "Members only", members: 28, activity: "Verified • 4 announcements today", unread: 1, verified: true, icon: "shippingbox.fill", colors: [Color(hex: 0x111827), Color(hex: 0x7B3FF2)])
    ]
}

private struct ExampleCommunitiesView: View {
    var body: some View {
        List {
            Section("Examples") {
                OneWayResolvedLabel("Campus Builders", systemImage: "person.3")
                OneWayResolvedLabel("Neighborhood Watch", systemImage: "shield")
                OneWayResolvedLabel("Weekend Sports", systemImage: "sportscourt")
            }
        }
        .navigationTitle("Example Communities")
        .scrollContentBackground(.hidden)
        .background(OneWayDesignSystem.Colors.background.ignoresSafeArea())
        .oneWayMenuBar()
    }
}

private struct NewCommunityView: View {
    var onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""

    var body: some View {
        Form {
            Section("Details") {
                TextField("Community name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Button("Create Community") {
                    onCreate(name, description)
                    dismiss()
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("New Community")
        .scrollContentBackground(.hidden)
        .background(OneWayDesignSystem.Colors.background.ignoresSafeArea())
        .oneWayMenuBar()
    }
}

private struct CommunityDetailView: View {
    let communityID: UUID
    let communityService: CommunityService
    let messagingService: MessagingService
    let cryptoService: CryptoService

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CommunityChatViewModel
    @State private var isAddingMembers = false
    @State private var isShowingSettings = false
    @StateObject private var voiceRecorder = VoicemailRecorder(maxDuration: 60)
    @State private var voiceDisappearing: MessageDisappearingOverride = .inherit

    init(
        communityID: UUID,
        communityService: CommunityService,
        messagingService: MessagingService,
        cryptoService: CryptoService
    ) {
        self.communityID = communityID
        self.communityService = communityService
        self.messagingService = messagingService
        self.cryptoService = cryptoService
        _viewModel = StateObject(
            wrappedValue: CommunityChatViewModel(
                communityID: communityID,
                communityService: communityService
            )
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                detailHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        membersStrip
                        if viewModel.canChat {
                            chatArea
                        } else {
                            publicPreview
                        }
                    }
                    .padding(.horizontal, OneWayDesignSystem.Spacing.page)
                    .padding(.top, 12)
                    .padding(.bottom, 180)
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }

            if viewModel.canChat {
                composer
                    .padding(.bottom, 96)
                    .zIndex(20)
            }
        }
        .background(OneWayDesignSystem.Colors.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await viewModel.load()
            viewModel.startRealtime()
        }
        .onDisappear {
            viewModel.stopRealtime()
        }
        .sheet(isPresented: $isShowingSettings) {
            CommunitySettingsView(viewModel: viewModel) {
                isShowingSettings = false
                dismiss()
            }
        }
        .navigationDestination(isPresented: $isAddingMembers) {
            AddCommunityMembersView(
                communityID: communityID,
                communityService: communityService,
                onDone: {
                    Task { await viewModel.load() }
                }
            )
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    OneWayResolvedIcon(systemName: "chevron.left")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.purple)
                        .frame(width: 42, height: 42)
                        .background(OneWayDesignSystem.Colors.surface, in: Circle())
                        .overlay(Circle().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.community?.name ?? "Community")
                        .font(.title2.weight(.black))
                        .oneWayReadableText(.title)
                        .lineLimit(1)
                    Text("\(viewModel.members.count) members")
                        .font(.caption.weight(.bold))
                        .oneWayReadableText(.subtitle)
                }

                Spacer()

                OneWayResolvedLabel("Members only", systemImage: "person.2.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(OneWayDesignSystem.Colors.lavender, in: Capsule())

                Button {
                    isShowingSettings = true
                } label: {
                    OneWayResolvedIcon(systemName: "gearshape.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.purple)
                        .frame(width: 42, height: 42)
                        .background(OneWayDesignSystem.Colors.surface, in: Circle())
                        .overlay(Circle().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if let status = viewModel.statusMessage {
                HStack(spacing: 10) {
                    Text(status)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(viewModel.statusColor)
                    Spacer(minLength: 8)
                    if viewModel.canRetryLoad {
                        Button {
                            Task { await viewModel.refresh() }
                        } label: {
                            OneWayResolvedLabel("Retry", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.black))
                                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, OneWayDesignSystem.Spacing.page)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(OneWayDesignSystem.Colors.background)
    }

    private var membersStrip: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Members")
                        .font(.headline.weight(.black))
                        .oneWayReadableText(.title)
                    Spacer()
                    Button {
                        isAddingMembers = true
                    } label: {
                        OneWayResolvedLabel("Add Member", systemImage: "person.badge.plus")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(OneWayDesignSystem.Colors.purpleGradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canManageMembers)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.members) { member in
                            VStack(spacing: 7) {
                                ZStack {
                                    Circle()
                                        .fill(OneWayDesignSystem.Colors.lavender)
                                    Text(initials(for: member.displayName))
                                        .font(.caption.weight(.black))
                                        .foregroundStyle(OneWayDesignSystem.Colors.purple)
                                }
                                .frame(width: 48, height: 48)
                                Text(member.displayName)
                                    .font(.caption2.weight(.bold))
                                    .oneWayReadableText(.subtitle)
                                    .lineLimit(1)
                                    .frame(width: 58)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var chatArea: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Community Chat")
                        .font(.headline.weight(.black))
                        .oneWayReadableText(.title)
                    Spacer()
                    HStack(spacing: 8) {
                        shortcutButton("dot.radiowaves.left.and.right") {
                            viewModel.setStatus("Chirp shortcut ready.")
                        }
                        shortcutButton("phone.fill") {
                            viewModel.setStatus("Voice call shortcut ready.")
                        }
                        shortcutButton("video.fill") {
                            viewModel.setStatus("Video shortcut ready.")
                        }
                    }
                }

                if viewModel.messages.isEmpty {
                    VStack(spacing: 8) {
                        OneWayResolvedIcon(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 34, weight: .black))
                            .foregroundStyle(OneWayDesignSystem.Colors.purple)
                        Text("Start the conversation")
                            .font(.headline.weight(.black))
                            .oneWayReadableText(.title)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 34)
                } else {
                    ScrollViewReader { proxy in
                        ZStack(alignment: .bottom) {
                            ScrollView {
                                LazyVStack(spacing: 10) {
                                    ForEach(viewModel.messages) { message in
                                        CommunityChatBubble(
                                            message: message,
                                            currentHandle: viewModel.currentHandle,
                                            onRetry: {
                                                Task { await viewModel.retryMessage(message) }
                                            }
                                        )
                                        .id(message.id)
                                    }

                                    Color.clear
                                        .frame(height: 1)
                                        .id("community-chat-bottom")
                                        .onAppear { viewModel.isNearBottom = true }
                                        .onDisappear { viewModel.isNearBottom = false }
                                }
                            }
                            .frame(maxHeight: 360)
                            .onChange(of: viewModel.messages.count) { _, _ in
                                if viewModel.shouldAutoScroll {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo("community-chat-bottom", anchor: .bottom)
                                    }
                                    viewModel.markMessagesSeen()
                                }
                            }

                            if viewModel.hasNewMessages {
                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo("community-chat-bottom", anchor: .bottom)
                                    }
                                    viewModel.markMessagesSeen()
                                } label: {
                                    OneWayResolvedLabel("New messages", systemImage: "arrow.down")
                                        .font(.caption.weight(.black))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(OneWayDesignSystem.Colors.purpleGradient, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, 8)
                            }
                        }
                    }
                }

                if !viewModel.typingDisplayText.isEmpty {
                    Text(viewModel.typingDisplayText)
                        .font(.caption.weight(.bold))
                        .oneWayReadableText(.subtitle)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private var publicPreview: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Public Community Preview")
                        .font(.headline.weight(.black))
                        .oneWayReadableText(.title)
                    Spacer()
                    CommunityStatusBadge(text: viewModel.community?.visibility.displayName ?? "Public")
                }

                Text(viewModel.community?.description.nilIfBlank ?? "Join this community to enter the shared chat.")
                    .font(.subheadline.weight(.semibold))
                    .oneWayReadableText(.subtitle)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await viewModel.joinCommunity() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isJoining {
                            ProgressView()
                                .tint(.white)
                        } else {
                            OneWayResolvedIcon(systemName: "person.badge.plus")
                        }
                        Text("Join Community")
                    }
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(OneWayDesignSystem.Colors.purpleGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isJoining)
            }
        }
    }

    private var composer: some View {
        CommunityChatComposer(
            text: $viewModel.composerText,
            isSending: viewModel.isSending,
            isRecordingVoice: isRecordingVoice,
            disappearingOverride: $voiceDisappearing,
            onPlus: {
                viewModel.setStatus("Attachment picker ready.")
            },
            onMic: {
                Task { await toggleVoiceRecording() }
            },
            onSend: {
                Task { await viewModel.sendMessage(text: viewModel.composerText) }
            },
            onTextChanged: { value in
                viewModel.composerDidChange(value)
            }
        )
    }

    private var isRecordingVoice: Bool {
        if case .recording = voiceRecorder.state { return true }
        return false
    }

    @MainActor
    private func toggleVoiceRecording() async {
        if isRecordingVoice {
            guard let url = voiceRecorder.stop(), let data = try? Data(contentsOf: url), !data.isEmpty else {
                viewModel.setStatus("Voice recording could not be saved.")
                return
            }
            try? FileManager.default.removeItem(at: url)
            await viewModel.sendVoiceMessage(data: data, disappearing: voiceDisappearing)
            voiceDisappearing = .inherit
            return
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { viewModel.setStatus("Enable microphone access to record a voice message."); return }
        do { try voiceRecorder.start(); viewModel.setStatus("Recording… Tap the microphone again to send.") }
        catch { viewModel.setStatus(error.localizedDescription) }
    }

    private func shortcutButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                .frame(width: 32, height: 32)
                .background(OneWayDesignSystem.Colors.lavender, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func initials(for name: String) -> String {
        let pieces = name.split(separator: " ")
        let first = pieces.first?.first.map(String.init) ?? "?"
        let second = pieces.dropFirst().first?.first.map(String.init) ?? ""
        return (first + second).uppercased()
    }
}

private struct CommunityChatComposer: View {
    @Binding var text: String
    let isSending: Bool
    let isRecordingVoice: Bool
    @Binding var disappearingOverride: MessageDisappearingOverride
    let onPlus: () -> Void
    let onMic: () -> Void
    let onSend: () -> Void
    let onTextChanged: (String) -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        VStack(spacing: 8) {
        HStack {
            Menu {
                Picker("Voice message privacy", selection: $disappearingOverride) {
                    Text("Use chat setting").tag(MessageDisappearingOverride.inherit)
                    Text("Keep voice message").tag(MessageDisappearingOverride.keep)
                    Text("Disappear after read").tag(MessageDisappearingOverride.afterRead)
                }
            } label: {
                OneWayResolvedLabel(disappearingOverride == .afterRead ? "Disappear after read" : "Chat privacy", systemImage: disappearingOverride == .afterRead ? "timer" : "shield")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
            }
            Spacer()
        }
        HStack(spacing: 10) {
            Button(action: onPlus) {
                OneWayResolvedIcon(systemName: "plus")
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                    .frame(width: 42, height: 42)
                    .background(OneWayDesignSystem.Colors.lavender, in: Circle())
            }
            .buttonStyle(.plain)

            TextField("Message community…", text: $text)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.sentences)
                .font(.body.weight(.semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(OneWayDesignSystem.Colors.surface, in: Capsule())
                .overlay(Capsule().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                .onChange(of: text) { _, newValue in
                    onTextChanged(newValue)
                }

            Button(action: onMic) {
                OneWayResolvedIcon(systemName: isRecordingVoice ? "stop.fill" : "mic.fill")
                    .font(.headline.weight(.black))
                    .foregroundStyle(isRecordingVoice ? .red : OneWayDesignSystem.Colors.purple)
                    .frame(width: 42, height: 42)
                    .background(OneWayDesignSystem.Colors.lavender, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecordingVoice ? "Stop and send voice message" : "Record voice message")

            Button(action: onSend) {
                ZStack {
                    Circle()
                        .fill(canSend ? AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient) : AnyShapeStyle(OneWayDesignSystem.Colors.faintText.opacity(0.35)))
                    if isSending {
                        ProgressView()
                            .tint(.white)
                    } else {
                        OneWayResolvedIcon(systemName: "paperplane.fill")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 46, height: 46)
                .shadow(color: canSend ? OneWayDesignSystem.Colors.purple.opacity(0.22) : .clear, radius: 10, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        }
        .padding(.horizontal, OneWayDesignSystem.Spacing.page)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            OneWayDesignSystem.Colors.background,
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OneWayDesignSystem.Colors.border)
                .frame(height: 1)
        }
    }
}

private struct CommunityChatBubble: View {
    let message: CommunityMessage
    let currentHandle: String
    let onRetry: () -> Void

    private var isMine: Bool {
        message.senderHandle.caseInsensitiveCompare(currentHandle) == .orderedSame
    }

    var body: some View {
        HStack {
            if isMine {
                Spacer(minLength: 48)
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
                Text(message.senderName)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.faintText)
                if message.body == "__ONEWAY_DISAPPEARED__" {
                    OneWayResolvedLabel("Voice message disappeared", systemImage: "timer")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                        .padding(.vertical, 8)
                } else if let voice = message.voiceAttachment {
                    VoiceMessagePlayer(data: voice.payload)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(isMine ? AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient) : AnyShapeStyle(OneWayDesignSystem.Colors.elevatedSurface), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Text(message.body)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isMine ? .white : OneWayDesignSystem.Colors.text)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(
                            isMine
                                ? AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient)
                                : AnyShapeStyle(OneWayDesignSystem.Colors.elevatedSurface),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }

                HStack(spacing: 6) {
                    switch message.deliveryStatus {
                    case .sending:
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Sending")
                    case .failed:
                        OneWayResolvedIcon(systemName: "exclamationmark.circle.fill")
                        Text("Failed")
                        Button("Retry", action: onRetry)
                            .font(.caption2.weight(.black))
                    default:
                        EmptyView()
                    }
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(message.deliveryStatus == .failed ? .red : OneWayDesignSystem.Colors.faintText)
            }

            if !isMine {
                Spacer(minLength: 48)
            }
        }
    }
}

private struct CommunitySettingsView: View {
    @ObservedObject var viewModel: CommunityChatViewModel
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedVisibility: CommunityVisibility = .public
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OneWayCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(viewModel.community?.name ?? "Community")
                                .font(.title2.weight(.black))
                                .oneWayReadableText(.title)
                            Text(viewModel.community?.description.nilIfBlank ?? "Community settings")
                                .font(.subheadline.weight(.semibold))
                                .oneWayReadableText(.subtitle)
                            OneWayResolvedLabel(viewModel.community?.visibility.displayName ?? "Public", systemImage: "eye.fill")
                                .font(.caption.weight(.black))
                                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                        }
                    }

                    if viewModel.isCreator {
                        OneWayCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Community Settings")
                                    .font(.headline.weight(.black))
                                    .oneWayReadableText(.title)

                                Picker("Visibility", selection: $selectedVisibility) {
                                    ForEach(CommunityVisibility.allCases, id: \.self) { visibility in
                                        Text(visibility.displayName).tag(visibility)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: selectedVisibility) { _, value in
                                    Task { await viewModel.updateVisibility(value) }
                                }

                                Button(role: .destructive) {
                                    showDeleteConfirmation = true
                                } label: {
                                    OneWayResolvedLabel("Delete Community", systemImage: "trash.fill")
                                        .font(.headline.weight(.black))
                                        .foregroundStyle(.red)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Color.red.opacity(0.10), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        OneWayCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Manage Members")
                                    .font(.headline.weight(.black))
                                    .oneWayReadableText(.title)

                                ForEach(viewModel.members.filter { $0.handle.caseInsensitiveCompare(viewModel.currentHandle) != .orderedSame }) { member in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(member.displayName)
                                                .font(.subheadline.weight(.black))
                                                .oneWayReadableText(.title)
                                            Text(member.handle)
                                                .font(.caption.weight(.semibold))
                                                .oneWayReadableText(.subtitle)
                                        }
                                        Spacer()
                                        Button {
                                            Task { await viewModel.removeMember(member) }
                                        } label: {
                                            Text("Remove")
                                                .font(.caption.weight(.black))
                                                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        Button {
                                            Task { await viewModel.blockMember(member) }
                                        } label: {
                                            Text("Block")
                                                .font(.caption.weight(.black))
                                                .foregroundStyle(.red)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(Color.red.opacity(0.10), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(12)
                                    .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                            }
                        }

                        OneWayCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Blocked / Banned Users")
                                    .font(.headline.weight(.black))
                                    .oneWayReadableText(.title)
                                Text((viewModel.community?.blockedUserIds.isEmpty ?? true) ? "No blocked users." : (viewModel.community?.blockedUserIds.joined(separator: ", ") ?? ""))
                                    .font(.subheadline.weight(.semibold))
                                    .oneWayReadableText(.subtitle)
                            }
                        }
                    } else if viewModel.isMember {
                        OneWayCard {
                            Button {
                                Task {
                                    await viewModel.leaveCommunity()
                                    dismiss()
                                }
                            } label: {
                                OneWayResolvedLabel("Leave Community", systemImage: "rectangle.portrait.and.arrow.right")
                                    .font(.headline.weight(.black))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.red.opacity(0.10), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, OneWayDesignSystem.Spacing.page)
                .padding(.vertical, 18)
            }
            .background(OneWayDesignSystem.Colors.background.ignoresSafeArea())
            .navigationTitle("Community Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Back") { dismiss() }
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.purple)
                }
            }
            .onAppear {
                selectedVisibility = viewModel.community?.visibility ?? .public
            }
            .confirmationDialog("Delete this community?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Community", role: .destructive) {
                    Task {
                        if await viewModel.deleteCommunity() {
                            dismiss()
                            onDeleted()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the community from every user's list and disables chat.")
            }
        }
    }
}

private struct AddCommunityMembersView: View {
    let communityID: UUID
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CommunityMembersViewModel
    let onDone: () -> Void

    init(
        communityID: UUID,
        communityService: CommunityService,
        onDone: @escaping () -> Void
    ) {
        self.communityID = communityID
        self.onDone = onDone
        _viewModel = StateObject(
            wrappedValue: CommunityMembersViewModel(
                communityID: communityID,
                communityService: communityService
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add Members")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .oneWayReadableText(.title)
                    Text("Invite people by @OneWayID, OW-number, phone, or email.")
                        .font(.subheadline.weight(.semibold))
                        .oneWayReadableText(.subtitle)
                }

                OneWayCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Find a OneWay user")
                            .font(.headline.weight(.black))
                            .oneWayReadableText(.title)

                        HStack(spacing: 10) {
                            TextField("@king, OW-654321, phone, or email", text: $viewModel.input)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                                .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))

                            Button {
                                Task { await viewModel.addMember(input: viewModel.input) }
                            } label: {
                                HStack(spacing: 7) {
                                    if viewModel.isSearching {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        OneWayResolvedIcon(systemName: "plus")
                                    }
                                    Text("Add")
                                }
                                .font(.headline.weight(.black))
                                .foregroundStyle(.white)
                                .frame(minWidth: 86, minHeight: 48)
                                .background(OneWayDesignSystem.Colors.purpleGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .shadow(color: OneWayDesignSystem.Colors.purple.opacity(0.22), radius: 12, x: 0, y: 7)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isSearching)
                        }

                        if let status = viewModel.statusMessage {
                            Text(status)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(viewModel.statusColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if viewModel.canRetry {
                            Button {
                                Task { await viewModel.retryAddMember() }
                            } label: {
                                OneWayResolvedLabel("Retry", systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.black))
                                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                            }
                            .buttonStyle(.plain)
                        }

                        if viewModel.showInviteByLink {
                            Button {
                                viewModel.showInviteLink()
                            } label: {
                                OneWayResolvedLabel("Invite by link", systemImage: "link")
                                    .font(.subheadline.weight(.black))
                                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                OneWayCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Selected members")
                                .font(.headline.weight(.black))
                                .oneWayReadableText(.title)
                            Spacer()
                            Text("\(viewModel.members.count)")
                                .font(.caption.weight(.black))
                                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
                        }

                        if viewModel.members.isEmpty {
                            Text("No members yet.")
                                .font(.subheadline.weight(.semibold))
                                .oneWayReadableText(.subtitle)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(viewModel.members) { member in
                                    memberRow(member)
                                }
                            }
                        }
                    }
                }

                if viewModel.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(OneWayDesignSystem.Colors.purple)
                        Text("Loading members...")
                            .font(.subheadline.weight(.semibold))
                            .oneWayReadableText(.subtitle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, OneWayDesignSystem.Spacing.page)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .background(OneWayDesignSystem.Colors.background.ignoresSafeArea())
        .navigationTitle("Add Members")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Back") {
                    onDone()
                    dismiss()
                }
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
            }
        }
        .task { await viewModel.load() }
    }

    private func memberRow(_ member: CommunityMember) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(OneWayDesignSystem.Colors.lavender)
                Text(initials(for: member.displayName))
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(member.displayName)
                    .font(.subheadline.weight(.black))
                    .oneWayReadableText(.title)
                Text(member.handle)
                    .font(.caption.weight(.semibold))
                    .oneWayReadableText(.subtitle)
            }

            Spacer()

            Text(member.role.rawValue.capitalized)
                .font(.caption2.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(OneWayDesignSystem.Colors.lavender, in: Capsule())
        }
        .padding(12)
        .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
    }

    private func initials(for name: String) -> String {
        let pieces = name.split(separator: " ")
        let first = pieces.first?.first.map(String.init) ?? "?"
        let second = pieces.dropFirst().first?.first.map(String.init) ?? ""
        return (first + second).uppercased()
    }
}

@MainActor
private final class CommunityChatViewModel: ObservableObject {
    @Published var community: Community?
    @Published var members: [CommunityMember] = []
    @Published var messages: [CommunityMessage] = []
    @Published var composerText = ""
    @Published var isLoading = false
    @Published var isSending = false
    @Published var isJoining = false
    @Published var isUpdatingSettings = false
    @Published var statusMessage: String?
    @Published var statusColor: Color = OneWayDesignSystem.Colors.purple
    @Published var canRetryLoad = false
    @Published var isNearBottom = true
    @Published var hasNewMessages = false
    @Published var typingHandles: Set<String> = []
    @Published var isJoinedByMembershipCache = false

    private let communityID: UUID
    private let communityService: CommunityService
    private var realtimeTask: Task<Void, Never>?
    private var realtimeStateTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private var typingStopTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var realtimeState: CommunityRealtimeConnectionState = .disconnected
    private var didSendTypingStarted = false
    private var didLogFirstMessageRender = false
    private var hasLoadedFreshState = false
    private var lastFullRefreshAt: Date?
    private var lastMembersRefreshAt: Date?

    init(communityID: UUID, communityService: CommunityService) {
        self.communityID = communityID
        self.communityService = communityService
    }

    var currentHandle: String {
        Self.currentHandle()
    }

    var currentUserID: String {
        Self.devUserID(for: currentHandle)
    }

    var isCreator: Bool {
        community?.creatorUserId == currentUserID || community?.creatorHandle.caseInsensitiveCompare(currentHandle) == .orderedSame
    }

    var isMember: Bool {
        if isJoinedByMembershipCache { return true }
        return members.contains { $0.handle.caseInsensitiveCompare(currentHandle) == .orderedSame }
    }

    var canChat: Bool {
        guard let community, community.deletedAt == nil else { return false }
        return isCreator || isMember
    }

    var canManageMembers: Bool {
        isCreator
    }

    var shouldAutoScroll: Bool {
        isNearBottom || !hasNewMessages
    }

    var typingDisplayText: String {
        let visible = typingHandles
            .filter { $0.caseInsensitiveCompare(currentHandle) != .orderedSame }
            .sorted()
        guard !visible.isEmpty else { return "" }
        if visible.count == 1 {
            return "\(visible[0]) is typing..."
        }
        return "\(visible.prefix(2).joined(separator: ", ")) are typing..."
    }

    func load() async {
        guard !isLoading else { return }
        CommunityPerformanceLogger.profile("client.communityScreen.open", clientMessageId: nil, communityId: communityID)
        loadCachedMessages()
        await hydrateCachedCommunityAndMembership()
        if hasLoadedFreshState, !shouldRunFullRefresh(minimumAge: 10) {
            if canChat { startRealtime() }
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            async let memberships = communityService.fetchMyMembershipIDs()
            async let allCommunities = communityService.listCommunities()
            async let fetchedMembers = communityService.members(of: communityID)
            async let fetchedMessages = fetchDeltaMessages()
            community = try await allCommunities.first(where: { $0.id == communityID }) ?? community
            members = try await fetchedMembers
            isJoinedByMembershipCache = try await memberships.contains(communityID)
            do {
                mergeMessages(try await fetchedMessages, markNew: false)
            } catch APIClientError.server(let statusCode, let message) where statusCode == 403 && message.lowercased().contains("membership") {
                messages = []
                isJoinedByMembershipCache = false
            }
            hasLoadedFreshState = true
            lastFullRefreshAt = Date()
            canRetryLoad = false
            statusMessage = nil
            if canChat {
                startRealtime()
            }
            CommunityPerformanceLogger.profile("client.communityScreen.renderComplete", clientMessageId: nil, communityId: communityID)
        } catch {
            statusColor = .red
            canRetryLoad = isNetworkError(error)
            statusMessage = communityErrorMessage(error, fallback: "Could not load community.")
        }
    }

    func sendMessage(text rawText: String) async {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        defer { isSending = false }

        let tapStartedAt = Date()
        let optimistic = makeLocalMessage(body: trimmed, status: .sending)
        appendOrReplace(optimistic, markNew: false)
        CommunityPerformanceLogger.profile(
            "client.localBubble.appended",
            clientMessageId: optimistic.clientMessageId,
            communityId: communityID,
            startedAt: tapStartedAt
        )
        Task { @MainActor in
            await Task.yield()
            CommunityPerformanceLogger.profile(
                "client.localBubble.nextRunLoop",
                clientMessageId: optimistic.clientMessageId,
                communityId: communityID,
                startedAt: tapStartedAt
            )
        }
        composerText = ""

        do {
            CommunityPerformanceLogger.profile(
                "client.send.callStarted",
                clientMessageId: optimistic.clientMessageId,
                communityId: communityID,
                startedAt: tapStartedAt
            )
            let sent = try await communityService.sendMessage(trimmed, in: communityID, clientMessageId: optimistic.clientMessageId ?? optimistic.id)
            replaceOptimisticMessage(localID: optimistic.id, with: sent)
            CommunityPerformanceLogger.profile(
                "client.send.confirmedInViewModel",
                clientMessageId: optimistic.clientMessageId,
                communityId: communityID,
                startedAt: tapStartedAt
            )
            sendTypingStopped()
            statusMessage = nil
        } catch {
            replaceMessage(id: optimistic.id, status: .failed)
            scheduleRetry(for: optimistic)
            statusColor = .red
            if case APIClientError.server(let statusCode, let message) = error,
               statusCode == 403,
                message.lowercased().contains("membership") {
                statusMessage = "Join this community to send messages."
                await loadFresh(force: true)
            } else {
                statusMessage = communityErrorMessage(error, fallback: "Message failed. Try again.")
            }
        }
    }

    func sendVoiceMessage(data: Data, disappearing: MessageDisappearingOverride) async {
        guard !data.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            let sent = try await communityService.sendVoiceMessage(
                data,
                in: communityID,
                clientMessageId: UUID(),
                disappearing: disappearing
            )
            appendOrReplace(sent, markNew: false)
            statusMessage = disappearing == .afterRead ? "Voice message sent. It will disappear after it is read." : nil
        } catch {
            statusColor = .red
            statusMessage = communityErrorMessage(error, fallback: "Voice message failed. Tap the microphone to try again.")
        }
    }

    func retryMessage(_ message: CommunityMessage) async {
        guard message.deliveryStatus == .failed else { return }
        retryTasks[message.id]?.cancel()
        retryTasks.removeValue(forKey: message.id)
        await retryFailedMessage(message)
    }

    func startRealtime() {
        guard canChat, realtimeTask == nil else { return }
        stopPolling()
        startRealtimeStateMonitor()
        startTyping()
        realtimeTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in self.communityService.subscribeToCommunityMessages(communityId: self.communityID) {
                    await MainActor.run {
                        self.appendOrReplace(message, markNew: true)
                    }
                    await self.refreshMembersQuietly()
                }
                await MainActor.run {
                    self.realtimeTask = nil
                    self.startPolling()
                }
            } catch {
                await MainActor.run {
                    self.realtimeTask = nil
                    self.startPolling()
                    self.statusColor = OneWayDesignSystem.Colors.purple
                    self.statusMessage = "Realtime reconnecting. Using live refresh."
                }
            }
        }
    }

    func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
        realtimeStateTask?.cancel()
        realtimeStateTask = nil
        typingTask?.cancel()
        typingTask = nil
        typingStopTask?.cancel()
        typingStopTask = nil
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        sendTypingStopped()
        stopPolling()
    }

    func composerDidChange(_ value: String) {
        guard canChat else { return }
        let hasText = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText && !didSendTypingStarted {
            didSendTypingStarted = true
            communityService.sendCommunityTyping(communityId: communityID, isTyping: true)
        } else if !hasText {
            sendTypingStopped()
            return
        }

        typingStopTask?.cancel()
        typingStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                self?.sendTypingStopped()
            }
        }
    }

    func markMessagesSeen() {
        hasNewMessages = false
        isNearBottom = true
    }

    func joinCommunity() async {
        guard !isJoining else { return }
        isJoining = true
        let previousMembers = members
        let previousCommunity = community
        optimisticallyJoinCurrentUser()
        setStatus("Joined community.")
        defer { isJoining = false }

        do {
            try await communityService.joinCommunity(id: communityID)
            isJoinedByMembershipCache = true
            await loadFresh(force: true)
            startRealtime()
            setStatus("Joined community.")
        } catch {
            members = previousMembers
            community = previousCommunity
            statusColor = .red
            statusMessage = communityErrorMessage(error, fallback: "Unable to join this community.")
        }
    }

    func leaveCommunity() async {
        do {
            try await communityService.leaveCommunity(id: communityID)
            isJoinedByMembershipCache = false
            stopRealtime()
            await loadFresh(force: true)
            setStatus("You left this community.")
        } catch {
            statusColor = .red
            statusMessage = "Unable to leave this community."
        }
    }

    func updateVisibility(_ visibility: CommunityVisibility) async {
        isUpdatingSettings = true
        defer { isUpdatingSettings = false }

        do {
            try await communityService.updateCommunityVisibility(id: communityID, visibility: visibility)
            await loadFresh(force: true)
            setStatus("Community visibility updated.")
        } catch {
            statusColor = .red
            statusMessage = "Only the creator can change visibility."
        }
    }

    func deleteCommunity() async -> Bool {
        isUpdatingSettings = true
        defer { isUpdatingSettings = false }

        do {
            try await communityService.deleteCommunity(id: communityID)
            return true
        } catch {
            statusColor = .red
            statusMessage = "Only the creator can delete this community."
            return false
        }
    }

    func blockMember(_ member: CommunityMember) async {
        do {
            try await communityService.blockUser(communityID: communityID, userID: member.handle)
            await loadFresh(force: true)
            setStatus("\(member.handle) blocked from community.")
        } catch {
            statusColor = .red
            statusMessage = "Unable to block this member."
        }
    }

    func removeMember(_ member: CommunityMember) async {
        do {
            try await communityService.removeMember(communityID: communityID, memberID: member.id)
            await loadFresh(force: true)
            setStatus("\(member.handle) removed from community.")
        } catch {
            statusColor = .red
            statusMessage = "Unable to remove this member."
        }
    }

    func setStatus(_ message: String) {
        statusColor = OneWayDesignSystem.Colors.purple
        statusMessage = message
    }

    func refresh() async {
        await loadFresh(force: true)
    }

    private func loadFresh(force: Bool = false) async {
        guard force || shouldRunFullRefresh(minimumAge: 5) else { return }
        do {
            async let memberships = communityService.fetchMyMembershipIDs()
            async let allCommunities = communityService.listCommunities()
            async let fetchedMembers = communityService.members(of: communityID)
            async let fetchedMessages = fetchDeltaMessages()
            community = try await allCommunities.first(where: { $0.id == communityID }) ?? community
            members = try await fetchedMembers
            isJoinedByMembershipCache = try await memberships.contains(communityID)
            mergeMessages(try await fetchedMessages, markNew: false)
            hasLoadedFreshState = true
            lastFullRefreshAt = Date()
        } catch {
            statusColor = .red
            canRetryLoad = isNetworkError(error)
            statusMessage = communityErrorMessage(error, fallback: "Could not refresh community.")
        }
    }

    private func refreshMembersQuietly() async {
        guard shouldRefreshMembersQuietly(minimumAge: 12) else { return }
        do {
            members = try await communityService.members(of: communityID)
            lastMembersRefreshAt = Date()
        } catch {
            // Realtime should never make the chat noisier. Pull-to-refresh still surfaces hard failures.
        }
    }

    private func startPolling() {
        guard canChat, realtimeState != .connected, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.pollMessages()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollMessages() async {
        do {
            mergeMessages(try await fetchDeltaMessages(), markNew: true)
        } catch {
            // Keep polling quietly; the header already shows manual retry for full-load failures.
        }
    }

    private func fetchDeltaMessages() async throws -> [CommunityMessage] {
        let latestSentAt = messages
            .filter { $0.deliveryStatus != .sending && $0.deliveryStatus != .failed }
            .map(\.sentAt)
            .max()
            .map { $0.addingTimeInterval(-2) }
        if let latestSentAt {
            return try await communityService.fetchMessages(communityId: communityID, since: latestSentAt)
        }
        return try await communityService.fetchMessages(communityId: communityID)
    }

    private func shouldRunFullRefresh(minimumAge: TimeInterval) -> Bool {
        guard let lastFullRefreshAt else { return true }
        return Date().timeIntervalSince(lastFullRefreshAt) >= minimumAge
    }

    private func shouldRefreshMembersQuietly(minimumAge: TimeInterval) -> Bool {
        guard let lastMembersRefreshAt else { return true }
        return Date().timeIntervalSince(lastMembersRefreshAt) >= minimumAge
    }

    private func startRealtimeStateMonitor() {
        guard realtimeStateTask == nil else { return }
        realtimeStateTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.communityService.subscribeToCommunityRealtimeState() {
                await MainActor.run {
                    self.realtimeState = state
                    switch state {
                    case .connected:
                        self.stopPolling()
                        if self.statusMessage == "Realtime reconnecting. Using live refresh." {
                            self.statusMessage = nil
                        }
                    case .connecting:
                        break
                    case .disconnected:
                        self.startPolling()
                        self.statusColor = OneWayDesignSystem.Colors.purple
                        self.statusMessage = "Realtime reconnecting. Using live refresh."
                    }
                }
            }
        }
    }

    private func startTyping() {
        guard typingTask == nil else { return }
        typingTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.communityService.subscribeToCommunityTyping(communityId: self.communityID) {
                await MainActor.run {
                    guard event.handle.caseInsensitiveCompare(self.currentHandle) != .orderedSame else { return }
                    if event.isTyping {
                        self.typingHandles.insert(event.handle)
                    } else {
                        self.typingHandles.remove(event.handle)
                    }
                }
            }
        }
    }

    private func sendTypingStopped() {
        typingStopTask?.cancel()
        typingStopTask = nil
        guard didSendTypingStarted else { return }
        didSendTypingStarted = false
        communityService.sendCommunityTyping(communityId: communityID, isTyping: false)
    }

    private func mergeMessages(_ incoming: [CommunityMessage], markNew: Bool) {
        for message in incoming.sorted(by: { $0.sentAt < $1.sentAt }) {
            appendOrReplace(message, markNew: markNew)
        }
    }

    private func appendOrReplace(_ message: CommunityMessage, markNew: Bool) {
        let insertStartedAt = Date()
        if !didLogFirstMessageRender {
            didLogFirstMessageRender = true
            CommunityPerformanceLogger.profile(
                "client.firstMessage.render",
                clientMessageId: message.clientMessageId,
                communityId: message.communityID
            )
        }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else if let clientMessageId = message.clientMessageId,
                  let pendingIndex = messages.firstIndex(where: { $0.clientMessageId == clientMessageId || $0.id == clientMessageId }) {
            messages[pendingIndex] = message
        } else if let pendingIndex = messages.firstIndex(where: {
            $0.deliveryStatus == .sending
            && $0.senderHandle.caseInsensitiveCompare(message.senderHandle) == .orderedSame
            && $0.body == message.body
        }) {
            messages[pendingIndex] = message
        } else {
            messages.append(message)
        }

        messages.sort { $0.sentAt < $1.sentAt }
        if markNew && !isNearBottom && message.senderHandle.caseInsensitiveCompare(currentHandle) != .orderedSame {
            hasNewMessages = true
        }
        if message.senderHandle.caseInsensitiveCompare(currentHandle) != .orderedSame {
            communityService.markCommunityMessageRead(communityId: communityID, messageId: message.id)
        }
        persistCachedMessages()
        CommunityPerformanceLogger.profile(
            "client.ui.messageArrayInserted",
            clientMessageId: message.clientMessageId,
            communityId: message.communityID,
            startedAt: insertStartedAt,
            metadata: "markNew=\(markNew) isMine=\(message.senderHandle.caseInsensitiveCompare(currentHandle) == .orderedSame)"
        )
        Task { @MainActor in
            await Task.yield()
            CommunityPerformanceLogger.profile(
                "client.ui.insert.nextRunLoop",
                clientMessageId: message.clientMessageId,
                communityId: message.communityID,
                startedAt: insertStartedAt
            )
        }
    }

    private func replaceOptimisticMessage(localID: UUID, with sent: CommunityMessage) {
        if let index = messages.firstIndex(where: { $0.id == localID }) {
            messages[index] = sent
            messages.sort { $0.sentAt < $1.sentAt }
            persistCachedMessages()
        } else {
            appendOrReplace(sent, markNew: false)
        }
    }

    private func replaceMessage(id: UUID, status: MessageDeliveryStatus) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let message = messages[index]
        messages[index] = CommunityMessage(
            id: message.id,
            clientMessageId: message.clientMessageId,
            communityID: message.communityID,
            senderID: message.senderID,
            senderName: message.senderName,
            senderHandle: message.senderHandle,
            body: message.body,
            sentAt: message.sentAt,
            deliveryStatus: status
        )
        persistCachedMessages()
    }

    private func scheduleRetry(for message: CommunityMessage, attempt: Int = 1) {
        guard attempt <= 3, retryTasks[message.id] == nil else { return }
        retryTasks[message.id] = Task { [weak self] in
            let seconds = min(8, 1 << attempt)
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                _ = self.retryTasks.removeValue(forKey: message.id)
            }
            await self.retryFailedMessage(message, attempt: attempt)
        }
    }

    private func retryFailedMessage(_ message: CommunityMessage, attempt: Int = 1) async {
        guard canChat else { return }
        replaceMessage(id: message.id, status: .sending)
        do {
            let sent = try await communityService.sendMessage(
                message.body,
                in: communityID,
                clientMessageId: message.clientMessageId ?? message.id
            )
            replaceOptimisticMessage(localID: message.id, with: sent)
            statusMessage = nil
        } catch {
            replaceMessage(id: message.id, status: .failed)
            scheduleRetry(for: message, attempt: attempt + 1)
        }
    }

    private func loadCachedMessages() {
        guard messages.isEmpty,
              let data = UserDefaults.standard.data(forKey: messageCacheKey),
              let cached = try? JSONDecoder().decode([CommunityMessage].self, from: data),
              !cached.isEmpty else {
            return
        }
        messages = cached.sorted { $0.sentAt < $1.sentAt }
    }

    private func hydrateCachedCommunityAndMembership() async {
        let cachedMemberships = await communityService.cachedJoinedCommunityIDs()
        isJoinedByMembershipCache = cachedMemberships.contains(communityID)
        if community == nil {
            community = await communityService.cachedCommunities().first(where: { $0.id == communityID })
        }
    }

    private func persistCachedMessages() {
        let cacheable = messages
            .filter { $0.deliveryStatus != .failed }
            .suffix(200)
        guard let data = try? JSONEncoder().encode(Array(cacheable)) else { return }
        UserDefaults.standard.set(data, forKey: messageCacheKey)
    }

    private var messageCacheKey: String {
        "oneway.community.messages.cache.\(communityID.uuidString.lowercased())"
    }

    private func makeLocalMessage(body: String, status: MessageDeliveryStatus) -> CommunityMessage {
        CommunityMessage(
            id: UUID(),
            clientMessageId: UUID(),
            communityID: communityID,
            senderID: UUID(uuidString: currentUserID) ?? UUID(),
            senderName: currentHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@")).capitalized,
            senderHandle: currentHandle,
            body: body,
            sentAt: Date(),
            deliveryStatus: status
        )
    }

    private func communityErrorMessage(_ error: Error, fallback: String) -> String {
        if isNetworkError(error) {
            return "Network offline. Check your connection and retry."
        }
        if case APIClientError.server(let statusCode, let message) = error {
            if statusCode == 403, message.lowercased().contains("membership") {
                return "Join this community to open the chat."
            }
            return message.isEmpty ? fallback : message
        }
        return fallback
    }

    private func isNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func currentHandle() -> String {
        let candidates = [
            UserDefaults.standard.string(forKey: "OneWay.LastLoginIdentifier"),
            UserDefaults.standard.string(forKey: "OneWay.DebugLoginIdentifier"),
            UserDefaults.standard.string(forKey: "OneWay.DebugLoginIdentifierOverride"),
            ProcessInfo.processInfo.environment["ONEWAY_DEBUG_LOGIN_IDENTIFIER"]
        ]
        let raw = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return normalizedHandle(raw ?? "king")
    }

    private static func normalizedHandle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        return "@\(trimmed)"
    }

    private static func devUserID(for value: String) -> String {
        let normalized = normalizedHandle(value)
        switch normalized {
        case "@king":
            return "dev-user-king"
        case "@twinblixx":
            return "dev-user-twinblixx"
        default:
            return "dev-user-\(normalized.dropFirst())"
        }
    }

    private func optimisticallyJoinCurrentUser() {
        let memberID = UUID(uuidString: currentUserID) ?? UUID()
        if !members.contains(where: { $0.handle.caseInsensitiveCompare(currentHandle) == .orderedSame }) {
            members.append(CommunityMember(
                id: memberID,
                displayName: currentHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@")).capitalized,
                handle: currentHandle,
                role: isCreator ? .owner : .member,
                isMuted: false
            ))
        }
        if var community, !community.members.contains(memberID) {
            community.members.append(memberID)
            community.updatedAt = Date()
            self.community = community
        }
    }
}

@MainActor
private final class CommunityMembersViewModel: ObservableObject {
    enum StatusKind {
        case success
        case error
        case info
    }

    @Published var input = ""
    @Published var members: [CommunityMember] = []
    @Published var isLoading = false
    @Published var isSearching = false
    @Published var statusMessage: String?
    @Published var statusKind: StatusKind = .info
    @Published var showInviteByLink = false
    @Published var canRetry = false

    var statusColor: Color {
        switch statusKind {
        case .success:
            return Color.green
        case .error:
            return Color.red
        case .info:
            return OneWayDesignSystem.Colors.purple
        }
    }

    private let communityID: UUID
    private let communityService: CommunityService
    private let userSearch: OneWayNumberService
    private var lastFailedInput: String?

    init(
        communityID: UUID,
        communityService: CommunityService,
        userSearch: OneWayNumberService = .shared
    ) {
        self.communityID = communityID
        self.communityService = communityService
        self.userSearch = userSearch
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            members = try await communityService.members(of: communityID)
        } catch {
            setStatus("Could not load community members.", kind: .error)
        }
    }

    func addMember(input rawInput: String) async {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setStatus("Enter a @OneWayID, OW-number, phone, or email.", kind: .error)
            showInviteByLink = false
            canRetry = false
            return
        }

        let normalized = Self.normalizedLookup(trimmed)
        let displayHandle = Self.displayHandle(for: normalized)
        if members.contains(where: { Self.member($0, matches: normalized) }) {
            setStatus("\(displayHandle) is already a member.", kind: .info)
            showInviteByLink = false
            canRetry = false
            return
        }

        isSearching = true
        showInviteByLink = false
        canRetry = false
        defer { isSearching = false }

        do {
            guard let candidate = try await findUser(for: normalized) else {
                setStatus("No OneWay user found for \(displayHandle).", kind: .error)
                showInviteByLink = true
                lastFailedInput = trimmed
                return
            }

            if members.contains(where: { Self.member($0, matches: candidate.handle) }) {
                setStatus("\(candidate.handle) is already a member.", kind: .info)
                return
            }

            _ = try await communityService.addMember(communityID: communityID, handle: candidate.handle, role: .member)
            members = try await communityService.members(of: communityID)
            input = ""
            setStatus("\(candidate.handle) added to community.", kind: .success)
            lastFailedInput = nil
        } catch {
            setStatus("Network failed while adding \(displayHandle).", kind: .error)
            canRetry = true
            lastFailedInput = trimmed
        }
    }

    func retryAddMember() async {
        guard let lastFailedInput else { return }
        await addMember(input: lastFailedInput)
    }

    func showInviteLink() {
        setStatus("Invite link ready to share when community links are enabled.", kind: .info)
        showInviteByLink = false
    }

    private func findUser(for lookup: String) async throws -> MemberCandidate? {
        if let fallback = Self.devFallbackCandidate(for: lookup) {
            return fallback
        }

        let results = try await userSearch.searchUsers(query: lookup)
        guard let user = results.first else {
            return nil
        }

        let handle = Self.normalizedHandle(
            user.onewayId?.nilIfBlank
                ?? user.username?.nilIfBlank
                ?? user.emailAlias?.nilIfBlank
                ?? lookup
        )
        let displayName = user.displayName?.nilIfBlank
            ?? handle.dropFirst().capitalized

        return MemberCandidate(
            displayName: displayName,
            handle: handle,
            lookup: lookup
        )
    }

    private func setStatus(_ message: String, kind: StatusKind) {
        statusMessage = message
        statusKind = kind
    }

    private struct MemberCandidate {
        let displayName: String
        let handle: String
        let lookup: String
    }

    private static func devFallbackCandidate(for lookup: String) -> MemberCandidate? {
        let lower = lookup.lowercased()
        guard lower == "@king" || lower == "ow-654321" else {
            return nil
        }

        return MemberCandidate(displayName: "King", handle: "@king", lookup: lookup)
    }

    private static func normalizedLookup(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("ow-") {
            return trimmed.uppercased()
        }
        if trimmed.contains("@") && !trimmed.hasPrefix("@") {
            return trimmed.lowercased()
        }
        if trimmed.hasPrefix("@") {
            return normalizedHandle(trimmed)
        }
        if trimmed.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "-" || $0 == "(" || $0 == ")" || $0 == " " }) {
            return trimmed
        }
        return normalizedHandle(trimmed)
    }

    private static func normalizedHandle(_ value: String) -> String {
        let handle = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        return "@\(handle)"
    }

    private static func displayHandle(for lookup: String) -> String {
        lookup.hasPrefix("@") ? lookup : lookup
    }

    private static func member(_ member: CommunityMember, matches lookup: String) -> Bool {
        let memberHandle = normalizedHandle(member.handle)
        if lookup.hasPrefix("@") {
            return memberHandle == normalizedHandle(lookup)
        }
        return member.handle.caseInsensitiveCompare(lookup) == .orderedSame
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct GroupDetailView: View {
    let group: GroupChat
    let members: [CommunityMember]

    var body: some View {
        List {
            Section("Info") {
                Text(group.topic ?? "No topic")
                Text("Members: \(group.memberIDs.count)")
            }

            Section("Members") {
                ForEach(members.filter { group.memberIDs.contains($0.id) }) { member in
                    Text(member.displayName)
                }
            }
        }
        .navigationTitle(group.name)
        .scrollContentBackground(.hidden)
        .background(OneWayDesignSystem.Colors.background.ignoresSafeArea())
        .oneWayMenuBar()
    }
}
