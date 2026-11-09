import SwiftUI

struct OneWaySitesDashboardView: View {
    @StateObject private var viewModel = OneWaySitesViewModel()
    @State private var path = NavigationPath()
    @State private var searchText = ""
    @State private var filter: SiteDashboardFilter = .all
    @State private var shouldOpenCreateFlow: Bool
    @State private var highlightedSiteID: UUID?
    @State private var successMessage: String?
    private let returnToDashboardAfterCreate: Bool

    init(startOnCreate: Bool = false, returnToDashboardAfterCreate: Bool = false) {
        _shouldOpenCreateFlow = State(initialValue: startOnCreate)
        self.returnToDashboardAfterCreate = returnToDashboardAfterCreate
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { proxy in
                let safe = proxy.safeAreaInsets
                let horizontalPadding: CGFloat = proxy.size.width < 390 ? 10 : 14

                ZStack {
                    OneWayCallTheme.background.ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            SiteDashboardHeader()
                                .padding(.horizontal, 2)
                            mySitesSection
                            SiteActivitySummaryView(
                                visitors: trafficToday,
                                leads: unreadForms,
                                forms: max(1, viewModel.sites.count),
                                sales: max(0, viewModel.sites.count * 3)
                            ) {
                                path.append(SitesRoute.analytics)
                            }
                            SiteManagementToolsView { path.append($0) }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, max(12, safe.top + 4))
                        .padding(.bottom, safe.bottom + 130)
                    }
                    if let successMessage {
                        Text(successMessage)
                            .font(.subheadline.weight(.black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(OneWayCallTheme.purpleGradient, in: Capsule())
                            .shadow(color: OneWayCallTheme.purple.opacity(0.28), radius: 18, x: 0, y: 8)
                            .padding(.top, max(12, safe.top + 4))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(5)
                    }
                }
            }
            .navigationBarHidden(true)
        .task { await viewModel.loadAccountContact() }
            .navigationDestination(for: SitesRoute.self) { routeView($0) }
            .onAppear {
                guard shouldOpenCreateFlow else { return }
                shouldOpenCreateFlow = false
                path.append(SitesRoute.create)
            }
        }
    }

    private var mySitesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("My Sites")
                    .font(.title3.weight(.black))
                    .foregroundStyle(OneWayCallTheme.text)
                    .lineLimit(1)
                Spacer()
                Button("View All") {
                    filter = .all
                    searchText = ""
                }
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }

            HStack(spacing: 10) {
                OneWayResolvedIcon(systemName: "magnifyingglass")
                    .foregroundStyle(OneWayCallTheme.muted)
                TextField("Search sites...", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .oneWayReadableText(.body)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(OneWayCallTheme.surface, in: Capsule())
            .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))

            Picker("Filter", selection: $filter) {
                Text("All").tag(SiteDashboardFilter.all)
                Text("Published").tag(SiteDashboardFilter.published)
                Text("Drafts").tag(SiteDashboardFilter.drafts)
            }
            .pickerStyle(.segmented)

            if viewModel.sites.isEmpty {
                emptyState
            } else if filteredSites.isEmpty {
                Text("No sites match your search or filter.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x6F687D))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ForEach(filteredSites) { site in
                    SiteListRow(
                        site: site,
                        lastEdited: relative(site.lastEdited),
                        onOpen: { path.append(SitesRoute.overview(site.id)) },
                        onPreview: { path.append(SitesRoute.preview(site.id)) },
                        onOpenQuantum: { path.append(SitesRoute.quantum(site.id)) },
                        onEdit: { path.append(SitesRoute.editor(site.id)) },
                        onSettings: { path.append(SitesRoute.settings(site.id)) },
                        onDomain: { path.append(SitesRoute.domain(site.id)) },
                        onSubmissions: { path.append(SitesRoute.submissions(site.id)) },
                        onPublishToggle: { togglePublish(site) }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(highlightedSiteID == site.id ? OneWayCallTheme.purple : Color.clear, lineWidth: 2)
                    )
                }
            }
        }
        .padding(12)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            OneWayResolvedIcon(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(OneWayCallTheme.purple)
            Text("No sites yet")
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayCallTheme.text)
            Text("Use the + menu to create your first OneWay Site with AI, a template, or a blank canvas.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: 0x6F687D))
                .multilineTextAlignment(.center)
            OneWayResolvedLabel("Create from the + menu", systemImage: "plus.circle.fill")
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(OneWayCallTheme.lavenderSurface, in: Capsule())
                .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var filteredSites: [OneWayBuilderSite] {
        viewModel.sites
            .filter { site in
                searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                site.name.localizedCaseInsensitiveContains(searchText) ||
                site.domain.subdomain.localizedCaseInsensitiveContains(searchText) ||
                site.domain.customDomain.localizedCaseInsensitiveContains(searchText)
            }
            .filter { site in
                switch filter {
                case .all: return true
                case .published: return site.status == .published
                case .drafts: return site.status == .draft
                }
            }
            .sorted { $0.lastEdited > $1.lastEdited }
    }

    @ViewBuilder
    private func routeView(_ route: SitesRoute) -> some View {
        switch route {
        case .create:
            CreateSiteFlowView(viewModel: viewModel) { handleCreateFlowRoute($0) }
        case .ai:
            AISiteBuilderView(viewModel: viewModel) { site in handleCreatedSite(site.id) }
        case .templates:
            SiteTemplatePickerView(viewModel: viewModel) { site in handleCreatedSite(site.id) }
        case .domains:
            SitesDomainsView(viewModel: viewModel) { path.append($0) }
        case .analytics:
            SitesAnalyticsView(viewModel: viewModel)
        case .cms:
            SitesCMSView()
        case .forms:
            SitesFormsManagerView(viewModel: viewModel) { path.append($0) }
        case .hosting:
            SitesHostingView()
        case .importSite:
            SitesImportView()
        case .overview(let id):
            if let site = viewModel.site(id) {
                SiteOverviewView(
                    viewModel: viewModel,
                    site: site,
                    visitors: siteVisitors(site),
                    seoScore: seoScore(site),
                    performanceScore: performanceScore(site),
                    onRoute: { path.append($0) }
                )
            }
        case .editor(let id):
            if let site = viewModel.site(id) { SiteEditorView(viewModel: viewModel, site: site) { path.append($0) } }
        case .preview(let id):
            if let site = viewModel.site(id) { SitePreviewView(site: site) }
        case .quantum(let id):
            if let site = viewModel.site(id) {
                BrowserHomeView(
                    domainService: StubDomainService(seedSlugs: [site.oneWaySlug]),
                    siteService: NetworkSiteService(client: .shared),
                    initialURL: site.quantumPublicURL
                )
            }
        case .settings(let id):
            if let site = viewModel.site(id) { SiteSettingsView(viewModel: viewModel, site: site) { path.append($0) } }
        case .domain(let id):
            if let site = viewModel.site(id) { DomainSettingsView(viewModel: viewModel, site: site) }
        case .submissions(let id):
            if let site = viewModel.site(id) { SiteSubmissionsView(viewModel: viewModel, site: site) }
        }
    }

    private func togglePublish(_ site: OneWayBuilderSite) {
        if site.status == .published {
            viewModel.unpublish(site)
        } else {
            _ = viewModel.publish(site)
        }
    }

    private func handleCreateFlowRoute(_ route: SitesRoute) {
        if case .editor(let siteID) = route, returnToDashboardAfterCreate {
            handleCreatedSite(siteID)
        } else {
            path.append(route)
        }
    }

    private func handleCreatedSite(_ siteID: UUID) {
        guard returnToDashboardAfterCreate else {
            path.append(SitesRoute.editor(siteID))
            return
        }

        print("SITE_CREATE_SUCCEEDED siteId=\(siteID.uuidString) status=draft source=creationTools")
        print("MY_SITES_LIST_UPDATED count=\(viewModel.sites.count) highlightedSiteId=\(siteID.uuidString)")
        searchText = ""
        filter = .all
        highlightedSiteID = siteID
        successMessage = "Site created. Added to My Sites."
        path = NavigationPath()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                successMessage = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            highlightedSiteID = nil
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var unreadForms: Int { max(1, viewModel.sites.reduce(0) { $0 + viewModel.submissions(for: $1).filter { !$0.isRead }.count }) }
    private var trafficToday: Int { max(1842, viewModel.sites.count * 421) }

    private func siteVisitors(_ site: OneWayBuilderSite) -> Int {
        abs(site.name.hashValue % 900) + 120
    }

    private func seoScore(_ site: OneWayBuilderSite) -> Int {
        82 + abs(site.domain.subdomain.hashValue % 15)
    }

    private func performanceScore(_ site: OneWayBuilderSite) -> Int {
        86 + abs(site.name.hashValue % 11)
    }
}

enum SitesRoute: Hashable {
    case create
    case ai
    case templates
    case domains
    case analytics
    case cms
    case forms
    case hosting
    case importSite
    case overview(UUID)
    case editor(UUID)
    case preview(UUID)
    case quantum(UUID)
    case settings(UUID)
    case domain(UUID)
    case submissions(UUID)
}

enum SiteDashboardFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case published = "Published"
    case drafts = "Drafts"

    var id: String { rawValue }
}
