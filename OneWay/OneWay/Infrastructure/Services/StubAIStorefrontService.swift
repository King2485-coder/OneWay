import Foundation
import SwiftUI

final class StubAIStorefrontService: AIStorefrontService {
    func generate(from request: AIStorefrontRequest) async throws -> AIStorefrontResult {
        let inferred = infer(from: request.businessName)
        let business = BusinessProfile(
            id: UUID(),
            ownerID: UUID(),
            name: inferred.name,
            category: inferred.category,
            tagline: inferred.tagline,
            description: inferred.description,
            logoURL: nil,
            coverImageURL: nil,
            contactEmail: nil,
            phone: nil,
            website: nil,
            socialLinks: [:],
            address: nil,
            hours: "Mon-Fri 9a-5p",
            products: sampleProducts(),
            theme: StorefrontTheme(primaryColorHex: "#4F46E5", accentColorHex: "#22D3EE", backgroundStyle: "glass", fontName: "SFPro"),
            layout: StorefrontLayout(heroStyle: "split", gridStyle: "masonry", spacing: 12),
            sections: [],
            isPublished: false
        )

        let sections = makeSections(products: business.products, hero: inferred.hero)
        let storefront = Storefront(
            id: UUID(),
            business: business,
            sections: sections,
            theme: business.theme,
            layout: business.layout,
            slug: slugify(request.businessName),
            isPublished: false,
            publishedState: .draft
        )
        let copy = Dictionary(uniqueKeysWithValues: sections.map { ($0.type, $0.title) })
        return AIStorefrontResult(storefront: storefront, generatedCopy: copy)
    }

    func regenerateSection(storefront: Storefront, section: StorefrontSectionType) async throws -> StorefrontSection {
        StorefrontSection(type: section, title: "Regenerated \(section.rawValue.capitalized)", body: "Updated by AI", items: sampleProducts(), mediaURLs: [])
    }

    private func sampleProducts() -> [ProductOrService] {
        [
            ProductOrService(name: "Starter Plan", description: "Great for getting started.", price: "$19/mo", isSubscription: true),
            ProductOrService(name: "Pro Service", description: "Everything you need to scale.", price: "$199", isSubscription: false)
        ]
    }

    private func makeSections(products: [ProductOrService], hero: (title: String, body: String)) -> [StorefrontSection] {
        [
            StorefrontSection(type: .hero, title: hero.title, body: hero.body, items: [], mediaURLs: []),
            StorefrontSection(type: .products, title: "Featured", body: nil, items: products, mediaURLs: []),
            StorefrontSection(type: .services, title: "Services", body: "What we can do for you", items: products, mediaURLs: []),
            StorefrontSection(type: .cta, title: "Get in touch", body: nil, items: [], mediaURLs: [])
        ]
    }

    private func slugify(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: allowed.inverted)
            .joined()
    }

    private func infer(from prompt: String) -> (name: String, category: String, tagline: String, description: String, hero: (title: String, body: String)) {
        let lowered = prompt.lowercased()
        if lowered.contains("dog") || lowered.contains("pet") {
            return (
                name: "Paws & Play",
                category: "Pets",
                tagline: "Everything for happy dogs",
                description: "Curated toys, treats, and gear for your pup.",
                hero: (title: "Treat your best friend", body: "Handpicked dog toys, treats, and essentials delivered.")
            )
        } else if lowered.contains("coffee") {
            return (
                name: "Roast House",
                category: "Food & Drink",
                tagline: "Specialty coffee, roasted weekly",
                description: "Fresh beans, brew gear, and barista-approved recipes.",
                hero: (title: "Brew better at home", body: "Seasonal roasts and brew kits shipped fresh.")
            )
        } else if lowered.contains("fashion") || lowered.contains("apparel") || lowered.contains("clothing") {
            return (
                name: "Arc Street",
                category: "Apparel",
                tagline: "Modern fits, limited drops",
                description: "Elevated essentials and statement pieces.",
                hero: (title: "Refresh your rotation", body: "Curated capsules, small-batch releases.")
            )
        }
        return (
            name: prompt.isEmpty ? "OneWay Storefront" : prompt,
            category: "General",
            tagline: "Built with OneWay AI",
            description: "Auto-generated storefront for \(prompt.isEmpty ? "your business" : prompt).",
            hero: (title: "Welcome", body: "Discover our latest picks.")
        )
    }
}
