import Foundation

@MainActor
final class LocalBusinessService: BusinessService, BusinessSearchService {
    private let storageKey = "oneway.storefronts"
    private var storefronts: [Storefront] = []

    init() {
        storefronts = load()
    }

    func listStorefronts() async throws -> [Storefront] {
        storefronts
    }

    func listMarketplaceStorefronts() async throws -> [Storefront] {
        storefronts
            .filter(\.isPublished)
            .sorted { $0.id.uuidString > $1.id.uuidString }
    }

    func createStorefront(name: String, category: String, tagline: String?) async throws -> Storefront {
        let store = makeStore(name: name, category: category, tagline: tagline ?? "")
        storefronts.append(store)
        persist()
        return store
    }

    func save(storefront: Storefront) async throws -> Storefront {
        if let idx = storefronts.firstIndex(where: { $0.id == storefront.id }) {
            storefronts[idx] = storefront
        } else {
            storefronts.append(storefront)
        }
        persist()
        return storefront
    }

    func publish(storefrontID: UUID, isPublished: Bool) async throws -> Storefront {
        guard let idx = storefronts.firstIndex(where: { $0.id == storefrontID }) else {
            throw NSError(domain: "LocalBusinessService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Storefront not found."])
        }
        storefronts[idx].isPublished = isPublished
        storefronts[idx].publishedState = isPublished ? .published : .draft
        persist()
        return storefronts[idx]
    }

    func delete(storefrontID: UUID) async throws {
        storefronts.removeAll { $0.id == storefrontID }
        persist()
    }

    func listListings(storefrontID: UUID) async throws -> [ProductOrService] {
        storefronts.first(where: { $0.id == storefrontID })?.business.products ?? []
    }

    func createListing(storefrontID: UUID, product: ProductOrService) async throws -> ProductOrService {
        guard let idx = storefronts.firstIndex(where: { $0.id == storefrontID }) else { return product }
        storefronts[idx].business.products.append(product)
        if let sectionIndex = storefronts[idx].sections.firstIndex(where: { $0.type == .products }) {
            storefronts[idx].sections[sectionIndex].items = storefronts[idx].business.products
        } else {
            storefronts[idx].sections.append(StorefrontSection(type: .products, title: "Products", items: storefronts[idx].business.products))
        }
        storefronts[idx].setupComplete = storefronts[idx].paymentsReady && storefronts[idx].policiesReady && !storefronts[idx].business.products.isEmpty
        persist()
        return product
    }

    func updateListing(storefrontID: UUID, product: ProductOrService) async throws -> ProductOrService {
        guard let idx = storefronts.firstIndex(where: { $0.id == storefrontID }) else { return product }
        if let productIndex = storefronts[idx].business.products.firstIndex(where: { $0.id == product.id }) {
            storefronts[idx].business.products[productIndex] = product
        } else {
            storefronts[idx].business.products.append(product)
        }
        if let sectionIndex = storefronts[idx].sections.firstIndex(where: { $0.type == .products }) {
            storefronts[idx].sections[sectionIndex].items = storefronts[idx].business.products
        } else {
            storefronts[idx].sections.append(StorefrontSection(type: .products, title: "Products", items: storefronts[idx].business.products))
        }
        persist()
        return product
    }

    func deleteListing(storefrontID: UUID, productID: UUID) async throws {
        guard let idx = storefronts.firstIndex(where: { $0.id == storefrontID }) else { return }
        storefronts[idx].business.products.removeAll { $0.id == productID }
        if let sectionIndex = storefronts[idx].sections.firstIndex(where: { $0.type == .products }) {
            storefronts[idx].sections[sectionIndex].items = storefronts[idx].business.products
        }
        persist()
    }

    func fetchPolicies(storefrontID: UUID) async throws -> StorePolicyDraft {
        storefronts.first(where: { $0.id == storefrontID })?.policy ?? .default
    }

    func savePolicies(storefrontID: UUID, policy: StorePolicyDraft) async throws -> StorePolicyDraft {
        guard let idx = storefronts.firstIndex(where: { $0.id == storefrontID }) else { return policy }
        storefronts[idx].policy = policy
        storefronts[idx].policiesReady = true
        persist()
        return policy
    }

    func uploadStorefrontImage(data: Data, fileName: String, mimeType: String) async throws -> URL {
        let ext = fileName.split(separator: ".").last.map(String.init) ?? fileExtension(for: mimeType)
        let encoded = data.base64EncodedString()
        guard let url = URL(string: "data:image/\(ext);base64,\(encoded)") else {
            throw NSError(domain: "LocalBusinessService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create image URL."])
        }
        return url
    }

    func uploadProductImage(productID: UUID, data: Data, fileName: String, mimeType: String) async throws -> ProductOrService {
        let url = try await uploadStorefrontImage(data: data, fileName: fileName, mimeType: mimeType)
        for storeIndex in storefronts.indices {
            if let productIndex = storefronts[storeIndex].business.products.firstIndex(where: { $0.id == productID }) {
                storefronts[storeIndex].business.products[productIndex].mediaURL = url
                persist()
                return storefronts[storeIndex].business.products[productIndex]
            }
        }
        throw NSError(domain: "LocalBusinessService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Product not found."])
    }

    func checkStorefrontHandleAvailability(handle: String, excluding storefrontID: UUID?) async throws -> StorefrontHandleAvailability {
        let normalized = normalizeHandle(handle)
        guard !normalized.isEmpty else {
            return StorefrontHandleAvailability(handle: normalized, status: .invalid, message: "Use lowercase letters, numbers, and hyphens.")
        }
        let taken = storefronts.contains {
            $0.id != storefrontID && ($0.slug == normalized || $0.business.handle == normalized)
        }
        return StorefrontHandleAvailability(
            handle: normalized,
            status: taken ? .taken : .available,
            message: taken ? "That shop link is already taken." : "Available"
        )
    }

    // Search
    func search(query: String, mode: BusinessSearchMode) async throws -> [SearchResult] {
        let lowered = query.lowercased()
        var results: [SearchResult] = []
        for store in storefronts {
            if store.business.name.lowercased().contains(lowered) || store.business.category.lowercased().contains(lowered) {
                results.append(SearchResult(id: UUID(), title: store.business.name, subtitle: store.business.tagline, kind: .storefront, storefront: store, product: nil, category: store.business.category))
            }
            for product in store.business.products where product.name.lowercased().contains(lowered) || product.description.lowercased().contains(lowered) {
                results.append(SearchResult(id: UUID(), title: product.name, subtitle: store.business.name, kind: .product, storefront: store, product: product, category: store.business.category))
            }
            if mode == .manage {
                for section in store.sections where section.title.lowercased().contains(lowered) || (section.body?.lowercased().contains(lowered) ?? false) {
                    results.append(SearchResult(id: UUID(), title: section.title, subtitle: store.business.name, kind: .collection, storefront: store, product: nil, category: store.business.category))
                }
            }
        }
        return results
    }

    // MARK: - Private helpers

    private func persist() {
        if let data = try? JSONEncoder().encode(storefronts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() -> [Storefront] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Storefront].self, from: data) else { return [] }
        return decoded
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
            handle: slug,
            category: category,
            tagline: tagline,
            description: "A starter demo store you can replace.",
            logoURL: nil,
            coverImageURL: nil,
            announcement: "Launching soon on OneWay.",
            sellerStory: "Tell buyers what makes your shop special.",
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
            StorefrontSection(type: .hero, title: "Welcome to OneWay", body: "Business messaging meets shopping in one place.", items: [], mediaURLs: []),
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
            shopURL: APIConfig.storefrontPublicURLString(for: slug),
            paymentStatus: "active",
            paymentsReady: true,
            policiesReady: true,
            setupComplete: true,
            publishChecklist: [],
            policy: .default,
            isPublished: true,
            publishedState: .published
        )
    }

    private func slugify(_ name: String) -> String {
        let base = normalizeHandle(name)
        var candidate = base.isEmpty ? UUID().uuidString.lowercased() : base
        var counter = 1
        while storefronts.contains(where: { $0.slug == candidate }) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private func normalizeHandle(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return value
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { allowed.contains($0) }
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        default:
            return "jpg"
        }
    }
}
