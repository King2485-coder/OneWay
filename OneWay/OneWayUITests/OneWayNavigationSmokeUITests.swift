import XCTest

final class OneWayNavigationSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--qa-seeded-data"]
        app.launchEnvironment["ONEWAY_LOGIN_BYPASS"] = "1"
        app.launchEnvironment["ONEWAY_DEV_AUTH_ENABLED"] = "1"
        app.launchEnvironment["ONEWAY_API_BASE_URL"] = "http://127.0.0.1:3000"
        app.launch()
        let denyNotifications = app.alerts.buttons["Don’t Allow"]
        if denyNotifications.waitForExistence(timeout: 2) { denyNotifications.tap() }
    }

    func testLaunchAndVisitEveryBottomTab() {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        for tab in ["Home", "Communities", "Calls", "Shops"] {
            openTab(named: tab)
            XCTAssertTrue(app.staticTexts[tab].exists || app.buttons[tab].exists || app.tabBars.buttons[tab].exists, "\(tab) should be reachable.")
            attachScreenshot(named: "tab-\(tab)")
        }
    }

    func testOpenMajorFeatureHubs() {
        openTab(named: "Shops")
        tapIfExists(["Search", "Favorites", "Messages", "Account"])

        openTab(named: "Calls")
        tapIfExists(["Keypad", "Chirp", "Contacts", "Recents", "Favorites", "Voicemail"])

        openCreateMenu()
        tapIfExists(["Create Site", "Create Shop", "Ask AI"])

        attachScreenshot(named: "major-feature-hubs")
    }

    func testBackOrCloseIsAvailableOnPushedPages() {
        openCreateMenu()
        if tapFirstExisting(["Create Site", "Create Shop", "Ask AI"]) {
            XCTAssertTrue(
                app.navigationBars.buttons["Back"].exists ||
                app.buttons["Back"].exists ||
                app.buttons["Close"].exists ||
                app.buttons.matching(identifier: "chevron.left").count > 0,
                "Pushed Settings pages should expose a back or close control."
            )
        }
    }

    func testLightOSScreensHaveReadablePrimaryText() {
        for tab in ["Communities", "Calls", "Shops"] {
            openTab(named: tab)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label == ''")).firstMatch.exists)
        }
    }

    private func openTab(named title: String) {
        if app.tabBars.buttons[title].waitForExistence(timeout: 2) {
            app.tabBars.buttons[title].tap()
            return
        }
        let labels = title == "Home"
            ? ["Home", "Open Quantum", "Open OneWay Quantum"]
            : [title, "Open \(title)"]
        let accessibleButton = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        if accessibleButton.waitForExistence(timeout: 2) {
            accessibleButton.tap()
            return
        }
        if app.buttons[title].waitForExistence(timeout: 2) {
            app.buttons[title].tap()
            return
        }
        XCTFail("Could not find tab \(title).")
    }

    private func tapIfExists(_ labels: [String]) {
        for label in labels {
            _ = tapFirstExisting([label])
        }
    }

    private func openCreateMenu() {
        if app.buttons["Create"].waitForExistence(timeout: 1) {
            app.buttons["Create"].tap()
            return
        }
        let buttons = app.buttons.allElementsBoundByIndex
        if buttons.count >= 3 {
            buttons[2].tap()
        }
    }

    @discardableResult
    private func tapFirstExisting(_ labels: [String]) -> Bool {
        for label in labels {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 1) {
                button.tap()
                return true
            }
            let text = app.staticTexts[label]
            if text.waitForExistence(timeout: 1) {
                text.tap()
                return true
            }
        }
        return false
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
