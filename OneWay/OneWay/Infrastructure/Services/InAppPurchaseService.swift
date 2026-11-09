import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

enum InAppPurchaseError: LocalizedError {
    case productUnavailable
    case purchaseCancelled
    case purchasePending
    case transactionUnverified

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "This subscription is not available yet. Check the StoreKit product setup and try again."
        case .purchaseCancelled:
            return "Purchase cancelled."
        case .purchasePending:
            return "Purchase is pending approval. Try adding the number again after approval."
        case .transactionUnverified:
            return "The App Store could not verify this purchase."
        }
    }
}

@MainActor
final class InAppPurchaseService {
    static let shared = InAppPurchaseService()

    static let extraNumbersProductID = "oneway.extra_numbers.monthly"

    private let client: APIClient
    private let isoFormatter = ISO8601DateFormatter()

    init(client: APIClient = .shared) {
        self.client = client
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func purchaseExtraNumbers() async throws {
        #if canImport(StoreKit)
        guard #available(iOS 15.0, *) else {
            throw InAppPurchaseError.productUnavailable
        }

        let products = try await StoreKit.Product.products(for: [Self.extraNumbersProductID])
        guard let product = products.first else {
            throw InAppPurchaseError.productUnavailable
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try verifiedTransaction(from: verification)
            try await sync(transaction: transaction)
            await transaction.finish()
        case .userCancelled:
            throw InAppPurchaseError.purchaseCancelled
        case .pending:
            throw InAppPurchaseError.purchasePending
        @unknown default:
            throw InAppPurchaseError.productUnavailable
        }
        #else
        throw InAppPurchaseError.productUnavailable
        #endif
    }

    func syncExtraNumbersEntitlement() async throws -> Bool {
        #if canImport(StoreKit)
        guard #available(iOS 15.0, *) else {
            return false
        }

        for await result in StoreKit.Transaction.currentEntitlements {
            let transaction = try verifiedTransaction(from: result)
            guard transaction.productID == Self.extraNumbersProductID else {
                continue
            }
            try await sync(transaction: transaction)
            return true
        }
        return false
        #else
        return false
        #endif
    }

    #if canImport(StoreKit)
    @available(iOS 15.0, *)
    private func verifiedTransaction(from result: StoreKit.VerificationResult<StoreKit.Transaction>) throws -> StoreKit.Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified:
            throw InAppPurchaseError.transactionUnverified
        }
    }

    @available(iOS 15.0, *)
    private func sync(transaction: StoreKit.Transaction) async throws {
        struct Request: Encodable {
            let productId: String
            let transactionId: String
            let originalTransactionId: String?
            let expiresAt: String?
        }

        struct Response: Decodable {
            let transactionId: String
        }

        let expiresAt = transaction.expirationDate.map { isoFormatter.string(from: $0) }
        let request = Request(
            productId: transaction.productID,
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            expiresAt: expiresAt
        )

        let _: Response = try await client.post("api/subscriptions/app-store/sync", body: request)
    }
    #endif
}
