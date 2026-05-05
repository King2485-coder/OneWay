import Foundation

enum MessageCachePolicy: String {
    case metadataOnly
    case encryptedPayloadOnly
}

protocol LocalPersistenceStore {
    func saveChatSummaries(_ chats: [ChatSummary])
    func loadChatSummaries() -> [ChatSummary]
    func saveMessages(_ messages: [ChatMessage], for chatID: UUID)
    func loadMessages(for chatID: UUID) -> [ChatMessage]
    func clearAll()
}

final class LocalPersistence {
    let cachePolicy: MessageCachePolicy

    private let store: LocalPersistenceStore

    init(cachePolicy: MessageCachePolicy = .metadataOnly, store: LocalPersistenceStore = InMemoryLocalStore()) {
        self.cachePolicy = cachePolicy
        self.store = store
    }

    func cacheChatSummaries(_ chats: [ChatSummary]) {
        store.saveChatSummaries(chats)
    }

    func readChatSummaries() -> [ChatSummary] {
        store.loadChatSummaries()
    }

    func cacheMessages(_ messages: [ChatMessage], for chatID: UUID) {
        guard cachePolicy != .metadataOnly else {
            return
        }
        store.saveMessages(messages, for: chatID)
    }

    func readMessages(for chatID: UUID) -> [ChatMessage] {
        guard cachePolicy != .metadataOnly else {
            return []
        }
        return store.loadMessages(for: chatID)
    }

    func clear() {
        store.clearAll()
    }
}

final class InMemoryLocalStore: LocalPersistenceStore {
    private var chats: [ChatSummary] = []
    private var messagesByChatID: [UUID: [ChatMessage]] = [:]

    func saveChatSummaries(_ chats: [ChatSummary]) {
        self.chats = chats
    }

    func loadChatSummaries() -> [ChatSummary] {
        chats
    }

    func saveMessages(_ messages: [ChatMessage], for chatID: UUID) {
        messagesByChatID[chatID] = messages
    }

    func loadMessages(for chatID: UUID) -> [ChatMessage] {
        messagesByChatID[chatID] ?? []
    }

    func clearAll() {
        chats.removeAll()
        messagesByChatID.removeAll()
    }
}
