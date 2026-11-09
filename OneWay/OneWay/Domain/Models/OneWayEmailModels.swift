import Foundation

struct OneWayEmailReadiness: Codable, Equatable {
    let ready: Bool
    let liveDeliveryEnabled: Bool
    let provider: String
    let domain: String
    let missing: [String]
    let dnsRequired: [String]
}

struct OneWayEmailMailbox: Codable, Identifiable, Equatable {
    let id: String
    let address: String
    let status: String
    let createdAt: String
    let readiness: OneWayEmailReadiness
}

struct OneWayEmailAttachment: Codable, Identifiable, Equatable {
    let id: String
    let filename: String
    let contentType: String
    let bytes: Int
}

struct OneWayEmailLabel: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let color: String
}

struct OneWayEmailMessage: Codable, Identifiable, Equatable {
    let id: String
    let threadId: String
    let providerMessageId: String?
    let direction: String
    let folder: String
    let from: [String]
    let to: [String]
    let cc: [String]
    let subject: String
    let bodyText: String
    let bodyHtml: String?
    let status: String
    let isRead: Bool
    let isStarred: Bool
    let spamScore: Double?
    let sentAt: String?
    let receivedAt: String?
    let createdAt: String
    let updatedAt: String
    let attachments: [OneWayEmailAttachment]
    let labels: [OneWayEmailLabel]?
}

enum OneWayEmailFolder: String, CaseIterable, Identifiable {
    case inbox, starred, sent, drafts, archive, trash, spam, all
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .inbox: return "tray.fill"
        case .starred: return "star.fill"
        case .sent: return "paperplane.fill"
        case .drafts: return "doc.text.fill"
        case .archive: return "archivebox.fill"
        case .trash: return "trash.fill"
        case .spam: return "exclamationmark.shield.fill"
        case .all: return "tray.2.fill"
        }
    }
}

struct OneWayEmailDraft: Equatable {
    var id: String? = nil
    var threadId: String? = nil
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
}
