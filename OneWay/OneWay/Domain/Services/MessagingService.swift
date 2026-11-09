import Foundation
import Combine

struct ChatRealtimeEvent: Equatable {
    let chatID: UUID?
    let conversationID: String
    let message: ChatMessage?
}

@MainActor
protocol MessagingService {
    func fetchChats() async throws -> [ChatSummary]
    func fetchMessages(chatID: UUID) async throws -> [ChatMessage]
    func fetchPrivacySettings(chatID: UUID) async throws -> ConversationPrivacySettings
    func updatePrivacySettings(_ settings: ConversationPrivacySettings, chatID: UUID) async throws -> ConversationPrivacySettings
    func observeMessages(chatID: UUID) -> AsyncThrowingStream<ChatMessage, Error>
    func observeChatUpdates() -> AsyncThrowingStream<ChatRealtimeEvent, Error>
    func preconnectRealtime()
    func sendMessage(_ text: String, chatID: UUID) async throws -> ChatMessage?
    func sendMessage(_ text: String, chatID: UUID, disappearing: MessageDisappearingOverride) async throws -> ChatMessage?
    func sendMediaMessage(_ attachment: MessageAttachment, caption: String, chatID: UUID, disappearing: MessageDisappearingOverride) async throws -> ChatMessage?
    func retryMessage(messageID: UUID, chatID: UUID) async throws
    func startCall(chatID: UUID, type: CallType) async throws
    func react(_ emoji: String, messageID: UUID, chatID: UUID) async throws
    func deleteForMe(messageID: UUID, chatID: UUID) async throws
    func deleteForEveryone(messageID: UUID, chatID: UUID) async throws
    func editMessage(messageID: UUID, chatID: UUID, newText: String) async throws
    func pinMessage(messageID: UUID, chatID: UUID) async throws
    func starMessage(messageID: UUID, chatID: UUID) async throws
    func forwardMessage(messageID: UUID, fromChatID: UUID, toChatID: UUID) async throws
    func reply(to messageID: UUID, text: String, chatID: UUID) async throws -> ChatMessage?
}
