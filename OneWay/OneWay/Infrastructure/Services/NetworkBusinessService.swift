import Foundation

#if canImport(UIKit)

@MainActor
final class NetworkBusinessService: BusinessService, BusinessSearchService {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func listStorefronts() async throws -> [Storefront] {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
        do {
            let (data, _) = try await perform(URLRequest(url: url))
            let apiStores = try decoder.decode([APIStorefront].self, from: data)
            return apiStores.map(mapStorefront)
        } catch {
            let fallbackURL = baseURL.appendingPathComponent("storefront")
            let (data, _) = try await perform(URLRequest(url: fallbackURL))
            let snapshot = try decoder.decode(StorefrontSnapshot.self, from: data)
            return [mapSnapshotStorefront(snapshot)]
        }
    }

    func createStorefront(name: String, category: String, tagline: String?) async throws -> Storefront {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["name": name, "category": category, "tagline": tagline ?? ""]
        req.httpBody = try encoder.encode(body)
        let (data, _) = try await perform(req)
        let apiStore = try decoder.decode(APIStorefront.self, from: data)
        return mapStorefront(apiStore)
    }

    @discardableResult
    func save(storefront: Storefront) async throws -> Storefront {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
            .appendingPathComponent(storefront.id.uuidString)
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payloadHandle = normalizedHandle(storefront.slug)
        let body: [String: Any?] = [
            "name": storefront.business.name,
            "description": storefront.business.description,
            "category": storefront.business.category,
            "tagline": storefront.business.tagline,
            "requestedHandle": payloadHandle
        ]
#if DEBUG
        print("[StorefrontSave] currentHandleText=nil draftHandle=\(storefront.slug) payloadHandle=\(payloadHandle) backendHandle=\(storefront.slug) selectedStoreName=\(storefront.business.name) sourceOfTruth=storefront.slug")
#endif
        req.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        let (data, _) = try await perform(req)
        let apiStore = try decoder.decode(APIStorefront.self, from: data)
        let saved = mapStorefront(apiStore)
#if DEBUG
        print("[StorefrontSave] resultHandle=\(saved.slug) preview=https://oneway.is/shop/\(saved.slug)")
#endif
        return saved
    }

    func publish(storefrontID: UUID, isPublished: Bool) async throws {
        let path = isPublished ? "publish" : "unpublish"
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
            .appendingPathComponent(storefrontID.uuidString)
            .appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try await perform(req)
    }

    func delete(storefrontID: UUID) async throws {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
            .appendingPathComponent(storefrontID.uuidString)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await perform(req)
    }

    func search(query: String, mode: BusinessSearchMode) async throws -> [SearchResult] {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("api").appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "scope", value: mode == .manage ? "manage" : "shop")
        ]
        let (data, _) = try await perform(URLRequest(url: comps.url!))
        return try decoder.decode([SearchResult].self, from: data)
    }


    private func normalizedHandle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: - Networking helpers

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        applyAuthHeaders(to: &request)
        #if DEBUG
        print("[Network] \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")
        #endif
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200..<300 ~= http.statusCode else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "NetworkBusinessService",
                          code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Request failed (\(http.statusCode)): \(snippet.prefix(120))"])
        }
        return (data, response)
    }

    private func applyAuthHeaders(to request: inout URLRequest) {
        // Dev auth path: the server uses x-dev-user-id until real JWT auth
        // is enforced. Keeping this here avoids scattering headers across
        // every call site.
        request.setValue(AuthTokenStore.shared.currentUserID(), forHTTPHeaderField: "x-dev-user-id")
        request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    // MARK: - DTOs

    struct APIStorefront: Codable {
        let id: UUID
        let ownerId: String?
        let name: String
        let slug: String
        let description: String
        let category: String
        let tagline: String?
        let published: Bool?
        let products: [APIProduct]?
        let collections: [APICollection]?
        let theme: APITheme?
        let layout: APILayout?
    }

    struct APIProduct: Codable {
        let id: UUID
        let name: String
        let description: String
        let price: String
        let isSubscription: Bool?
        let mediaURL: URL?
    }

    struct APICollection: Codable {
        let id: UUID
        let title: String
    }

    struct APITheme: Codable {
        let primaryHex: String
        let accentHex: String
        let background: String
        let font: String
    }

    struct APILayout: Codable {
        let heroStyle: String
        let gridStyle: String
        let spacing: Double
    }

    // MARK: - Mapping

    func mapStorefront(_ api: APIStorefront) -> Storefront {
        let theme = StorefrontTheme(
            primaryColorHex: api.theme?.primaryHex ?? "#111827",
            accentColorHex: api.theme?.accentHex ?? "#2563EB",
            backgroundStyle: api.theme?.background ?? "light",
            fontName: api.theme?.font ?? "SFPro"
        )

        let layout = StorefrontLayout(
            heroStyle: api.layout?.heroStyle ?? "split",
            gridStyle: api.layout?.gridStyle ?? "card",
            spacing: api.layout?.spacing ?? 12
        )

        let products: [ProductOrService] = (api.products ?? []).map {
            ProductOrService(
                id: $0.id,
                name: $0.name,
                description: $0.description,
                price: $0.price,
                isSubscription: $0.isSubscription ?? false,
                mediaURL: $0.mediaURL
            )
        }

        let business = BusinessProfile(
            id: api.id,
            ownerID: UUID(uuidString: api.ownerId ?? "") ?? api.id,
            name: api.name,
            category: api.category,
            tagline: api.tagline ?? "",
            description: api.description,
            logoURL: nil,
            coverImageURL: nil,
            contactEmail: nil,
            phone: nil,
            website: nil,
            socialLinks: [:],
            address: nil,
            hours: nil,
            products: products,
            theme: theme,
            layout: layout,
            sections: [],
            isPublished: api.published ?? false
        )

        var sections: [StorefrontSection] = []
        sections.append(StorefrontSection(type: .hero, title: api.name, body: api.tagline ?? api.description, items: [], mediaURLs: []))
        if !products.isEmpty {
            sections.append(StorefrontSection(type: .products, title: "Products", body: nil, items: products, mediaURLs: []))
        }
        sections.append(StorefrontSection(type: .about, title: "About", body: api.description, items: [], mediaURLs: []))

        return Storefront(
            id: api.id,
            business: business,
            sections: sections,
            theme: theme,
            layout: layout,
            slug: api.slug,
            isPublished: api.published ?? false,
            publishedState: (api.published ?? false) ? .published : .draft
        )
    }

    private func mapSnapshotStorefront(_ snapshot: StorefrontSnapshot) -> Storefront {
        let storeID = UUID()
        let theme = StorefrontTheme(
            primaryColorHex: "#0A84FF",
            accentColorHex: "#30D158",
            backgroundStyle: "dark",
            fontName: "SF Pro"
        )
        let layout = StorefrontLayout(heroStyle: "immersive", gridStyle: "cards", spacing: 12)
        let items = snapshot.products.map {
            ProductOrService(
                name: $0.name,
                description: $0.description,
                price: String(format: "$%.2f", $0.price),
                isSubscription: $0.isSubscription,
                mediaURL: $0.imageUrl.flatMap(URL.init(string:))
            )
        }
        let business = BusinessProfile(
            id: storeID,
            ownerID: storeID,
            name: snapshot.store.name,
            category: "Live Commerce",
            tagline: snapshot.store.tagline ?? "",
            description: snapshot.heroSubtitle ?? "Shop and connect live.",
            logoURL: nil,
            coverImageURL: nil,
            contactEmail: nil,
            phone: nil,
            website: nil,
            socialLinks: [:],
            address: nil,
            hours: nil,
            products: items,
            theme: theme,
            layout: layout,
            sections: [],
            isPublished: true
        )
        let sections = [
            StorefrontSection(type: .hero, title: snapshot.heroTitle ?? snapshot.store.name, body: snapshot.heroSubtitle),
            StorefrontSection(type: .products, title: "Products", items: items),
            StorefrontSection(type: .about, title: "About", body: snapshot.store.tagline)
        ]
        return Storefront(
            id: storeID,
            business: business,
            sections: sections,
            theme: theme,
            layout: layout,
            slug: snapshot.store.slug,
            isPublished: true,
            publishedState: .published
        )
    }
}

#endif
