import Foundation

// MARK: - Enums

enum DomainStatus: String, Codable, CaseIterable {
    case active
    case expired
    case suspended
    case pending
}

enum SiteMode: String, Codable, CaseIterable, Identifiable {
    case nocode
    case code
    case ai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nocode: return "No-code"
        case .code:   return "Code"
        case .ai:     return "AI"
        }
    }

    var hint: String {
        switch self {
        case .nocode: return "Stack blocks, no syntax."
        case .code:   return "Hand-write HTML / CSS / JS."
        case .ai:     return "Describe it, AI builds it."
        }
    }
}

enum PaymentMethod: String, Codable, CaseIterable {
    case appleIAP = "apple_iap"
    case stripe
    case crypto
}

enum PaymentStatus: String, Codable, CaseIterable {
    case pending
    case completed
    case failed
    case refunded
}

// MARK: - Records

struct OneWayDomain: Identifiable, Equatable, Codable {
    let id: UUID
    let userId: UUID
    let slug: String
    let status: DomainStatus
    let expiresAt: Date
    let renewalPriceUSD: Decimal
    let siteId: UUID?
    let paymentMethod: PaymentMethod?
    let paymentReference: String?
    let createdAt: Date
    let updatedAt: Date

    var fullDomain: String { "\(slug).oneway.app" }
}

struct OneWaySite: Identifiable, Equatable, Codable {
    let id: UUID
    let userId: UUID
    let domainSlug: String
    var title: String
    var description: String
    var mode: SiteMode
    var htmlContent: String
    var blocks: [SiteBlock]
    var published: Bool
    let createdAt: Date
    let updatedAt: Date
}

struct OneWayPayment: Identifiable, Equatable, Codable {
    let id: UUID
    let userId: UUID
    let domainSlug: String?
    let amountUSD: Decimal
    let method: PaymentMethod
    let providerRef: String?
    let status: PaymentStatus
    let createdAt: Date
}

// MARK: - Site builder block model

enum SiteBlock: Equatable, Codable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case image(url: URL, alt: String?)
    case link(href: URL, label: String)
    case divider
    case html(raw: String)

    enum CodingKeys: String, CodingKey {
        case type, level, text, url, alt, href, label, raw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "heading":
            self = .heading(
                level: try c.decode(Int.self, forKey: .level),
                text: try c.decode(String.self, forKey: .text)
            )
        case "paragraph":
            self = .paragraph(text: try c.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                url: try c.decode(URL.self, forKey: .url),
                alt: try c.decodeIfPresent(String.self, forKey: .alt)
            )
        case "link":
            self = .link(
                href: try c.decode(URL.self, forKey: .href),
                label: try c.decode(String.self, forKey: .label)
            )
        case "divider":
            self = .divider
        case "html":
            self = .html(raw: try c.decode(String.self, forKey: .raw))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown block type \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heading(let level, let text):
            try c.encode("heading", forKey: .type)
            try c.encode(level, forKey: .level)
            try c.encode(text, forKey: .text)
        case .paragraph(let text):
            try c.encode("paragraph", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let url, let alt):
            try c.encode("image", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(alt, forKey: .alt)
        case .link(let href, let label):
            try c.encode("link", forKey: .type)
            try c.encode(href, forKey: .href)
            try c.encode(label, forKey: .label)
        case .divider:
            try c.encode("divider", forKey: .type)
        case .html(let raw):
            try c.encode("html", forKey: .type)
            try c.encode(raw, forKey: .raw)
        }
    }
}

// MARK: - Slug validation (mirrors Domain table CHECK + RESERVED list on the client)

enum SlugValidation: Equatable {
    case valid(String)
    case empty
    case tooShort
    case tooLong
    case invalidCharacters
    case reserved

    var errorMessage: String? {
        switch self {
        case .valid:             return nil
        case .empty:             return "Pick a name first."
        case .tooShort:          return "At least 2 characters."
        case .tooLong:           return "Max 32 characters."
        case .invalidCharacters: return "Letters, numbers, and dashes only."
        case .reserved:          return "That name is reserved."
        }
    }
}

enum SlugValidator {
    static let reserved: Set<String> = [
        "home", "directory", "admin", "api", "www",
        "oneway", "support", "help", "docs", "mail"
    ]

    static let regex = try! NSRegularExpression(
        pattern: "^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$"
    )

    static func validate(_ raw: String) -> SlugValidation {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return .empty }
        if s.count < 2 { return .tooShort }
        if s.count > 32 { return .tooLong }
        if reserved.contains(s) { return .reserved }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard regex.firstMatch(in: s, range: range) != nil else { return .invalidCharacters }
        return .valid(s)
    }
}
