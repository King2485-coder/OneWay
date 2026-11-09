import XCTest
@testable import CipherChat

final class PortalRegistryTests: XCTestCase {
    func testBuiltInRegistryUsesCanonicalPortalURLs() {
        let expected: [String: String] = [
            "youtube": "https://www.youtube.com/",
            "google": "https://www.google.com/",
            "reddit": "https://www.reddit.com/",
            "amazon": "https://www.amazon.com/",
            "wikipedia": "https://www.wikipedia.org/",
            "apple": "https://www.apple.com/",
            "x": "https://x.com/"
        ]

        for (id, url) in expected {
            XCTAssertEqual(PortalRegistry.builtIns.first { $0.id == id }?.homeURLString, url)
        }
        XCTAssertEqual(Set(PortalRegistry.builtIns.map(\.id)).count, PortalRegistry.builtIns.count)
    }

    func testURLValidatorNormalizesHTTPSAndRejectsDangerousSchemes() throws {
        let validated = try PortalURLValidator.validate(name: " Example ", address: "Example.com/path#fragment")
        XCTAssertEqual(validated.name, "Example")
        XCTAssertEqual(validated.url.absoluteString, "https://example.com/path")

        for address in [
            "javascript:alert(1)",
            "data:text/html,hello",
            "file:///tmp/page.html",
            "http://example.com"
        ] {
            XCTAssertThrowsError(try PortalURLValidator.validate(name: "Blocked", address: address))
        }
    }

    func testQuantumBrowserPolicyRejectsPortalAppHandoffSchemes() {
        XCTAssertFalse(OneWayBrowserPolicy.isAllowed(URL(string: "x://timeline")!))
        XCTAssertFalse(OneWayBrowserPolicy.isAllowed(URL(string: "twitter://timeline")!))
        XCTAssertFalse(OneWayBrowserPolicy.isAllowed(URL(string: "javascript:alert(1)")!))
        XCTAssertTrue(OneWayBrowserPolicy.isAllowed(URL(string: "https://x.com/")!))
    }
}

@MainActor
final class PortalPreferenceAndStartupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PortalAppsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultStartupIsQuantumHome() {
        XCTAssertEqual(OneWayStartupExperienceService(defaults: defaults).resolve(), .quantumHome)
    }

    func testSpecificPortalStartsDirectlyAtPortalHome() {
        let store = PortalPreferenceStore(defaults: defaults)
        store.setStartup(mode: .specificPortal, portalID: "youtube")

        XCTAssertEqual(
            OneWayStartupExperienceService(defaults: defaults).resolve(),
            .portal(id: "youtube", url: URL(string: "https://www.youtube.com/")!)
        )
    }

    func testAskEveryLaunchProducesChooserDecision() {
        let store = PortalPreferenceStore(defaults: defaults)
        store.setStartup(mode: .askEveryLaunch)
        XCTAssertEqual(OneWayStartupExperienceService(defaults: defaults).resolve(), .askEveryLaunch)
    }

    func testResumeLastPortalRestoresOnlyAllowedSafeURL() {
        let store = PortalPreferenceStore(defaults: defaults)
        store.recordOpen(
            portalID: "youtube",
            url: URL(string: "https://www.youtube.com/feed/subscriptions")!,
            tabID: UUID(),
            allowURLRestoration: true
        )
        store.setStartup(mode: .resumeLastPortal)

        XCTAssertEqual(
            OneWayStartupExperienceService(defaults: defaults).resolve(),
            .portal(id: "youtube", url: URL(string: "https://www.youtube.com/feed/subscriptions")!)
        )
    }

    func testHistoryHiddenBehaviorFallsBackToPortalHome() {
        let store = PortalPreferenceStore(defaults: defaults)
        store.recordOpen(
            portalID: "reddit",
            url: URL(string: "https://www.reddit.com/r/privacy")!,
            tabID: UUID(),
            allowURLRestoration: false
        )
        store.setStartup(mode: .resumeLastPortal)

        XCTAssertEqual(
            OneWayStartupExperienceService(defaults: defaults).resolve(),
            .portal(id: "reddit", url: URL(string: "https://www.reddit.com/")!)
        )
        XCTAssertNil(store.configuration.startup.lastKnownURLString)
    }

    func testDisabledStartupPortalFallsBackWithoutResettingOtherBrowserState() {
        let store = PortalPreferenceStore(defaults: defaults)
        store.setStartup(mode: .specificPortal, portalID: "amazon")
        store.setEnabled("amazon", enabled: false)

        XCTAssertEqual(OneWayStartupExperienceService(defaults: defaults).resolve(), .quantumHome)
        XCTAssertFalse(store.portal(id: "amazon")?.isEnabled ?? true)
    }

    func testCustomPortalLifecycleAndBuiltInProtection() throws {
        let store = PortalPreferenceStore(defaults: defaults)
        let custom = try store.addCustom(name: "OneWay Docs", address: "https://docs.example.com/start")
        XCTAssertEqual(custom.allowedHosts, ["docs.example.com"])
        XCTAssertNotNil(store.portal(id: custom.id))

        try store.updateCustom(id: custom.id, name: "Updated Docs", address: "https://docs.example.com/home")
        XCTAssertEqual(store.portal(id: custom.id)?.name, "Updated Docs")

        store.removeCustom(custom.id)
        XCTAssertNil(store.portal(id: custom.id))

        store.removeCustom("youtube")
        XCTAssertNotNil(store.portal(id: "youtube"))
    }

    func testFavoriteAndReorderPersist() {
        let store = PortalPreferenceStore(defaults: defaults)
        store.toggleFavorite("youtube")
        XCTAssertTrue(store.portal(id: "youtube")?.isFavorite ?? false)

        let originalCount = store.configuration.portals.count
        store.move(from: IndexSet(integer: 0), to: originalCount)
        XCTAssertEqual(store.configuration.portals.count, originalCount)

        let reloaded = PortalPreferenceStore(defaults: defaults)
        XCTAssertTrue(reloaded.portal(id: "youtube")?.isFavorite ?? false)
    }

    func testInitialPortalURLIsPresentBeforeFirstBrowserRender() {
        let youtube = URL(string: "https://www.youtube.com/")!
        let viewModel = BrowserViewModel(initialURL: youtube)
        XCTAssertEqual(viewModel.activeTab.url, youtube)
        XCTAssertEqual(viewModel.currentURL, youtube)
    }

    func testQuantumHomeClearsConsumedStartupPortalForCurrentSession() {
        let x = URL(string: "https://x.com/")!
        let viewModel = BrowserViewModel(initialURL: x)

        viewModel.goHome()

        XCTAssertNil(viewModel.activeTab.url)
        XCTAssertNil(viewModel.currentURL)
        XCTAssertEqual(viewModel.query, "")
    }
}
