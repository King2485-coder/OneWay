import SwiftUI
import Combine
import UniformTypeIdentifiers

struct OneWayQuickActionsView: View {
    let onSelect: (OneWayQuickAction) -> Void
    var onSelectFeature: ((OneWayFeature) -> Void)? = nil
    let onDeleteAccount: () async throws -> Void
    let onClose: () -> Void

    var body: some View {
        OneWayCompactHubView(
            onSelectAction: onSelect,
            onSelectFeature: onSelectFeature,
            onDeleteAccount: onDeleteAccount,
            onClose: onClose
        )
    }
}

enum OneWayHubCategory: String, CaseIterable, Identifiable, Codable {
    case create = "Create"
    case manage = "Manage"
    case promote = "Promote"
    case account = "Account"

    var id: String { rawValue }
}

enum OneWayHubRoute: Hashable, Codable {
    case feature(OneWayFeature)
    case action(OneWayQuickAction)

    var id: String {
        switch self {
        case .feature(let feature): return "feature.\(feature.rawValue)"
        case .action(let action): return "action.\(action.rawValue)"
        }
    }
}

struct OneWayHubDestination: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let category: OneWayHubCategory
    let iconRole: OneWayIconRole
    let route: OneWayHubRoute
    let keywords: [String]
    let badgeCount: Int?

    init(
        title: String,
        subtitle: String,
        category: OneWayHubCategory,
        iconRole: OneWayIconRole,
        route: OneWayHubRoute,
        keywords: [String] = [],
        badgeCount: Int? = nil
    ) {
        self.id = route.id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.iconRole = iconRole
        self.route = route
        self.keywords = keywords
        self.badgeCount = badgeCount
    }

    func matches(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return ([title, subtitle, category.rawValue] + keywords)
            .contains { $0.lowercased().contains(normalized) }
    }
}

enum OneWayHubDestinationRegistry {
    static func destinations() -> [OneWayHubDestination] {
        [
            .init(
                title: "Personal Messages",
                subtitle: "Private social conversations.",
                category: .create,
                iconRole: .messages,
                route: .feature(.messages),
                keywords: ["chat", "texts", "dm", "personal"]
            ),
            .init(
                title: "Calls",
                subtitle: "OneWay voice calling.",
                category: .create,
                iconRole: .calls,
                route: .feature(.calls),
                keywords: ["phone", "audio"]
            ),
            .init(
                title: "Video",
                subtitle: "Secure video calling.",
                category: .create,
                iconRole: .videoCall,
                route: .feature(.video),
                keywords: ["facetime", "livekit"]
            ),
            .init(
                title: "Chirp",
                subtitle: "Push-to-talk walkie mode.",
                category: .create,
                iconRole: .chirp,
                route: .feature(.chirp),
                keywords: ["walkie", "radio", "push to talk"]
            ),
            .init(
                title: "Contacts",
                subtitle: "People you can call, Chirp, or message.",
                category: .manage,
                iconRole: .contacts,
                route: .feature(.contacts),
                keywords: ["friends", "people"]
            ),
            .init(
                title: "Voicemail",
                subtitle: "Private voice messages.",
                category: .manage,
                iconRole: .voicemail,
                route: .feature(.voicemail),
                keywords: ["voice mail"]
            ),
            .init(
                title: "OneWay Email",
                subtitle: "Private inbox, drafts, and attachments.",
                category: .manage,
                iconRole: .email,
                route: .feature(.email),
                keywords: ["mail"]
            ),
            .init(
                title: "OneWay AI",
                subtitle: "Ask, build, and discover.",
                category: .create,
                iconRole: .aiBuilder,
                route: .action(.askAI),
                keywords: ["assistant", "quantum ai"]
            ),
            .init(
                title: "Create Site",
                subtitle: "Build a website with AI or a template.",
                category: .create,
                iconRole: .newSite,
                route: .action(.newSite),
                keywords: ["website", "site builder"]
            ),
            .init(
                title: "Create Shop",
                subtitle: "Launch an online storefront.",
                category: .create,
                iconRole: .newShop,
                route: .action(.createShop),
                keywords: ["store", "seller", "storefront"]
            ),
            .init(
                title: "Upload File",
                subtitle: "Add a private cloud file.",
                category: .create,
                iconRole: .uploadFile,
                route: .action(.uploadFile),
                keywords: ["cloud", "files"]
            ),
            .init(
                title: "New Community",
                subtitle: "Create a secure group space.",
                category: .create,
                iconRole: .community,
                route: .action(.newCommunity),
                keywords: ["group", "channel"]
            ),
            .init(title: "Create Post or Content", subtitle: "Open Communities to publish content.", category: .create, iconRole: .media, route: .action(.createPost), keywords: ["post", "content", "publish"]),
            .init(title: "Events", subtitle: "Open Communities to create or manage events.", category: .create, iconRole: .calendar, route: .action(.events), keywords: ["calendar", "community events", "schedule"]),
            .init(
                title: "Shops",
                subtitle: "Discover and shop exclusive items.",
                category: .manage,
                iconRole: .shops,
                route: .feature(.shops),
                keywords: ["marketplace", "shop home"]
            ),
            .init(
                title: "My Sites",
                subtitle: "Drafts, domains, publishing, analytics.",
                category: .manage,
                iconRole: .sites,
                route: .action(.mySites),
                keywords: ["sites", "domains"]
            ),
            .init(
                title: "My Shops",
                subtitle: "Products, orders, customers, performance.",
                category: .manage,
                iconRole: .storefront,
                route: .action(.myShops),
                keywords: ["seller", "orders", "store"]
            ),
            .init(title: "Edit Shop", subtitle: "Update storefront details and settings.", category: .manage, iconRole: .shopSettings, route: .action(.editShop), keywords: ["store settings", "storefront settings", "seller"]),
            .init(title: "Manage Products", subtitle: "Edit listings, inventory, and variants.", category: .manage, iconRole: .product, route: .action(.manageProducts), keywords: ["inventory", "listings"]),
            .init(title: "Add Product", subtitle: "Create a new product listing.", category: .create, iconRole: .quickAdd, route: .action(.addProduct), keywords: ["new listing", "inventory", "seller product"]),
            .init(title: "Orders", subtitle: "Fulfill and manage customer orders.", category: .manage, iconRole: .orders, route: .action(.shopOrders), keywords: ["fulfillment", "sales"]),
            .init(title: "Shop Analytics", subtitle: "Review shop performance and activity.", category: .promote, iconRole: .analytics, route: .action(.shopAnalytics), keywords: ["sales", "visitors"]),
            .init(title: "Site Analytics", subtitle: "Review site traffic and publishing activity.", category: .promote, iconRole: .analytics, route: .action(.siteAnalytics), keywords: ["website analytics", "visitors"]),
            .init(title: "Shop Policies", subtitle: "Manage shipping, returns, refunds, and support.", category: .manage, iconRole: .privacyShield, route: .action(.shopPolicies), keywords: ["shipping", "returns", "refunds"]),
            .init(title: "Launch, Pause or Resume Shop", subtitle: "Control storefront availability.", category: .manage, iconRole: .shops, route: .action(.shopLifecycle), keywords: ["publish", "launch", "pause", "resume"]),
            .init(title: "Permanently Delete Shop", subtitle: "Open shop controls for permanent deletion.", category: .account, iconRole: .delete, route: .action(.deleteShop), keywords: ["remove storefront"]),
            .init(
                title: "Shop Messages",
                subtitle: "Buyer and seller commerce inbox.",
                category: .manage,
                iconRole: .messages,
                route: .action(.shopMessages),
                keywords: ["commerce messages", "seller messages", "marketplace messages"]
            ),
            .init(title: "Seller Payments", subtitle: "Manage seller earnings and payouts.", category: .account, iconRole: .paymentSetup, route: .action(.sellerPayments), keywords: ["earnings", "payouts", "seller wallet"]),
            .init(
                title: "OneWay Ads",
                subtitle: "Sponsored placements and campaign tools.",
                category: .promote,
                iconRole: .oneWayAds,
                route: .action(.oneWayAds),
                keywords: ["ads", "analytics", "campaign"]
            ),
            .init(
                title: "Wallet",
                subtitle: "Secure your assets and transactions.",
                category: .account,
                iconRole: .wallet,
                route: .feature(.wallet),
                keywords: ["pay", "money"]
            ),
            .init(
                title: "Cloud",
                subtitle: "Private OneWay storage.",
                category: .manage,
                iconRole: .cloud,
                route: .feature(.cloud),
                keywords: ["files", "drive"]
            ),
            .init(
                title: "Settings",
                subtitle: "Privacy, notifications, security, account.",
                category: .account,
                iconRole: .settings,
                route: .feature(.settings),
                keywords: ["preferences", "privacy", "security"]
            )
        ]
    }
}

@MainActor
final class OneWayHubPreferencesStore: ObservableObject {
    static let changed = Notification.Name("OneWayHubPreferencesChanged")
    static let routeRequested = Notification.Name("OneWayHubRouteRequested")
    static let openRequested = Notification.Name("OneWayHubOpenRequested")
    @Published var showToolbox = true { didSet { persist() } }
    @Published var homeBackground = "Cosmic" { didSet { persist() } }
    @Published var showQuantumAI = true { didSet { persist() } }
    @Published private(set) var pinNotice = ""
    private var changeSubscription: AnyCancellable?
    private var reloading = false
    @Published private(set) var pinnedIDs: [String]
    @Published private(set) var recentIDs: [String]
    @Published var showRecentlyOpened: Bool {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let key: String

    convenience init(defaults: UserDefaults = .standard) {
        self.init(userID: AppEnvironment.currentUserID(), defaults: defaults)
    }

    init(userID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "oneway.universalHub.preferences.v1.\(Self.namespace(for: userID))"
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(Storage.self, from: data) {
            let obsoleteHubIDs: Set<String> = [["feature", "seller", "Studio"].joined(separator: ".")]
            pinnedIDs = stored.pinnedIDs.filter { !obsoleteHubIDs.contains($0) }
            recentIDs = stored.recentIDs.filter { !obsoleteHubIDs.contains($0) }
            showRecentlyOpened = stored.showRecentlyOpened
        } else {
            pinnedIDs = []
            recentIDs = []
            showRecentlyOpened = true
        }
        reload()
        changeSubscription = NotificationCenter.default.publisher(for: Self.changed)
            .sink { [weak self] note in
                guard let self, note.object as? String == self.key else { return }
                self.reload()
            }
    }

    private func reload() {
        guard let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(Storage.self, from: data) else { return }
        reloading = true
        let validIDs = Set(OneWayHubDestinationRegistry.destinations().map(\.id))
        var seen = Set<String>()
        pinnedIDs = stored.pinnedIDs.filter { validIDs.contains($0) && seen.insert($0).inserted }
        recentIDs = stored.recentIDs.filter { validIDs.contains($0) }
        showRecentlyOpened = stored.showRecentlyOpened
        showToolbox = stored.showToolbox ?? true
        homeBackground = stored.homeBackground ?? "Cosmic"
        showQuantumAI = stored.showQuantumAI ?? true
        reloading = false
    }

    var pinnedDestinations: [OneWayHubDestination] {
        let all = OneWayHubDestinationRegistry.destinations()
        return pinnedIDs.compactMap { id in all.first { $0.id == id } }
    }

    func isPinned(_ destination: OneWayHubDestination) -> Bool {
        pinnedIDs.contains(destination.id)
    }

    func togglePin(_ destination: OneWayHubDestination) {
        if let index = pinnedIDs.firstIndex(of: destination.id) {
            pinnedIDs.remove(at: index)
            pinNotice = "\(destination.title) removed from your homepage toolbox"
        } else {
            pinnedIDs.append(destination.id)
            showToolbox = true
            pinNotice = "\(destination.title) added to your homepage toolbox"
        }
        persist()
    }

    func recordOpen(_ destination: OneWayHubDestination) {
        recentIDs.removeAll { $0 == destination.id }
        recentIDs.insert(destination.id, at: 0)
        recentIDs = Array(recentIDs.prefix(8))
        persist()
    }

    private func persist() {
        guard !reloading else { return }
        let storage = Storage(pinnedIDs: pinnedIDs, recentIDs: recentIDs, showRecentlyOpened: showRecentlyOpened, showToolbox: showToolbox, homeBackground: homeBackground, showQuantumAI: showQuantumAI)
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: key)
    }

    private static func namespace(for userID: String) -> String {
        Data(userID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct Storage: Codable {
        var pinnedIDs: [String]
        var recentIDs: [String]
        var showRecentlyOpened: Bool
        var showToolbox: Bool?
        var homeBackground: String?
        var showQuantumAI: Bool?
    }
}

private struct OneWayCompactHubView: View {
    let onSelectAction: (OneWayQuickAction) -> Void
    let onSelectFeature: ((OneWayFeature) -> Void)?
    let onDeleteAccount: () async throws -> Void
    let onClose: () -> Void

    @StateObject private var preferences = OneWayHubPreferencesStore()
    @State private var searchText = ""
    @State private var isDeletingAccount = false
    @State private var showsDeletionConfirmation = false
    @State private var deletionError: String?
    @StateObject private var creationTools = CreationToolsViewModel()
    @State private var showsFileImporter = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    private var allDestinations: [OneWayHubDestination] {
        OneWayHubDestinationRegistry.destinations().filter { destination in
            if case .feature = destination.route { return onSelectFeature != nil }
            return true
        }
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [OneWayHubDestination] {
        allDestinations.filter { $0.matches(searchText) }
    }

    private var pinnedDestinations: [OneWayHubDestination] {
        preferences.pinnedIDs.compactMap { id in allDestinations.first { $0.id == id } }
    }

    private var recentDestinations: [OneWayHubDestination] {
        Array(preferences.recentIDs.compactMap { id in allDestinations.first { $0.id == id } }.prefix(4))
    }

    private func destinations(in category: OneWayHubCategory) -> [OneWayHubDestination] {
        allDestinations.filter { $0.category == category }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayCompactHubPalette.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        header
                        searchField
                        if !preferences.pinNotice.isEmpty {
                            Text(preferences.pinNotice).font(.caption.weight(.semibold)).foregroundStyle(OneWayCompactHubPalette.purple).padding(.horizontal, 8)
                        }

                        if query.isEmpty {
                            if !pinnedDestinations.isEmpty {
                                destinationSection(
                                    title: "Pinned",
                                    systemName: "pin.fill",
                                    destinations: pinnedDestinations
                                )
                            }

                            if preferences.showRecentlyOpened && !recentDestinations.isEmpty {
                                destinationSection(
                                    title: "Recently Opened",
                                    systemName: "sparkles",
                                    destinations: recentDestinations
                                )
                            }

                            destinationSection(
                                title: "Create",
                                systemName: "plus.circle.fill",
                                destinations: destinations(in: .create)
                            )

                            destinationSection(
                                title: "Manage",
                                systemName: "slider.horizontal.3",
                                destinations: destinations(in: .manage)
                            )

                            destinationSection(
                                title: "Promote",
                                systemName: "megaphone.fill",
                                destinations: destinations(in: .promote)
                            )

                            destinationSection(
                                title: "Account",
                                systemName: "person.crop.circle.fill",
                                destinations: destinations(in: .account)
                            )

                            deleteAccountButton

                            Toggle(isOn: $preferences.showRecentlyOpened) {
                                Text("Show Recently Opened")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            .tint(OneWayCompactHubPalette.purple)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                        } else if searchResults.isEmpty {
                            emptyState
                        } else {
                            destinationSection(
                                title: "Search Results",
                                systemName: "magnifyingglass",
                                destinations: searchResults
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 34)
                }
            }
            .preferredColorScheme(.dark)
            .alert("Unable to Delete Account", isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionError ?? "Please try again.")
            }
            .confirmationDialog(
                "Permanently delete your OneWay account?",
                isPresented: $showsDeletionConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    deleteAccount()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your account and OneWay-owned data will be permanently deleted. This cannot be undone.")
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.data, .content],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await creationTools.upload(url: url) }
            case .failure(let error):
                creationTools.reportImportFailure(error)
            }
        }
        .alert("Upload File", isPresented: Binding(
            get: { creationTools.cloudErrorMessage != nil || creationTools.uploadMessage != nil },
            set: { if !$0 { creationTools.clearNotice() } }
        )) {
            Button("OK") { creationTools.clearNotice() }
        } message: {
            Text(creationTools.cloudErrorMessage ?? creationTools.uploadMessage ?? "Upload complete.")
        }
    }

    private var deleteAccountButton: some View {
        Button {
            guard !isDeletingAccount else { return }
            showsDeletionConfirmation = true
        } label: {
            HStack(spacing: 10) {
                if isDeletingAccount {
                    ProgressView().tint(.white)
                } else {
                    OneWayResolvedIcon(systemName: "trash.fill")
                }
                Text("Delete Account")
                    .font(.system(size: 17, weight: .black, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDeletingAccount)
        .accessibilityLabel("Delete Account")
        .accessibilityIdentifier("oneWayHub.deleteAccount")
    }

    private func deleteAccount() {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        Task {
            do {
                try await onDeleteAccount()
            } catch {
                deletionError = error.localizedDescription
                isDeletingAccount = false
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            OneWayPhysicalIcon(
                role: .oneWayApp,
                size: 52,
                state: .selected,
                container: .none,
                accessibilityLabel: "OneWay Hub",
                glowIntensity: 0.3
            )

            VStack(alignment: .leading, spacing: 5) {
                Text("All Features")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(-3)
                Text("Access every major OneWay feature from one place.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(OneWayCompactHubPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button(action: onClose) {
                OneWayResolvedIcon(systemName: "xmark")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(OneWayCompactHubPalette.glass, in: Circle())
                    .overlay(Circle().stroke(OneWayCompactHubPalette.purple.opacity(0.65), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close OneWay Hub")
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(OneWayCompactHubPalette.secondary)

            TextField("Search OneWay", text: $searchText, prompt: Text("Search OneWay").foregroundColor(OneWayCompactHubPalette.secondary))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    OneWayResolvedIcon(systemName: "xmark.circle.fill")
                        .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
        .oneWayCompactHubGlass(cornerRadius: 15)
        .accessibilityLabel("Search OneWay")
    }

    private func destinationSection(
        title: String,
        systemName: String,
        destinations: [OneWayHubDestination]
    ) -> some View {
        Group {
            if !destinations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(title: title, systemName: systemName)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(destinations) { destination in
                            destinationCard(destination)
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, systemName: String) -> some View {
        HStack(spacing: 9) {
            OneWayResolvedIcon(systemName: systemName)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(OneWayCompactHubPalette.purple)

            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .black, design: .rounded))
                .tracking(3)
                .foregroundStyle(OneWayCompactHubPalette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            LinearGradient(
                colors: [OneWayCompactHubPalette.purple, OneWayCompactHubPalette.purple.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func destinationCard(_ destination: OneWayHubDestination) -> some View {
        VStack(spacing: 0) {
            HStack { Spacer()
                Button {
                preferences.togglePin(destination)
            } label: {
                OneWayPinIcon(isPinned: preferences.isPinned(destination), size: 20)
                    .frame(width: 24, height: 24)
                    .background(preferences.isPinned(destination) ? OneWayCompactHubPalette.purple.opacity(0.32) : OneWayCompactHubPalette.deep.opacity(0.9), in: Circle())
                    .overlay(Circle().stroke(OneWayCompactHubPalette.purple.opacity(0.46), lineWidth: 1))
                    .frame(width: 44, height: 44, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel(preferences.isPinned(destination) ? "Unpin \(destination.title)" : "Pin \(destination.title)")
            }.frame(height: 44)
            Button {
                open(destination)
            } label: {
                VStack(spacing: 8) {
                    OneWayPhysicalIcon(role: destination.iconRole, size: 52, state: .selected,
                                       container: .none, accessibilityLabel: destination.title, glowIntensity: 0.15)
                        .accessibilityHidden(true)
                    Text(destination.title)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(destination.subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(OneWayCompactHubPalette.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 118, alignment: .top)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(destination.title)
            .accessibilityHint(destination.subtitle)

        }
        .oneWayCompactHubGlass(cornerRadius: 22)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            OneWayPhysicalIcon(role: .search, size: 64, container: .none, accessibilityLabel: "No features found")
            Text("No features found")
                .font(.system(size: 19, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("Try another feature name or category.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OneWayCompactHubPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(26)
        .oneWayCompactHubGlass(cornerRadius: 20)
    }

    private func destinations(for routes: [OneWayHubRoute]) -> [OneWayHubDestination] {
        routes.compactMap { route in allDestinations.first { $0.route == route } }
    }

    private func open(_ destination: OneWayHubDestination) {
        preferences.recordOpen(destination)
        switch destination.route {
        case .action(let action):
            if action == .uploadFile {
                showsFileImporter = true
            } else {
                onSelectAction(action)
            }
        case .feature(let feature):
            onSelectFeature?(feature)
            onClose()
        }
    }
}

private enum OneWayCompactHubPalette {
    static let deep = Color(hex: 0x05040C)
    static let panel = Color(hex: 0x110D21)
    static let glass = Color(hex: 0x110D21).opacity(0.76)
    static let purple = Color(hex: 0xA85BFF)
    static let secondary = Color(hex: 0xC9B8FF)
    static let background = LinearGradient(
        colors: [Color(hex: 0x05040C), Color(hex: 0x07051A), Color(hex: 0x120728), Color(hex: 0x030413)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private extension View {
    func oneWayCompactHubGlass(cornerRadius: CGFloat) -> some View {
        self
            .background(
                LinearGradient(
                    colors: [OneWayCompactHubPalette.panel.opacity(0.96), OneWayCompactHubPalette.glass],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(OneWayCompactHubPalette.purple.opacity(0.38), lineWidth: 1)
            }
            .shadow(color: OneWayCompactHubPalette.purple.opacity(0.04), radius: 12, y: 6)
    }
}

private enum OneWayHubProfileTab: String, CaseIterable, Identifiable {
    case all = "All"
    case connect = "Connect"
    case create = "Create"
    case more = "More"

    var id: String { rawValue }
}

private struct OneWayUniversalHubView: View {
    let onSelectAction: (OneWayQuickAction) -> Void
    let onSelectFeature: ((OneWayFeature) -> Void)?
    let onClose: () -> Void

    @StateObject private var preferences = OneWayHubPreferencesStore()
    @State private var searchText = ""
    @State private var selectedTab: OneWayHubProfileTab = .all
    @State private var showsPinnedOnly = false
    @FocusState private var searchIsFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var gridColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private var allDestinations: [OneWayHubDestination] {
        OneWayHubDestinationRegistry.destinations()
            .filter { destination in
                if case .feature = destination.route { return onSelectFeature != nil }
                return true
            }
    }

    private var filteredDestinations: [OneWayHubDestination] {
        allDestinations.filter { $0.matches(searchText) }
    }

    private var pinnedDestinations: [OneWayHubDestination] {
        preferences.pinnedIDs.compactMap { id in allDestinations.first { $0.id == id } }
            .filter { $0.matches(searchText) }
    }

    private var recentDestinations: [OneWayHubDestination] {
        preferences.recentIDs.compactMap { id in allDestinations.first { $0.id == id } }
            .filter { !preferences.pinnedIDs.contains($0.id) && $0.matches(searchText) }
    }

    private var orderedDestinations: [OneWayHubDestination] {
        let prioritizedIDs = preferences.pinnedIDs + preferences.recentIDs
        let prioritized = prioritizedIDs.compactMap { id in allDestinations.first { $0.id == id } }
        let remaining = allDestinations.filter { destination in
            !prioritizedIDs.contains(destination.id)
        }
        return prioritized + remaining
    }

    private var displayedDestinations: [OneWayHubDestination] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return filteredDestinations
        }
        if showsPinnedOnly {
            return pinnedDestinations
        }
        return orderedDestinations.filter { destination in
            switch selectedTab {
            case .all:
                return true
            case .connect:
                return destination.category == .create
            case .create:
                return destination.category == .manage
            case .more:
                return destination.category == .promote || destination.category == .account
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayHubProfilePalette.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
                        topBar
                        hero
                        identity
                        stats
                        searchField
                        tabs

                        if let featured = displayedDestinations.first {
                            featuredCard(featured)
                            let remaining = Array(displayedDestinations.dropFirst())
                            if !remaining.isEmpty {
                                destinationSection(sectionTitle, destinations: remaining)
                            }
                        } else {
                            emptyState
                        }

                        trustSection

                        Toggle(isOn: $preferences.showRecentlyOpened) {
                            Text("Show Recently Opened")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .tint(OneWayHubProfilePalette.purple)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 54)
                        .oneWayHubProfileGlass(cornerRadius: 18)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            hubIconButton(systemName: "xmark", accessibilityLabel: "Close OneWay Hub", action: onClose)

            HStack(spacing: 7) {
                Text("OneWay Hub")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                OneWayResolvedIcon(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(OneWayHubProfilePalette.purple)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            hubIconButton(systemName: "magnifyingglass", accessibilityLabel: "Search OneWay") {
                searchIsFocused = true
            }

            hubIconButton(
                systemName: showsPinnedOnly ? "pin.fill" : "pin",
                accessibilityLabel: showsPinnedOnly ? "Show all features" : "Show pinned features"
            ) {
                showsPinnedOnly.toggle()
                searchText = ""
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0x230750), Color(hex: 0x0A0D2A), Color(hex: 0x101744)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image("OneWayCreatorHero")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(.vertical, 8)
                    .shadow(color: OneWayHubProfilePalette.glow.opacity(0.58), radius: 24, y: 10)
            }
            .frame(height: 174)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(OneWayHubProfilePalette.purple.opacity(0.58), lineWidth: 1)
            }

            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.black.opacity(0.78))
                    .frame(width: 94, height: 94)
                    .overlay(Circle().stroke(OneWayHubProfilePalette.purple, lineWidth: 3))
                    .shadow(color: OneWayHubProfilePalette.glow.opacity(0.52), radius: 18, y: 8)
                OneWayPhysicalIcon(
                    role: .oneWayApp,
                    size: 82,
                    state: .selected,
                    container: .none,
                    accessibilityLabel: "OneWay Hub",
                    glowIntensity: 0.28
                )
                Circle()
                    .fill(OneWayHubProfilePalette.green)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(OneWayHubProfilePalette.deep, lineWidth: 3))
                    .padding(5)
            }
            .offset(x: 14, y: 46)
        }
        .padding(.top, 2)
        .padding(.bottom, 48)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("OneWay Hub")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                OneWayResolvedIcon(systemName: "checkmark.seal.fill")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(OneWayHubProfilePalette.purple)
            }

            Text("Every major OneWay feature, ready from one place.")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(OneWayHubProfilePalette.secondary)

            Button {
                searchIsFocused = true
            } label: {
                HStack(spacing: 10) {
                    OneWayResolvedIcon(systemName: "magnifyingglass")
                    Text("Find a Feature")
                }
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .frame(height: 54)
                .background(OneWayHubProfilePalette.buttonGradient, in: Capsule())
                .shadow(color: OneWayHubProfilePalette.purple.opacity(0.34), radius: 18, y: 9)
            }
            .buttonStyle(.plain)
        }
    }

    private var stats: some View {
        HStack(spacing: 0) {
            OneWayHubProfileStat(icon: "square.grid.2x2.fill", value: "\(allDestinations.count)", label: "Features")
            OneWayHubProfileDivider()
            OneWayHubProfileStat(icon: "pin.fill", value: "\(preferences.pinnedIDs.count)", label: "Pinned")
            OneWayHubProfileDivider()
            OneWayHubProfileStat(icon: "rectangle.3.group.fill", value: "5", label: "Spaces")
            OneWayHubProfileDivider()
            OneWayHubProfileStat(icon: "lock.shield.fill", value: "100%", label: "Private")
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .oneWayHubProfileGlass(cornerRadius: 22)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)
            TextField("Search OneWay", text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .focused($searchIsFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    OneWayResolvedIcon(systemName: "xmark.circle.fill")
                        .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 54)
        .oneWayHubProfileGlass(cornerRadius: 20)
        .accessibilityLabel("Search OneWay")
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(OneWayHubProfileTab.allCases) { tab in
                Button {
                    selectedTab = tab
                    showsPinnedOnly = false
                    searchText = ""
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(selectedTab == tab && !showsPinnedOnly ? .white : OneWayHubProfilePalette.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background {
                            if selectedTab == tab && !showsPinnedOnly {
                                Capsule().fill(OneWayHubProfilePalette.buttonGradient)
                            } else {
                                Capsule().fill(OneWayHubProfilePalette.glass)
                            }
                        }
                        .overlay {
                            Capsule()
                                .stroke(OneWayHubProfilePalette.purple.opacity(selectedTab == tab && !showsPinnedOnly ? 0 : 0.34), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func featuredCard(_ destination: OneWayHubDestination) -> some View {
        HStack(spacing: 16) {
            OneWayPhysicalIcon(
                role: destination.iconRole,
                size: 126,
                state: .selected,
                container: .none,
                accessibilityLabel: destination.title,
                glowIntensity: 0.34
            )
            .frame(maxWidth: .infinity)
            .background(OneWayHubProfilePalette.glow.opacity(0.16), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(alignment: .leading, spacing: 9) {
                Text(destination.title)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(destination.subtitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(OneWayHubProfilePalette.secondary)
                    .lineLimit(3)

                Button {
                    open(destination)
                } label: {
                    HStack(spacing: 9) {
                        OneWayResolvedIcon(systemName: "arrow.up.right")
                        Text("Open Feature")
                    }
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(OneWayHubProfilePalette.buttonGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .oneWayHubProfileGlass(cornerRadius: 22)
        .overlay(alignment: .topTrailing) {
            pinButton(destination)
                .padding(8)
        }
    }

    private func destinationSection(_ title: String, destinations: [OneWayHubDestination]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(destinations.count)")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(OneWayHubProfilePalette.purple)
            }

            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(destinations) { destination in
                    destinationCard(destination)
                }
            }
        }
    }

    private func destinationCard(_ destination: OneWayHubDestination) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                open(destination)
            } label: {
                HStack(spacing: 7) {
                    OneWayPhysicalIcon(
                        role: destination.iconRole,
                        size: 48,
                        state: .selected,
                        container: .none,
                        accessibilityLabel: destination.title,
                        glowIntensity: 0.28
                    )
                    .accessibilityHidden(true)

                    VStack(alignment: .center, spacing: 5) {
                        Text(destination.title)
                            .font(.system(size: 14.5, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .allowsTightening(true)
                            .frame(maxWidth: 90, alignment: .center)

                        Text(destination.subtitle)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                            .lineLimit(3)
                            .minimumScaleFactor(0.78)

                        if let badge = destination.badgeCount, badge > 0 {
                            Text("\(badge)")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(OneWayDesignSystem.Colors.purple, in: Capsule())
                                .accessibilityLabel("\(badge) updates")
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)

                }
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 40)
                .padding(.bottom, 12)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(destination.title)
            .accessibilityHint(destination.subtitle)

            pinButton(destination)
                .padding(6)
        }
        .oneWayHubProfileGlass(cornerRadius: 20)
    }

    private func pinButton(_ destination: OneWayHubDestination) -> some View {
        Button {
            preferences.togglePin(destination)
        } label: {
            OneWayPinIcon(isPinned: preferences.isPinned(destination), size: 24)
                .frame(width: 30, height: 30)
                .background(preferences.isPinned(destination) ? OneWayHubProfilePalette.purple.opacity(0.32) : OneWayHubProfilePalette.deep.opacity(0.88), in: Circle())
                .overlay(Circle().stroke(OneWayHubProfilePalette.purple.opacity(0.48), lineWidth: 1))
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preferences.isPinned(destination) ? "Unpin \(destination.title)" : "Pin \(destination.title)")
    }

    private var trustSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Built into OneWay")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            LazyVGrid(columns: gridColumns, spacing: 10) {
                OneWayHubTrustChip(icon: "checkmark.shield.fill", title: "Secure\nAccess")
                OneWayHubTrustChip(icon: "lock.fill", title: "Private by\nDefault")
                OneWayHubTrustChip(icon: "bolt.fill", title: "Instant\nLaunch")
                OneWayHubTrustChip(icon: "pin.fill", title: "Pin Your\nFavorites")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            OneWayPhysicalIcon(role: .search, size: 72, container: .none, accessibilityLabel: "No features found")
            Text(showsPinnedOnly ? "No pinned features yet" : "No features found")
                .font(.system(size: 21, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text(showsPinnedOnly ? "Pin the tools you use most and they will appear here." : "Try another feature name or category.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OneWayHubProfilePalette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .oneWayHubProfileGlass(cornerRadius: 22)
    }

    private var sectionTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Search Results" }
        if showsPinnedOnly { return "Pinned Features" }
        switch selectedTab {
        case .all: return "All Features"
        case .connect: return "Communication"
        case .create: return "Create & Explore"
        case .more: return "Business & Personal"
        }
    }

    private func hubIconButton(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: systemName)
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(OneWayHubProfilePalette.purple)
                .frame(width: 48, height: 48)
                .oneWayHubProfileGlass(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func open(_ destination: OneWayHubDestination) {
        preferences.recordOpen(destination)
        switch destination.route {
        case .action(let action):
            onSelectAction(action)
        case .feature(let feature):
            onSelectFeature?(feature)
            onClose()
        }
    }

}

private enum OneWayHubProfilePalette {
    static let deep = Color(hex: 0x05040C)
    static let panel = Color(hex: 0x110D21)
    static let glass = Color(hex: 0x14142E).opacity(0.74)
    static let stroke = Color(hex: 0x8B4CFF).opacity(0.34)
    static let purple = Color(hex: 0xA85BFF)
    static let secondary = Color(hex: 0xD7C9FF)
    static let green = Color(hex: 0x22E87C)
    static let glow = Color(hex: 0x8438FF)
    static let background = LinearGradient(
        colors: [Color(hex: 0x05040C), Color(hex: 0x07051A), Color(hex: 0x15082D), Color(hex: 0x030413)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let buttonGradient = LinearGradient(
        colors: [Color(hex: 0x7C35FF), Color(hex: 0xC866FF)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

private extension View {
    func oneWayHubProfileGlass(cornerRadius: CGFloat) -> some View {
        self
            .background(
                LinearGradient(
                    colors: [OneWayHubProfilePalette.panel.opacity(0.94), OneWayHubProfilePalette.glass],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(OneWayHubProfilePalette.stroke, lineWidth: 1)
            }
            .shadow(color: OneWayHubProfilePalette.glow.opacity(0.14), radius: 22, y: 12)
    }
}

private struct OneWayHubProfileStat: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 7) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(OneWayHubProfilePalette.purple)
                .frame(height: 22)
            Text(value)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(OneWayHubProfilePalette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OneWayHubProfileDivider: View {
    var body: some View {
        Rectangle()
            .fill(OneWayHubProfilePalette.stroke)
            .frame(width: 1, height: 62)
    }
}

private struct OneWayHubTrustChip: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 23, weight: .black))
                .foregroundStyle(OneWayHubProfilePalette.purple)
                .frame(width: 32)
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.horizontal, 12)
        .oneWayHubProfileGlass(cornerRadius: 16)
    }
}

enum OneWayQuickAction: String, CaseIterable, Identifiable, Codable {
    case newMessage
    case newCommunity
    case createPost
    case events
    case newCall
    case newSite
    case mySites
    case uploadFile
    case createShop
    case myShops
    case editShop
    case manageProducts
    case addProduct
    case shopOrders
    case shopMessages
    case shopAnalytics
    case siteAnalytics
    case sellerPayments
    case shopPolicies
    case shopLifecycle
    case deleteShop
    case oneWayAds
    case wallet
    case askAI
    case appSettings
    case signOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newMessage: return "New Message"
        case .newCommunity: return "New Community"
        case .createPost: return "Create Post or Content"
        case .events: return "Events"
        case .newCall: return "New Call"
        case .newSite: return "New Site"
        case .mySites: return "My Sites"
        case .uploadFile: return "Upload File"
        case .createShop: return "New Shop"
        case .myShops: return "My Shops"
        case .editShop: return "Edit Shop"
        case .manageProducts: return "Manage Products"
        case .addProduct: return "Add Product"
        case .shopOrders: return "Orders"
        case .shopMessages: return "Buyer and Seller Messages"
        case .shopAnalytics: return "Shop Analytics"
        case .siteAnalytics: return "Site Analytics"
        case .sellerPayments: return "Wallet, Earnings and Payouts"
        case .shopPolicies: return "Shop Policies"
        case .shopLifecycle: return "Launch, Pause or Resume Shop"
        case .deleteShop: return "Permanently Delete Shop"
        case .oneWayAds: return "OneWay Ads"
        case .wallet: return "Wallet"
        case .askAI: return "Ask OneWay AI"
        case .appSettings: return "App Settings"
        case .signOut: return "Sign Out"
        }
    }

    var subtitle: String {
        switch self {
        case .newMessage: return "Start a private conversation."
        case .newCommunity: return "Create a secure group space."
        case .createPost: return "Open Communities to publish content."
        case .events: return "Open Communities to create or manage events."
        case .newCall: return "Start voice or video."
        case .newSite: return "Build a website with AI or start from a template."
        case .mySites: return "Manage drafts, domains, publishing, analytics, and forms."
        case .uploadFile: return "Add a private cloud file."
        case .createShop: return "Launch a storefront and start selling."
        case .myShops: return "Manage your storefront, products, orders, and messages."
        case .editShop: return "Update storefront details and settings."
        case .manageProducts: return "Manage listings and inventory."
        case .addProduct: return "Create a new product listing."
        case .shopOrders: return "Fulfill and manage customer orders."
        case .shopMessages: return "Open the commerce inbox."
        case .shopAnalytics: return "Review shop performance."
        case .siteAnalytics: return "Review site traffic and publishing activity."
        case .sellerPayments: return "Manage seller earnings and payouts."
        case .shopPolicies: return "Manage shipping, returns, refunds, and support."
        case .shopLifecycle: return "Launch, pause, or resume your shop."
        case .deleteShop: return "Open controls to permanently remove a shop."
        case .oneWayAds: return "Create sponsored placements, fund campaigns, review policy status, and track performance."
        case .wallet: return "Pay, send, receive, and manage funds."
        case .askAI: return "Get help across OneWay."
        case .appSettings: return "Manage privacy, appearance, notifications, security, and OneWay preferences."
        case .signOut: return "Sign out of this OneWay account on this device."
        }
    }

    var icon: String {
        switch self {
        case .newMessage: return "bubble.left.and.bubble.right.fill"
        case .newCommunity: return "person.3.fill"
        case .createPost: return "square.and.pencil"
        case .events: return "calendar"
        case .newCall: return "phone.fill"
        case .newSite: return "globe"
        case .mySites: return "rectangle.stack.fill"
        case .uploadFile: return "icloud.and.arrow.up.fill"
        case .createShop: return "storefront.fill"
        case .myShops: return "shippingbox.fill"
        case .editShop: return "slider.horizontal.3"
        case .manageProducts: return "shippingbox.fill"
        case .addProduct: return "plus.square.fill"
        case .shopOrders: return "list.clipboard.fill"
        case .shopMessages: return "bubble.left.and.bubble.right.fill"
        case .shopAnalytics, .siteAnalytics: return "chart.line.uptrend.xyaxis"
        case .sellerPayments: return "banknote.fill"
        case .shopPolicies: return "doc.text.fill"
        case .shopLifecycle: return "dot.radiowaves.left.and.right"
        case .deleteShop: return "trash.fill"
        case .oneWayAds: return "megaphone.fill"
        case .wallet: return "wallet.pass.fill"
        case .askAI: return "sparkles"
        case .appSettings: return "gearshape.fill"
        case .signOut: return "rectangle.portrait.and.arrow.right"
        }
    }

    var iconColor: Color {
        switch self {
        case .signOut:
            return Color.red.opacity(0.92)
        default:
            return OneWayDesignSystem.Colors.purple
        }
    }

    var iconBackground: Color {
        switch self {
        case .signOut:
            return Color.red.opacity(0.14)
        default:
            return OneWayDesignSystem.Colors.lavender
        }
    }

    var borderColor: Color {
        switch self {
        case .signOut:
            return Color.red.opacity(0.28)
        default:
            return OneWayDesignSystem.Colors.border
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .appSettings:
            return "Open App Settings"
        case .signOut:
            return "Sign Out of OneWay"
        default:
            return title
        }
    }

    var accessibilityHint: String {
        switch self {
        case .signOut:
            return "Opens a confirmation before signing out."
        default:
            return subtitle
        }
    }
}
