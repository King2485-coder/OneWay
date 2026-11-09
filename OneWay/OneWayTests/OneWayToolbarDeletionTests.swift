import XCTest
@testable import CipherChat

@MainActor
final class OneWayToolbarDeletionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OneWayToolbarDeletionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEveryDefaultCallShortcutCanBeRemovedAndStaysRemoved() {
        let defaultsFeatures: [OneWayFeature] = [
            .favorites, .recents, .chirp, .contacts, .keypad, .voicemail
        ]

        for feature in defaultsFeatures {
            defaults.removePersistentDomain(forName: suiteName)
            let userID = "remove-\(feature.rawValue)"
            let store = OneWayToolbarPreferencesStore(userID: userID, defaults: defaults)
            let slot = try! XCTUnwrap(
                store.slots(for: .calls).first { $0.feature == feature }
            )

            XCTAssertEqual(store.remove(slotID: slot.id, in: .calls), feature)
            XCTAssertEqual(store.slots(for: .calls).count, 5)
            XCTAssertFalse(store.contains(feature, in: .calls))

            let relaunchedStore = OneWayToolbarPreferencesStore(
                userID: userID,
                defaults: defaults
            )
            XCTAssertEqual(relaunchedStore.slots(for: .calls).count, 5)
            XCTAssertFalse(relaunchedStore.contains(feature, in: .calls))

            XCTAssertTrue(relaunchedStore.add(feature, to: .calls))
            XCTAssertTrue(relaunchedStore.contains(feature, in: .calls))
            XCTAssertEqual(relaunchedStore.slots(for: .calls).count, 6)
        }
    }

    func testRemovalCanReduceToolbarToOneButCannotRemoveFinalShortcut() {
        let store = OneWayToolbarPreferencesStore(
            userID: "minimum-count",
            defaults: defaults
        )

        for slot in Array(store.slots(for: .calls).prefix(5)) {
            XCTAssertNotNil(store.remove(slotID: slot.id, in: .calls))
        }

        let finalSlot = try! XCTUnwrap(store.slots(for: .calls).first)
        XCTAssertEqual(store.slots(for: .calls).count, 1)
        XCTAssertNil(store.remove(slotID: finalSlot.id, in: .calls))
        XCTAssertEqual(store.slots(for: .calls), [finalSlot])
    }

    func testRemovedShortcutCanBeAddedBackWithoutDuplicates() {
        let store = OneWayToolbarPreferencesStore(
            userID: "add-back",
            defaults: defaults
        )
        let recents = try! XCTUnwrap(
            store.slots(for: .calls).first { $0.feature == .recents }
        )

        XCTAssertEqual(store.remove(slotID: recents.id, in: .calls), .recents)
        XCTAssertTrue(store.add(.recents, to: .calls))
        XCTAssertFalse(store.add(.recents, to: .calls))
        XCTAssertEqual(
            store.slots(for: .calls).filter { $0.feature == .recents }.count,
            1
        )
    }

    func testRemovalOnlyChangesSharedCallLayout() {
        let store = OneWayToolbarPreferencesStore(
            userID: "shared-call-layout",
            defaults: defaults
        )
        let mainBefore = store.slots(for: .main)
        let shopsBefore = store.slots(for: .shops)
        let favorites = try! XCTUnwrap(
            store.slots(for: .calls).first { $0.feature == .favorites }
        )

        XCTAssertEqual(store.remove(slotID: favorites.id, in: .calls), .favorites)
        XCTAssertFalse(store.contains(.favorites, in: .calls))
        XCTAssertEqual(store.slots(for: .main), mainBefore)
        XCTAssertEqual(store.slots(for: .shops), shopsBefore)
    }
}
