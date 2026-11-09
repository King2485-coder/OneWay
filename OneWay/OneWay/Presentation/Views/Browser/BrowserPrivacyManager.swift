import Foundation
import WebKit

struct BrowserPrivacyStats: Equatable {
    var trackersBlocked = 0
    var adsBlocked = 0

    var dataSavedKilobytes: Int {
        (trackersBlocked * 42) + (adsBlocked * 96)
    }
}

final class BrowserPrivacyManager {
    static let shared = BrowserPrivacyManager()

    private init() {}

    func configure(_ configuration: WKWebViewConfiguration, settings: BrowserSettings, isPrivate: Bool) {
        configuration.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.applicationNameForUserAgent = "OneWayQuantum/1.0"

        guard settings.blockTrackers else { return }
        installContentRules(into: configuration.userContentController)
    }

    func clearPrivateData(completion: @escaping () -> Void = {}) {
        // Privacy-sensitive: called when private tabs close so cookies/cache/session storage do not survive.
        WKWebsiteDataStore.nonPersistent().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: completion
        )
    }

    func clearAllWebsiteData(completion: @escaping () -> Void = {}) {
        // Privacy-sensitive: destructive local-only browser data wipe. Do not send browsing data to a server.
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: completion
        )
    }

    private func installContentRules(into userContentController: WKUserContentController) {
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: "OneWayStarterBlockRules") { ruleList, _ in
            if let ruleList {
                userContentController.add(ruleList)
                return
            }

            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "OneWayStarterBlockRules",
                encodedContentRuleList: Self.starterRulesJSON
            ) { compiledRuleList, _ in
                guard let compiledRuleList else { return }
                userContentController.add(compiledRuleList)
            }
        }
    }

    private static let starterRulesJSON = """
    [
      {"trigger":{"url-filter":".*doubleclick\\\\.net.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*googlesyndication\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*google-analytics\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*facebook\\\\.net.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*adsystem\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*adservice\\\\.google\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*scorecardresearch\\\\.com.*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*hotjar\\\\.com.*"},"action":{"type":"block"}}
    ]
    """
}
