import XCTest

final class OneWayServiceFailureTests: XCTestCase {
    func testMockNetworkClientReturnsOfflineFailure() async {
        let client = MockQANetworkClient(mode: .offline)

        do {
            _ = try await client.fetch(path: "/api/chats")
            XCTFail("Offline client should throw.")
        } catch MockQAError.offline {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Expected offline error, got \(error).")
        }
    }

    func testPermissionDeniedStatesHaveUserFacingRecoveryCopy() {
        let permissions: [MockPermissionState] = [
            .cameraDenied,
            .microphoneDenied,
            .contactsDenied,
            .notificationsDenied
        ]

        for permission in permissions {
            XCTAssertFalse(permission.recoveryTitle.isEmpty)
            XCTAssertTrue(permission.recoveryMessage.contains("Settings") || permission.recoveryMessage.contains("permission"))
        }
    }

    func testSeededMockDataContainsReleaseSmokeFixtures() {
        let store = MockQASeedStore()
        store.seedChats()
        store.seedCalls()
        store.seedBusiness()

        XCTAssertGreaterThanOrEqual(store.chats.count, 3)
        XCTAssertGreaterThanOrEqual(store.calls.count, 3)
        XCTAssertGreaterThanOrEqual(store.businessItems.count, 3)
    }
}

enum MockQAError: Error, Equatable {
    case offline
    case serverFailure
}

struct MockQANetworkClient {
    enum Mode {
        case online
        case offline
        case serverFailure
    }

    let mode: Mode

    func fetch(path: String) async throws -> Data {
        switch mode {
        case .online:
            return Data(path.utf8)
        case .offline:
            throw MockQAError.offline
        case .serverFailure:
            throw MockQAError.serverFailure
        }
    }
}

enum MockPermissionState {
    case cameraDenied
    case microphoneDenied
    case contactsDenied
    case notificationsDenied

    var recoveryTitle: String {
        switch self {
        case .cameraDenied: return "Camera Permission Needed"
        case .microphoneDenied: return "Microphone Permission Needed"
        case .contactsDenied: return "Contacts Permission Needed"
        case .notificationsDenied: return "Notifications Permission Needed"
        }
    }

    var recoveryMessage: String {
        switch self {
        case .cameraDenied:
            return "Enable camera permission in Settings to use QR scanning and video calls."
        case .microphoneDenied:
            return "Enable microphone permission in Settings to use Calls, Chirp, and voice notes."
        case .contactsDenied:
            return "Enable contacts permission in Settings to import your address book."
        case .notificationsDenied:
            return "Enable notification permission in Settings to receive chats, calls, and business updates."
        }
    }
}

final class MockQASeedStore {
    private(set) var chats: [String] = []
    private(set) var calls: [String] = []
    private(set) var businessItems: [String] = []

    func seedChats() {
        chats = ["Arianna", "Cargo King Team", "Tucson Families"]
    }

    func seedCalls() {
        calls = ["OW-654321", "@rocky", "+1 520 555 0123"]
    }

    func seedBusiness() {
        businessItems = ["OneWay Shops", "OneWay Sites", "Shop Management"]
    }
}
