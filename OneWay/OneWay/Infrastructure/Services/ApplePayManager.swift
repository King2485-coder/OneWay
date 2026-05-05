import Foundation
#if canImport(PassKit)
import PassKit
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ApplePayManager: NSObject {
    static let shared = ApplePayManager()

    #if canImport(PassKit)
    private var completion: ((Bool) -> Void)?
    #endif

    func startApplePay(for product: ShopProduct, completion: @escaping (Bool) -> Void = { _ in }) {
        #if canImport(PassKit)
        guard PKPaymentAuthorizationViewController.canMakePayments() else {
            completion(false)
            return
        }

        let request = PKPaymentRequest()
        request.merchantIdentifier = "merchant.oneway.app"
        request.supportedNetworks = [.visa, .masterCard, .amex]
        request.merchantCapabilities = .capability3DS
        request.countryCode = "US"
        request.currencyCode = "USD"
        request.paymentSummaryItems = [
            PKPaymentSummaryItem(label: product.name, amount: NSDecimalNumber(value: product.price))
        ]

        self.completion = completion
        guard let controller = PKPaymentAuthorizationViewController(paymentRequest: request) else {
            completion(false)
            return
        }
        controller.delegate = self
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .present(controller, animated: true)
        #else
        completion(false)
        #endif
    }

    func openExternalCheckout(url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

#if canImport(PassKit)
extension ApplePayManager: PKPaymentAuthorizationViewControllerDelegate {
    func paymentAuthorizationViewController(_ controller: PKPaymentAuthorizationViewController, didAuthorizePayment payment: PKPayment, handler completion: @escaping (PKPaymentAuthorizationResult) -> Void) {
        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
        self.completion?(true)
    }

    func paymentAuthorizationViewControllerDidFinish(_ controller: PKPaymentAuthorizationViewController) {
        controller.dismiss(animated: true)
    }
}
#endif
