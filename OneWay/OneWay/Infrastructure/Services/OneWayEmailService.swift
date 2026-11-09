import Foundation

final class OneWayEmailService {
    static let shared = OneWayEmailService()
    private let api = APIClient.shared

    private struct MailboxEnvelope: Decodable { let mailbox: OneWayEmailMailbox? }
    private struct MessageEnvelope: Decodable { let message: OneWayEmailMessage }
    private struct ListEnvelope: Decodable { let messages: [OneWayEmailMessage]; let nextCursor: String? }
    private struct ThreadEnvelope: Decodable { let id: String; let messages: [OneWayEmailMessage] }
    private struct ClaimBody: Encodable { let address: String? }
    private struct MessageBody: Encodable {
        let id: String?
        let threadId: String?
        let draftId: String?
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let bodyText: String
        let bodyHtml: String?
        let inReplyTo: String?
        let references: [String]?
    }
    private struct UpdateBody: Encodable { let folder: String?; let isRead: Bool?; let isStarred: Bool? }
    private struct BlockBody: Encodable { let sender: String }
    private struct BlockResponse: Decodable { let blocked: Bool; let sender: String }

    func mailbox() async throws -> OneWayEmailMailbox? {
        let envelope: MailboxEnvelope = try await api.get("api/email/mailbox")
        return envelope.mailbox
    }

    func claim(address: String? = nil) async throws -> OneWayEmailMailbox {
        let envelope: MailboxEnvelope = try await api.post("api/email/mailbox/claim", body: ClaimBody(address: address))
        guard let mailbox = envelope.mailbox else { throw APIClientError.emptyResponse }
        return mailbox
    }

    func messages(folder: OneWayEmailFolder, query: String = "") async throws -> [OneWayEmailMessage] {
        var queryItems = [URLQueryItem(name: "folder", value: folder.rawValue)]
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        let envelope: ListEnvelope = try await api.get("api/email/messages", queryItems: queryItems)
        return envelope.messages
    }

    func thread(_ id: String) async throws -> [OneWayEmailMessage] {
        let envelope: ThreadEnvelope = try await api.get("api/email/threads/\(id)")
        return envelope.messages
    }

    func send(_ draft: OneWayEmailDraft) async throws -> OneWayEmailMessage {
        let body = messageBody(draft, draftId: draft.id)
        let envelope: MessageEnvelope = try await api.post("api/email/send", body: body)
        return envelope.message
    }

    func saveDraft(_ draft: OneWayEmailDraft) async throws -> OneWayEmailMessage {
        let envelope: MessageEnvelope = try await api.post("api/email/drafts", body: messageBody(draft, draftId: nil))
        return envelope.message
    }

    func update(_ message: OneWayEmailMessage, folder: OneWayEmailFolder? = nil, isRead: Bool? = nil, isStarred: Bool? = nil) async throws -> OneWayEmailMessage {
        let envelope: MessageEnvelope = try await api.patch("api/email/messages/\(message.id)", body: UpdateBody(folder: folder?.rawValue, isRead: isRead, isStarred: isStarred))
        return envelope.message
    }

    func block(_ sender: String) async throws {
        let _: BlockResponse = try await api.post("api/email/blocked-senders", body: BlockBody(sender: sender))
    }

    func attachmentURL(_ attachment: OneWayEmailAttachment) -> URL {
        api.baseURL.appendingPathComponent("api/email/attachments/\(attachment.id)")
    }

    func download(_ attachment: OneWayEmailAttachment) async throws -> URL {
        let url = attachmentURL(attachment)
        var request = URLRequest(url: url)
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let authorization = DevAuth.authorizationHeader(forPath: path, baseURL: api.baseURL)
            ?? AuthTokenStore.shared.authenticatedAuthorizationHeader()
        guard let authorization else { throw OneWayNetworkError.unauthorized }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIClientError.invalidResponse
        }
        let safeName = attachment.filename.replacingOccurrences(of: "/", with: "_")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneway-email-\(attachment.id)-\(safeName)")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func messageBody(_ draft: OneWayEmailDraft, draftId: String?) -> MessageBody {
        MessageBody(
            id: draft.id, threadId: draft.threadId, draftId: draftId,
            to: split(draft.to), cc: split(draft.cc), bcc: split(draft.bcc),
            subject: draft.subject, bodyText: draft.body, bodyHtml: nil,
            inReplyTo: nil, references: nil
        )
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
