import Foundation

final class StubKeyService: KeyService {
    func ensureIdentityKeys() async throws {
        // Stub for future key generation + device binding.
    }

    func localIdentityFingerprint() async throws -> String {
        "STUB-FINGERPRINT-0000"
    }
}
