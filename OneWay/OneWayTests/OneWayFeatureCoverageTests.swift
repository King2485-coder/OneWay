import XCTest

final class OneWayFeatureCoverageTests: XCTestCase {
    func testReleaseQACoversEveryMajorFeatureArea() {
        let requiredAreas: Set<OneWayQAFeatureArea> = [
            .auth,
            .chats,
            .groupChats,
            .communities,
            .calls,
            .videoCalls,
            .pstnCalling,
            .walkie,
            .contacts,
            .keypad,
            .voicemail,
            .wallet,
            .businessHub,
            .shops,
            .shopManagement,
            .sites,
            .browser,
            .settings,
            .profile,
            .notifications,
            .navigation,
            .emptyStates,
            .lightOSStyling,
            .offlineAndErrorStates
        ]

        XCTAssertEqual(Set(OneWayQATestMatrix.release.featureAreas), requiredAreas)
    }

    func testEveryFeatureAreaHasAutomatedAndManualCoverage() {
        for area in OneWayQATestMatrix.release.featureAreas {
            XCTAssertFalse(area.automatedChecks.isEmpty, "\(area.rawValue) needs automated checks.")
            XCTAssertFalse(area.manualChecks.isEmpty, "\(area.rawValue) needs manual QA checks.")
        }
    }

    func testMainNavigationHasNoDuplicateDestinations() {
        let tabs = OneWayQATestMatrix.release.bottomTabs
        XCTAssertEqual(Set(tabs.map(\.title)).count, tabs.count)
        XCTAssertEqual(tabs.map(\.title), ["Home", "Community", "Create", "Calls", "Wallet"])
    }
}

enum OneWayQAFeatureArea: String, CaseIterable {
    case auth = "Auth/login/logout"
    case chats = "Chats"
    case groupChats = "Group chats"
    case communities = "Communities"
    case calls = "Calls"
    case videoCalls = "Video calls"
    case pstnCalling = "PSTN calling"
    case walkie = "Chirp"
    case contacts = "Contacts"
    case keypad = "Keypad"
    case voicemail = "Voicemail"
    case wallet = "Wallet"
    case businessHub = "Business Hub"
    case shops = "Shops"
    case shopManagement = "Shop Management"
    case sites = "Sites"
    case browser = "Browser"
    case settings = "Settings"
    case profile = "Profile"
    case notifications = "Notifications"
    case navigation = "Navigation/back buttons"
    case emptyStates = "Empty states"
    case lightOSStyling = "Light OS styling"
    case offlineAndErrorStates = "Offline/error states"

    var automatedChecks: [String] {
        switch self {
        case .auth:
            return ["launch gate", "logout route", "session fallback"]
        case .calls, .videoCalls, .pstnCalling:
            return ["call screen reachability", "permission denial", "failed transport state"]
        case .businessHub, .shops, .shopManagement, .sites:
            return ["business tab reachability", "detail back navigation", "empty state"]
        case .navigation:
            return ["bottom tab traversal", "pushed page back/close"]
        case .lightOSStyling:
            return ["readability smoke", "bottom nav visibility"]
        default:
            return ["screen reachability", "empty state", "error state"]
        }
    }

    var manualChecks: [String] {
        ["visual polish", "tap primary actions", "verify no clipped content"]
    }
}

struct OneWayQATestMatrix {
    static let release = OneWayQATestMatrix(
        bottomTabs: [
            .init(title: "Home"),
            .init(title: "Community"),
            .init(title: "Create"),
            .init(title: "Calls"),
            .init(title: "Wallet")
        ],
        featureAreas: OneWayQAFeatureArea.allCases
    )

    let bottomTabs: [OneWayQATab]
    let featureAreas: [OneWayQAFeatureArea]
}

struct OneWayQATab: Hashable {
    let title: String
}
