import Foundation
import WebKit

struct BrowserStoredPage: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var urlString: String
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, url: URL, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.urlString = url.absoluteString
        self.updatedAt = updatedAt
    }

    var url: URL? {
        URL(string: urlString)
    }
}

enum BrowserRecentSiteStore {
    private static let key = "oneway.browser.recentSites.v1"
    private static let maxCount = 16

    static func load() -> [URL] {
        UserDefaults.standard
            .stringArray(forKey: key)?
            .compactMap(URL.init(string:)) ?? []
    }

    static func record(_ url: URL) {
        guard OneWayBrowserPolicy.isAllowed(url) else { return }

        let normalizedURL = normalized(url)
        let recentURLs = [normalizedURL] + load().filter {
            normalized($0).absoluteString != normalizedURL.absoluteString
        }

        UserDefaults.standard.set(
            recentURLs.prefix(maxCount).map(\.absoluteString),
            forKey: key
        )
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }
}

enum BrowserBookmarkStore {
    private static let key = "oneway.browser.bookmarks.v1"

    static func load() -> [BrowserStoredPage] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BrowserStoredPage].self, from: data)) ?? []
    }

    static func isBookmarked(_ url: URL) -> Bool {
        let normalizedURL = BrowserRecentSiteStore.normalized(url)
        return load().contains {
            $0.url.map(BrowserRecentSiteStore.normalized)?.absoluteString == normalizedURL.absoluteString
        }
    }

    static func toggle(url: URL, title: String) -> Bool {
        let normalizedURL = BrowserRecentSiteStore.normalized(url)
        var bookmarks = load()

        if let index = bookmarks.firstIndex(where: {
            $0.url.map(BrowserRecentSiteStore.normalized)?.absoluteString == normalizedURL.absoluteString
        }) {
            bookmarks.remove(at: index)
            save(bookmarks)
            return false
        }

        bookmarks.insert(
            BrowserStoredPage(title: cleanTitle(title, fallback: normalizedURL.host ?? normalizedURL.absoluteString), url: normalizedURL),
            at: 0
        )
        save(bookmarks)
        return true
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ bookmarks: [BrowserStoredPage]) {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum BrowserTabStore {
    private static let key = "oneway.browser.tabs.v1"
    private static let maxCount = 24

    static func load() -> [BrowserStoredPage] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BrowserStoredPage].self, from: data)) ?? []
    }

    static func record(url: URL, title: String) {
        guard OneWayBrowserPolicy.isAllowed(url) else { return }
        let normalizedURL = BrowserRecentSiteStore.normalized(url)
        var tabs = load().filter {
            $0.url.map(BrowserRecentSiteStore.normalized)?.absoluteString != normalizedURL.absoluteString
        }
        tabs.insert(
            BrowserStoredPage(title: cleanTitle(title, fallback: normalizedURL.host ?? normalizedURL.absoluteString), url: normalizedURL),
            at: 0
        )
        save(Array(tabs.prefix(maxCount)))
    }

    static func close(_ page: BrowserStoredPage) {
        save(load().filter { $0.id != page.id })
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ tabs: [BrowserStoredPage]) {
        if let data = try? JSONEncoder().encode(tabs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum BrowserHistoryStore {
    private static let key = "oneway.browser.history.v1"
    private static let maxCount = 200

    static func load() -> [BrowserStoredPage] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BrowserStoredPage].self, from: data)) ?? []
    }

    static func record(url: URL, title: String) {
        guard OneWayBrowserPolicy.isAllowed(url) else { return }
        let normalizedURL = BrowserRecentSiteStore.normalized(url)
        var history = load().filter {
            $0.url.map(BrowserRecentSiteStore.normalized)?.absoluteString != normalizedURL.absoluteString
        }
        history.insert(
            BrowserStoredPage(title: cleanTitle(title, fallback: normalizedURL.host ?? normalizedURL.absoluteString), url: normalizedURL),
            at: 0
        )
        save(Array(history.prefix(maxCount)))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ history: [BrowserStoredPage]) {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum BrowserDataStore {
    static func clearWebsiteData(completion: @escaping () -> Void = {}) {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(
            ofTypes: dataTypes,
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    static func clearLocalBrowserState() {
        BrowserRecentSiteStore.clear()
        BrowserHistoryStore.clear()
        BrowserTabStore.clear()
        BrowserBookmarkStore.clear()
    }
}

private func cleanTitle(_ title: String, fallback: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
}
