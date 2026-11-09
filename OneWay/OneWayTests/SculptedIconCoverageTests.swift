import XCTest
import UIKit
@testable import CipherChat

final class SculptedIconCoverageTests: XCTestCase {
    func testEveryNamedRoleHasLoadableArtwork() {
        for role in OneWayIconRole.allCases {
            guard let name = role.assetName else {
                XCTFail("No artwork assigned to \(role.rawValue)")
                continue
            }
            XCTAssertNotNil(UIImage(named: name), "Missing artwork: \(name)")
        }
        XCTAssertNotNil(UIImage(named: "OneWaySculptedPin"))
    }

    func testSmallControlsKeepDistinctMeanings() {
        let heart = OneWaySculptedCatalog.utilityAsset(for: "heart.fill")
        let star = OneWaySculptedCatalog.utilityAsset(for: "star.fill")
        XCTAssertNotEqual(heart?.name, star?.name)
        XCTAssertEqual(OneWayIconRole.resolve(systemName: "square.and.arrow.up"), .share)
        XCTAssertEqual(OneWayIconRole.resolve(systemName: "paperclip"), .attachments)
        XCTAssertEqual(OneWayIconRole.resolve(systemName: "circle.grid.3x3.fill"), .keypad)
    }

    func testDirectionalControlsDoNotPointTheSameWay() {
        let back = OneWaySculptedCatalog.utilityAsset(for: "chevron.left")
        let forward = OneWaySculptedCatalog.utilityAsset(for: "chevron.right")
        XCTAssertEqual(back?.name, forward?.name)
        XCTAssertEqual(back?.rotation, 0)
        XCTAssertEqual(forward?.rotation, 180)
        XCTAssertNotEqual(
            OneWaySculptedCatalog.utilityAsset(for: "chevron.up")?.rotation,
            OneWaySculptedCatalog.utilityAsset(for: "chevron.down")?.rotation
        )
    }
}
