import Foundation

struct BrowserTab: Identifiable, Equatable, Codable {
    var id = UUID()
    var title: String
    var url: URL?
    var isPrivate: Bool
    var createdAt = Date()
    var updatedAt = Date()

    static func home(isPrivate: Bool = false) -> BrowserTab {
        BrowserTab(title: isPrivate ? "New Quantum Private Tab" : "New Quantum Tab", url: nil, isPrivate: isPrivate)
    }

    var displayURL: String {
        url?.absoluteString ?? "OneWay Quantum start"
    }

    var displayDomain: String {
        url?.host?.replacingOccurrences(of: "www.", with: "") ?? "Quantum Start"
    }
}

struct BrowserDownload: Identifiable, Equatable, Codable {
    enum Status: String, Codable {
        case saved = "Saved"
        case pending = "Pending"
        case failed = "Failed"
    }

    var id = UUID()
    var filename: String
    var sourceURL: String
    var date = Date()
    var status: Status
}

struct BrowserSettings: Codable, Equatable {
        enum SearchEngine: String, Codable, CaseIterable, Identifiable {
            case duckDuckGo = "DuckDuckGo"
            case google = "Google"
            case bing = "Bing"

        var id: String { rawValue }

        func searchURL(for query: String) -> URL? {
            var components: URLComponents?
            switch self {
            case .duckDuckGo:
                components = URLComponents(string: "https://duckduckgo.com/")
            case .google:
                components = URLComponents(string: "https://www.google.com/search")
            case .bing:
                components = URLComponents(string: "https://www.bing.com/search")
            }
            components?.queryItems = [.init(name: "q", value: query)]
            return components?.url
        }
    }

    var defaultSearchEngine: SearchEngine = .duckDuckGo
    var privateModeDefault = true
    var httpsOnlyMode = true
    var blockTrackers = true
    var showRecentHistoryOnHome = false
    var saveBrowsingHistory = true
    var clearHistoryOnExit = false
    var hideSiteThumbnails = false
    var requireFaceIDForHistory = false

    init(
        defaultSearchEngine: SearchEngine = .duckDuckGo,
        privateModeDefault: Bool = true,
        httpsOnlyMode: Bool = true,
        blockTrackers: Bool = true,
        showRecentHistoryOnHome: Bool = false,
        saveBrowsingHistory: Bool = true,
        clearHistoryOnExit: Bool = false,
        hideSiteThumbnails: Bool = false,
        requireFaceIDForHistory: Bool = false
    ) {
        self.defaultSearchEngine = defaultSearchEngine
        self.privateModeDefault = privateModeDefault
        self.httpsOnlyMode = httpsOnlyMode
        self.blockTrackers = blockTrackers
        self.showRecentHistoryOnHome = showRecentHistoryOnHome
        self.saveBrowsingHistory = saveBrowsingHistory
        self.clearHistoryOnExit = clearHistoryOnExit
        self.hideSiteThumbnails = hideSiteThumbnails
        self.requireFaceIDForHistory = requireFaceIDForHistory
    }

    enum CodingKeys: String, CodingKey {
        case defaultSearchEngine
        case privateModeDefault
        case httpsOnlyMode
        case blockTrackers
        case showRecentHistoryOnHome
        case saveBrowsingHistory
        case clearHistoryOnExit
        case hideSiteThumbnails
        case requireFaceIDForHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultSearchEngine = (try? container.decodeIfPresent(SearchEngine.self, forKey: .defaultSearchEngine)) ?? .duckDuckGo
        privateModeDefault = try container.decodeIfPresent(Bool.self, forKey: .privateModeDefault) ?? true
        httpsOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .httpsOnlyMode) ?? true
        blockTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockTrackers) ?? true
        showRecentHistoryOnHome = try container.decodeIfPresent(Bool.self, forKey: .showRecentHistoryOnHome) ?? false
        saveBrowsingHistory = try container.decodeIfPresent(Bool.self, forKey: .saveBrowsingHistory) ?? true
        clearHistoryOnExit = try container.decodeIfPresent(Bool.self, forKey: .clearHistoryOnExit) ?? false
        hideSiteThumbnails = try container.decodeIfPresent(Bool.self, forKey: .hideSiteThumbnails) ?? false
        requireFaceIDForHistory = try container.decodeIfPresent(Bool.self, forKey: .requireFaceIDForHistory) ?? false
    }
}

struct BrowserNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
