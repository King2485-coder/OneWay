import Foundation

public enum EnvelopeEncodingError: Error { case oversized }

/// Narrow implementation of the already-approved OneWay RFC 8949 envelope.
/// It carries opaque libsignal ciphertext only; plaintext is never accepted.
public enum DeterministicSignalEnvelope {
    public static func encode(
        messageID: Data,
        senderDeviceID: UInt32,
        recipientDeviceID: UInt32,
        messageType: UInt8,
        ciphertext: Data
    ) throws -> Data {
        guard messageID.count == 16, ciphertext.count <= 1_048_576 else { throw EnvelopeEncodingError.oversized }
        // Five-entry integer-keyed map. Keys are already in deterministic encoded order.
        var out = Data([0xA5])
        appendUnsigned(0, to: &out); appendBytes(messageID, to: &out)
        appendUnsigned(1, to: &out); appendUnsigned(UInt64(senderDeviceID), to: &out)
        appendUnsigned(2, to: &out); appendUnsigned(UInt64(recipientDeviceID), to: &out)
        appendUnsigned(3, to: &out); appendUnsigned(UInt64(messageType), to: &out)
        appendUnsigned(4, to: &out); appendBytes(ciphertext, to: &out)
        return out
    }

    private static func appendUnsigned(_ value: UInt64, to data: inout Data) {
        appendMajor(0, value: value, to: &data)
    }

    private static func appendBytes(_ bytes: Data, to data: inout Data) {
        appendMajor(2, value: UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendMajor(_ major: UInt8, value: UInt64, to data: inout Data) {
        let prefix = major << 5
        switch value {
        case 0..<24: data.append(prefix | UInt8(value))
        case 24...0xFF: data.append(contentsOf: [prefix | 24, UInt8(value)])
        case 0x100...0xFFFF:
            data.append(prefix | 25); appendBigEndian(UInt16(value), to: &data)
        case 0x1_0000...0xFFFF_FFFF:
            data.append(prefix | 26); appendBigEndian(UInt32(value), to: &data)
        default:
            data.append(prefix | 27); appendBigEndian(value, to: &data)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}
