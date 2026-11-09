import Foundation
import Combine
import WebKit
#if canImport(UIKit)
import UIKit
#endif

enum OneWayBrowserPolicy {
    static func isOneWayHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()
        return normalizedHost == "oneway.app"
            || normalizedHost.hasSuffix(".oneway.app")
            || normalizedHost == "oneway.is"
            || normalizedHost == "www.oneway.is"
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.host != nil else { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    static func isOneWayURL(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return isOneWayHost(host)
    }

    static func slug(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "sites.oneway.app" {
            let slug = url.pathComponents.dropFirst().first?.lowercased()
            return slug?.isEmpty == false ? slug : nil
        }
        if host == "oneway.app" { return nil }
        guard host.hasSuffix(".oneway.app") else { return nil }
        let slug = host.replacingOccurrences(of: ".oneway.app", with: "")
        if slug == "sites" { return nil }
        return slug.isEmpty ? nil : slug
    }

    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://search.oneway.app/")
        components?.queryItems = [.init(name: "q", value: query)]
        return components?.url
    }

    static func webSearchURL(for query: String) -> URL? {
        BrowserSettings.SearchEngine.duckDuckGo.searchURL(for: query)
    }

    static func shortcutURL(for rawQuery: String) -> URL? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return publicSiteAliases[query] ?? oneWayShortcuts[query]
    }

    static func resolve(_ rawQuery: String, settings: BrowserSettings = BrowserSettings()) -> BrowserNavigationResolution {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedQuery = trimmedQuery.lowercased()
        guard !trimmedQuery.isEmpty else {
            return .blocked("Enter a website or private search.")
        }

        if let oneWaySiteURL = oneWaySiteURL(from: trimmedQuery) {
            print("QUANTUM_ONEWAY_ADDRESS_ENTERED")
            print("QUANTUM_SITE_SLUG_PARSED")
            return .open(oneWaySiteURL)
        }

        if let shortcut = shortcutURL(for: lowercasedQuery) {
            return .open(shortcut)
        }

        let candidateString: String
        if trimmedQuery.contains("://") {
            candidateString = trimmedQuery
        } else if trimmedQuery.contains(".") && !trimmedQuery.contains(" ") {
            candidateString = "https://\(trimmedQuery)"
        } else {
            guard let searchURL = settings.defaultSearchEngine.searchURL(for: trimmedQuery) else {
                return .blocked("That search could not be prepared.")
            }
            return .open(searchURL)
        }

        guard var components = URLComponents(string: candidateString), components.host != nil else {
            return .blocked("That address does not look valid.")
        }
        if settings.httpsOnlyMode, components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard let url = components.url, isAllowed(url) else {
            return .blocked("OneWay Quantum can open web links only.")
        }
        return .open(url)
    }

    private static let oneWayShortcuts: [String: URL] = [
        "oneway": URL(string: "https://oneway.is")!,
        "home": URL(string: "https://oneway.is")!,
        "search": URL(string: "https://duckduckgo.com")!
    ]

    private static let publicSiteAliases: [String: URL] = [
        "youtube": URL(string: "https://www.youtube.com")!,
        "wikipedia": URL(string: "https://www.wikipedia.org")!,
        "reddit": URL(string: "https://www.reddit.com")!,
        "x": URL(string: "https://x.com")!,
        "twitter": URL(string: "https://x.com")!,
        "github": URL(string: "https://github.com")!,
        "news": URL(string: "https://news.google.com")!,
        "google": URL(string: "https://www.google.com")!
    ]

    private static func oneWaySiteURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let slug: String?
        if lower.hasPrefix("oneway://site/") {
            slug = String(lower.dropFirst("oneway://site/".count))
        } else if lower.hasPrefix("oneway://") {
            slug = String(lower.dropFirst("oneway://".count))
        } else if lower.hasPrefix("https://sites.oneway.app/") {
            slug = String(lower.dropFirst("https://sites.oneway.app/".count))
        } else {
            slug = nil
        }
        guard let rawSlug = slug else { return nil }
        let normalizedSlug = String(rawSlug.split(separator: "?").first ?? "")
            .split(separator: "#")
            .first
            .map(String.init)?
            .replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")) ?? ""
        guard !normalizedSlug.isEmpty else { return nil }
        return URL(string: "https://sites.oneway.app/\(normalizedSlug)")
    }
}

enum BrowserNavigationResolution {
    case open(URL)
    case blocked(String)
}

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var query = ""
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabID: BrowserTab.ID?
    @Published var settings = BrowserSettings()
    @Published var privacyStats = BrowserPrivacyStats()
    @Published var downloads: [BrowserDownload] = []
    @Published var history: [BrowserStoredPage] = []
    @Published var notice: BrowserNotice?

    @Published var pageTitle: String = "OneWay"
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var estimatedProgress = 0.0
    @Published var hasSecurityWarning = false
    @Published var showsSecurityCard = false
    @Published var isDesktopSiteRequested = false
    @Published var findQuery = ""
    @Published var findMatchCount: Int?

    @Published private(set) var directory: [DirectoryEntry] = []
    @Published private(set) var isLoadingDirectory = false
    @Published var errorMessage: String?

    private weak var webView: WKWebView?
    private weak var portalStore: PortalPreferenceStore?
    private var activePortalID: String?
    private var suppressWebUpdatesUntilNextNavigation = false
    private let domainService: DomainService?

    private let tabsKey = "oneway.privateBrowser.tabs.v1"
    private let activeTabKey = "oneway.privateBrowser.activeTab.v1"
    private let settingsKey = "oneway.privateBrowser.settings.v1"
    private let downloadsKey = "oneway.privateBrowser.downloads.v1"

    init(domainService: DomainService? = nil, initialURL: URL? = nil) {
        self.domainService = domainService
        loadPersistentState()
        if tabs.isEmpty {
            tabs = [.home(isPrivate: settings.privateModeDefault)]
            activeTabID = tabs.first?.id
        }
        if let initialURL, OneWayBrowserPolicy.isAllowed(initialURL) {
            prepareInitialURL(initialURL)
        }
    }

    var activeTab: BrowserTab {
        guard let activeTabID, let tab = tabs.first(where: { $0.id == activeTabID }) else {
            return tabs.first ?? .home(isPrivate: settings.privateModeDefault)
        }
        return tab
    }

    var canSubmitQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var resolvedURL: URL? {
        if case let .open(url) = resolveQuery() { return url }
        return nil
    }

    var displayAddress: String {
        currentURL?.host?.replacingOccurrences(of: "www.", with: "") ?? activeTab.displayDomain
    }

    var shareURL: URL? { currentURL ?? activeTab.url }

    var isCurrentPageBookmarked: Bool {
        guard let shareURL else { return false }
        return BrowserBookmarkStore.isBookmarked(shareURL)
    }

    var currentDomain: String {
        currentURL?.host?.replacingOccurrences(of: "www.", with: "") ?? "Quantum Start"
    }

    var isSecureConnection: Bool {
        currentURL?.scheme?.lowercased() == "https" && !hasSecurityWarning
    }

    var tabCount: Int { tabs.count }

    func resolveQuery() -> BrowserNavigationResolution {
        OneWayBrowserPolicy.resolve(query, settings: settings)
    }

    func submitQuery() {
        switch resolveQuery() {
        case .open(let url):
            open(url)
        case .blocked(let message):
            notice = BrowserNotice(title: "OneWay Quantum", message: message)
        }
    }

    func open(_ url: URL) {
        guard OneWayBrowserPolicy.isAllowed(url) else { return }
        suppressWebUpdatesUntilNextNavigation = false
        if let slug = OneWayBrowserPolicy.slug(from: url) {
            URLCache.shared.removeAllCachedResponses()
            print("QUANTUM_TAB_CACHE_CLEARED slug=\(slug)")
            print("QUANTUM_CONTENT_MODE_SELECTED mode=ONEWAY_SITE slug=\(slug)")
            print("QUANTUM_EXTERNAL_RENDERER_SUPPRESSED slug=\(slug)")
        }
        if currentURL?.absoluteString == url.absoluteString,
           activeTab.url?.absoluteString == url.absoluteString,
           isLoading {
            print("QUANTUM_SITE_DUPLICATE_LOAD_SUPPRESSED navigationId=browser-tab normalizedURL=\(url.absoluteString) requestCount=1")
            return
        }
        print("QUANTUM_NAVIGATION_REQUESTED navigationId=browser-tab normalizedURL=\(url.absoluteString)")
        if let slug = OneWayBrowserPolicy.slug(from: url) {
            print("QUANTUM_ONEWAY_SITE_DETECTED navigationId=browser-tab slug=\(slug) normalizedURL=\(url.absoluteString)")
        } else {
            print("QUANTUM_EXTERNAL_URL_DETECTED navigationId=browser-tab normalizedURL=\(url.absoluteString)")
        }
        haptic()
        currentURL = url
        query = url.absoluteString
        updateActiveTab(title: url.host ?? "Quantum Page", url: url)
        saveTabs()
    }

    func openPortal(_ portal: PortalDefinition, preferences: PortalPreferenceStore) {
        portalStore = preferences
        activePortalID = portal.id

        guard portal.id != PortalRegistry.quantumHomeID else {
            goHome()
            preferences.recordOpen(
                portalID: portal.id,
                url: nil,
                tabID: activeTabID,
                allowURLRestoration: false
            )
            return
        }
        guard let launchURL = portal.launchURL else {
            notice = BrowserNotice(title: "Portal Unavailable", message: "\(portal.name) does not have a valid launch address.")
            return
        }

        if preferences.configuration.openingBehavior == .reusePortalTab,
           let matchingTab = tabs.first(where: { tab in
               guard let url = tab.url else { return false }
               return portal.allows(url)
           }) {
            selectTab(matchingTab)
            if let existingURL = matchingTab.url {
                currentURL = existingURL
            }
        } else {
            open(launchURL)
        }

        preferences.recordOpen(
            portalID: portal.id,
            url: currentURL ?? launchURL,
            tabID: activeTabID,
            allowURLRestoration: settings.saveBrowsingHistory && !activeTab.isPrivate
        )
    }

    func openFreshOneWaySiteTab(_ url: URL) {
        guard OneWayBrowserPolicy.slug(from: url) != nil else {
            open(url)
            return
        }
        let new = BrowserTab.home(isPrivate: settings.privateModeDefault)
        tabs.insert(new, at: 0)
        activeTabID = new.id
        currentURL = nil
        pageTitle = "OneWay"
        query = ""
        webView = nil
        URLCache.shared.removeAllCachedResponses()
        BrowserPrivacyManager.shared.clearPrivateData()
        print("QUANTUM_TAB_CREATED tabId=\(new.id.uuidString)")
        print("QUANTUM_TAB_BUILD_IDENTIFIER \(OneWayBuildInfo.summary)")
        open(url)
    }

    /// Reuse a home tab without replacing an open website or changing private mode.
    func showQuantumHome() {
        let privateMode = activeTab.isPrivate
        if let home = tabs.first(where: { $0.url == nil && $0.isPrivate == privateMode }) {
            selectTab(home)
        } else {
            newTab(privateMode: privateMode)
        }
        // Ignore late updates from the website we just left, as goHome does.
        suppressWebUpdatesUntilNextNavigation = true
        webView?.stopLoading()
        webView = nil
    }

    func newTab(privateMode: Bool? = nil) {
        haptic()
        let new = BrowserTab.home(isPrivate: privateMode ?? settings.privateModeDefault)
        tabs.insert(new, at: 0)
        activeTabID = new.id
        currentURL = nil
        pageTitle = "OneWay"
        query = ""
        saveTabs()
    }

    func selectTab(_ tab: BrowserTab) {
        haptic()
        suppressWebUpdatesUntilNextNavigation = false
        activeTabID = tab.id
        currentURL = tab.url
        pageTitle = tab.title
        query = tab.url?.absoluteString ?? ""
        saveTabs()
    }

    func closeTab(_ tab: BrowserTab) {
        let wasPrivate = tab.isPrivate
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty {
            newTab(privateMode: settings.privateModeDefault)
        } else if activeTabID == tab.id {
            selectTab(tabs[0])
        }
        if wasPrivate {
            BrowserPrivacyManager.shared.clearPrivateData()
        }
        saveTabs()
    }

    func setPrivateMode(_ isPrivate: Bool) {
        updateActiveTab(isPrivate: isPrivate)
        if isPrivate {
            BrowserPrivacyManager.shared.clearPrivateData()
        }
        saveTabs()
    }

    func goHome() {
        guard let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        suppressWebUpdatesUntilNextNavigation = true
        webView?.stopLoading()
        webView = nil
        tabs[index].title = "New Private Tab"
        tabs[index].url = nil
        tabs[index].updatedAt = Date()
        currentURL = nil
        pageTitle = "OneWay"
        query = ""
        saveTabs()
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func updateWebState(from webView: WKWebView) {
        guard !suppressWebUpdatesUntilNextNavigation else { return }
        self.webView = webView
        pageTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? currentURL?.host ?? "OneWay"
        currentURL = webView.url ?? currentURL
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        estimatedProgress = min(max(webView.estimatedProgress, 0), 1)
        hasSecurityWarning = currentURL?.scheme?.lowercased() == "http"
        if let currentURL {
            updateActiveTab(title: pageTitle, url: currentURL)
        }
    }

    func goBack() {
        guard webView?.canGoBack == true else { return }
        haptic()
        webView?.goBack()
    }
    func goForward() {
        guard webView?.canGoForward == true else { return }
        webView?.goForward()
        haptic()
    }
    func reload() {
        guard webView?.isLoading != true else { return }
        webView?.reload()
        haptic()
    }
    func stopLoading() { webView?.stopLoading(); haptic() }

    func bookmarkCurrentPage() {
        guard let url = shareURL else {
            notice = BrowserNotice(title: "Bookmark", message: "There is no page to bookmark yet.")
            return
        }
        let added = BrowserBookmarkStore.toggle(url: url, title: pageTitle)
        haptic()
        notice = BrowserNotice(
            title: added ? "Bookmark Added" : "Bookmark Removed",
            message: pageTitle.nilIfBlank ?? url.absoluteString
        )
    }

    func closeCurrentTab() {
        closeTab(activeTab)
    }

    func closeOtherTabs() {
        guard let activeTabID else { return }
        tabs = tabs.filter { $0.id == activeTabID }
        saveTabs()
        haptic()
    }

    func closeAllTabs() {
        tabs = [.home(isPrivate: settings.privateModeDefault)]
        activeTabID = tabs.first?.id
        currentURL = nil
        pageTitle = "OneWay"
        query = ""
        webView = nil
        saveTabs()
        haptic()
    }

    func pasteAndGo() {
        #if canImport(UIKit)
        guard let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            notice = BrowserNotice(title: "Paste and Go", message: "Clipboard does not contain an address or search.")
            return
        }
        query = value
        submitQuery()
        #endif
    }

    func requestDesktopSite(_ enabled: Bool) {
        isDesktopSiteRequested = enabled
        webView?.customUserAgent = enabled
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
            : nil
        reload()
        notice = BrowserNotice(title: enabled ? "Desktop Site" : "Mobile Site", message: enabled ? "Quantum requested the desktop version for this tab." : "Quantum requested the mobile version for this tab.")
    }

    func findOnPage(_ query: String) {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        guard !escaped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            findMatchCount = nil
            return
        }
        let script = """
        (() => {
          const q = '\(escaped)';
          const body = document.body ? document.body.innerText : '';
          const matches = body.toLowerCase().split(q.toLowerCase()).length - 1;
          window.find(q);
          return matches;
        })();
        """
        webView?.evaluateJavaScript(script) { [weak self] result, _ in
            DispatchQueue.main.async {
                self?.findMatchCount = result as? Int
            }
        }
    }

    func findNext() {
        findOnPage(findQuery)
    }

    func findPrevious() {
        let escaped = findQuery
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.find('\(escaped)', false, true);")
    }

    func recordCurrentPage() {
        guard let currentURL else { return }
        updateActiveTab(title: pageTitle, url: currentURL)
        BrowserRecentSiteStore.record(currentURL)
        if settings.saveBrowsingHistory && !activeTab.isPrivate {
            BrowserHistoryStore.record(url: currentURL, title: pageTitle)
            history = BrowserHistoryStore.load()
        }
        if let portalStore,
           let portalID = activePortalID,
           let portal = portalStore.portal(id: portalID),
           portal.allows(currentURL) {
            portalStore.recordOpen(
                portalID: portalID,
                url: currentURL,
                tabID: activeTabID,
                allowURLRestoration: settings.saveBrowsingHistory && !activeTab.isPrivate
            )
        }
        saveTabs()
    }

    func notePotentialBlockedResource(_ url: URL) {
        guard settings.blockTrackers, let host = url.host?.lowercased() else { return }
        let trackerHints = ["doubleclick", "analytics", "adservice", "googlesyndication", "facebook.net", "hotjar"]
        if trackerHints.contains(where: { host.contains($0) }) {
            privacyStats.trackersBlocked += 1
        }
        if host.contains("ad") || host.contains("ads") {
            privacyStats.adsBlocked += 1
        }
        // TODO: connect WKContentRuleList match telemetry if Apple exposes per-rule callbacks.
    }

    func markLoadFailed() {
        hasSecurityWarning = true
        isLoading = false
        estimatedProgress = 1
    }

    func applyNativeSiteLoadingState(isLoading: Bool, progress: Double) {
        self.isLoading = isLoading
        self.estimatedProgress = min(max(progress, 0), 1)
        if !isLoading {
            hasSecurityWarning = false
        }
    }

    func noteNativeSiteURL(_ url: URL) {
        currentURL = url
        query = url.absoluteString
        updateActiveTab(title: pageTitle, url: url)
        saveTabs()
    }

    func recordDownload(from url: URL?, suggestedFilename: String?) {
        guard let url else { return }
        let filename = suggestedFilename?.nilIfBlank ?? url.lastPathComponent.nilIfBlank ?? "Download"
        downloads.insert(BrowserDownload(filename: filename, sourceURL: url.absoluteString, status: .saved), at: 0)
        saveDownloads()
    }

    func clearBrowsingData() {
        BrowserDataStore.clearLocalBrowserState()
        BrowserPrivacyManager.shared.clearAllWebsiteData()
        history = []
        privacyStats = BrowserPrivacyStats()
        notice = BrowserNotice(title: "Quantum Data Cleared", message: "Quantum history, recent sites, tabs, cookies, cache, and local website data were cleared.")
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    func loadDirectory() async {
        guard let domainService else { return }
        isLoadingDirectory = true
        defer { isLoadingDirectory = false }
        do {
            directory = try await domainService.directory(limit: 100)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the directory."
        }
    }

    private func loadPersistentState() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(BrowserSettings.self, from: data) {
            settings = decoded
        }
        if let data = UserDefaults.standard.data(forKey: tabsKey),
           let decoded = try? JSONDecoder().decode([BrowserTab].self, from: data) {
            tabs = decoded
        }
        if let activeString = UserDefaults.standard.string(forKey: activeTabKey),
           let uuid = UUID(uuidString: activeString) {
            activeTabID = uuid
        }
        if let data = UserDefaults.standard.data(forKey: downloadsKey),
           let decoded = try? JSONDecoder().decode([BrowserDownload].self, from: data) {
            downloads = decoded
        }
        history = BrowserHistoryStore.load()
    }

    private func prepareInitialURL(_ url: URL) {
        suppressWebUpdatesUntilNextNavigation = false
        if let matchingTab = tabs.first(where: {
            $0.url.map(BrowserRecentSiteStore.normalized)?.absoluteString
                == BrowserRecentSiteStore.normalized(url).absoluteString
        }) {
            activeTabID = matchingTab.id
            currentURL = matchingTab.url
            pageTitle = matchingTab.title
            query = matchingTab.url?.absoluteString ?? ""
            return
        }

        guard let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            let tab = BrowserTab(title: url.host ?? "Quantum Portal", url: url, isPrivate: settings.privateModeDefault)
            tabs.insert(tab, at: 0)
            self.activeTabID = tab.id
            currentURL = url
            query = url.absoluteString
            saveTabs()
            return
        }
        tabs[index].title = url.host ?? "Quantum Portal"
        tabs[index].url = url
        tabs[index].updatedAt = Date()
        currentURL = url
        pageTitle = tabs[index].title
        query = url.absoluteString
        saveTabs()
    }

    private func saveTabs() {
        if let data = try? JSONEncoder().encode(tabs) {
            UserDefaults.standard.set(data, forKey: tabsKey)
        }
        UserDefaults.standard.set(activeTabID?.uuidString, forKey: activeTabKey)
    }

    private func saveDownloads() {
        if let data = try? JSONEncoder().encode(downloads) {
            UserDefaults.standard.set(data, forKey: downloadsKey)
        }
    }

    private func updateActiveTab(title: String? = nil, url: URL? = nil, isPrivate: Bool? = nil) {
        guard let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        if let title { tabs[index].title = title }
        if let url { tabs[index].url = url }
        if let isPrivate { tabs[index].isPrivate = isPrivate }
        tabs[index].updatedAt = Date()
    }

    private func haptic() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
