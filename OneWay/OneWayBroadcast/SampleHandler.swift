import Foundation
import LiveKit

final class SampleHandler: LKSampleHandler, @unchecked Sendable {
    override var enableLogging: Bool { true }

    override func connectionDidClose(error: Error?) {
        guard let error else {
            super.connectionDidClose(error: nil)
            return
        }

        let userFacingError = NSError(
            domain: "com.king.OneWay.broadcast",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Screen sharing stopped because the OneWay call is no longer connected.",
                NSUnderlyingErrorKey: error,
            ]
        )
        super.connectionDidClose(error: userFacingError)
    }
}
