import Foundation

@MainActor
final class StubBusinessService: BusinessService, BusinessSearchService {
    private var storefronts: [Storefront] = []

    func listStorefronts() async throws -> [Storefront] {
        if storefronts.isEmpty {
            storefronts.append(makeDefaultStore())
        }
        return storefronts
    }

    func createStorefront(name: String, category: String, tagline: String?) async throws -> Storefront {
        let store = makeStore(name: name, category: category, tagline: tagline ?? "")
        storefronts.append(store)
        return store
    }

    @discardableResult
    func save(storefront: Storefront) async throws -> Storefront {
        if let idx = storefronts.firstIndex(where: { $0.id == storefront.id }) {
            storefronts[idx] = storefront
        } else {
            storefronts.append(storefront)
        }
        return storefront
    }

    func publish(storefrontID: UUID, isPublished: Bool) async throws {
        guard let idx = storefronts.firstIndex(where: { $0.id == storefrontID }) else { return }
        storefronts[idx].isPublished = isPublished
        storefronts[idx].publishedState = isPublished ? .published : .draft
    }

    func delete(storefrontID: UUID) async throws {
        // Hard delete: remove storefront and all data tied to it in memory.
        storefronts.removeAll { $0.id == storefrontID }
    }

    func search(query: String, mode: BusinessSearchMode) async throws -> [SearchResult] {
        let lowered = query.lowercased()
        let stores = try await listStorefronts()
        var results: [SearchResult] = []

        for store in stores {
            if store.business.name.lowercased().contains(lowered) || store.business.category.lowercased().contains(lowered) {
                results.append(
                    SearchResult(
                        id: UUID(),
                        title: store.business.name,
                        subtitle: store.business.tagline,
                        kind: .storefront,
                        storefront: store,
                        product: nil,
                        category: store.business.category
                    )
                )
            }

            for product in store.business.products {
                if product.name.lowercased().contains(lowered) || product.description.lowercased().contains(lowered) {
                    results.append(
                        SearchResult(
                            id: UUID(),
                            title: product.name,
                            subtitle: store.business.name,
                            kind: .product,
                            storefront: store,
                            product: product,
                            category: store.business.category
                        )
                    )
                }
            }

            if mode == .manage {
                for section in store.sections {
                    if section.title.lowercased().contains(lowered) || (section.body?.lowercased().contains(lowered) ?? false) {
                        results.append(
                            SearchResult(
                                id: UUID(),
                                title: section.title,
                                subtitle: store.business.name,
                                kind: .collection,
                                storefront: store,
                                product: nil,
                                category: store.business.category
                            )
                        )
                    }
                }
            }
        }

        let categories = ["Apparel", "Electronics", "Wellness", "Services", "Gifts"]
        for category in categories where category.lowercased().contains(lowered) {
            results.append(
                SearchResult(
                    id: UUID(),
                    title: category,
                    subtitle: "Category",
                    kind: .category,
                    storefront: nil,
                    product: nil,
                    category: category
                )
            )
        }

        return results
    }

    // MARK: - Seed data

    private func makeDefaultStore() -> Storefront {
        makeStore(name: "OneWay Demo Store", category: "General", tagline: "Secure storefront powered by OneWay")
    }

    private func makeStore(name: String, category: String, tagline: String) -> Storefront {
        let slug = slugify(name)
        let products = [
            ProductOrService(name: "Sample Tee", description: "Cotton tee", price: "$24", isSubscription: false),
            ProductOrService(name: "Sticker Pack", description: "Logo stickers", price: "$8", isSubscription: false)
        ]

        let business = BusinessProfile(
            id: UUID(),
            ownerID: UUID(),
            name: name,
            category: category,
            tagline: tagline,
            description: "A starter demo store you can replace.",
            logoURL: nil,
            coverImageURL: nil,
            contactEmail: "hello@oneway.app",
            phone: nil,
            website: nil,
            socialLinks: [:],
            address: nil,
            hours: "Always on",
            products: products,
            theme: StorefrontTheme(primaryColorHex: "#6366F1", accentColorHex: "#22D3EE", backgroundStyle: "glass", fontName: "SFPro"),
            layout: StorefrontLayout(heroStyle: "split", gridStyle: "card", spacing: 12),
            sections: [],
            isPublished: true
        )

        let sections = [
            StorefrontSection(type: .hero, title: "Welcome to OneWay", body: "Encrypted-first business messaging meets shopping.", items: [], mediaURLs: []),
            StorefrontSection(type: .products, title: "Featured", body: nil, items: products, mediaURLs: []),
            StorefrontSection(type: .cta, title: "Message seller", body: "Get fast answers", items: [], mediaURLs: [])
        ]

        return Storefront(
            id: UUID(),
            business: business,
            sections: sections,
            theme: business.theme,
            layout: business.layout,
            slug: slug,
            isPublished: true,
            publishedState: .published
        )
    }

    private func slugify(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let base = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: allowed.inverted)
            .joined()
        // ensure uniqueness
        var candidate = base.isEmpty ? UUID().uuidString.lowercased() : base
        var counter = 1
        while storefronts.contains(where: { $0.slug == candidate }) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }
}
