import XCTest
@testable import CipherChat

@MainActor
final class OneWayAutomationPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OneWayAutomationPreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsAreSafe() {
        let store = OneWayAutomationPreferencesStore(defaults: defaults)

        XCTAssertFalse(store.actionButtonEnabled)
        XCTAssertEqual(store.primaryAction, .smartActionMenu)
        XCTAssertEqual(store.state(for: .drivingMode), .askFirst)
        XCTAssertEqual(store.state(for: .chirpPushToTalk), .askFirst)
        XCTAssertEqual(store.state(for: .favoriteContact), .askFirst)
        XCTAssertEqual(store.state(for: .navigation), .askFirst)
        XCTAssertEqual(store.state(for: .emergencyMode), .askFirst)
        XCTAssertEqual(store.state(for: .lockScreenAccess), .askFirst)
        XCTAssertEqual(store.state(for: .hapticConfirmation), .on)
    }

    func testAskFirstActionsRouteToSmartMenu() {
        let store = OneWayAutomationPreferencesStore(defaults: defaults)
        let router = OneWayActionRouter(store: store)

        XCTAssertEqual(router.safeAction(for: .startChirp), .smartActionMenu)
        XCTAssertEqual(router.safeAction(for: .callFavorite), .smartActionMenu)
        XCTAssertEqual(router.safeAction(for: .openNavigation), .smartActionMenu)
        XCTAssertEqual(router.safeAction(for: .emergencyMode), .smartActionMenu)
    }

    func testEnabledSensitiveActionRoutesDirectly() {
        let store = OneWayAutomationPreferencesStore(defaults: defaults)
        store.setState(.on, for: .chirpPushToTalk)
        let router = OneWayActionRouter(store: store)

        XCTAssertEqual(router.safeAction(for: .startChirp), .startChirp)
    }

    func testVehicleChoicesPersist() {
        let store = OneWayAutomationPreferencesStore(defaults: defaults)
        store.addVehicle(named: "Family Car")

        guard var vehicle = store.recognizedVehicles.first else {
            XCTFail("Expected vehicle")
            return
        }
        vehicle.drivingModeEnabled = true
        vehicle.behavior = .askForDestination
        vehicle.rememberChoice = true
        store.updateVehicle(vehicle)

        let reloaded = OneWayAutomationPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.recognizedVehicles.count, 1)
        XCTAssertEqual(reloaded.recognizedVehicles[0].name, "Family Car")
        XCTAssertTrue(reloaded.recognizedVehicles[0].drivingModeEnabled)
        XCTAssertEqual(reloaded.recognizedVehicles[0].behavior, .askForDestination)
        XCTAssertTrue(reloaded.recognizedVehicles[0].rememberChoice)
    }

}
