import Foundation

struct AIStructuredStorefront: Codable {
    struct Hero: Codable { let title: String; let body: String }
    struct Item: Codable { let name: String; let description: String; let price: String }
    let name: String
    let tagline: String
    let category: String
    let description: String
    let hero: Hero
    let products: [Item]
}

final class ProductionAIStorefrontService: AIStorefrontService {
    private let apiKey: String
    private let session: URLSession = .shared
    private let model = "gpt-4o-mini"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func generate(from request: AIStorefrontRequest) async throws -> AIStorefrontResult {
        let prompt = """
        You are an AI storefront builder. Return JSON only, matching this schema:
        {
          "name": string,
          "tagline": string,
          "category": string,
          "description": string,
          "hero": { "title": string, "body": string },
          "products": [ { "name": string, "description": string, "price": string } ]
        }
        Use the user's prompt: "\(request.prompt)". Category hint: \(request.category).
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You build ecommerce storefront configs in JSON."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.7,
            "response_format": ["type": "json_object"]
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (respData, _) = try await session.data(for: urlRequest)
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: respData)
        guard let jsonString = decoded.choices.first?.message.content.data(using: .utf8) else {
            throw NSError(domain: "AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty AI response"])
        }
        let structured = try JSONDecoder().decode(AIStructuredStorefront.self, from: jsonString)

        // Map to app models
        let products = structured.products.map {
            ProductOrService(name: $0.name, description: $0.description, price: $0.price, isSubscription: false)
        }
        let business = BusinessProfile(
            id: UUID(),
            ownerID: UUID(),
            name: structured.name,
            category: structured.category,
            tagline: structured.tagline,
            description: structured.description,
            logoURL: nil,
            coverImageURL: nil,
            contactEmail: nil,
            phone: nil,
            website: nil,
            socialLinks: [:],
            address: nil,
            hours: "Always on",
            products: products,
            theme: StorefrontTheme(primaryColorHex: "#111827", accentColorHex: "#2563EB", backgroundStyle: "light", fontName: "SFPro"),
            layout: StorefrontLayout(heroStyle: "centered", gridStyle: "card", spacing: 12),
            sections: [],
            isPublished: false
        )
        let sections: [StorefrontSection] = [
            StorefrontSection(type: .hero, title: structured.hero.title, body: structured.hero.body, items: [], mediaURLs: []),
            StorefrontSection(type: .products, title: "Featured", body: nil, items: products, mediaURLs: [])
        ]
        let storefront = Storefront(
            id: UUID(),
            business: business,
            sections: sections,
            theme: business.theme,
            layout: business.layout,
            slug: slugify(structured.name),
            isPublished: false,
            publishedState: .draft
        )
        let copy = Dictionary(uniqueKeysWithValues: sections.map { ($0.type, $0.title) })
        return AIStorefrontResult(storefront: storefront, generatedCopy: copy)
    }

    func regenerateSection(storefront: Storefront, section: StorefrontSectionType) async throws -> StorefrontSection {
        StorefrontSection(type: section, title: "Updated \(section.rawValue.capitalized)", body: "AI refreshed this section.", items: storefront.sections.first(where: { $0.type == .products })?.items ?? [], mediaURLs: [])
    }

    // MARK: - OpenAI response
    private struct OpenAIResponse: Codable {
        struct Choice: Codable { let message: Message }
        struct Message: Codable { let role: String; let content: String }
        let choices: [Choice]
    }

    private func slugify(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let base = name.lowercased().replacingOccurrences(of: " ", with: "-").components(separatedBy: allowed.inverted).joined()
        return base.isEmpty ? UUID().uuidString.lowercased() : base
    }
}
