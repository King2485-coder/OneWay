import XCTest

final class OneWayAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--qa-accessibility"]
        app.launchEnvironment["ONEWAY_LOGIN_BYPASS"] = "1"
        app.launchEnvironment["ONEWAY_DEV_AUTH_ENABLED"] = "1"
        app.launchEnvironment["ONEWAY_API_BASE_URL"] = "http://127.0.0.1:3000"
        app.launch()
        dismissNotificationPromptIfNeeded()
    }

    func testMainTabsExposeHittableControls() {
        let tabs = ["Home", "Communities", "Calls", "Shops"]
        for tab in tabs {
            let control = tabControl(named: tab)
            XCTAssertTrue(control.waitForExistence(timeout: 3), "\(tab) control should exist.")
            XCTAssertTrue(control.isHittable, "\(tab) control should not be hidden by overlays.")
        }
    }

    func testSnapshotAttachmentsForReleaseReview() {
        for tab in ["Communities", "Shops", "Calls"] {
            // Feature hubs may intentionally hide the main toolbar. Relaunch so
            // every screenshot begins from the same deterministic root state.
            app.terminate()
            app.launch()
            dismissNotificationPromptIfNeeded()
            openTab(named: tab)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "release-accessibility-\(tab)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testChatBottomControlsAreVisibleAndHittable() {
        app.terminate()
        app.launchArguments += ["-qa-chat-composer"]
        app.launch()
        dismissNotificationPromptIfNeeded()

        let firstChat = app.buttons["chat.row.0"]
        XCTAssertTrue(firstChat.waitForExistence(timeout: 5), "Seeded chat should be available to UI tests.")
        XCTAssertTrue(firstChat.isHittable)
        firstChat.tap()

        for identifier in ["chat.attachments", "chat.camera", "chat.photoLibrary"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 5), "\(identifier) should be visible.")
            XCTAssertTrue(control.isHittable, "\(identifier) should have an unobstructed hit target.")
        }

        XCTAssertFalse(app.buttons["chat.search"].exists, "The removed composer search control must not leave a hidden tap target.")

        let message = app.textFields["Message"]
        XCTAssertTrue(message.waitForExistence(timeout: 2))
        message.tap()
        message.typeText("App Review control test")

        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 2), "Send should replace auxiliary actions once text is entered.")
        XCTAssertTrue(send.isHittable)
        send.tap()
    }

    func testSettingsBackReturnsFromRootRoute() {
        verifySettingsBack(launchArgument: "-qa-settings-back")
    }

    func testSettingsBackDismissesSheetRoute() {
        verifySettingsBack(launchArgument: "-qa-settings-sheet-back")
    }

    func testAccountRouteRemainsPresented() {
        app.terminate()
        app.launchArguments += ["-qa-settings-back"]
        app.launchEnvironment["ONEWAY_API_BASE_URL"] = "http://127.0.0.1:1"
        app.launch()
        dismissNotificationPromptIfNeeded()

        let account = app.buttons["settings.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()

        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 3))
        let openedAt = Date()
        while Date().timeIntervalSince(openedAt) < 30 {
            XCTAssertTrue(app.navigationBars["Account"].exists, "Account route popped without an intentional Back action.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        XCTAssertTrue(app.buttons["account.retry"].waitForExistence(timeout: 3), "An offline account refresh must stay open and offer Retry.")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5), "Foregrounding must preserve the Account route.")

        app.navigationBars["Account"].buttons.firstMatch.tap()
        XCTAssertTrue(account.waitForExistence(timeout: 3), "Back must return to the existing Settings page.")
    }

    func testInviteFriendRouteRemainsPresented() {
        app.terminate()
        app.launchArguments += ["-qa-settings-back"]
        app.launch()
        dismissNotificationPromptIfNeeded()

        let invite = app.buttons["settings.row.Invite a friend"]
        for _ in 0..<5 where !invite.exists {
            app.swipeUp()
        }
        XCTAssertTrue(invite.waitForExistence(timeout: 5))
        invite.tap()

        XCTAssertTrue(app.navigationBars["Add Contact"].waitForExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(app.navigationBars["Add Contact"].exists, "Invite a friend must not dismiss or exit after opening.")
        XCTAssertEqual(app.state, .runningForeground, "Opening Invite a friend must not terminate the app.")
    }

    func testDeleteAccountIsDirectlyAvailableAndStartsAfterConfirmation() {
        app.terminate()
        app.launchArguments += ["-qa-delete-account"]
        app.launch()
        dismissNotificationPromptIfNeeded()

        let delete = app.buttons["oneWayHub.deleteAccount"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete Account must appear directly in the plus page.")
        XCTAssertTrue(delete.isHittable)
        XCTAssertEqual(delete.label, "Delete Account")
        delete.tap()

        let confirmation = app.staticTexts["Permanently delete your OneWay account?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2), "Delete Account should use one standard confirmation and never route through a Burn flow.")
        let confirmDelete = app.sheets.buttons["Delete Account"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 2))
        confirmDelete.tap()

        XCTAssertTrue(
            app.alerts["Unable to Delete Account"].waitForExistence(timeout: 5),
            "After confirmation, deletion must call the server immediately; the offline UI test backend should return a retryable error."
        )
        XCTAssertFalse(app.staticTexts["Burn My OneWay Account"].exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(delete.waitForExistence(timeout: 2), "A failed deletion must leave the account UI available for retry.")
    }

    func testKeypadKeyboardCanBeDismissedWithoutTrappingControls() {
        app.terminate()
        app.launchArguments += ["-qa-keypad"]
        app.launch()
        dismissNotificationPromptIfNeeded()

        let field = app.textFields["OneWay ID, OneWay number, or phone number"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "The native keyboard toolbar must expose Done.")
        done.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2))

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        app.swipeDown()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 3), "A downward gesture must dismiss interactively.")

        let oneKey = app.buttons["Digit 1"]
        if !oneKey.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(oneKey.waitForExistence(timeout: 3))
        XCTAssertTrue(oneKey.isHittable, "Custom keypad controls must remain reachable by scrolling after dismissal.")
        oneKey.tap()
        XCTAssertTrue(field.value as? String == "1" || field.value as? String == "@1")
    }

    func testNewMessageReferenceFlowIsCompleteAndInteractive() {
        app.terminate()
        app.launchArguments += ["-qa-new-message", "-qa-new-message-reference"]
        app.launch()
        dismissNotificationPromptIfNeeded()

        XCTAssertTrue(app.staticTexts["New Message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OneWay Results"].exists)
        XCTAssertTrue(app.staticTexts["Marcus Reed"].exists)
        XCTAssertTrue(app.buttons["Add Contact"].isHittable)
        XCTAssertTrue(app.buttons["Message"].isHittable)
        let eraseAfterRead = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Erase After Read")
        ).firstMatch
        XCTAssertTrue(eraseAfterRead.isHittable)
        XCTAssertTrue(app.buttons["1 min"].isHittable)
        XCTAssertTrue(app.staticTexts["Recent Conversations"].exists)
        XCTAssertTrue(app.staticTexts["Ava Chen"].exists)
        XCTAssertTrue(app.staticTexts["Jordan Ellis"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "new-message-reference"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func verifySettingsBack(launchArgument: String) {
        app.terminate()
        app.launchArguments += [launchArgument]
        app.launch()
        dismissNotificationPromptIfNeeded()

        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Settings Back button should be visible.")
        XCTAssertTrue(back.isHittable, "Settings Back button should have an unobstructed 44-point hit target.")
        back.tap()

        XCTAssertTrue(app.staticTexts["Chats"].waitForExistence(timeout: 5), "Back should return to the immediately preceding Chats screen.")
        XCTAssertFalse(back.exists, "Settings should close after one tap without duplicating the prior screen.")
    }

    private func openTab(named title: String) {
        let control = tabControl(named: title)
        if control.waitForExistence(timeout: 2) {
            control.tap()
        } else {
            XCTFail("Could not find tab \(title).")
        }
    }

    private func tabControl(named title: String) -> XCUIElement {
        let labels = title == "Home"
            ? ["Home", "Open Quantum", "Open OneWay Quantum"]
            : [title, "Open \(title)"]
        return app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func dismissNotificationPromptIfNeeded() {
        let deny = app.alerts.buttons["Don’t Allow"]
        if deny.waitForExistence(timeout: 2) { deny.tap() }
    }
}
