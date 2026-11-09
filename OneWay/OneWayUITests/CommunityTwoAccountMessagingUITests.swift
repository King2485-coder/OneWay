import XCTest

final class CommunityTwoAccountMessagingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--qa-community-two-account"]
        app.launchEnvironment["ONEWAY_LOGIN_BYPASS"] = "1"
        app.launch()
    }

    func testDeveloperQACommunityTwoAccountRunnerPasses() {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(
            app.staticTexts["Community two-account test passed."].waitForExistence(timeout: 10)
                || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Community two-account test passed")).firstMatch.waitForExistence(timeout: 10),
            "Developer QA should report the two-account community test passed."
        )
        XCTAssertTrue(app.staticTexts["Duplicate blocked"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["King sees both messages"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Member count"].waitForExistence(timeout: 3))
    }
}
