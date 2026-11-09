import XCTest
@testable import CipherChat

final class ShopPoliciesTests: XCTestCase {
    func testExampleTemplateContainsEveryRequiredEditableSection() {
        XCTAssertEqual(ShopPolicyTemplate.fields.count, 10)
        for (_, keyPath) in ShopPolicyTemplate.fields {
            XCTAssertFalse(ShopPolicyTemplate.example[keyPath: keyPath].isEmpty)
        }
    }

    func testPolicyDocumentsKeepDraftAndPublishedContentSeparate() throws {
        var draft = ShopPolicyTemplate.example
        draft.customPolicy = "Draft only"
        let published = ShopPolicyTemplate.example
        let document = ShopPolicyDocument(
            sections: draft,
            publishedSections: published,
            version: 2,
            status: "published",
            createdAt: nil,
            updatedAt: nil,
            publishedAt: nil
        )
        XCTAssertEqual(document.sections?.customPolicy, "Draft only")
        XCTAssertNotEqual(document.sections, document.publishedSections)
        XCTAssertEqual(document.version, 2)
    }

    func testShopPoliciesRouteKeepsSelectedShopIdentity() {
        let shopID = UUID()
        XCTAssertEqual(MarketplaceRoute.shopPolicies(shopID), .shopPolicies(shopID))
        XCTAssertNotEqual(MarketplaceRoute.shopPolicies(shopID), .shopPolicies(nil))
    }
}
