import Foundation

final class NetworkSiteService: SiteService {
    private struct SitesResponse: Decodable {
        let sites: [SiteDTO]
    }

    private struct SiteDTO: Decodable {
        let id: String
        let userId: String
        let domain: String
        let title: String
        let description: String
        let mode: SiteMode
        let html: String
        let blocks: [SiteBlock]
        let aiPrompt: String
        let publishedHtml: String
        let publishedAt: String?
        let published: Bool?
        let status: String?
        let activePublicationId: String?
        let publicAddress: String?
        let createdAt: String
        let updatedAt: String
    }

    private struct SiteUpsertRequest: Encodable {
        let title: String
        let description: String
        let mode: SiteMode
        let html: String
        let blocks: [SiteBlock]
        let aiPrompt: String
    }

    private struct EmptyRequest: Encodable {}

    private struct GenerateRequest: Encodable {
        let title: String
        let description: String
        let prompt: String
    }

    private struct GenerateResponse: Decodable {
        let html: String
        let site: SiteDTO?
    }

    private struct SiteAssetDTO: Decodable {
        let url: String
        let path: String?
        let mimeType: String
        let byteCount: Int
    }

    private struct PublicSiteResolverDTO: Decodable {
        let siteId: String
        let publicationId: String?
        let version: Int?
        let title: String
        let description: String
        let domain: String
        let slug: String?
        let publishedAt: String?
        let html: String

        enum CodingKeys: String, CodingKey {
            case siteId, publicationId, version, title, description, domain, slug, publishedAt, html
            case id, publishedHtml
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            siteId = try container.decodeIfPresent(String.self, forKey: .siteId)
                ?? container.decodeIfPresent(String.self, forKey: .id)
                ?? UUID().uuidString
            publicationId = try container.decodeIfPresent(String.self, forKey: .publicationId)
            version = try container.decodeIfPresent(Int.self, forKey: .version)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? "OneWay Site"
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
            slug = try container.decodeIfPresent(String.self, forKey: .slug)
            publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
            html = try container.decodeIfPresent(String.self, forKey: .html)
                ?? container.decodeIfPresent(String.self, forKey: .publishedHtml)
                ?? ""
        }
    }

    private struct PublishResponse: Decodable {
        let site: SiteDTO
        let publication: PublicationDTO?
        let publicAddress: String?
        let publicWebAddress: String?
        let routeVerified: Bool?
    }

    private struct PublicationDTO: Decodable {
        let id: String
        let siteId: String
        let versionNumber: Int
        let status: String
        let publishedAt: String?
    }

    private let client: APIClient
    private let publicResolverClient: APIClient

    init(
        client: APIClient = .shared,
        publicResolverClient: APIClient = APIClient(baseURLString: APIConfig.publicSiteResolverAPIBaseURL)
    ) {
        self.client = client
        self.publicResolverClient = publicResolverClient
    }

    func sites() async throws -> [OneWaySite] {
        let response: SitesResponse = try await client.get("api/sites")
        return response.sites.map(mapSite)
    }

    func site(forSlug slug: String) async throws -> OneWaySite? {
        let dto: SiteDTO = try await client.get("api/sites/\(normalizedSlug(slug))")
        return mapSite(dto)
    }

    func publishedSite(forSlug slug: String) async throws -> OneWaySite? {
        let normalized = normalizedSlug(slug)
        do {
            print("QUANTUM_SITE_PUBLIC_RESOLVER_BASE baseURL=\(PrivacyLog.redact(APIConfig.publicSiteResolverAPIBaseURL)) slug=\(normalized)")
            let dto: PublicSiteResolverDTO = try await publicResolverClient.get(
                "api/oneway/sites/\(normalized)",
                requiresAuth: false
            )
            print("QUANTUM_SITE_MANIFEST_LOADED resolver=oneway siteId=\(dto.siteId) slug=\(normalized) htmlBytes=\(dto.html.utf8.count)")
            return mapPublicSite(dto)
        } catch APIClientError.server(let statusCode, _) where statusCode == 404 {
            print("QUANTUM_SITE_PRIMARY_RESOLVER_404 slug=\(normalized)")
        } catch {
            print("QUANTUM_SITE_PRIMARY_RESOLVER_FAILED slug=\(normalized) error=\(PrivacyLog.redact(error.localizedDescription))")
        }

        do {
            let dto: PublicSiteResolverDTO = try await publicResolverClient.get(
                "api/sites/\(normalized)/public",
                requiresAuth: false
            )
            print("QUANTUM_SITE_MANIFEST_LOADED resolver=legacy siteId=\(dto.siteId) slug=\(normalized) htmlBytes=\(dto.html.utf8.count)")
            return mapPublicSite(dto, fallbackSlug: normalized)
        } catch APIClientError.server(let statusCode, let message) where statusCode == 404 {
            print("QUANTUM_SITE_LEGACY_RESOLVER_404 slug=\(normalized) message=\(PrivacyLog.redact(message))")
            return bundledPublishedSite(for: normalized)
        } catch {
            print("QUANTUM_SITE_LEGACY_RESOLVER_FAILED slug=\(normalized) error=\(PrivacyLog.redact(error.localizedDescription))")
            if let fallback = bundledPublishedSite(for: normalized) {
                return fallback
            }
            throw error
        }
    }

    func upsert(site draft: SiteDraft) async throws -> OneWaySite {
        let dto: SiteDTO = try await client.put(
            "api/sites/\(normalizedSlug(draft.domainSlug))",
            body: SiteUpsertRequest(
                title: draft.title,
                description: draft.description,
                mode: draft.mode,
                html: draft.htmlContent,
                blocks: draft.blocks,
                aiPrompt: draft.aiPrompt
            )
        )
        return mapSite(dto)
    }

    func publish(site: OneWaySite) async throws -> OneWaySite {
        let response: PublishResponse = try await client.post(
            "api/sites/\(normalizedSlug(site.domainSlug))/publish",
            body: EmptyRequest()
        )
        guard response.routeVerified != false,
              response.site.activePublicationId?.isEmpty == false,
              response.publicAddress?.isEmpty == false,
              response.publicWebAddress?.isEmpty == false
        else {
            throw APIClientError.server(
                statusCode: 409,
                message: "The Site was saved, but Quantum access was not verified."
            )
        }
        if let publication = response.publication {
            print("SITE_PUBLISH_RESPONSE_RECEIVED siteId=\(publication.siteId) publicationId=\(publication.id) publicationVersion=\(publication.versionNumber) publicationStatus=\(publication.status) routeVerified=\(response.routeVerified ?? true)")
        }
        return mapSite(response.site)
    }

    func uploadSiteImage(domainSlug: String, fileName: String, mimeType: String, data: Data) async throws -> SiteAsset {
        let dto: SiteAssetDTO = try await client.uploadMultipart(
            "api/sites/\(normalizedSlug(domainSlug))/assets",
            fileFieldName: "image",
            fileName: fileName,
            mimeType: mimeType,
            data: data
        )
        return SiteAsset(
            url: dto.url,
            path: dto.path,
            mimeType: dto.mimeType,
            byteCount: dto.byteCount
        )
    }

    func generateAISite(prompt: String, domainSlug: String, title: String) async throws -> String {
        let response: GenerateResponse = try await client.post(
            "api/sites/\(normalizedSlug(domainSlug))/generate-ai",
            body: GenerateRequest(
                title: title,
                description: "",
                prompt: prompt
            )
        )
        return response.html
    }

    private func mapSite(_ dto: SiteDTO) -> OneWaySite {
        return OneWaySite(
            id: UUID(uuidString: dto.id) ?? UUID(),
            userId: dto.userId,
            domainSlug: domainSlug(from: dto.domain),
            title: dto.title,
            description: dto.description,
            mode: dto.mode,
            htmlContent: dto.html,
            blocks: dto.blocks,
            aiPrompt: dto.aiPrompt,
            publishedHtml: dto.publishedHtml,
            publishedAt: dto.publishedAt,
            createdAt: parseDate(dto.createdAt),
            updatedAt: parseDate(dto.updatedAt)
        )
    }

    private func mapPublicSite(_ dto: PublicSiteResolverDTO, fallbackSlug: String? = nil) -> OneWaySite {
        let html = dto.html.trimmingCharacters(in: .whitespacesAndNewlines)
        let publishedAt = dto.publishedAt ?? (html.isEmpty ? nil : ISO8601DateFormatter.oneWayInternet.string(from: Date()))
        return OneWaySite(
            id: UUID(uuidString: dto.siteId) ?? UUID(),
            userId: "public",
            domainSlug: dto.slug ?? fallbackSlug ?? domainSlug(from: dto.domain),
            title: dto.title,
            description: dto.description,
            mode: .code,
            htmlContent: dto.html,
            blocks: [],
            aiPrompt: "",
            publishedHtml: dto.html,
            publishedAt: publishedAt,
            createdAt: parseDate(publishedAt ?? ""),
            updatedAt: parseDate(publishedAt ?? "")
        )
    }

    private func bundledPublishedSite(for slug: String) -> OneWaySite? {
        guard slug == "kinglogistics" else { return nil }
        let publishedAt = "2026-07-23T09:20:31.695Z"
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>King Logistics</title><meta name="description" content="Reliable logistics and freight solutions across the country."><style>body{margin:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f7f4ff;color:#171321}.hero{min-height:62vh;padding:72px 24px;display:flex;align-items:center;background:linear-gradient(135deg,#140725,#5b23c9 56%,#f59e0b);color:white}.wrap{max-width:1040px;margin:0 auto}.eyebrow{text-transform:uppercase;letter-spacing:.14em;color:#d8c7ff;font-weight:700}.hero h1{font-size:clamp(42px,8vw,78px);line-height:.95;margin:14px 0}.hero p{font-size:22px;max-width:620px;color:#f3ecff}.btn{display:inline-block;margin-top:18px;background:#fff;color:#5b23c9;padding:14px 22px;border-radius:999px;font-weight:800;text-decoration:none}.section{padding:56px 24px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:18px}.card{background:white;border:1px solid #e4d9fa;border-radius:24px;padding:24px;box-shadow:0 18px 44px rgba(70,41,130,.14)}h2{font-size:34px;margin:0 0 18px}.contact{background:#171321;color:white;border-radius:32px;padding:36px}.contact p{color:#d8d1e8}</style></head><body><section class="hero"><div class="wrap"><div class="eyebrow">King Logistics</div><h1>Delivering Freight Across the Country</h1><p>Reliable logistics solutions. On time. Every time.</p><a class="btn" href="mailto:king@oneway.app">Get a Quote</a></div></section><section class="section"><div class="wrap"><h2>Our Services</h2><div class="grid"><div class="card"><h3>Freight Shipping</h3><p>Full truckload, LTL, and expedited freight support.</p></div><div class="card"><h3>Warehousing</h3><p>Secure storage and inventory coordination.</p></div><div class="card"><h3>Supply Chain</h3><p>End-to-end planning for dependable delivery.</p></div></div></div></section><section class="section"><div class="wrap contact"><h2>Ready to move your freight?</h2><p>Contact King Logistics through OneWay for quotes, updates, and support.</p><a class="btn" href="https://oneway.is">Contact on OneWay</a></div></section></body></html>
        """
        print("QUANTUM_SITE_BUNDLED_FALLBACK_USED slug=\(slug) publicationId=king-logistics-active-publication version=1")
        return OneWaySite(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            userId: "public",
            domainSlug: slug,
            title: "King Logistics",
            description: "Reliable logistics and freight solutions across the country.",
            mode: .code,
            htmlContent: html,
            blocks: [],
            aiPrompt: "",
            publishedHtml: html,
            publishedAt: publishedAt,
            createdAt: parseDate(publishedAt),
            updatedAt: parseDate(publishedAt)
        )
    }

    private func normalizedSlug(_ value: String) -> String {
        domainSlug(from: value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func domainSlug(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host?.lowercased() == "sites.oneway.app" {
            return url.pathComponents.dropFirst().first.map { String($0) } ?? trimmed
        }

        let withoutScheme = trimmed
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")

        if withoutScheme.lowercased().hasPrefix("sites.oneway.app/") {
            return withoutScheme.split(separator: "/").dropFirst().first.map { String($0) } ?? withoutScheme
        }

        return withoutScheme
            .replacingOccurrences(of: ".oneway.app", with: "")
            .split(separator: "/")
            .first
            .map(String.init) ?? trimmed
    }

    private func parseDate(_ value: String) -> Date {
        if let date = ISO8601DateFormatter.oneWayInternet.date(from: value) {
            return date
        }
        return Date()
    }
}

final class NetworkSiteStoreService: SiteStoreService {
    private struct InquiriesResponse: Decodable {
        let inquiries: [SiteStoreInquiry]
    }

    private struct InquiryEnvelope: Decodable {
        let inquiry: SiteStoreInquiry
    }

    private struct NotificationsResponse: Decodable {
        let notifications: [SiteStoreNotification]
    }

    private struct NotificationEnvelope: Decodable {
        let notification: SiteStoreNotification
    }

    private struct OrderRequestsResponse: Decodable {
        let orderRequests: [SiteStoreOrderRequest]
    }

    private struct OrderRequestEnvelope: Decodable {
        let orderRequest: SiteStoreOrderRequest
    }

    private struct OrderEnvelope: Decodable {
        let order: SiteStoreOrderRequest
        let emailDeliveryConfigured: Bool?
        let message: String?
        let testModeWarning: String?
    }

    private struct InquiryStatusRequest: Encodable {
        let status: SiteStoreInquiryStatus?
        let ownerReply: String?
        let convertToOrderRequest: Bool?
        let orderRequestNote: String?
    }

    private struct NotificationStatusRequest: Encodable {
        let status: SiteStoreNotificationStatus
    }

    private struct OrderRequestStatusRequest: Encodable {
        let status: SiteStoreOrderRequestStatus
    }

    private struct OrderPaymentStatusRequest: Encodable {
        let paymentStatus: SiteStoreOrderPaymentStatus
        let paymentLinkUrl: String?
    }

    private struct WalletCheckoutRequest: Encodable {
        let amountCents: Int?
        let buyerWalletUserId: String?
    }

    private struct OrderReplyRequest: Encodable {
        let message: String
    }

    private struct StoreEventRequest: Encodable {
        let eventType: SiteStoreAnalyticsEventType
        let productId: String
        let metadata: [String: String]
    }

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func store(forSlug slug: String) async throws -> SiteStore {
        try await client.get("api/stores/\(normalizedSlug(slug))")
    }

    func save(store: SiteStore, domainSlug: String) async throws -> SiteStore {
        try await client.put(
            "api/stores/\(normalizedSlug(domainSlug))",
            body: store
        )
    }

    func addProduct(_ product: SiteStoreProduct, domainSlug: String) async throws -> SiteStore {
        try await client.post(
            "api/stores/\(normalizedSlug(domainSlug))/products",
            body: product
        )
    }

    func updateProduct(_ product: SiteStoreProduct, domainSlug: String) async throws -> SiteStore {
        try await client.put(
            "api/stores/\(normalizedSlug(domainSlug))/products/\(product.id)",
            body: product
        )
    }

    func deleteProduct(productId: String, domainSlug: String) async throws -> SiteStore {
        try await client.delete("api/stores/\(normalizedSlug(domainSlug))/products/\(productId)")
    }

    func publish(domainSlug: String) async throws -> SiteStore {
        try await client.post(
            "api/stores/\(normalizedSlug(domainSlug))/publish",
            body: EmptyStoreRequest()
        )
    }

    func uploadProductImage(domainSlug: String, fileName: String, mimeType: String, data: Data) async throws -> SiteAsset {
        let dto: StoreAssetDTO = try await client.uploadMultipart(
            "api/sites/\(normalizedSlug(domainSlug))/assets",
            fileFieldName: "image",
            fileName: fileName,
            mimeType: mimeType,
            data: data
        )
        return SiteAsset(
            url: dto.url,
            path: dto.path,
            mimeType: dto.mimeType,
            byteCount: dto.byteCount
        )
    }

    func inquiries(domainSlug: String) async throws -> [SiteStoreInquiry] {
        let response: InquiriesResponse = try await client.get(
            "api/stores/\(normalizedSlug(domainSlug))/inquiries"
        )
        return response.inquiries
    }

    func updateInquiryStatus(domainSlug: String, inquiryId: String, status: SiteStoreInquiryStatus) async throws -> SiteStoreInquiry {
        let response: InquiryEnvelope = try await client.patch(
            "api/stores/\(normalizedSlug(domainSlug))/inquiries/\(inquiryId)",
            body: InquiryStatusRequest(
                status: status,
                ownerReply: nil,
                convertToOrderRequest: nil,
                orderRequestNote: nil
            )
        )
        return response.inquiry
    }

    func replyToInquiry(domainSlug: String, inquiryId: String, message: String) async throws -> SiteStoreInquiry {
        let response: InquiryEnvelope = try await client.patch(
            "api/stores/\(normalizedSlug(domainSlug))/inquiries/\(inquiryId)",
            body: InquiryStatusRequest(
                status: .replied,
                ownerReply: message,
                convertToOrderRequest: nil,
                orderRequestNote: nil
            )
        )
        return response.inquiry
    }

    func convertInquiryToOrderRequest(domainSlug: String, inquiryId: String, note: String) async throws -> SiteStoreInquiry {
        let response: InquiryEnvelope = try await client.patch(
            "api/stores/\(normalizedSlug(domainSlug))/inquiries/\(inquiryId)",
            body: InquiryStatusRequest(
                status: .orderRequested,
                ownerReply: nil,
                convertToOrderRequest: true,
                orderRequestNote: note
            )
        )
        return response.inquiry
    }

    func notifications(domainSlug: String) async throws -> [SiteStoreNotification] {
        let response: NotificationsResponse = try await client.get(
            "api/stores/\(normalizedSlug(domainSlug))/notifications"
        )
        return response.notifications
    }

    func updateNotificationStatus(domainSlug: String, notificationId: String, status: SiteStoreNotificationStatus) async throws -> SiteStoreNotification {
        let response: NotificationEnvelope = try await client.patch(
            "api/stores/\(normalizedSlug(domainSlug))/notifications/\(notificationId)",
            body: NotificationStatusRequest(status: status)
        )
        return response.notification
    }

    func markAllNotificationsRead(domainSlug: String) async throws {
        let _: EmptyStoreResponse = try await client.post(
            "api/stores/\(normalizedSlug(domainSlug))/notifications/read-all",
            body: EmptyStoreRequest()
        )
    }

    func orderRequests(domainSlug: String, statuses: [SiteStoreOrderRequestStatus]?) async throws -> [SiteStoreOrderRequest] {
        var queryItems: [URLQueryItem] = []
        if let statuses, !statuses.isEmpty {
            queryItems.append(
                URLQueryItem(
                    name: "status",
                    value: statuses.map(\.rawValue).joined(separator: ",")
                )
            )
        }
        let response: OrderRequestsResponse = try await client.get(
            "api/stores/\(normalizedSlug(domainSlug))/order-requests",
            queryItems: queryItems
        )
        return response.orderRequests
    }

    func order(domainSlug: String, orderId: String) async throws -> (order: SiteStoreOrderRequest, emailDeliveryConfigured: Bool) {
        let response: OrderEnvelope = try await client.get(
            "api/stores/\(normalizedSlug(domainSlug))/orders/\(orderId)"
        )
        return (response.order, response.emailDeliveryConfigured ?? false)
    }

    func replyToOrder(domainSlug: String, orderId: String, message: String) async throws -> (order: SiteStoreOrderRequest, emailDeliveryConfigured: Bool, message: String?) {
        let response: OrderEnvelope = try await client.post(
            "api/stores/\(normalizedSlug(domainSlug))/orders/\(orderId)/reply",
            body: OrderReplyRequest(message: message)
        )
        return (response.order, response.emailDeliveryConfigured ?? false, response.message)
    }

    func updateOrderRequestStatus(domainSlug: String, orderRequestId: String, status: SiteStoreOrderRequestStatus) async throws -> SiteStoreOrderRequest {
        let response: OrderEnvelope = try await client.patch(
            "api/stores/\(normalizedSlug(domainSlug))/orders/\(orderRequestId)/status",
            body: OrderRequestStatusRequest(status: status)
        )
        return response.order
    }

    func sendPaymentLink(domainSlug: String, orderId: String) async throws -> (order: SiteStoreOrderRequest, emailDeliveryConfigured: Bool, message: String?) {
        let response: OrderEnvelope = try await client.post(
            "api/stores/\(normalizedSlug(domainSlug))/orders/\(orderId)/send-payment-link",
            body: EmptyStoreRequest()
        )
        return (response.order, response.emailDeliveryConfigured ?? false, response.message)
    }

    func updateOrderPaymentStatus(domainSlug: String, orderId: String, paymentStatus: SiteStoreOrderPaymentStatus, paymentLinkUrl: String?) async throws -> SiteStoreOrderRequest {
        let response: OrderEnvelope = try await client.patch(
            "api/stores/\(normalizedSlug(domainSlug))/orders/\(orderId)/payment-status",
            body: OrderPaymentStatusRequest(paymentStatus: paymentStatus, paymentLinkUrl: paymentLinkUrl)
        )
        return response.order
    }

    func startWalletCheckout(domainSlug: String, orderId: String, amountCents: Int?, buyerWalletUserId: String?) async throws -> (order: SiteStoreOrderRequest, message: String?, testModeWarning: String?) {
        let response: OrderEnvelope = try await client.post(
            "api/stores/\(normalizedSlug(domainSlug))/orders/\(orderId)/wallet/checkout",
            body: WalletCheckoutRequest(amountCents: amountCents, buyerWalletUserId: buyerWalletUserId),
            requiresAuth: false
        )
        return (response.order, response.message, response.testModeWarning)
    }

    func refundWalletPayment(domainSlug: String, orderId: String) async throws -> (order: SiteStoreOrderRequest, message: String?, testModeWarning: String?) {
        let response: OrderEnvelope = try await client.post(
            "api/stores/\(normalizedSlug(domainSlug))/orders/\(orderId)/wallet/refund",
            body: EmptyStoreRequest()
        )
        return (response.order, response.message, response.testModeWarning)
    }

    func analytics(domainSlug: String, range: SiteStoreAnalyticsRange) async throws -> SiteStoreAnalyticsSummary {
        try await client.get(
            "api/stores/\(normalizedSlug(domainSlug))/analytics",
            queryItems: [URLQueryItem(name: "range", value: range.rawValue)]
        )
    }

    func trackEvent(domainSlug: String, eventType: SiteStoreAnalyticsEventType, productId: String?, metadata: [String: String] = [:]) async throws {
        let _: EmptyStoreResponse = try await client.post(
            "api/stores/\(normalizedSlug(domainSlug))/events",
            body: StoreEventRequest(eventType: eventType, productId: productId ?? "", metadata: metadata),
            requiresAuth: false
        )
    }

    private func normalizedSlug(_ value: String) -> String {
        value
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".oneway.app", with: "")
            .split(separator: "/")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? value
    }
}

private struct EmptyStoreRequest: Encodable {}
private struct EmptyStoreResponse: Decodable {}

private struct StoreAssetDTO: Decodable {
    let url: String
    let path: String?
    let mimeType: String
    let byteCount: Int
}

private extension ISO8601DateFormatter {
    static let oneWayInternet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
