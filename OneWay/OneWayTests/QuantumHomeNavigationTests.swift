import XCTest
@testable import CipherChat

@MainActor final class QuantumHomeNavigationTests: XCTestCase {
    func testHomeShortcutPreservesWebsiteAndReusesHomeTab() throws {
        let website = URL(string: "https://www.youtube.com/")!
        let browser = BrowserViewModel(initialURL: website)
        let websiteTab = browser.activeTab
        let privacy = websiteTab.isPrivate
        browser.showQuantumHome()
        XCTAssertNil(browser.activeTab.url)
        XCTAssertNil(browser.currentURL)
        XCTAssertEqual(browser.activeTab.isPrivate, privacy)
        XCTAssertEqual(browser.tabs.first { $0.id == websiteTab.id }?.url, website)
        let homeID = browser.activeTab.id
        let count = browser.tabs.count
        browser.selectTab(try XCTUnwrap(browser.tabs.first { $0.id == websiteTab.id }))
        browser.showQuantumHome()
        XCTAssertEqual(browser.activeTab.id, homeID)
        XCTAssertEqual(browser.tabs.count, count)
        XCTAssertEqual(browser.query, "")
    }
}
