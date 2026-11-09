import XCTest
@testable import CipherChat

final class ShopActionRegressionTests: XCTestCase {
    func testBlankOptionalFieldsProduceSafeCreationValues() {
        XCTAssertEqual(
            ShopCreationRequirements.usableName(requested: "   ", profileName: "Taylor"),
            "Taylor's Shop"
        )
        XCTAssertEqual(
            ShopCreationRequirements.usableName(requested: "   ", profileName: "   "),
            "My OneWay Shop"
        )
        XCTAssertEqual(ShopCreationRequirements.usableCategory(""), "General")
    }

    func testRequestedShopNameIsPreserved() {
        XCTAssertEqual(
            ShopCreationRequirements.usableName(requested: "  Many Sites  ", profileName: "Taylor"),
            "Many Sites"
        )
    }

    func testSellerToolsUsesExistingRoutes() {
        XCTAssertEqual(ShopCreationRequirements.sellerToolsDestination(shopCount: 0), .createShop)
        XCTAssertEqual(ShopCreationRequirements.sellerToolsDestination(shopCount: 1), .manageShop)
        XCTAssertEqual(ShopCreationRequirements.sellerToolsDestination(shopCount: 2), .myShops)
    }

    func testOneLevelPopPreservesPrecedingSupportRoute() {
        var path: [MarketplaceRoute] = [.marketplaceSupport, .manageShop]
        path.removeLast()
        XCTAssertEqual(path, [.marketplaceSupport])
    }
}
