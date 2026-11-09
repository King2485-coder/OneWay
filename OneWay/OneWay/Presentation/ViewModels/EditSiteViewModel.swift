import Foundation
import Combine

enum SiteTemplate: String, CaseIterable, Identifiable {
    case service
    case portfolio
    case restaurant
    case event

    var id: String { rawValue }

    var title: String {
        switch self {
        case .service: return "Local Service"
        case .portfolio: return "Portfolio"
        case .restaurant: return "Food / Cafe"
        case .event: return "Event"
        }
    }

    var subtitle: String {
        switch self {
        case .service: return "Hero, trust copy, hours, contact."
        case .portfolio: return "Story, highlights, booking CTA."
        case .restaurant: return "Menu intro, hours, call button."
        case .event: return "Announcement, details, RSVP link."
        }
    }

    var icon: String {
        switch self {
        case .service: return "briefcase.fill"
        case .portfolio: return "photo.on.rectangle.angled"
        case .restaurant: return "fork.knife"
        case .event: return "calendar.badge.clock"
        }
    }
}

@MainActor
final class EditSiteViewModel: ObservableObject {
    @Published var title: String = "My OneWay Site"
    @Published var siteDescription: String = ""
    @Published var mode: SiteMode = .nocode
    @Published var html: String = ""
    @Published var aiPrompt: String = ""
    @Published var blocks: [SiteBlock] = []
    @Published private(set) var publishedAt: String?
    @Published private(set) var publishedHtml: String = ""
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var isPublishing = false
    @Published private(set) var isGenerating = false
    @Published private(set) var uploadingBlockIndex: Int?
    @Published private(set) var uploadingGalleryImageKey: String?
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    let domainSlug: String
    private var loadedSite: OneWaySite?

    private let siteService: SiteService

    init(siteService: SiteService, domainSlug: String) {
        self.siteService = siteService
        self.domainSlug = domainSlug
    }

    var fullDomain: String { "\(domainSlug).oneway.app" }
    var isPublished: Bool { publishedAt != nil && !publishedHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var liveURL: URL? { URL(string: "https://\(fullDomain)") }
    var qualityResult: WebsiteQualityResult {
        WebsiteQualityStandard.validateSite(
            title: title,
            description: siteDescription,
            mode: mode,
            html: html,
            blocks: blocks
        )
    }
    var publishChecklist: [String] { qualityResult.missingItems }
    var canPublish: Bool {
        qualityResult.isReadyToPublish
    }

    var validationMessage: String? {
        publishChecklist.first
    }

    var previewHTML: String {
        switch mode {
        case .nocode:
            return SiteRenderer.render(blocks: blocks, title: title, description: siteDescription)
        case .ai:
            return blocks.isEmpty ? html : SiteRenderer.render(blocks: blocks, title: title, description: siteDescription)
        case .code:
            return html
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let site = try await siteService.site(forSlug: domainSlug) {
                loadedSite = site
                title = site.title
                siteDescription = site.description
                mode = site.mode
                html = site.htmlContent
                blocks = site.blocks
                aiPrompt = site.aiPrompt
                publishedAt = site.publishedAt
                publishedHtml = site.publishedHtml
            } else if blocks.isEmpty {
                blocks = Self.defaultBlocks(title: title, description: siteDescription)
            }
        } catch {
            errorMessage = "Couldn't load this site."
        }
    }

    func save(thenPublish: Bool = false) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let draft = SiteDraft(
                domainSlug: domainSlug,
                title: title,
                description: siteDescription,
                mode: mode,
                htmlContent: html,
                blocks: blocks,
                aiPrompt: aiPrompt
            )
            let site = try await siteService.upsert(site: draft)
            apply(site)
            errorMessage = nil
            infoMessage = thenPublish ? nil : "Draft saved."

            if thenPublish {
                guard canPublish else {
                    errorMessage = WebsiteQualityStandard.almostReadyMessage + "\n• " + publishChecklist.joined(separator: "\n• ")
                    return
                }
                isPublishing = true
                defer { isPublishing = false }
                let published = try await siteService.publish(site: site)
                apply(published)
                infoMessage = "\(fullDomain) is live."
            }
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func generateWithAI() async {
        guard !aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Describe the site first."
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        do {
            _ = try await siteService.generateAISite(
                prompt: aiPrompt,
                domainSlug: domainSlug,
                title: title
            )
            applyGeneratedSiteBlocks()
            try await saveGeneratedDraft()
            errorMessage = nil
            infoMessage = "AI built a complete draft. Review the sections, images, and products, then publish."
        } catch {
            applyGeneratedSiteBlocks()
            do {
                try await saveGeneratedDraft()
                errorMessage = nil
                infoMessage = "AI was unavailable, so OneWay built a polished starter site you can publish or edit."
            } catch {
                errorMessage = "AI generation failed, but your local draft is ready to review."
            }
        }
    }

    private func applyGeneratedSiteBlocks() {
        let generated = Self.aiGeneratedBlocks(prompt: aiPrompt, domainSlug: domainSlug, title: title)
        title = generated.title
        siteDescription = generated.description
        blocks = generated.blocks
        html = ""
        mode = .ai
    }

    private func saveGeneratedDraft() async throws {
        let draft = SiteDraft(
            domainSlug: domainSlug,
            title: title,
            description: siteDescription,
            mode: mode,
            htmlContent: html,
            blocks: blocks,
            aiPrompt: aiPrompt
        )
        let site = try await siteService.upsert(site: draft)
        apply(site)
    }

    func applyStarterTemplate() {
        html = Self.starterTemplate(title: title, description: siteDescription, domain: fullDomain)
        mode = .code
        infoMessage = "Starter page added. Edit anything, then preview or publish."
    }

    func addBlock(_ block: SiteBlock) {
        blocks.append(block)
    }

    func applyTemplate(_ template: SiteTemplate) {
        blocks = Self.blocks(for: template, title: title, description: siteDescription)
        mode = .nocode
        infoMessage = "\(template.title) template added. Customize the sections, then publish."
    }

    func removeBlock(at index: Int) {
        guard blocks.indices.contains(index) else { return }
        blocks.remove(at: index)
    }

    func moveBlock(from index: Int, direction: Int) {
        let newIndex = index + direction
        guard blocks.indices.contains(index), blocks.indices.contains(newIndex) else { return }
        blocks.swapAt(index, newIndex)
    }

    func moveBlocks(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let sortedOffsets = offsets.sorted()
        guard !sortedOffsets.isEmpty else { return }

        var next = blocks
        let moving = sortedOffsets.compactMap { next.indices.contains($0) ? next[$0] : nil }
        for index in sortedOffsets.reversed() where next.indices.contains(index) {
            next.remove(at: index)
        }

        let adjustedDestination = destination - sortedOffsets.filter { $0 < destination }.count
        let insertionIndex = min(max(adjustedDestination, 0), next.count)
        next.insert(contentsOf: moving, at: insertionIndex)
        blocks = next
    }

    func updateBlock(at index: Int, with block: SiteBlock) {
        guard blocks.indices.contains(index) else { return }
        blocks[index] = block
    }

    func uploadPhoto(data: Data, fileName: String, mimeType: String, toBlockAt index: Int) async {
        guard blocks.indices.contains(index) else { return }
        uploadingBlockIndex = index
        defer { uploadingBlockIndex = nil }

        do {
            let asset = try await siteService.uploadSiteImage(
                domainSlug: domainSlug,
                fileName: fileName,
                mimeType: mimeType,
                data: data
            )

            if case .photo(_, let alt, let caption) = blocks[index] {
                blocks[index] = .photo(url: asset.url, alt: alt, caption: caption)
            } else {
                blocks[index] = .photo(url: asset.url, alt: "Site photo", caption: "")
            }
            errorMessage = nil
            infoMessage = "Photo added. Save or publish when you're ready."
        } catch {
            errorMessage = "Photo upload failed: \(error.localizedDescription)"
        }
    }

    func isUploadingGalleryImage(blockIndex: Int, imageIndex: Int) -> Bool {
        uploadingGalleryImageKey == galleryImageKey(blockIndex: blockIndex, imageIndex: imageIndex)
    }

    func uploadGalleryPhoto(
        data: Data,
        fileName: String,
        mimeType: String,
        blockIndex: Int,
        imageIndex: Int
    ) async {
        guard blocks.indices.contains(blockIndex),
              case .gallery(_, let images) = blocks[blockIndex],
              images.indices.contains(imageIndex) else { return }

        let uploadKey = galleryImageKey(blockIndex: blockIndex, imageIndex: imageIndex)
        uploadingGalleryImageKey = uploadKey
        defer { uploadingGalleryImageKey = nil }

        do {
            let asset = try await siteService.uploadSiteImage(
                domainSlug: domainSlug,
                fileName: fileName,
                mimeType: mimeType,
                data: data
            )

            guard blocks.indices.contains(blockIndex),
                  case .gallery(let title, let currentImages) = blocks[blockIndex],
                  currentImages.indices.contains(imageIndex) else { return }

            var next = currentImages
            next[imageIndex].url = asset.url
            if next[imageIndex].alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                next[imageIndex].alt = "Gallery image"
            }
            blocks[blockIndex] = .gallery(title: title, images: next)
            errorMessage = nil
            infoMessage = "Gallery photo added. Save or publish when you're ready."
        } catch {
            errorMessage = "Gallery photo upload failed: \(error.localizedDescription)"
        }
    }

    private func apply(_ site: OneWaySite) {
        loadedSite = site
        title = site.title
        siteDescription = site.description
        mode = site.mode
        html = site.htmlContent
        blocks = site.blocks
        aiPrompt = site.aiPrompt
        publishedAt = site.publishedAt
        publishedHtml = site.publishedHtml
    }

    private func galleryImageKey(blockIndex: Int, imageIndex: Int) -> String {
        "\(blockIndex)-\(imageIndex)"
    }

    private static func looksLikeHTML(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("<html")
            || lower.contains("<body")
            || lower.contains("<main")
            || lower.contains("<section")
            || lower.contains("<h1")
    }

    private static func defaultBlocks(title: String, description: String) -> [SiteBlock] {
        [
            .hero(eyebrow: "Built on OneWay", title: title, subtitle: description.isEmpty ? "Tell people who you are and how to reach you." : description),
            .text(text: "Add your story, services, menu, portfolio, or announcement here."),
            .services(title: "What we offer", items: Self.defaultServiceItems()),
            .testimonial(quote: "Add a short customer quote or credibility note here.", name: "Happy customer", role: ""),
            .faq(title: "Good to know", items: Self.defaultFAQItems()),
            .callText(label: "Ready to connect?", phoneNumber: "")
        ]
    }

    private static func aiGeneratedBlocks(
        prompt: String,
        domainSlug: String,
        title: String
    ) -> (title: String, description: String, blocks: [SiteBlock]) {
        let businessName = inferredBusinessName(prompt: prompt, fallback: title, domainSlug: domainSlug)
        let description = inferredDescription(prompt: prompt, businessName: businessName)
        let services = inferredServices(prompt: prompt)

        return (
            title: businessName,
            description: description,
            blocks: [
                .hero(eyebrow: "Now on OneWay", title: businessName, subtitle: description),
                .text(text: "\(businessName) gives visitors a clear place to understand the offer, browse services, and contact the business through OneWay."),
                .services(title: "Products and services", items: services),
                .button(label: "View Products", url: "#products"),
                .contact(name: businessName, email: "support@oneway.is", phone: ""),
                .callText(label: "Contact through OneWay", phoneNumber: "Contact through OneWay"),
                .button(label: "Message Business", url: "https://oneway.is/contact"),
                .button(label: "Contact on OneWay", url: "https://oneway.is/support"),
                .gallery(title: "Featured images", images: [
                    SiteGalleryImage(url: "https://images.unsplash.com/photo-1497366754035-f200968a6e72?auto=format&fit=crop&w=900&q=80", alt: "\(businessName) workspace", caption: "A polished first impression"),
                    SiteGalleryImage(url: "https://images.unsplash.com/photo-1556761175-b413da4baf72?auto=format&fit=crop&w=900&q=80", alt: "\(businessName) service preview", caption: "Products and services"),
                    SiteGalleryImage(url: "https://images.unsplash.com/photo-1521791136064-7986c2920216?auto=format&fit=crop&w=900&q=80", alt: "\(businessName) customer support", caption: "Easy customer contact")
                ]),
                .faq(title: "Support", items: [
                    SiteFAQItem(question: "How do customers get started?", answer: "Use the Contact on OneWay or Message Business button and the business will follow up with next steps."),
                    SiteFAQItem(question: "Can this site be updated later?", answer: "Yes. Images, products, services, copy, colors, and contact options can be edited in Site Studio.")
                ])
            ]
        )
    }

    private static func inferredBusinessName(prompt: String, fallback: String, domainSlug: String) -> String {
        let cleanFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanFallback.isEmpty && cleanFallback.lowercased() != "my oneway site" {
            return cleanFallback
        }

        let words = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .prefix(4)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        if !words.isEmpty {
            return words.joined(separator: " ").capitalized
        }

        return domainSlug
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func inferredDescription(prompt: String, businessName: String) -> String {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPrompt.count >= 24 {
            return String(cleanPrompt.prefix(180))
        }
        return "\(businessName) offers clear products, helpful service, and fast contact through OneWay."
    }

    private static func inferredServices(prompt: String) -> [SiteServiceItem] {
        let lower = prompt.lowercased()
        if lower.contains("restaurant") || lower.contains("food") || lower.contains("cafe") {
            return [
                SiteServiceItem(title: "Menu highlights", detail: "Feature signature dishes, specials, pickup options, and ordering details."),
                SiteServiceItem(title: "Catering or events", detail: "Let visitors ask about larger orders, private events, or custom requests."),
                SiteServiceItem(title: "Contact to order", detail: "Customers can message the business through OneWay for availability and next steps.")
            ]
        }
        if lower.contains("photo") || lower.contains("portfolio") || lower.contains("creative") {
            return [
                SiteServiceItem(title: "Featured work", detail: "Showcase selected projects, style, and the kind of work customers can book."),
                SiteServiceItem(title: "Creative services", detail: "Describe packages, deliverables, timelines, and collaboration options."),
                SiteServiceItem(title: "Project inquiries", detail: "Invite visitors to message through OneWay for rates and availability.")
            ]
        }
        return [
            SiteServiceItem(title: "Primary offer", detail: "A clear product or service customers can understand and ask about right away."),
            SiteServiceItem(title: "Fast follow-up", detail: "OneWay contact actions make it easy for visitors to message, call, or request help."),
            SiteServiceItem(title: "Professional support", detail: "Customers get a complete site with business details, contact options, and next steps.")
        ]
    }

    private static func blocks(for template: SiteTemplate, title: String, description: String) -> [SiteBlock] {
        let siteTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My OneWay Site" : title
        let siteDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        switch template {
        case .service:
            return [
                .hero(eyebrow: "Now reachable on OneWay", title: siteTitle, subtitle: siteDescription.isEmpty ? "Reliable service, easy booking, and fast follow-up." : siteDescription),
                .text(text: "Tell visitors what problem you solve, where you serve, and why customers trust you."),
                .services(title: "Services", items: [
                    SiteServiceItem(title: "Same-day help", detail: "Explain the fast service or booking option you want visitors to notice first."),
                    SiteServiceItem(title: "Clear estimates", detail: "Tell people what to expect before they call or message."),
                    SiteServiceItem(title: "Local follow-up", detail: "Show the areas you serve and how quickly you respond.")
                ]),
                .testimonial(quote: "Fast, reliable, and easy to reach.", name: "Local customer", role: ""),
                .hours(hours: "Monday-Friday, 9 AM-5 PM"),
                .faq(title: "Before you call", items: Self.defaultFAQItems()),
                .contact(name: siteTitle, email: "hello@example.com", phone: ""),
                .callText(label: "Call or text for an estimate", phoneNumber: "")
            ]
        case .portfolio:
            return [
                .hero(eyebrow: "Portfolio", title: siteTitle, subtitle: siteDescription.isEmpty ? "A focused place to show your best work and invite new projects." : siteDescription),
                .photo(url: "", alt: "Featured work", caption: "Add a favorite project photo."),
                .gallery(title: "Selected work", images: Self.emptyGalleryImages()),
                .text(text: "Share your creative focus, favorite projects, awards, or the kind of clients you love working with."),
                .services(title: "What I create", items: [
                    SiteServiceItem(title: "Featured projects", detail: "Add the kind of work you want visitors to book you for."),
                    SiteServiceItem(title: "Creative direction", detail: "Describe your process, package, or collaboration style.")
                ]),
                .button(label: "View my work", url: "https://"),
                .contact(name: siteTitle, email: "booking@example.com", phone: "")
            ]
        case .restaurant:
            return [
                .hero(eyebrow: "Fresh on OneWay", title: siteTitle, subtitle: siteDescription.isEmpty ? "Great food, simple hours, and an easy way to reach us." : siteDescription),
                .text(text: "Add your signature dishes, daily specials, or what makes your spot worth visiting."),
                .services(title: "Menu highlights", items: [
                    SiteServiceItem(title: "House favorite", detail: "Describe the dish people should try first."),
                    SiteServiceItem(title: "Daily special", detail: "Add a rotating item, lunch deal, or seasonal feature."),
                    SiteServiceItem(title: "Catering or pickup", detail: "Tell visitors how to order beyond the dining room.")
                ]),
                .gallery(title: "Favorites", images: Self.emptyGalleryImages()),
                .hours(hours: "Tuesday-Sunday, 11 AM-9 PM"),
                .button(label: "See menu", url: "https://"),
                .callText(label: "Call to order", phoneNumber: "")
            ]
        case .event:
            return [
                .hero(eyebrow: "Upcoming event", title: siteTitle, subtitle: siteDescription.isEmpty ? "Give people the essential details and a clear next step." : siteDescription),
                .text(text: "Add the date, location, schedule, ticket notes, parking, and anything guests should know."),
                .gallery(title: "Event preview", images: Self.emptyGalleryImages()),
                .faq(title: "Event details", items: [
                    SiteFAQItem(question: "Where is it?", answer: "Add the venue, address, parking, or arrival instructions."),
                    SiteFAQItem(question: "What should guests bring?", answer: "Add tickets, dress code, ID, or accessibility notes.")
                ]),
                .button(label: "RSVP", url: "https://"),
                .contact(name: "Event contact", email: "events@example.com", phone: "")
            ]
        }
    }

    private static func defaultServiceItems() -> [SiteServiceItem] {
        [
            SiteServiceItem(title: "Main offer", detail: "Describe the primary service, product, or reason people should contact you."),
            SiteServiceItem(title: "Fast follow-up", detail: "Tell visitors how quickly you respond and what happens next."),
            SiteServiceItem(title: "Trusted support", detail: "Add a proof point, warranty, location, or experience note.")
        ]
    }

    private static func defaultFAQItems() -> [SiteFAQItem] {
        [
            SiteFAQItem(question: "How do I get started?", answer: "Call, text, or send a message and we will follow up with next steps."),
            SiteFAQItem(question: "Where are you located?", answer: "Add your service area, address, or online availability.")
        ]
    }

    private static func emptyGalleryImages() -> [SiteGalleryImage] {
        [
            SiteGalleryImage(url: "", alt: "Gallery image", caption: "First highlight"),
            SiteGalleryImage(url: "", alt: "Gallery image", caption: "Second highlight"),
            SiteGalleryImage(url: "", alt: "Gallery image", caption: "Third highlight")
        ]
    }

    private static func starterTemplate(title: String, description: String, domain: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>\(escape(title))</title>
          <meta name="description" content="\(escape(description.isEmpty ? "A professional OneWay site with clear contact information and a real next step." : description))">
          <style>
            body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #13072d; color: white; }
            main { max-width: 860px; margin: 0 auto; padding: 72px 24px; }
            .pill { color: #ffcc33; font-weight: 800; letter-spacing: .12em; text-transform: uppercase; }
            h1 { font-size: clamp(44px, 10vw, 88px); line-height: .95; margin: 12px 0; }
            p { color: #d8ccff; font-size: 20px; line-height: 1.55; }
            a { display: inline-block; margin-top: 24px; padding: 14px 20px; border-radius: 999px; background: #3385ff; color: white; text-decoration: none; font-weight: 800; }
            footer { max-width: 860px; margin: 0 auto; padding: 0 24px 42px; color: #b8a5ef; }
            footer nav { display: flex; gap: 14px; flex-wrap: wrap; }
          </style>
        </head>
        <body>
          <main>
            <p class="pill">\(escape(domain))</p>
            <h1>\(escape(title.isEmpty ? "My OneWay Site" : title))</h1>
            <p>\(escape(description.isEmpty ? "A simple landing page published on OneWay." : description))</p>
            <a href="mailto:hello@oneway.app">Contact us</a>
          </main>
          <footer>
            <nav aria-label="Site links">
              <a href="https://oneway.is/privacy">Privacy</a>
              <a href="https://oneway.is/terms">Terms</a>
              <a href="https://oneway.is/support">Support</a>
            </nav>
          </footer>
        </body>
        </html>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
