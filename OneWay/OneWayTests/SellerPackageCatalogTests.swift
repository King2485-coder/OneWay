import XCTest
@testable import CipherChat

final class SellerPackageCatalogTests: XCTestCase {
    func testCatalogIdentifiersAreUniqueAndComplete() {
        let packages = SellerPackageCatalog.defaultPackages

        XCTAssertEqual(packages.count, 14)
        XCTAssertEqual(Set(packages.map(\.id)).count, packages.count)
        XCTAssertEqual(Set(packages.map(\.code)).count, packages.count)
        XCTAssertEqual(Set(packages.compactMap(\.appStoreProductId)).count, packages.count)
        XCTAssertTrue(packages.allSatisfy { $0.appStoreProductId?.isEmpty == false })
    }

    func testCatalogOrderIsStable() {
        let packages = SellerPackageCatalog.defaultPackages
        XCTAssertEqual(packages.map(\.sortOrder), packages.map(\.sortOrder).sorted())
    }

    func testEveryPackageGrantMatchesItsConfiguredCapacity() {
        for package in SellerPackageCatalog.defaultPackages {
            switch package.packageType {
            case .productSlot, .productBundle:
                XCTAssertEqual(package.grantedEntitlementType, .productSlot, package.code)
                XCTAssertEqual(package.grantedCapacityQuantity, package.quantity ?? -1, package.code)
            case .shopSlot, .shopBundle:
                XCTAssertEqual(package.grantedEntitlementType, .shopSlot, package.code)
                XCTAssertEqual(package.grantedCapacityQuantity, package.quantity ?? -1, package.code)
            case .unlimitedProducts:
                XCTAssertEqual(package.grantedEntitlementType, .unlimitedProducts, package.code)
                XCTAssertEqual(package.grantedCapacityQuantity, 1, package.code)
            case .sellerPro:
                XCTAssertEqual(package.grantedEntitlementType, .sellerPro, package.code)
                XCTAssertEqual(package.grantedCapacityQuantity, 1, package.code)
            }
        }
    }

    func testSwiftCatalogMatchesBackendCommercialConfiguration() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("server/src/services/sellerMonetization.ts")
        let backendSource = try String(contentsOf: sourceURL, encoding: .utf8)

        for package in SellerPackageCatalog.defaultPackages {
            XCTAssertTrue(backendSource.contains("id: \"\(package.id)\""), package.id)
            XCTAssertTrue(backendSource.contains("code: \"\(package.code)\""), package.code)
            XCTAssertTrue(
                backendSource.contains("appStoreProductId: \"\(package.appStoreProductId ?? "")\""),
                package.code
            )
        }
    }
}
