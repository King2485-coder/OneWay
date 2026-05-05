import Foundation

protocol KeyService {
    func ensureIdentityKeys() async throws
    func localIdentityFingerprint() async throws -> String
}
