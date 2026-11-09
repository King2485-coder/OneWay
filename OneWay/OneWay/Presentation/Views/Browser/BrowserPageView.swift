import SwiftUI
import Combine
import WebKit

final class BrowserPageState: ObservableObject {
    @Published var title: String?
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var estimatedProgress = 0.0
    @Published var pageZoom: CGFloat = 1.0

    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
        update(from: webView)
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    func findInPage(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        webView?.evaluateJavaScript("window.find(\(Self.javascriptStringLiteral(trimmedQuery)))")
    }

    func setZoom(_ zoom: CGFloat) {
        let clampedZoom = min(max(zoom, 0.7), 1.8)
        pageZoom = clampedZoom
        webView?.pageZoom = clampedZoom
    }

    func zoomIn() {
        setZoom(pageZoom + 0.1)
    }

    func zoomOut() {
        setZoom(pageZoom - 0.1)
    }

    func stopLoading() {
        webView?.stopLoading()
        if let webView {
            update(from: webView)
        }
    }

    func update(from webView: WKWebView) {
        title = webView.title
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        estimatedProgress = min(max(webView.estimatedProgress, 0), 1)
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else {
            return "\"\""
        }
        return String(arrayLiteral.dropFirst().dropLast())
    }
}

struct BrowserPageView: View {
    private let siteService: SiteService

    @StateObject private var browserState = BrowserPageState()
    @State private var currentURL: URL
    @State private var pageHTML: String?
    @State private var isResolvingPage = true
    @State private var blockedNavigation: BlockedBrowserNavigation?
    @State private var notice: BrowserNotice?
    @State private var isBookmarked = false
    @State private var tabs: [BrowserStoredPage] = []
    @State private var activeSheet: BrowserPageSheet?
    @State private var addressQuery = ""

    init(url: URL, siteService: SiteService) {
        self.siteService = siteService
        self._currentURL = State(initialValue: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            loadingBar

            ZStack {
                SiteWebView(
                    url: currentURL,
                    html: pageHTML,
                    browserState: browserState,
                    onBlockedNavigation: { blockedURL in
                        blockedNavigation = BlockedBrowserNavigation(url: blockedURL)
                    },
                    onInternalNavigation: navigate
                )

                if isResolvingPage {
                    ProgressView("Loading OneWay site...")
                        .tint(Theme.accentGold)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(18)
                        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            browserControls
        }
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(pageTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(OneWayBrowserPolicy.isOneWayURL(activeURL) ? "OneWay Quantum" : "Quantum")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accentGold)
                }
            }
        }
        .alert(item: $blockedNavigation) { blocked in
            Alert(
                title: Text("Unsupported Link"),
                message: Text("OneWay Quantum can open web links inside the app. \(blocked.hostDescription) uses a link type that is not supported yet."),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            recordActivePage()
            refreshSavedState()
        }
        .onChange(of: browserState.currentURL) { _, newURL in
            guard let newURL, OneWayBrowserPolicy.isAllowed(newURL) else { return }
            if currentURL != newURL {
                currentURL = newURL
            }
            recordActivePage()
            refreshSavedState()
        }
        .task(id: currentURL.absoluteString) {
            await resolvePage()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .address:
                BrowserAddressSheet(
                    query: $addressQuery,
                    onOpen: openAddressQuery
                )
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
            case .tabs:
                BrowserTabsSheet(
                    tabs: tabs,
                    currentURL: activeURL,
                    onNewTab: {
                        activeSheet = nil
                        navigate(to: URL(string: "https://home.oneway.app")!)
                    },
                    onSelect: { url in
                        activeSheet = nil
                        navigate(to: url)
                    },
                    onClose: { page in
                        BrowserTabStore.close(page)
                        refreshSavedState()
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .tools:
                BrowserToolsSheet(
                    browserState: browserState,
                    activeURL: activeURL,
                    isBookmarked: isBookmarked,
                    onToggleBookmark: {
                        isBookmarked = BrowserBookmarkStore.toggle(url: activeURL, title: pageTitle)
                    },
                    onOpenSearch: {
                        activeSheet = nil
                        navigate(to: URL(string: "https://search.oneway.app")!)
                    },
                    onClearRecent: {
                        BrowserRecentSiteStore.clear()
                        notice = BrowserNotice(title: "Quantum Cleared", message: "Recent Quantum sites were cleared.")
                    },
                    onClearHistory: {
                        BrowserHistoryStore.clear()
                        notice = BrowserNotice(title: "Quantum History Cleared", message: "Quantum history was cleared.")
                    },
                    onClearTabs: {
                        BrowserTabStore.clear()
                        refreshSavedState()
                        notice = BrowserNotice(title: "Quantum Tabs Closed", message: "All saved Quantum tabs were closed.")
                    },
                    onClearBookmarks: {
                        BrowserBookmarkStore.clear()
                        refreshSavedState()
                        notice = BrowserNotice(title: "Quantum Bookmarks Cleared", message: "All Quantum bookmarks were removed.")
                    },
                    onClearWebsiteData: {
                        BrowserDataStore.clearWebsiteData {
                            browserState.reload()
                            notice = BrowserNotice(title: "Quantum Website Data Cleared", message: "Cookies, cache, and website storage were cleared.")
                        }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var loadingBar: some View {
        Group {
            if browserState.isLoading {
                ProgressView(value: browserState.estimatedProgress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accentGold)
                    .frame(height: 2)
            } else {
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 1)
            }
        }
    }

    private var browserControls: some View {
        VStack(spacing: 10) {
            Button {
                addressQuery = activeURL.absoluteString
                activeSheet = .address
            } label: {
                HStack(spacing: 8) {
                    OneWayResolvedIcon(systemName: activeURL.scheme == "https" ? "lock.fill" : "globe")
                        .font(.caption)
                        .foregroundStyle(Theme.accentGold)

                    Text(displayAddress)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(Theme.textSecondary)

                    Spacer(minLength: 0)

                    OneWayResolvedIcon(systemName: "magnifyingglass")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.glassSurface, in: Capsule())
            .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    browserButton("house.fill") {
                        navigate(to: URL(string: "https://home.oneway.app")!)
                    }

                    browserButton("chevron.left", isEnabled: browserState.canGoBack) {
                        browserState.goBack()
                    }

                    browserButton("chevron.right", isEnabled: browserState.canGoForward) {
                        browserState.goForward()
                    }

                    ShareLink(item: activeURL) {
                        OneWayResolvedIcon(systemName: "square.and.arrow.up")
                            .frame(width: 42, height: 34)
                            .background(Theme.glassSurface, in: Capsule())
                            .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)

                    browserButton(isBookmarked ? "star.fill" : "star") {
                        isBookmarked = BrowserBookmarkStore.toggle(url: activeURL, title: pageTitle)
                    }

                    browserButton("square.on.square") {
                        refreshSavedState()
                        activeSheet = .tabs
                    }

                    browserButton("ellipsis") {
                        activeSheet = .tools
                    }

                    browserButton(browserState.isLoading ? "xmark" : "arrow.clockwise") {
                        if browserState.isLoading {
                            browserState.stopLoading()
                        } else {
                            browserState.reload()
                        }
                    }
                }
                .font(.headline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.black.opacity(0.92))
        .overlay(Divider().overlay(Theme.divider), alignment: .top)
    }

    private func browserButton(
        _ systemName: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: systemName)
                .frame(width: 42, height: 34)
                .background(Theme.glassSurface, in: Capsule())
                .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textMuted)
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
    }

    private var pageTitle: String {
        if let title = browserState.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return activeURL.host ?? "OneWay"
    }

    private var displayAddress: String {
        let host = activeURL.host ?? activeURL.absoluteString
        let path = activeURL.path == "/" ? "" : activeURL.path
        return "\(host)\(path)"
    }

    private var activeURL: URL {
        if let stateURL = browserState.currentURL,
           OneWayBrowserPolicy.isAllowed(stateURL) {
            return stateURL
        }
        return currentURL
    }

    private func navigate(to url: URL) {
        guard OneWayBrowserPolicy.isAllowed(url) else { return }
        BrowserRecentSiteStore.record(url)
        currentURL = url
    }

    private func openAddressQuery() {
        switch OneWayBrowserPolicy.resolve(addressQuery) {
        case .open(let url):
            activeSheet = nil
            navigate(to: url)
        case .blocked(let message):
            notice = BrowserNotice(title: "OneWay Quantum", message: message)
        }
    }

    private func resolvePage() async {
        isResolvingPage = true
        defer { isResolvingPage = false }

        guard OneWayBrowserPolicy.isOneWayURL(currentURL) else {
            pageHTML = nil
            return
        }

        if currentURL.host?.lowercased() == "search.oneway.app" {
            let query = OneWayBrowserHTML.query(from: currentURL)
            if let shortcutURL = OneWayBrowserPolicy.shortcutURL(for: query),
               shortcutURL.host?.lowercased() != "search.oneway.app" {
                pageHTML = nil
                navigate(to: shortcutURL)
                return
            }
            pageHTML = await OneWayBrowserHTML.searchPage(for: currentURL)
            return
        }

        guard let slug = OneWayBrowserPolicy.slug(from: currentURL) else {
            pageHTML = OneWayBrowserHTML.homePage()
            return
        }
        print("QUANTUM_ONEWAY_HOST_DETECTED host=\(currentURL.host?.lowercased() ?? "nil") mode=ONEWAY_SITE")
        print("QUANTUM_ONEWAY_SLUG_PARSED slug=\(slug)")

        if slug == "home" {
            pageHTML = OneWayBrowserHTML.homePage()
            return
        }

        do {
            print("QUANTUM_SITE_API_RESOLVE_STARTED slug=\(slug)")
            if let site = try await siteService.publishedSite(forSlug: slug), site.published {
                print("QUANTUM_SITE_API_RESOLVE_SUCCEEDED slug=\(slug) siteId=\(site.id.uuidString)")
                print("QUANTUM_SITE_HOME_RENDER_STARTED siteId=\(site.id.uuidString)")
                pageHTML = render(site)
                print("QUANTUM_SITE_HOME_RENDER_SUCCEEDED siteId=\(site.id.uuidString)")
            } else {
                pageHTML = OneWayBrowserHTML.unpublishedPage(slug: slug)
            }
        } catch {
            print("QUANTUM_SITE_HOME_RENDER_FAILED slug=\(slug) failureCode=API_RESOLVER_ERROR")
            pageHTML = OneWayBrowserHTML.errorPage(
                slug: slug,
                message: "This Site may be published, but OneWay could not verify the publication right now. \(error.localizedDescription)"
            )
        }
    }

    private func render(_ site: OneWaySite) -> String {
        if !site.publishedHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return site.publishedHtml.replacingOccurrences(
                of: "https://api.oneway.is",
                with: APIConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
        }

        switch site.mode {
        case .nocode:
            return SiteRenderer.render(
                blocks: site.blocks,
                title: site.title,
                description: site.description
            )
        case .code, .ai:
            return site.htmlContent
        }
    }

    private func refreshSavedState() {
        tabs = BrowserTabStore.load()
        isBookmarked = BrowserBookmarkStore.isBookmarked(activeURL)
    }

    private func recordActivePage() {
        BrowserRecentSiteStore.record(activeURL)
        BrowserHistoryStore.record(url: activeURL, title: pageTitle)
        BrowserTabStore.record(url: activeURL, title: pageTitle)
    }
}

private enum BrowserPageSheet: Identifiable {
    case address
    case tabs
    case tools

    var id: String {
        switch self {
        case .address: return "address"
        case .tabs: return "tabs"
        case .tools: return "tools"
        }
    }
}

private struct BlockedBrowserNavigation: Identifiable {
    let id = UUID()
    let url: URL

    var hostDescription: String {
        url.host ?? url.absoluteString
    }
}

private struct BrowserAddressSheet: View {
    @Binding var query: String
    let onOpen: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Search Quantum or enter website")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    HStack(spacing: 10) {
                        OneWayResolvedIcon(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.textMuted)
                        TextField("Quantum Search, URL, or OneWay name", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.webSearch)
                            .submitLabel(.go)
                            .focused($isFocused)
                            .onSubmit(onOpen)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.divider, lineWidth: 1)
                    )

                    Button("Go", action: onOpen)
                        .buttonStyle(PrimaryPillButtonStyle())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(20)
            }
            .navigationTitle("OneWay Quantum")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                isFocused = true
            }
        }
    }
}

private struct BrowserToolsSheet: View {
    @ObservedObject var browserState: BrowserPageState

    let activeURL: URL
    let isBookmarked: Bool
    let onToggleBookmark: () -> Void
    let onOpenSearch: () -> Void
    let onClearRecent: () -> Void
    let onClearHistory: () -> Void
    let onClearTabs: () -> Void
    let onClearBookmarks: () -> Void
    let onClearWebsiteData: () -> Void

    @State private var findQuery = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pageHeader
                        findCard
                        zoomCard
                        browserActions
                        privacyActions
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Quantum Tools")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activeURL.host ?? activeURL.absoluteString)
                .font(.title3.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(activeURL.absoluteString)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var findCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find on Page")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 10) {
                TextField("Word or phrase", text: $findQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .onSubmit {
                        browserState.findInPage(findQuery)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    browserState.findInPage(findQuery)
                } label: {
                    OneWayResolvedIcon(systemName: "magnifyingglass")
                        .font(.headline)
                        .frame(width: 42, height: 40)
                        .background(Theme.accentGold.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(Theme.accentGold)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var zoomCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Page Zoom")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 12) {
                toolButton("minus.magnifyingglass") {
                    browserState.zoomOut()
                }
                Text("\(Int(browserState.pageZoom * 100))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                toolButton("plus.magnifyingglass") {
                    browserState.zoomIn()
                }
                Button("100%") {
                    browserState.setZoom(1.0)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Theme.glassSurface, in: Capsule())
                .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
            }
        }
        .padding(16)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var browserActions: some View {
        VStack(spacing: 10) {
            actionRow(
                symbol: isBookmarked ? "star.fill" : "star",
                title: isBookmarked ? "Remove Quantum Bookmark" : "Add to Quantum Bookmarks",
                action: onToggleBookmark
            )
            actionRow(symbol: "magnifyingglass", title: "Open Quantum Search", action: onOpenSearch)
            actionRow(symbol: "clock.arrow.circlepath", title: "Clear Recent Quantum Sites", action: onClearRecent)
            actionRow(symbol: "clock", title: "Clear Quantum History", action: onClearHistory)
        }
    }

    private var privacyActions: some View {
        VStack(spacing: 10) {
            actionRow(symbol: "square.on.square", title: "Close Saved Quantum Tabs", action: onClearTabs)
            actionRow(symbol: "star.slash", title: "Clear Quantum Bookmarks", action: onClearBookmarks)
            actionRow(symbol: "trash", title: "Clear Cookies and Website Data", isDestructive: true, action: onClearWebsiteData)
        }
    }

    private func actionRow(
        symbol: String,
        title: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                OneWayResolvedIcon(systemName: symbol)
                    .frame(width: 30)
                    .foregroundStyle(isDestructive ? Color.red : Theme.accentGold)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isDestructive ? Color.red : Theme.textPrimary)
                Spacer()
                OneWayResolvedIcon(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(14)
            .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func toolButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: symbol)
                .frame(width: 44, height: 40)
                .background(Theme.glassSurface, in: Capsule())
                .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
    }
}

private struct BrowserTabsSheet: View {
    let tabs: [BrowserStoredPage]
    let currentURL: URL
    let onNewTab: () -> Void
    let onSelect: (URL) -> Void
    let onClose: (BrowserStoredPage) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                if tabs.isEmpty {
                    VStack(spacing: 12) {
                        OneWayResolvedIcon(systemName: "square.on.square")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.textMuted)
                        Text("No Quantum tabs yet")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Open a page and Quantum will keep it here.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(tabs) { tab in
                                tabRow(tab)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Quantum Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New Quantum Tab", action: onNewTab)
                        .foregroundStyle(Theme.accentGold)
                }
            }
        }
    }

    private func tabRow(_ tab: BrowserStoredPage) -> some View {
        HStack(spacing: 12) {
            Button {
                if let url = tab.url {
                    onSelect(url)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(tab.title)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if tab.url?.absoluteString == currentURL.absoluteString {
                            Text("ACTIVE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.accentGold.opacity(0.18), in: Capsule())
                                .foregroundStyle(Theme.accentGold)
                        }
                    }
                    Text(tab.url?.host ?? tab.urlString)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                onClose(tab)
            } label: {
                OneWayResolvedIcon(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(Theme.glassSurface, in: Circle())
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }
}

private enum OneWayBrowserHTML {
    static func query(from url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "q" })?
            .value ?? ""
    }

    static func searchPage(for url: URL) async -> String {
        let query = query(from: url)

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return searchLandingPage()
        }

        do {
            var components = URLComponents(string: APIConfig.baseURL)!
            components.path = "/api/search"
            components.queryItems = [
                .init(name: "q", value: query),
                .init(name: "mode", value: "html")
            ]
            guard let endpoint = components.url else {
                return errorPage(slug: "search", message: "OneWay Search endpoint is invalid.")
            }

            let (data, response) = try await URLSession.shared.data(from: endpoint)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return errorPage(slug: "search", message: "OneWay Search is unavailable right now.")
            }
            return String(data: data, encoding: .utf8) ?? errorPage(slug: "search", message: "OneWay Search returned unreadable results.")
        } catch {
            return errorPage(slug: "search", message: error.localizedDescription)
        }
    }

    static func searchLandingPage() -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>OneWay Search</title>
          \(style)
        </head>
        <body>
          \(backButton)
          <main class="shell">
            <p class="eyebrow">ONEWAY SEARCH</p>
            <h1>Search OneWay from inside OneWay.</h1>
            <p class="lede">OneWay Search starts with people, domains, storefronts, products, and network content. A public web crawler can come next.</p>
            <form class="searchbox" action="https://search.oneway.app" method="get">
              <input name="q" placeholder="Search OneWay" autocomplete="off">
              <button type="submit">Search</button>
            </form>
          </main>
        </body>
        </html>
        """
    }

    static func homePage() -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>OneWay Quantum</title>
          \(style)
        </head>
        <body>
          \(backButton)
          <main class="shell">
            <p class="eyebrow">ONEWAY BROWSER</p>
            <h1>The OneWay network lives here.</h1>
            <p class="lede">Open published <strong>.oneway.app</strong> sites without leaving the app.</p>
            <section class="grid">
              <a class="card" href="https://mira.oneway.app">
                <span>Mira</span>
                <small>Sample OneWay site</small>
              </a>
              <a class="card" href="https://sandbox.oneway.app">
                <span>Sandbox</span>
                <small>Local test space</small>
              </a>
            </section>
          </main>
        </body>
        </html>
        """
    }

    static func unpublishedPage(slug: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>\(escape(slug)).oneway.app</title>
          \(style)
        </head>
        <body>
          \(backButton)
          <main class="shell">
            <p class="eyebrow">ONEWAY SITE</p>
            <h1>\(escape(slug)).oneway.app is not published yet.</h1>
            <p class="lede">This OneWay address exists in the browser, but there is no live page available for it right now.</p>
            <a class="button" href="https://home.oneway.app">Back to OneWay Quantum</a>
          </main>
        </body>
        </html>
        """
    }

    static func errorPage(slug: String, message: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>OneWay Site Error</title>
          \(style)
        </head>
        <body>
          \(backButton)
          <main class="shell">
            <p class="eyebrow">ONEWAY SITE</p>
            <h1>Unable to load \(escape(slug)).oneway.app.</h1>
            <p class="lede">\(escape(message))</p>
            <a class="button" href="https://home.oneway.app">Back to OneWay Quantum</a>
          </main>
        </body>
        </html>
        """
    }

    private static let style = """
      <style>
        *{box-sizing:border-box}html,body{min-height:100%;}body{margin:0;min-height:100dvh;background:
        radial-gradient(circle at 12% 10%,rgba(245,197,66,.24),transparent 24rem),
        linear-gradient(135deg,#080512,#170b32 55%,#2c1455);color:#f6f0ff;
        font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif}
        .top-back{position:fixed;top:calc(env(safe-area-inset-top) + 12px);left:18px;z-index:10;
        appearance:none;border:1px solid rgba(255,255,255,.16);border-radius:999px;
        background:rgba(255,255,255,.1);color:#f5c542;font:800 1rem/1 -apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif;
        padding:12px 16px;backdrop-filter:blur(16px);box-shadow:0 14px 36px rgba(0,0,0,.25)}
        .top-back:active{transform:translateY(1px);background:rgba(255,255,255,.16)}
        .shell{width:min(720px,100%);margin:0 auto;padding:64px 22px}
        .eyebrow{letter-spacing:.18em;color:#f5c542;font-size:.72rem;font-weight:800}
        h1{font-size:clamp(2.4rem,12vw,5rem);line-height:.92;margin:.35rem 0 1rem;
        letter-spacing:-.07em}p{color:rgba(246,240,255,.72);line-height:1.55}
        .lede{font-size:1.08rem;max-width:36rem}.grid{display:grid;gap:14px;margin-top:32px}
        .card,.button{display:block;text-decoration:none;color:#fff;border:1px solid rgba(255,255,255,.14);
        background:rgba(255,255,255,.08);border-radius:22px;padding:18px;backdrop-filter:blur(16px)}
        .card span{display:block;font-weight:900;font-size:1.2rem}.card small{color:rgba(246,240,255,.62)}
        .button{display:inline-block;margin-top:22px;font-weight:800}
        .searchbox{display:flex;gap:10px;margin-top:28px}.searchbox input{min-width:0;flex:1;border:1px solid rgba(255,255,255,.14);
        background:rgba(255,255,255,.08);color:#fff;border-radius:18px;padding:14px 16px;font-size:1rem}
        .searchbox button{border:0;border-radius:18px;padding:0 18px;background:#2f7bff;color:white;font-weight:900}
      </style>
      """

    private static let backButton = """
      <button class="top-back" type="button" onclick="if (history.length > 1) { history.back(); } else { location.href = 'https://home.oneway.app'; }">Back</button>
      """

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
