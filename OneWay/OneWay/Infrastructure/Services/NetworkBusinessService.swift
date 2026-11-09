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

    func listMarketplaceStorefronts() async throws -> [Storefront] {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
            .appendingPathComponent("marketplace")
        let (data, _) = try await perform(URLRequest(url: url), requiresAuth: false)
        let apiStores = try decoder.decode([APIStorefront].self, from: data)
        return apiStores.map(mapStorefront)
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

    func save(storefront: Storefront) async throws -> Storefront {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
            .appendingPathComponent(storefront.id.uuidString)
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let handle = sanitizedHandleForSave(storefront.business.handle)
        let nameValue = storefront.business.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryValue = storefront.business.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionValue = storefront.business.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let taglineValue = storefront.business.tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any?] = [
            "name": nameValue.isEmpty ? nil : nameValue,
            "handle": handle,
            "logoUrl": storefront.business.logoURL?.absoluteString,
            "bannerUrl": storefront.business.coverImageURL?.absoluteString,
            "announcement": storefront.business.announcement,
            "description": descriptionValue.isEmpty ? nil : descriptionValue,
            "sellerStory": storefront.business.sellerStory,
            "category": categoryValue.isEmpty ? nil : categoryValue,
            "tagline": taglineValue.isEmpty ? nil : taglineValue,
            "shippingSettingsJson": launchDetailsJson(for: storefront),
            "paymentStatus": storefront.paymentStatus,
            "paymentsReady": storefront.paymentsReady,
            "paymentsEnabled": storefront.paymentsEnabled,
            "stripeConnectStatus": storefront.stripeConnectStatus,
            "defaultPaymentMode": storefront.defaultPaymentMode,
            "defaultPaymentLinkUrl": storefront.defaultPaymentLinkURL?.absoluteString,
            "policiesReady": storefront.policiesReady,
            "setupCompleted": storefront.setupComplete,
            "status": storefront.isPublished ? "published" : "draft",
            "published": storefront.isPublished
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        let (data, _) = try await perform(req)
        let apiStore = try decoder.decode(APIStorefront.self, from: data)
        return mapStorefront(apiStore)
    }

    func publish(storefrontID: UUID, isPublished: Bool) async throws -> Storefront {
        let path = isPublished ? "publish" : "unpublish"
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
            .appendingPathComponent(storefrontID.uuidString)
            .appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, _) = try await perform(req)
        let apiStore = try decoder.decode(APIStorefront.self, from: data)
        return mapStorefront(apiStore)
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

    func listListings(storefrontID: UUID) async throws -> [ProductOrService] {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("seller")
            .appendingPathComponent("products")
        let (data, _) = try await perform(URLRequest(url: url))
        let products = try decoder.decode([APIProduct].self, from: data)
        return products.map(mapProduct)
    }

    func createListing(storefrontID: UUID, product: ProductOrService) async throws -> ProductOrService {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("seller")
            .appendingPathComponent("products")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: sellerProductBody(for: product).compactMapValues { $0 })
        #if DEBUG
        print("[ShopManagement] product save started action=create storeID=\(storefrontID.uuidString)")
        #endif
        let (data, _) = try await perform(req)
        let apiProduct = try decoder.decode(APIProduct.self, from: data)
        let saved = mapProduct(apiProduct)
        #if DEBUG
        print("[ShopManagement] productId received \(saved.id.uuidString)")
        #endif
        return saved
    }

    func updateListing(storefrontID: UUID, product: ProductOrService) async throws -> ProductOrService {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("seller")
            .appendingPathComponent("products")
            .appendingPathComponent(product.id.uuidString)
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: sellerProductBody(for: product).compactMapValues { $0 })
        #if DEBUG
        print("[ShopManagement] product save started action=update productID=\(product.id.uuidString)")
        #endif
        let (data, _) = try await perform(req)
        let apiProduct = try decoder.decode(APIProduct.self, from: data)
        let saved = mapProduct(apiProduct)
        #if DEBUG
        print("[ShopManagement] productId received \(saved.id.uuidString)")
        #endif
        return saved
    }

    func deleteListing(storefrontID: UUID, productID: UUID) async throws {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("seller")
            .appendingPathComponent("products")
            .appendingPathComponent(productID.uuidString)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await perform(req)
    }

    func fetchPolicies(storefrontID: UUID) async throws -> StorePolicyDraft {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
            .appendingPathComponent(storefrontID.uuidString)
            .appendingPathComponent("policies")
        let (data, _) = try await perform(URLRequest(url: url))
        let policy = try decoder.decode(APIPolicy.self, from: data)
        return mapPolicy(policy)
    }

    func savePolicies(storefrontID: UUID, policy: StorePolicyDraft) async throws -> StorePolicyDraft {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("storefronts")
            .appendingPathComponent(storefrontID.uuidString)
            .appendingPathComponent("policies")
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(policy)
        let (data, _) = try await perform(req)
        let saved = try decoder.decode(APIPolicy.self, from: data)
        return mapPolicy(saved)
    }

    func uploadStorefrontImage(data: Data, fileName: String, mimeType: String) async throws -> URL {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("uploads")
            .appendingPathComponent("image")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &req)
        req.httpBody = multipartBody(data: data, fileName: fileName, mimeType: mimeType, boundary: boundary)

        let (responseData, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: responseData, encoding: .utf8) ?? ""
            #if DEBUG
            print("[Upload] image upload failed status=\(http.statusCode) body=\(PrivacyLog.redact(snippet))")
            #endif
            throw NSError(
                domain: "NetworkBusinessService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Image upload failed (\(http.statusCode)): \(snippet.prefix(200))"]
            )
        }
        let payload = try decoder.decode(APIUploadResponse.self, from: responseData)
        guard let url = URL(string: payload.url) else {
            throw NSError(domain: "NetworkBusinessService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Image upload returned an invalid URL."])
        }
        return url
    }

    func uploadProductImage(productID: UUID, data: Data, fileName: String, mimeType: String) async throws -> ProductOrService {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("seller")
            .appendingPathComponent("products")
            .appendingPathComponent(productID.uuidString)
            .appendingPathComponent("images")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &req)
        req.httpBody = multipartBody(data: data, fileName: fileName, mimeType: mimeType, boundary: boundary)

        #if DEBUG
        print("[Upload] product image upload productID=\(productID.uuidString) file=\(fileName) bytes=\(data.count)")
        #endif

        let (responseData, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: responseData, encoding: .utf8) ?? ""
            #if DEBUG
            print("[Upload] product image upload failed productID=\(productID.uuidString) status=\(http.statusCode) body=\(PrivacyLog.redact(snippet))")
            #endif
            throw NSError(
                domain: "NetworkBusinessService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Product image upload failed (\(http.statusCode)): \(snippet.prefix(200))"]
            )
        }

        let payload = try decoder.decode(APIProductImageUploadResponse.self, from: responseData)
        return mapProduct(payload.product)
    }

    func checkStorefrontHandleAvailability(handle: String, excluding storefrontID: UUID?) async throws -> StorefrontHandleAvailability {
        let sanitized = sanitizedHandleForSave(handle) ?? ""
        guard !sanitized.isEmpty, isValidHandle(sanitized) else {
            return StorefrontHandleAvailability(
                handle: sanitized,
                status: .invalid,
                message: "Use lowercase letters, numbers, and hyphens."
            )
        }

        var comps = URLComponents(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("storefronts")
                .appendingPathComponent("handles")
                .appendingPathComponent(sanitized)
                .appendingPathComponent("availability"),
            resolvingAgainstBaseURL: false
        )!
        if let storefrontID {
            comps.queryItems = [.init(name: "excludeId", value: storefrontID.uuidString)]
        }
        let (data, _) = try await perform(URLRequest(url: comps.url!))
        let payload = try decoder.decode(APIHandleAvailability.self, from: data)
        return StorefrontHandleAvailability(
            handle: payload.handle,
            status: StorefrontHandleAvailabilityStatus(rawValue: payload.status) ?? (payload.available ? .available : .unknown),
            message: payload.message
        )
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

    // MARK: - Networking helpers

    private func perform(_ request: URLRequest, requiresAuth: Bool = true) async throws -> (Data, URLResponse) {
        var request = request
        if requiresAuth {
            applyAuthHeaders(to: &request)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        #if DEBUG
        print("[Network] \(request.httpMethod ?? "GET") \(PrivacyLog.redactURL(request.url))")
        #endif
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        #if DEBUG
        print("[Network] response status=\(http.statusCode) \(PrivacyLog.redactURL(request.url))")
        #endif
        guard 200..<300 ~= http.statusCode else {
            #if DEBUG
            let snippet = String(data: data, encoding: .utf8) ?? ""
            print("[Network] response failure status=\(http.statusCode) body=\(PrivacyLog.redact(snippet))")
            #endif
            let payload = try? decoder.decode(APIErrorPayload.self, from: data)
            let code = payload?.code ?? payload?.error ?? errorCode(for: http.statusCode)
            let message = payload?.message ?? friendlyMessage(for: code)
            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: message,
                "code": code
            ]
            if let field = payload?.field { userInfo["field"] = field }
            if let checklist = payload?.checklist { userInfo["checklist"] = checklist }
            throw NSError(domain: "OneWayStorefrontAPI", code: http.statusCode, userInfo: userInfo)
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
        let handle: String?
        let slug: String
        let shopUrl: String?
        let logoUrl: String?
        let bannerUrl: String?
        let announcement: String?
        let description: String
        let sellerStory: String?
        let category: String
        let location: String?
        let tagline: String?
        let shippingSettingsJson: String?
        let paymentStatus: String?
        let paymentsReady: Bool?
        let paymentsEnabled: Bool?
        let stripeConnectStatus: String?
        let defaultPaymentMode: String?
        let defaultPaymentLinkUrl: String?
        let policiesReady: Bool?
        let setupComplete: Bool?
        let publishChecklist: [String]?
        let published: Bool?
        let products: [APIProduct]?
        let collections: [APICollection]?
        let theme: APITheme?
        let policy: APIPolicy?
        let layout: APILayout?
    }

    struct APIProduct: Codable {
        let id: UUID
        let name: String?
        let title: String?
        let description: String
        let price: String?
        let priceCents: Int?
        let isSubscription: Bool?
        let mediaURL: URL?
        let primaryImageUrl: String?
        let inventory: Int?
        let inventoryCount: Int?
        let trackInventory: Bool?
        let lowStockThreshold: Int?
        let paymentMode: String?
        let paymentLinkUrl: String?
        let soldOut: Bool?
        let lowStock: Bool?
        let category: String?
        let tags: [String]?
        let imageUrls: [String]?
        let variants: [String]?
        let shippingInfo: String?
        let returnEligible: Bool?
        let status: String?
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

    struct APIPolicy: Codable {
        let returns: String?
        let refunds: String?
        let processingTime: String?
        let shipping: String?
        let support: String?
    }

    struct APIUploadResponse: Codable {
        let url: String
    }

    struct APIProductImageUploadResponse: Codable {
        let image: APIProductImage
        let product: APIProduct
    }

    struct APIProductImage: Codable {
        let imageId: String
        let productId: String
        let storeId: String
        let sellerId: String?
        let storageKey: String
        let url: String
        let thumbnailUrl: String?
        let contentType: String
        let fileSize: Int
        let sortOrder: Int
    }

    struct APIHandleAvailability: Codable {
        let code: String?
        let handle: String
        let available: Bool
        let status: String
        let message: String
    }

    struct APIErrorPayload: Codable {
        let code: String?
        let error: String?
        let message: String?
        let field: String?
        let checklist: [String]?
    }

    struct APILaunchDetails: Codable {
        var contactEmail: String?
        var phone: String?
        var website: String?
        var fulfillmentNote: String?
        var checkoutMode: String?
        var paymentLinkUrl: String?
        var pickupEnabled: Bool?
        var localDeliveryEnabled: Bool?
        var shippingEnabled: Bool?
        var digitalDeliveryEnabled: Bool?
        var pickupInstructions: String?
        var shippingNote: String?
        var deliveryAreaNote: String?
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
                name: $0.title ?? $0.name ?? "Untitled product",
                description: $0.description,
                price: $0.price ?? String(format: "$%.2f", Double($0.priceCents ?? 0) / 100),
                priceCents: $0.priceCents,
                isSubscription: $0.isSubscription ?? false,
            mediaURL: $0.mediaURL ?? $0.primaryImageUrl.flatMap(URL.init(string:)) ?? $0.imageUrls?.first.flatMap(URL.init(string:)),
                inventory: $0.inventoryCount ?? $0.inventory,
                trackInventory: $0.trackInventory,
                lowStockThreshold: $0.lowStockThreshold,
                paymentMode: $0.paymentMode,
                paymentLinkURL: $0.paymentLinkUrl.flatMap(URL.init(string:)),
                isVisible: isVisibleProductStatus($0.status),
                category: $0.category,
                tags: $0.tags ?? [],
                variants: $0.variants ?? [],
                shippingInfo: $0.shippingInfo,
                returnEligible: $0.returnEligible
            )
        }

        let launchDetails = decodeLaunchDetails(api.shippingSettingsJson)
        let business = BusinessProfile(
            id: api.id,
            ownerID: UUID(uuidString: api.ownerId ?? "") ?? api.id,
            name: api.name,
            handle: api.handle ?? api.slug,
            category: api.category,
            tagline: api.tagline ?? "",
            description: api.description,
            logoURL: api.logoUrl.flatMap(URL.init(string:)),
            coverImageURL: api.bannerUrl.flatMap(URL.init(string:)),
            announcement: api.announcement,
            sellerStory: api.sellerStory,
            contactEmail: launchDetails.contactEmail,
            phone: launchDetails.phone,
            website: launchDetails.paymentLinkUrl ?? launchDetails.website,
            socialLinks: [:],
            address: api.location,
            hours: launchDetails.fulfillmentNote,
            pickupEnabled: launchDetails.pickupEnabled,
            localDeliveryEnabled: launchDetails.localDeliveryEnabled,
            shippingEnabled: launchDetails.shippingEnabled,
            digitalDeliveryEnabled: launchDetails.digitalDeliveryEnabled,
            pickupInstructions: launchDetails.pickupInstructions,
            shippingNote: launchDetails.shippingNote,
            deliveryAreaNote: launchDetails.deliveryAreaNote,
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
            shopURL: api.shopUrl,
            paymentStatus: api.paymentStatus,
            paymentsReady: api.paymentsReady ?? false,
            paymentsEnabled: api.paymentsEnabled ?? false,
            stripeConnectStatus: api.stripeConnectStatus,
            defaultPaymentMode: api.defaultPaymentMode,
            defaultPaymentLinkURL: api.defaultPaymentLinkUrl.flatMap(URL.init(string:)),
            policiesReady: api.policiesReady ?? false,
            setupComplete: api.setupComplete ?? false,
            publishChecklist: api.publishChecklist ?? [],
            policy: mapPolicy(api.policy),
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
            handle: snapshot.store.slug,
            category: "Live Commerce",
            tagline: snapshot.store.tagline ?? "",
            description: snapshot.heroSubtitle ?? "Shop and connect live.",
            logoURL: nil,
            coverImageURL: nil,
            announcement: nil,
            sellerStory: nil,
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
            shopURL: APIConfig.storefrontPublicURLString(for: snapshot.store.slug),
            paymentStatus: "active",
            paymentsReady: true,
            paymentsEnabled: true,
            stripeConnectStatus: "connected",
            defaultPaymentMode: "contact",
            defaultPaymentLinkURL: nil,
            policiesReady: true,
            setupComplete: true,
            publishChecklist: [],
            policy: .default,
            isPublished: true,
            publishedState: .published
        )
    }

    private func mapPolicy(_ api: APIPolicy?) -> StorePolicyDraft {
        guard let api else { return .default }
        return StorePolicyDraft(
            returns: api.returns ?? StorePolicyDraft.default.returns,
            refunds: api.refunds ?? StorePolicyDraft.default.refunds,
            processingTime: api.processingTime ?? StorePolicyDraft.default.processingTime,
            shipping: api.shipping ?? StorePolicyDraft.default.shipping,
            support: api.support ?? StorePolicyDraft.default.support
        )
    }

    private func mapProduct(_ api: APIProduct) -> ProductOrService {
        ProductOrService(
            id: api.id,
            name: api.title ?? api.name ?? "Untitled product",
            description: api.description,
            price: api.price ?? String(format: "$%.2f", Double(api.priceCents ?? 0) / 100),
            priceCents: api.priceCents,
            isSubscription: api.isSubscription ?? false,
            mediaURL: api.mediaURL ?? api.primaryImageUrl.flatMap(URL.init(string:)) ?? api.imageUrls?.first.flatMap(URL.init(string:)),
            inventory: api.inventoryCount ?? api.inventory,
            trackInventory: api.trackInventory,
            lowStockThreshold: api.lowStockThreshold,
            paymentMode: api.paymentMode,
            paymentLinkURL: api.paymentLinkUrl.flatMap(URL.init(string:)),
            isVisible: isVisibleProductStatus(api.status),
            category: api.category,
            tags: api.tags ?? [],
            variants: api.variants ?? [],
            shippingInfo: api.shippingInfo,
            returnEligible: api.returnEligible
        )
    }

    private func listingStatus(for product: ProductOrService) -> String {
        (product.isVisible ?? true) ? "active" : "draft"
    }

    private func sellerProductBody(for product: ProductOrService) -> [String: Any?] {
        [
            "title": product.name,
            "description": product.description,
            "priceCents": product.priceCents ?? priceCents(from: product.price),
            "currency": "USD",
            "inventoryCount": product.inventory ?? 0,
            "category": product.category,
            "paymentMode": product.paymentMode ?? "contact",
            "paymentLinkUrl": product.paymentLinkURL?.absoluteString,
            "images": product.mediaURL.map { [$0.absoluteString] } ?? [],
            "primaryImageUrl": product.mediaURL?.absoluteString,
            "status": listingStatus(for: product)
        ]
    }

    private func isVisibleProductStatus(_ status: String?) -> Bool {
        let normalized = (status ?? "published").lowercased()
        return normalized == "published" || normalized == "active"
    }

    private func priceCents(from value: String) -> Int {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dollars = Double(cleaned) ?? 0
        return max(0, Int((dollars * 100).rounded()))
    }

    private func sanitizedHandleForSave(_ value: String?) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let handle = String(value ?? "")
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { allowed.contains($0) }
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return handle.isEmpty ? nil : handle
    }

    private func isValidHandle(_ value: String) -> Bool {
        let pattern = #"^[a-z0-9]+(-[a-z0-9]+)*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func errorCode(for statusCode: Int) -> String {
        switch statusCode {
        case 401, 403:
            return "unauthorized"
        case 409:
            return "duplicate_handle"
        case 400, 422:
            return "validation_failed"
        case 500...599:
            return "backend_unavailable"
        default:
            return "unknown"
        }
    }

    private func friendlyMessage(for code: String) -> String {
        switch code {
        case "duplicate_handle", "handle_taken":
            return "That shop link is already taken."
        case "validation_failed", "bad_request", "invalid_handle":
            return "Please complete all required fields."
        case "unauthorized", "unauthenticated", "profile_required":
            return "Please sign in again."
        case "backend_unavailable":
            return "We couldn't reach OneWay right now."
        default:
            return "Your draft was saved locally. Try again in a moment."
        }
    }

    private func launchDetailsJson(for storefront: Storefront) -> String {
        let details = APILaunchDetails(
            contactEmail: storefront.business.contactEmail,
            phone: storefront.business.phone,
            website: storefront.business.website,
            fulfillmentNote: storefront.business.hours,
            checkoutMode: storefront.defaultPaymentMode ?? (storefront.paymentsEnabled ? "payment_link" : "contact"),
            paymentLinkUrl: storefront.defaultPaymentLinkURL?.absoluteString ?? storefront.business.website,
            pickupEnabled: storefront.business.pickupEnabled,
            localDeliveryEnabled: storefront.business.localDeliveryEnabled,
            shippingEnabled: storefront.business.shippingEnabled,
            digitalDeliveryEnabled: storefront.business.digitalDeliveryEnabled,
            pickupInstructions: storefront.business.pickupInstructions,
            shippingNote: storefront.business.shippingNote,
            deliveryAreaNote: storefront.business.deliveryAreaNote
        )
        guard let data = try? encoder.encode(details),
              let json = String(data: data, encoding: .utf8) else {
            return storefront.business.hours ?? ""
        }
        return json
    }

    private func decodeLaunchDetails(_ value: String?) -> APILaunchDetails {
        guard let value, let data = value.data(using: .utf8) else {
            return APILaunchDetails(contactEmail: nil, phone: nil, website: nil, fulfillmentNote: nil, checkoutMode: nil, paymentLinkUrl: nil, pickupEnabled: nil, localDeliveryEnabled: nil, shippingEnabled: nil, digitalDeliveryEnabled: nil, pickupInstructions: nil, shippingNote: nil, deliveryAreaNote: nil)
        }
        if let decoded = try? decoder.decode(APILaunchDetails.self, from: data) {
            return decoded
        }
        return APILaunchDetails(contactEmail: nil, phone: nil, website: nil, fulfillmentNote: value, checkoutMode: nil, paymentLinkUrl: nil, pickupEnabled: nil, localDeliveryEnabled: nil, shippingEnabled: nil, digitalDeliveryEnabled: nil, pickupInstructions: nil, shippingNote: nil, deliveryAreaNote: nil)
    }

    private func multipartBody(data: Data, fileName: String, mimeType: String, boundary: String) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

#endif
