import XCTest
@testable import CipherChat

final class SignupSuggestionIntegrationTests: XCTestCase {
    func testNameAutofillsAndManualOverridesStayIndependent() {
        var draft = OneWaySignupSuggestions()
        draft.setDisplayName("Maya Stone")
        XCTAssertEqual(draft.onewayID, "@mayastone")
        XCTAssertEqual(draft.emailAddress, "mayastone@oneway.app")
        draft.setHandle("@maya_custom")
        draft.setDisplayName("Maya River")
        XCTAssertEqual(draft.onewayID, "@maya_custom")
        XCTAssertEqual(draft.emailAddress, "mayariver@oneway.app")
        draft.setEmailName("studio@oneway.app")
        draft.setDisplayName("Maya Lane")
        XCTAssertEqual(draft.emailAddress, "studio@oneway.app")
        XCTAssertEqual(draft.onewayID, "@maya_custom")
    }
    func testNamesNormalizeWithoutInventingNumbers() {
        var draft = OneWaySignupSuggestions()
        draft.setDisplayName("José River 🌟")
        XCTAssertEqual(draft.handle, "joseriver")
        XCTAssertEqual(draft.emailName, "joseriver")
    }
}

@MainActor final class HomepageToolboxIntegrationTests: XCTestCase {
    func testHubAndHomeSharePinsWithoutEvictingOtherTools() {
        let suite = "LiveToolboxTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = OneWayHubPreferencesStore(userID: "owner-a", defaults: defaults)
        let home = OneWayHubPreferencesStore(userID: "owner-a", defaults: defaults)
        let other = OneWayHubPreferencesStore(userID: "owner-b", defaults: defaults)
        home.showToolbox = false
        XCTAssertFalse(hub.showToolbox)
        let destinations = Array(OneWayHubDestinationRegistry.destinations().prefix(12))
        for destination in destinations { hub.togglePin(destination) }
        XCTAssertEqual(home.pinnedIDs, destinations.map(\.id))
        XCTAssertEqual(home.pinnedDestinations.count, 12)
        XCTAssertTrue(home.showToolbox)
        XCTAssertTrue(other.pinnedIDs.isEmpty)
        let restored = OneWayHubPreferencesStore(userID: "owner-a", defaults: defaults)
        XCTAssertEqual(restored.pinnedIDs, home.pinnedIDs)
        hub.togglePin(destinations[0])
        XCTAssertFalse(home.pinnedIDs.contains(destinations[0].id))
        XCTAssertTrue(hub.pinNotice.contains("removed"))
    }
    func testHomeCustomizationSynchronizesAndPersists() {
        let suite = "LiveHomeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = OneWayHubPreferencesStore(userID: "owner", defaults: defaults)
        let home = OneWayHubPreferencesStore(userID: "owner", defaults: defaults)
        editor.homeBackground = "Aurora"; editor.showQuantumAI = false
        XCTAssertEqual(home.homeBackground, "Aurora")
        XCTAssertFalse(home.showQuantumAI)
    }
}

final class WebsiteShopLinkIntegrationTests: XCTestCase {
    func testShopLinkRequiresExplicitEnableAndSafeShopSlug() throws {
        var site = OneWayBuilderSite(name: "Studio", domain: SiteDomain(subdomain: "studio.oneway.site", customDomain: "", sslStatus: "Pending", publishStatus: "Draft"), status: .draft, lastEdited: Date(), pages: [], theme: SiteTheme(primaryHex: "#111827", accentHex: "#7B3FF2", fontName: "System", isDark: false), seoTitle: "Studio", seoDescription: "", contactEmail: "", socialLinks: [])
        site.linkedShopSlug = "studio-shop"
        XCTAssertNil(site.linkedShopURL)
        site.shopLinkEnabled = true
        XCTAssertEqual(site.linkedShopURL, APIConfig.storefrontPublicURL(for: "studio-shop"))
        site.linkedShopSlug = "../other?token=bad"
        XCTAssertNil(site.linkedShopURL)
        let encoded = try JSONEncoder().encode(site)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "linkedShopSlug")
        legacy.removeValue(forKey: "linkedShopName")
        legacy.removeValue(forKey: "shopLinkEnabled")
        let restored = try JSONDecoder().decode(OneWayBuilderSite.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.linkedShopURL)
        XCTAssertEqual(restored.name, "Studio")
    }
}

@MainActor final class PortalAppShortcutIntegrationTests: XCTestCase {
    func testNativeAppPreferencePersistsForBuiltInAndCustomPortals() throws {
        let suite = "NativePortalTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PortalPreferenceStore(defaults: defaults)
        let custom = try store.addCustom(name: "Example", address: "https://example.com")
        store.setAppOpening("youtube", enabled: true)
        store.setAppOpening(custom.id, enabled: true)
        let restored = PortalPreferenceStore(defaults: defaults)
        XCTAssertEqual(restored.portal(id: "youtube")?.opensInstalledApp, true)
        XCTAssertEqual(restored.portal(id: custom.id)?.opensInstalledApp, true)
        XCTAssertEqual(restored.portal(id: "youtube")?.homeURL?.scheme, "https")
        XCTAssertNil(restored.portal(id: "google")?.opensInstalledApp)
    }
}
