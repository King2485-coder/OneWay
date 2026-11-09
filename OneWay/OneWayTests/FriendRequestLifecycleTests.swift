import XCTest

final class FriendRequestLifecycleTests: XCTestCase {
    func testIncomingAndOutgoingQueriesUseTheCorrectSideOfTheFriendship() {
        var ledger = FriendRequestLedger()
        let request = ledger.sendRequest(from: "user-a", to: "user-b")

        XCTAssertEqual(request.status, .created)
        XCTAssertEqual(ledger.incomingRequests(for: "user-b").map(\.recipientUserID), ["user-b"])
        XCTAssertEqual(ledger.incomingRequests(for: "user-b").map(\.requesterUserID), ["user-a"])
        XCTAssertEqual(ledger.outgoingRequests(for: "user-a").map(\.requesterUserID), ["user-a"])
        XCTAssertEqual(ledger.incomingRequests(for: "user-a"), [])
    }

    func testRealtimeFriendRequestEventTargetsOnlyTheRecipient() {
        let event = FriendRequestRealtimeEvent(
            name: "friend.request.received",
            requesterUserID: "user-a",
            recipientUserID: "user-b"
        )

        XCTAssertTrue(event.shouldDeliver(to: "user-b"))
        XCTAssertFalse(event.shouldDeliver(to: "user-a"))
        XCTAssertFalse(event.shouldDeliver(to: "user-c"))
    }

    func testDuplicateAndReversePendingRequestsAreBlocked() {
        var ledger = FriendRequestLedger()

        XCTAssertEqual(ledger.sendRequest(from: "user-a", to: "user-b").status, .created)
        XCTAssertEqual(ledger.sendRequest(from: "user-a", to: "user-b").status, .outgoingAlreadyExists)
        XCTAssertEqual(ledger.sendRequest(from: "user-b", to: "user-a").status, .incomingAlreadyExists)
    }

    func testAcceptUpdatesBothUsersAcceptedFriendLists() {
        var ledger = FriendRequestLedger()
        let request = ledger.sendRequest(from: "user-a", to: "user-b")

        XCTAssertTrue(ledger.accept(friendshipID: request.friendshipID, by: "user-b"))

        XCTAssertEqual(ledger.incomingRequests(for: "user-b"), [])
        XCTAssertEqual(ledger.acceptedFriendIDs(for: "user-a"), ["user-b"])
        XCTAssertEqual(ledger.acceptedFriendIDs(for: "user-b"), ["user-a"])
    }

    func testDeclineRemovesThePendingRequestFromReceiverInbox() {
        var ledger = FriendRequestLedger()
        let request = ledger.sendRequest(from: "user-a", to: "user-b")

        XCTAssertTrue(ledger.decline(friendshipID: request.friendshipID, by: "user-b"))

        XCTAssertEqual(ledger.incomingRequests(for: "user-b"), [])
        XCTAssertEqual(ledger.outgoingRequests(for: "user-a"), [])
        XCTAssertEqual(ledger.acceptedFriendIDs(for: "user-a"), [])
    }
}

private struct FriendRequestRealtimeEvent {
    let name: String
    let requesterUserID: String
    let recipientUserID: String

    func shouldDeliver(to socketUserID: String) -> Bool {
        name == "friend.request.received" &&
        socketUserID == recipientUserID &&
        socketUserID != requesterUserID
    }
}

private struct FriendRequestLedger {
    private var rows: [FriendshipRow] = []

    mutating func sendRequest(from requesterUserID: String, to recipientUserID: String) -> SendFriendRequestResult {
        guard requesterUserID != recipientUserID else {
            return SendFriendRequestResult(friendshipID: "", status: .selfRequest)
        }

        let pairKey = FriendshipRow.pairKey(requesterUserID, recipientUserID)
        if let existing = rows.first(where: { $0.pairKey == pairKey && $0.status == .pending }) {
            let status: SendFriendRequestStatus = existing.requesterUserID == requesterUserID
                ? .outgoingAlreadyExists
                : .incomingAlreadyExists
            return SendFriendRequestResult(friendshipID: existing.id, status: status)
        }

        if let existing = rows.first(where: { $0.pairKey == pairKey && $0.status == .accepted }) {
            return SendFriendRequestResult(friendshipID: existing.id, status: .alreadyFriends)
        }

        let row = FriendshipRow(
            id: "friendship-\(rows.count + 1)",
            requesterUserID: requesterUserID,
            recipientUserID: recipientUserID,
            status: .pending
        )
        rows.append(row)
        return SendFriendRequestResult(friendshipID: row.id, status: .created)
    }

    func incomingRequests(for userID: String) -> [FriendshipRow] {
        rows.filter { $0.recipientUserID == userID && $0.status == .pending }
    }

    func outgoingRequests(for userID: String) -> [FriendshipRow] {
        rows.filter { $0.requesterUserID == userID && $0.status == .pending }
    }

    func acceptedFriendIDs(for userID: String) -> [String] {
        rows
            .filter { $0.status == .accepted && ($0.requesterUserID == userID || $0.recipientUserID == userID) }
            .map { $0.requesterUserID == userID ? $0.recipientUserID : $0.requesterUserID }
    }

    mutating func accept(friendshipID: String, by recipientUserID: String) -> Bool {
        guard let index = rows.firstIndex(where: {
            $0.id == friendshipID &&
            $0.recipientUserID == recipientUserID &&
            $0.status == .pending
        }) else {
            return false
        }

        rows[index].status = .accepted
        return true
    }

    mutating func decline(friendshipID: String, by recipientUserID: String) -> Bool {
        guard let index = rows.firstIndex(where: {
            $0.id == friendshipID &&
            $0.recipientUserID == recipientUserID &&
            $0.status == .pending
        }) else {
            return false
        }

        rows[index].status = .declined
        return true
    }
}

private struct SendFriendRequestResult: Equatable {
    let friendshipID: String
    let status: SendFriendRequestStatus
}

private enum SendFriendRequestStatus {
    case created
    case outgoingAlreadyExists
    case incomingAlreadyExists
    case alreadyFriends
    case selfRequest
}

private struct FriendshipRow: Equatable {
    let id: String
    let requesterUserID: String
    let recipientUserID: String
    let pairKey: String
    var status: FriendshipRowStatus

    init(id: String, requesterUserID: String, recipientUserID: String, status: FriendshipRowStatus) {
        self.id = id
        self.requesterUserID = requesterUserID
        self.recipientUserID = recipientUserID
        self.pairKey = Self.pairKey(requesterUserID, recipientUserID)
        self.status = status
    }

    static func pairKey(_ firstUserID: String, _ secondUserID: String) -> String {
        [firstUserID, secondUserID].sorted().joined(separator: "#")
    }
}

private enum FriendshipRowStatus {
    case pending
    case accepted
    case declined
}
