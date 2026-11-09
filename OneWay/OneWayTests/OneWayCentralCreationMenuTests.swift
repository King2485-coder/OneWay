import XCTest
@testable import CipherChat

final class OneWayCentralCreationMenuTests: XCTestCase {
    func testLegacyHubDestinationsAreAbsent() {
        let destinations = OneWayHubDestinationRegistry.destinations()
        let visibleCopy = destinations.flatMap { [$0.title, $0.subtitle] }.joined(separator: " ").lowercased()

        let retiredShopHubName = ["seller", "studio"].joined(separator: " ")
        let retiredCreationHubName = ["creator", "hub"].joined(separator: " ")
        XCTAssertFalse(visibleCopy.contains(retiredShopHubName))
        XCTAssertFalse(visibleCopy.contains(retiredCreationHubName))
    }

    func testFormerHubActionsAreDirectlyAvailable() {
        let actionRoutes = Set(OneWayHubDestinationRegistry.destinations().compactMap { destination -> OneWayQuickAction? in
            guard case .action(let action) = destination.route else { return nil }
            return action
        })

        let required: Set<OneWayQuickAction> = [
            .newSite, .mySites, .createShop, .myShops, .editShop,
            .manageProducts, .addProduct, .shopOrders, .shopMessages,
            .shopAnalytics, .siteAnalytics, .oneWayAds, .sellerPayments,
            .shopPolicies, .shopLifecycle, .deleteShop, .uploadFile,
            .newCommunity, .createPost, .events
        ]
        XCTAssertTrue(required.isSubset(of: actionRoutes), "Missing direct actions: \(required.subtracting(actionRoutes))")
    }

    func testRestoredActionsHaveIntendedMetadataAndRoutes() {
        struct Expected {
            let title: String
            let category: OneWayHubCategory
            let iconRole: OneWayIconRole
            let searchTerm: String
        }

        let expected: [OneWayQuickAction: Expected] = [
            .editShop: .init(title: "Edit Shop", category: .manage, iconRole: .shopSettings, searchTerm: "storefront settings"),
            .events: .init(title: "Events", category: .create, iconRole: .calendar, searchTerm: "community events"),
            .shopMessages: .init(title: "Shop Messages", category: .manage, iconRole: .messages, searchTerm: "seller messages"),
            .addProduct: .init(title: "Add Product", category: .create, iconRole: .quickAdd, searchTerm: "new listing"),
            .sellerPayments: .init(title: "Seller Payments", category: .account, iconRole: .paymentSetup, searchTerm: "payouts")
        ]
        let destinations = OneWayHubDestinationRegistry.destinations()

        for (action, metadata) in expected {
            let matches = destinations.filter { $0.route == .action(action) }
            XCTAssertEqual(matches.count, 1, "Expected exactly one direct destination for \(action)")
            guard let destination = matches.first else { continue }
            XCTAssertEqual(destination.title, metadata.title)
            XCTAssertEqual(destination.category, metadata.category)
            XCTAssertEqual(destination.iconRole, metadata.iconRole)
            XCTAssertTrue(destination.matches(metadata.searchTerm), "\(action) must survive hub search")
        }
    }

    func testEveryHubRouteIsUnique() {
        let routes = OneWayHubDestinationRegistry.destinations().map(\.route)
        XCTAssertEqual(Set(routes).count, routes.count)
    }

    func testSellerActionsRequireShopOrRouteToCreation() {
        let sellerRoutes: [MarketplaceRoute] = [
            .editStore, .sellerMessages, .addProduct, .sellerPayments
        ]

        for route in sellerRoutes {
            XCTAssertEqual(
                OneWayShopNavigationPolicy.resolvedRoute(route, hasSellerShop: false),
                .createShop
            )
            XCTAssertEqual(
                OneWayShopNavigationPolicy.resolvedRoute(route, hasSellerShop: true),
                route
            )
        }
    }

    func testCentralMenuUsesRequestedSections() {
        XCTAssertEqual(Set(OneWayHubCategory.allCases), Set([.create, .manage, .promote, .account]))
    }
}
