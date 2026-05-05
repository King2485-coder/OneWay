import Foundation

final class StubStorageService: StorageService {
    private var messages: [UUID: [EncryptedMessage]] = [:]

    func storeCiphertext(_ message: EncryptedMessage) {
        var existing = messages[message.chatID] ?? []
        existing.append(message)
        messages[message.chatID] = existing
    }

    func loadCiphertext(chatID: UUID) -> [EncryptedMessage] {
        messages[chatID] ?? []
    }

    func deleteCiphertext(messageID: UUID) {
        messages.keys.forEach { key in
            messages[key] = messages[key]?.filter { $0.id != messageID }
        }
    }
}
