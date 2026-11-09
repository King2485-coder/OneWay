import XCTest
@testable import CipherChat

final class CommunityRepositorySharedStateTests: XCTestCase {
    func testKingAndTwinblixxShareOneCommunityAndMessages() async throws {
        let report = try await CommunityRepository.shared.runTwoAccountSharedStateTest(clearExisting: true)

        for step in report.steps {
            print("[CommunityRepositorySharedStateTests] \(step.passed ? "PASS" : "FAIL") \(step.title): \(step.detail)")
        }

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.steps.filter(\.passed).count, report.steps.count)
        XCTAssertTrue(report.steps.contains { $0.title == "Duplicate blocked" && $0.passed })
        XCTAssertTrue(report.steps.contains { $0.title == "Member count" && $0.detail.contains("2") })
    }
}
