import XCTest
@testable import CipherChat

final class QuantumBrowserViewportTests: XCTestCase {
    func testWebsiteDoesNotReserveAnEstimatedToolbarInset() {
        XCTAssertEqual(QuantumBrowserViewportPolicy.additionalWebContentInset, 0)
    }

    func testBrowserChromeUsesContainerSafeAreaInsets() {
        XCTAssertTrue(QuantumBrowserViewportPolicy.usesContainerSafeAreaInsets)
    }
}
