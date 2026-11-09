import Foundation
import LibSignalClient

public protocol DeviceIdentityService {
    func publicIdentity() throws -> Data
}

public protocol PreKeyService {
    func publicBundle(for deviceID: UInt32) throws -> PublicPreKeyEnvelope
}

public protocol SessionService {
    func hasSession(with address: ProtocolAddress) throws -> Bool
}

public protocol EnvelopeEncryptor {
    func encrypt(_ plaintext: Data, for address: ProtocolAddress) throws -> Data
}

public protocol EnvelopeDecryptor {
    func decrypt(_ ciphertext: Data, from address: ProtocolAddress) throws -> Data
}

public struct PublicPreKeyEnvelope: Codable, Equatable {
    public let deviceID: UInt32
    public let registrationID: UInt32
    public let identityPublicKey: Data
    public let signedPreKeyPublic: Data
    public let signedPreKeySignature: Data
    public let kyberPreKeyPublic: Data
    public let kyberPreKeySignature: Data

    public init(
        deviceID: UInt32,
        registrationID: UInt32,
        identityPublicKey: Data,
        signedPreKeyPublic: Data,
        signedPreKeySignature: Data,
        kyberPreKeyPublic: Data,
        kyberPreKeySignature: Data
    ) {
        self.deviceID = deviceID
        self.registrationID = registrationID
        self.identityPublicKey = identityPublicKey
        self.signedPreKeyPublic = signedPreKeyPublic
        self.signedPreKeySignature = signedPreKeySignature
        self.kyberPreKeyPublic = kyberPreKeyPublic
        self.kyberPreKeySignature = kyberPreKeySignature
    }
}

/// Production-facing code may depend on this boundary, never on libsignal concrete types.
/// The Phase 1B.5 target remains test-only and is not part of the OneWay app target.
public enum OneWayCryptoAdmission {
    public static let pinnedVersion = "v0.106.0"
    public static let pinnedCommit = "fc90b90fa2b9c37822fa47ba0e0dcdf387a0c071"
}
