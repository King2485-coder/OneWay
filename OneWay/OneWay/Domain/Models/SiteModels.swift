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
    let userId: String
    let domainSlug: String
    var title: String
    var description: String
    var mode: SiteMode
    var htmlContent: String
    var blocks: [SiteBlock]
    var aiPrompt: String
    var publishedHtml: String
    var publishedAt: String?
    let createdAt: Date
    let updatedAt: Date

    var published: Bool {
        guard let publishedAt, !publishedAt.isEmpty else { return false }
        return !publishedHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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

struct SiteGalleryImage: Equatable, Codable {
    var url: String
    var alt: String
    var caption: String
}

struct SiteServiceItem: Equatable, Codable {
    var title: String
    var detail: String
}

struct SiteFAQItem: Equatable, Codable {
    var question: String
    var answer: String
}

enum SiteBlock: Equatable, Codable {
    case hero(eyebrow: String, title: String, subtitle: String)
    case text(text: String)
    case button(label: String, url: String)
    case contact(name: String, email: String, phone: String)
    case hours(hours: String)
    case callText(label: String, phoneNumber: String)
    case photo(url: String, alt: String, caption: String)
    case gallery(title: String, images: [SiteGalleryImage])
    case testimonial(quote: String, name: String, role: String)
    case services(title: String, items: [SiteServiceItem])
    case faq(title: String, items: [SiteFAQItem])
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case image(url: URL, alt: String?)
    case link(href: URL, label: String)
    case divider
    case html(raw: String)

    enum CodingKeys: String, CodingKey {
        case type, level, text, url, alt, caption, href, label, raw
        case eyebrow, title, subtitle, name, email, phone, hours, phoneNumber
        case images, quote, role, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hero":
            self = .hero(
                eyebrow: try c.decodeIfPresent(String.self, forKey: .eyebrow) ?? "Built on OneWay",
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Welcome",
                subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
            )
        case "text":
            self = .text(text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "button":
            self = .button(
                label: try c.decodeIfPresent(String.self, forKey: .label) ?? "Learn more",
                url: try c.decodeIfPresent(String.self, forKey: .url) ?? ""
            )
        case "contact":
            self = .contact(
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                email: try c.decodeIfPresent(String.self, forKey: .email) ?? "",
                phone: try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
            )
        case "hours":
            self = .hours(hours: try c.decodeIfPresent(String.self, forKey: .hours) ?? "Monday-Friday, 9 AM-5 PM")
        case "callText":
            self = .callText(
                label: try c.decodeIfPresent(String.self, forKey: .label) ?? "Call or text us",
                phoneNumber: try c.decodeIfPresent(String.self, forKey: .phoneNumber) ?? ""
            )
        case "photo":
            self = .photo(
                url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
                alt: try c.decodeIfPresent(String.self, forKey: .alt) ?? "",
                caption: try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
            )
        case "gallery":
            self = .gallery(
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Gallery",
                images: try c.decodeIfPresent([SiteGalleryImage].self, forKey: .images) ?? []
            )
        case "testimonial":
            self = .testimonial(
                quote: try c.decodeIfPresent(String.self, forKey: .quote) ?? "Add a customer quote here.",
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Customer name",
                role: try c.decodeIfPresent(String.self, forKey: .role) ?? ""
            )
        case "services":
            self = .services(
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Services",
                items: try c.decodeIfPresent([SiteServiceItem].self, forKey: .items) ?? []
            )
        case "faq":
            self = .faq(
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Questions",
                items: try c.decodeIfPresent([SiteFAQItem].self, forKey: .items) ?? []
            )
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
        case .hero(let eyebrow, let title, let subtitle):
            try c.encode("hero", forKey: .type)
            try c.encode(eyebrow, forKey: .eyebrow)
            try c.encode(title, forKey: .title)
            try c.encode(subtitle, forKey: .subtitle)
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .button(let label, let url):
            try c.encode("button", forKey: .type)
            try c.encode(label, forKey: .label)
            try c.encode(url, forKey: .url)
        case .contact(let name, let email, let phone):
            try c.encode("contact", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(email, forKey: .email)
            try c.encode(phone, forKey: .phone)
        case .hours(let hours):
            try c.encode("hours", forKey: .type)
            try c.encode(hours, forKey: .hours)
        case .callText(let label, let phoneNumber):
            try c.encode("callText", forKey: .type)
            try c.encode(label, forKey: .label)
            try c.encode(phoneNumber, forKey: .phoneNumber)
        case .photo(let url, let alt, let caption):
            try c.encode("photo", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(alt, forKey: .alt)
            try c.encode(caption, forKey: .caption)
        case .gallery(let title, let images):
            try c.encode("gallery", forKey: .type)
            try c.encode(title, forKey: .title)
            try c.encode(images, forKey: .images)
        case .testimonial(let quote, let name, let role):
            try c.encode("testimonial", forKey: .type)
            try c.encode(quote, forKey: .quote)
            try c.encode(name, forKey: .name)
            try c.encode(role, forKey: .role)
        case .services(let title, let items):
            try c.encode("services", forKey: .type)
            try c.encode(title, forKey: .title)
            try c.encode(items, forKey: .items)
        case .faq(let title, let items):
            try c.encode("faq", forKey: .type)
            try c.encode(title, forKey: .title)
            try c.encode(items, forKey: .items)
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

// MARK: - OneWay website builder quality standard

struct WebsiteQualityResult: Equatable {
    let missingItems: [String]

    var isReadyToPublish: Bool { missingItems.isEmpty }
}

enum WebsiteQualityStandard {
    static let almostReadyMessage = "Your site is almost ready. Finish these items before publishing."

    static func validateSite(
        title: String,
        description: String,
        mode: SiteMode,
        html: String,
        blocks: [SiteBlock]
    ) -> WebsiteQualityResult {
        var missing: [String] = []
        let cleanTitle = normalized(title)
        let cleanDescription = normalized(description)

        if cleanTitle.isEmpty || isGenericTitle(cleanTitle) {
            missing.append("Add a real business or site name.")
        }

        if cleanDescription.isEmpty || isPlaceholderText(cleanDescription) {
            missing.append("Add an SEO description that explains the business.")
        }

        switch mode {
        case .nocode:
            missing.append(contentsOf: validateNoCodeBlocks(blocks, title: cleanTitle, description: cleanDescription))
        case .ai where !blocks.isEmpty:
            missing.append(contentsOf: validateNoCodeBlocks(blocks, title: cleanTitle, description: cleanDescription))
        case .code, .ai:
            missing.append(contentsOf: validateHTML(html))
        }

        return WebsiteQualityResult(missingItems: unique(missing))
    }

    static func validateStorefront(_ storefront: Storefront) -> WebsiteQualityResult {
        var missing: [String] = []
        let business = storefront.business
        let products = business.products + storefront.sections.flatMap(\.items)
        let visibleProducts = products.filter { $0.isVisible ?? true }
        let hasContact = [business.contactEmail, business.phone, business.website]
            .compactMap { $0 }
            .contains { !normalized($0).isEmpty }
        let hasHero = storefront.sections.contains { section in
            section.type == .hero && !normalized(section.title).isEmpty && !isPlaceholderText(section.title)
        }
        let hasAbout = !normalized(business.description).isEmpty
            || !normalized(business.sellerStory ?? "").isEmpty
            || storefront.sections.contains { $0.type == .about && hasSubstantialText($0.body ?? $0.title) }
        let hasCTA = storefront.sections.contains { section in
            section.type == .cta && !normalized(section.ctaLabel ?? section.title).isEmpty
        } || hasContact
        let hasProfessionalVisual = business.logoURL != nil || business.coverImageURL != nil || true

        if normalized(business.name).isEmpty || isGenericTitle(business.name) {
            missing.append("Add a business name.")
        }
        if !hasProfessionalVisual {
            missing.append("Add a logo or keep the OneWay professional placeholder.")
        }
        if normalized(business.category).isEmpty || business.category == "General" {
            missing.append("Choose a business category.")
        }
        if !hasHero {
            missing.append("Complete the hero section.")
        }
        if !hasAbout {
            missing.append("Complete the About or description section.")
        }
        if !hasContact {
            missing.append("Enable a contact method.")
        }
        if visibleProducts.isEmpty && !storefront.sections.contains(where: { $0.type == .services && !$0.items.isEmpty }) {
            missing.append("Add at least one product/service or a clear business purpose.")
        }
        if !hasCTA {
            missing.append("Add a real CTA button or contact action.")
        }
        if storefront.policy == nil && !storefront.policiesReady {
            missing.append("Add Privacy/Terms or shop policies.")
        }
        if storefront.paymentsEnabled && !storefront.paymentsReady {
            missing.append("Finish payment setup or switch checkout to Contact Seller.")
        }

        for section in storefront.sections {
            if isPlaceholderText(section.title) || isPlaceholderText(section.body ?? "") {
                missing.append("Replace unfinished placeholder copy.")
                break
            }
        }

        return WebsiteQualityResult(missingItems: unique(missing + storefront.publishChecklist))
    }

    private static func validateNoCodeBlocks(
        _ blocks: [SiteBlock],
        title: String,
        description: String
    ) -> [String] {
        var missing: [String] = []

        if blocks.isEmpty {
            return ["Add professional page sections."]
        }

        let hasHero = blocks.contains { block in
            if case .hero(_, let title, let subtitle) = block {
                return hasSubstantialText(title) && hasSubstantialText(subtitle)
                    && !isPlaceholderText(title) && !isPlaceholderText(subtitle)
            }
            return false
        }
        let hasAbout = hasSubstantialText(description)
            || blocks.contains { block in
                switch block {
                case .text(let text), .paragraph(let text):
                    return hasSubstantialText(text) && !isPlaceholderText(text)
                case .services(let title, let items):
                    return hasSubstantialText(title) && items.contains { hasSubstantialText($0.detail) && !isPlaceholderText($0.detail) }
                default:
                    return false
                }
            }
        let hasContact = blocks.contains { block in
            switch block {
            case .contact(_, let email, let phone):
                return isUsableContact(email) || isUsablePhone(phone)
            case .callText(_, let phoneNumber):
                return isUsablePhone(phoneNumber)
            case .button(_, let url):
                return isUsableURL(String(describing: url))
            case .link(let url, _):
                return isUsableURL(url.absoluteString)
            default:
                return false
            }
        }
        let hasOffer = blocks.contains { block in
            switch block {
            case .services(_, let items):
                return items.contains { hasSubstantialText($0.title) && hasSubstantialText($0.detail) && !isPlaceholderText($0.detail) }
            case .text(let text), .paragraph(let text):
                let lower = text.lowercased()
                return hasSubstantialText(text) && (lower.contains("service") || lower.contains("product") || lower.contains("offer") || lower.contains("book"))
            default:
                return false
            }
        }
        let hasCTA = blocks.contains { block in
            switch block {
            case .button(let label, let url):
                return hasSubstantialText(label) && !isPlaceholderText(label) && isUsableURL(url)
            case .callText(let label, let phoneNumber):
                return hasSubstantialText(label) && isUsablePhone(phoneNumber)
            case .contact(_, let email, let phone):
                return isUsableContact(email) || isUsablePhone(phone)
            default:
                return false
            }
        }
        let hasSupport = blocks.contains { block in
            if case .faq(_, let items) = block {
                return items.contains { hasSubstantialText($0.question) && hasSubstantialText($0.answer) && !isPlaceholderText($0.answer) }
            }
            return false
        } || hasContact

        if !hasHero { missing.append("Complete the hero section.") }
        if !hasAbout { missing.append("Complete the About or description section.") }
        if !hasContact { missing.append("Enable a contact method.") }
        if !hasOffer { missing.append("Add at least one product/service or a clear business purpose.") }
        if !hasCTA { missing.append("Add a real CTA button.") }
        if !hasSupport { missing.append("Add a Support or FAQ section.") }

        if blocks.contains(where: blockHasEmptyRequiredContent) {
            missing.append("Remove empty placeholder sections.")
        }
        if blocks.contains(where: blockHasPlaceholderCopy) {
            missing.append("Replace unfinished placeholder copy.")
        }

        return missing
    }

    private static func validateHTML(_ html: String) -> [String] {
        let cleanHTML = normalized(html)
        let lower = cleanHTML.lowercased()
        var missing: [String] = []

        if cleanHTML.isEmpty {
            return ["Add complete page content."]
        }
        if !(lower.contains("<html") || lower.contains("<body") || lower.contains("<main") || lower.contains("<section") || lower.contains("<h1")) {
            missing.append("Add a complete responsive HTML page.")
        }
        if !lower.contains("<meta name=\"viewport\"") {
            missing.append("Add mobile responsive viewport metadata.")
        }
        if !lower.contains("<title") || !lower.contains("meta name=\"description\"") {
            missing.append("Add SEO title and description.")
        }
        if !lower.contains("href=") {
            missing.append("Add real navigation, contact, or CTA links.")
        }
        if lower.contains("lorem ipsum") || lower.contains("example.com") || lower.contains("placeholder") {
            missing.append("Replace unfinished placeholder copy.")
        }
        if lower.contains("checkout") && !(lower.contains("payment") || lower.contains("contact seller") || lower.contains("mailto:") || lower.contains("tel:")) {
            missing.append("Configure payments or show Contact Seller instead of fake checkout.")
        }

        return missing
    }

    private static func blockHasEmptyRequiredContent(_ block: SiteBlock) -> Bool {
        switch block {
        case .hero(_, let title, let subtitle):
            return normalized(title).isEmpty || normalized(subtitle).isEmpty
        case .text(let text), .paragraph(let text):
            return normalized(text).isEmpty
        case .button(let label, let url):
            return normalized(label).isEmpty || !isUsableURL(url)
        case .contact(_, let email, let phone):
            return !isUsableContact(email) && !isUsablePhone(phone)
        case .callText(_, let phoneNumber):
            return !isUsablePhone(phoneNumber)
        case .services(_, let items):
            return items.isEmpty || items.contains { normalized($0.title).isEmpty || normalized($0.detail).isEmpty }
        case .faq(_, let items):
            return items.isEmpty || items.contains { normalized($0.question).isEmpty || normalized($0.answer).isEmpty }
        case .photo(let url, _, _):
            return normalized(url).isEmpty
        case .gallery(_, let images):
            return images.isEmpty || images.allSatisfy { normalized($0.url).isEmpty }
        case .testimonial(let quote, let name, _):
            return normalized(quote).isEmpty || normalized(name).isEmpty
        case .heading(_, let text), .link(_, let text):
            return normalized(text).isEmpty
        case .image, .divider, .html:
            return false
        case .hours(let hours):
            return normalized(hours).isEmpty
        }
    }

    private static func blockHasPlaceholderCopy(_ block: SiteBlock) -> Bool {
        switch block {
        case .hero(let eyebrow, let title, let subtitle):
            return [eyebrow, title, subtitle].contains(where: isPlaceholderText)
        case .text(let text), .paragraph(let text), .heading(_, let text), .html(let text):
            return isPlaceholderText(text)
        case .button(let label, let url):
            return isPlaceholderText(label) || isPlaceholderURL(url)
        case .contact(let name, let email, _):
            return isPlaceholderText(name) || email.lowercased().contains("example.com")
        case .callText(let label, _), .hours(let label):
            return isPlaceholderText(label)
        case .photo(let url, let alt, let caption):
            return isPlaceholderURL(url) || [alt, caption].contains(where: isPlaceholderText)
        case .gallery(let title, let images):
            return isPlaceholderText(title) || images.contains { isPlaceholderURL($0.url) || isPlaceholderText($0.caption) }
        case .testimonial(let quote, let name, let role):
            return [quote, name, role].contains(where: isPlaceholderText)
        case .services(let title, let items):
            return isPlaceholderText(title) || items.contains { isPlaceholderText($0.title) || isPlaceholderText($0.detail) }
        case .faq(let title, let items):
            return isPlaceholderText(title) || items.contains { isPlaceholderText($0.question) || isPlaceholderText($0.answer) }
        case .image(let url, let alt):
            return isPlaceholderURL(url.absoluteString) || isPlaceholderText(alt ?? "")
        case .link(let url, let label):
            return isPlaceholderURL(url.absoluteString) || isPlaceholderText(label)
        case .divider:
            return false
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasSubstantialText(_ value: String) -> Bool {
        normalized(value).count >= 12
    }

    private static func isGenericTitle(_ value: String) -> Bool {
        let lower = normalized(value).lowercased()
        return lower.isEmpty || ["my oneway site", "my store", "my shop", "new product", "welcome"].contains(lower)
    }

    private static func isPlaceholderText(_ value: String) -> Bool {
        let lower = normalized(value).lowercased()
        if lower.isEmpty { return false }
        return lower.contains("lorem ipsum")
            || lower.contains("add your")
            || lower.contains("add a ")
            || lower.contains("tell visitors")
            || lower.contains("tell people")
            || lower.contains("describe the")
            || lower.contains("write a short")
            || lower.contains("customer name")
            || lower.contains("happy customer")
            || lower.contains("gallery image")
            || lower.contains("first highlight")
            || lower.contains("second highlight")
            || lower.contains("third highlight")
            || lower.contains("main offer")
            || lower.contains("new product")
            || lower == "description"
    }

    private static func isPlaceholderURL(_ value: String) -> Bool {
        let lower = normalized(value).lowercased()
        return lower == "https://" || lower == "http://" || lower.contains("example.com")
    }

    private static func isUsableURL(_ value: String) -> Bool {
        let lower = normalized(value).lowercased()
        return lower.hasPrefix("https://")
            || lower.hasPrefix("http://")
            || lower.hasPrefix("mailto:")
            || lower.hasPrefix("tel:")
            || lower.hasPrefix("oneway:")
            || lower.hasPrefix("#")
            || lower.hasPrefix("/")
    }

    private static func isUsableContact(_ value: String) -> Bool {
        let lower = normalized(value).lowercased()
        return lower.contains("@") && !lower.contains("example.com")
    }

    private static func isUsablePhone(_ value: String) -> Bool {
        let lower = normalized(value).lowercased()
        return value.filter(\.isNumber).count >= 7 || lower.contains("oneway")
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
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
