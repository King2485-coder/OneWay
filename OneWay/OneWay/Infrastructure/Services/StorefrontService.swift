import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
@preconcurrency import UserNotifications
#endif

struct ShopProduct: Codable, Identifiable, Equatable {
    let id: String
    let storeId: String?
    let name: String
    let description: String
    let price: Double
    let imageUrl: String?
    let featured: Bool
    let published: Bool
    let isSubscription: Bool
}

struct SponsoredFeedEntry: Codable, Identifiable, Equatable {
    let id: String
    let budget: Double
    let clicks: Int
    let impressions: Int
    let featured: Bool
    let product: ShopProduct
}

struct ShopStore: Codable, Identifiable, Equatable {
    let id: String
    let ownerId: String?
    let name: String
    let slug: String
    let tagline: String?
    let category: String?
    let featured: Bool?
}

struct AIAvatar: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let personality: String
    let voiceType: String
    let niche: String
}

struct AIAvatarFeedItem: Codable, Identifiable, Equatable {
    let id: String
    let hook: String
    let script: String
    let caption: String
    let videoUrl: String?
    let status: String
    let avatar: AIAvatar
    let product: ShopProduct?
}

struct TrendingLiveSession: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let scheduledFor: String
    let status: String
    let viewerCount: Int
    let avatar: AIAvatar
    let product: ShopProduct?
}

struct FeaturedPayload: Codable {
    let products: [ShopProduct]
    let stores: [ShopStore]
}

struct CheckoutPayload: Codable {
    struct CheckoutOrder: Codable {
        let id: String
        let status: String
    }

    let order: CheckoutOrder
    let checkoutUrl: String?
}

struct RemoteMarketplaceOrder: Decodable {
    struct Item: Decodable {
        let name: String
        let quantity: Int
    }

    let id: String
    let storeId: String?
    let total: Double
    let status: String
    let paymentStatus: String
    let payoutStatus: String
    let oneWayPlatformFeeMinor: Int
    let sellerGrossAmountMinor: Int
    let sellerNetAmountMinor: Int
    let refundedAmountMinor: Int
    let disputedAmountMinor: Int
    let payoutAmountMinor: Int
    let createdAt: String
    let items: [Item]
}

struct CheckoutLineItem: Encodable {
    let productId: String
    let quantity: Int
}

struct RemoteShopConversation: Decodable {
    let id: String
    let shopId: String
    let buyerUserId: String
    let sellerUserId: String
    let productId: String?
    let orderId: String?
    let type: String
    let state: String
    let lastMessageAt: String
}

struct RemoteShopMessage: Decodable {
    let id: String
    let senderUserId: String
    let senderRole: String
    let recipientUserId: String
    let encryptedPayload: String
    let messageType: String
    let sentAt: String
}

private struct ShopConversationListResponse: Decodable { let conversations: [RemoteShopConversation] }
private struct ShopConversationResponse: Decodable { let conversation: RemoteShopConversation }
struct ShopConversationDetailResponse: Decodable {
    let conversation: RemoteShopConversation
    let messages: [RemoteShopMessage]
}
private struct ShopMessageResponse: Decodable { let message: RemoteShopMessage }
private struct CreateShopConversationRequest: Encodable {
    let shopId: String
    let productId: String?
    let orderId: String?
    let type: String
}
private struct SendShopMessageRequest: Encodable {
    let encryptedPayload: String
    let recipientUserId: String
    let messageType = "userMessage"
    let clientMessageId: String
}

struct StorefrontSnapshot: Codable {
    let store: ShopStore
    let products: [ShopProduct]
    let featured: [ShopProduct]
    let heroTitle: String?
    let heroSubtitle: String?
}

private struct MarketplaceStoreDTO: Codable {
    let id: String
    let ownerId: String?
    let name: String
    let slug: String
    let tagline: String?
    let category: String?
    let published: Bool?
}

struct ManagedStorefrontDTO: Codable, Equatable {
    let id: String
    let name: String
    let slug: String
    let description: String?
    let tagline: String?
    let category: String?
    let published: Bool
    let status: String?
}

struct ShopPolicySections: Codable, Equatable, Hashable {
    var processingTimes = ""
    var shippingAndDelivery = ""
    var returnsAndExchanges = ""
    var refunds = ""
    var cancellations = ""
    var digitalProducts = ""
    var damagedOrIncorrectOrders = ""
    var privacyAndCustomerInformation = ""
    var contactingTheSeller = ""
    var customPolicy = ""
}

struct ShopPolicyDocument: Codable, Equatable {
    let sections: ShopPolicySections?
    let publishedSections: ShopPolicySections?
    let version: Int
    let status: String?
    let createdAt: String?
    let updatedAt: String?
    let publishedAt: String?
}

struct PublicShopPolicyDocument: Codable, Equatable {
    let sections: ShopPolicySections
    let version: Int
    let publishedAt: String?
}

private struct ShopPolicyUpdateRequest: Encodable { let sections: ShopPolicySections }

private struct CreateStorefrontRequest: Encodable {
    let name: String
    let category: String
    let tagline: String
}

private struct UpdateStorefrontRequest: Encodable {
    let name: String
    let description: String
    let category: String
    let tagline: String
}

private struct EmptyStorefrontRequest: Encodable {}
private struct DeleteStorefrontRequest: Encodable { let confirmation: String }

private struct ManagedListingDTO: Decodable {
    let id: String
    let title: String
    let status: String
}

private struct CreateManagedListingRequest: Encodable {
    let title: String
    let description: String
    let priceCents: Int
    let currency = "USD"
    let inventory: Int
    let trackInventory = true
    let lowStockThreshold = 3
    let paymentMode = "contact"
    let category: String
    let tags: [String] = []
    let imageUrls: [String] = []
    let variants: [String] = []
    let shippingInfo: String
    let returnEligible = true
    let status: String
}

private struct UpdateManagedListingRequest: Encodable {
    let status: String
}

final class StorefrontService {
    static let shared = StorefrontService()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchStorefront() async throws -> StorefrontSnapshot {
        try await client.get("storefront", requiresAuth: false)
    }

    func fetchProducts() async throws -> [ShopProduct] {
        let snapshot = try await fetchStorefront()
        return snapshot.products
    }

    func fetchMarketplaceProducts() async throws -> [ShopProduct] {
        try await client.get("api/products", requiresAuth: false)
    }

    func fetchMarketplaceOrders() async throws -> [RemoteMarketplaceOrder] {
        try await client.get("api/orders")
    }

    func fetchFeatured() async throws -> FeaturedPayload {
        let snapshot = try await fetchStorefront()
        let featuredProducts = snapshot.featured.isEmpty
            ? snapshot.products.filter(\.featured)
            : snapshot.featured
        return FeaturedPayload(
            products: featuredProducts.isEmpty ? snapshot.products : featuredProducts,
            stores: [snapshot.store]
        )
    }

    func fetchMarketplaceStores(query: String? = nil, category: String? = nil, limit: Int? = nil) async throws -> [ShopStore] {
        var queryItems: [URLQueryItem] = []
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        if let category, !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "category", value: category))
        }
        if let limit, limit > 0 {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        let stores: [MarketplaceStoreDTO] = try await client.get(
            "api/storefronts/marketplace",
            queryItems: queryItems,
            requiresAuth: false
        )
        return stores.map {
            ShopStore(
                id: $0.id,
                ownerId: $0.ownerId,
                name: $0.name,
                slug: $0.slug,
                tagline: $0.tagline,
                category: $0.category,
                featured: $0.published
            )
        }
    }

    func fetchManagedStorefronts() async throws -> [ManagedStorefrontDTO] {
        try await client.get("api/storefronts/me")
    }

    func createManagedStorefront(name: String, description: String, category: String, idempotencyKey: String) async throws -> ManagedStorefrontDTO {
        try await client.post(
            "api/storefronts",
            body: CreateStorefrontRequest(name: name, category: category, tagline: description),
            headers: ["Idempotency-Key": idempotencyKey, "X-Correlation-ID": idempotencyKey]
        )
    }

    func updateManagedStorefront(id: String, name: String, description: String, category: String) async throws -> ManagedStorefrontDTO {
        try await client.patch(
            "api/storefronts/\(id)",
            body: UpdateStorefrontRequest(name: name, description: description, category: category, tagline: description)
        )
    }

    func publishManagedStorefront(id: String) async throws -> ManagedStorefrontDTO {
        try await client.post("api/storefronts/\(id)/publish", body: EmptyStorefrontRequest())
    }

    func unpublishManagedStorefront(id: String) async throws -> ManagedStorefrontDTO {
        try await client.post("api/storefronts/\(id)/unpublish", body: EmptyStorefrontRequest())
    }

    func deleteManagedStorefront(id: String, confirmation: String) async throws {
        let _: EmptyAPIResponse = try await client.delete(
            "api/storefronts/\(id)",
            body: DeleteStorefrontRequest(confirmation: confirmation)
        )
    }

    func fetchShopPolicies(shopID: UUID) async throws -> ShopPolicyDocument {
        try await client.get("api/storefronts/\(shopID.uuidString.lowercased())/policies")
    }

    func saveShopPolicies(shopID: UUID, sections: ShopPolicySections) async throws -> ShopPolicyDocument {
        try await client.patch(
            "api/storefronts/\(shopID.uuidString.lowercased())/policies",
            body: ShopPolicyUpdateRequest(sections: sections)
        )
    }

    func publishShopPolicies(shopID: UUID) async throws -> ShopPolicyDocument {
        try await client.post(
            "api/storefronts/\(shopID.uuidString.lowercased())/policies/publish",
            body: EmptyStorefrontRequest()
        )
    }

    func fetchPublishedShopPolicies(shopID: UUID) async throws -> PublicShopPolicyDocument {
        try await client.get(
            "api/storefronts/marketplace/\(shopID.uuidString.lowercased())/policies",
            requiresAuth: false
        )
    }

    func prepareManagedStorefrontForLaunch(id: String, products: [MarketplaceProduct]) async throws {
        let existing: [ManagedListingDTO] = try await client.get("api/storefronts/\(id)/listings")
        for product in products {
            if let match = existing.first(where: { $0.title.caseInsensitiveCompare(product.title) == .orderedSame }) {
                if match.status != "active" {
                    let _: ManagedListingDTO = try await client.patch(
                        "api/storefronts/listings/\(match.id)",
                        body: UpdateManagedListingRequest(status: "published")
                    )
                }
            } else {
                let inventory = product.specs
                    .first(where: { $0.hasPrefix("Inventory:") })
                    .flatMap { Int($0.replacingOccurrences(of: "Inventory:", with: "").trimmingCharacters(in: .whitespaces)) } ?? 1
                let request = CreateManagedListingRequest(
                    title: product.title,
                    description: product.description,
                    priceCents: max(0, Int((product.price * 100).rounded())),
                    inventory: max(1, inventory),
                    category: product.category,
                    shippingInfo: product.specs.first(where: { $0.lowercased().contains("shipping") }) ?? "Contact seller for shipping details.",
                    status: "published"
                )
                let _: ManagedListingDTO = try await client.post("api/storefronts/\(id)/listings", body: request)
            }
        }
    }

    func fetchTrendingProducts() async throws -> [ShopProduct] {
        do {
            return try await client.get("api/ai/trending-products", requiresAuth: false)
        } catch {
            return try await fetchProducts()
        }
    }

    func fetchSponsoredFeed() async throws -> [SponsoredFeedEntry] {
        do {
            return try await client.get("api/ads/feed", requiresAuth: false)
        } catch {
            return []
        }
    }

    func fetchAvatarFeed() async throws -> [AIAvatarFeedItem] {
        do {
            return try await client.get("api/ai/avatar/feed", requiresAuth: false)
        } catch {
            return []
        }
    }

    func fetchTrendingLives() async throws -> [TrendingLiveSession] {
        do {
            return try await client.get("api/ai/lives/trending", requiresAuth: false)
        } catch {
            return []
        }
    }

    func createCheckout(items: [CheckoutLineItem], idempotencyKey: String) async throws -> CheckoutPayload {
        struct CheckoutRequest: Encodable {
            let idempotencyKey: String
            let items: [CheckoutLineItem]
        }

        return try await client.post(
            "api/orders",
            body: CheckoutRequest(idempotencyKey: idempotencyKey, items: items)
        )
    }

    func createCheckout(for product: ShopProduct) async throws -> CheckoutPayload {
        try await createCheckout(
            items: [.init(productId: product.id, quantity: 1)],
            idempotencyKey: UUID().uuidString.lowercased()
        )
    }

    func fetchShopConversations() async throws -> [RemoteShopConversation] {
        let response: ShopConversationListResponse = try await client.get("api/shops/messages/conversations")
        return response.conversations
    }

    func fetchShopConversation(id: String) async throws -> ShopConversationDetailResponse {
        try await client.get("api/shops/messages/conversations/\(id)")
    }

    func createShopConversation(shopID: UUID, productID: UUID?, orderID: UUID?, type: String) async throws -> RemoteShopConversation {
        let response: ShopConversationResponse = try await client.post(
            "api/shops/messages/conversations",
            body: CreateShopConversationRequest(
                shopId: shopID.uuidString.lowercased(),
                productId: productID?.uuidString.lowercased(),
                orderId: orderID?.uuidString.lowercased(),
                type: type
            )
        )
        return response.conversation
    }

    func sendShopMessage(conversationID: UUID, text: String, recipientUserID: String) async throws -> RemoteShopMessage {
        let response: ShopMessageResponse = try await client.post(
            "api/shops/messages/conversations/\(conversationID.uuidString.lowercased())/messages",
            body: SendShopMessageRequest(
                encryptedPayload: text,
                recipientUserId: recipientUserID,
                clientMessageId: UUID().uuidString.lowercased()
            )
        )
        return response.message
    }
}

@MainActor
final class AIInfluencerManager {
    static let shared = AIInfluencerManager()

    func generateCaption(for product: ShopProduct) -> String {
        "🔥 Trending: \(product.name)! Tap to shop now."
    }

    func generateHook(for product: ShopProduct) -> String {
        "You NEED this \(product.name) in your cart."
    }

    func schedulePost() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        print("📅 AI scheduled a post")
    }
}

struct LaunchGrowthManager {
    static let shared = LaunchGrowthManager()

    func inviteLink(for userID: String) -> URL {
        URL(string: "https://oneway.app/invite/\(userID)")!
    }

    func referralRewardText() -> String {
        "$10 credits • boosted visibility • higher affiliate share"
    }

    func fomoMessage(for viewerCount: Int) -> String {
        "🔥 \(viewerCount) people watching now"
    }
}

@MainActor
final class RetentionNudgeManager {
    static let shared = RetentionNudgeManager()

    private let defaults = UserDefaults.standard
    private let scheduledKey = "oneway.retention_nudges_scheduled"

    func scheduleFirstDayNudgesIfNeeded() {
        guard !defaults.bool(forKey: scheduledKey) else { return }
        defaults.set(true, forKey: scheduledKey)

        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in

                let nudges: [(identifier: String, hours: Double, title: String, body: String)] = [
                    ("oneway.nudge.1h", 1, "Someone just went live", "🔥 Someone just went live — don’t miss it"),
                    ("oneway.nudge.6h", 6, "New deals dropped", "💸 New deals just dropped"),
                    ("oneway.nudge.24h", 24, "Trending lives are moving", "🚀 You’re missing trending lives right now")
                ]

                for nudge in nudges {
                    let content = UNMutableNotificationContent()
                    content.title = nudge.title
                    content.body = nudge.body
                    if CallSoundSuppressionController.shared.isSuppressionActive {
                        #if DEBUG
                        print(
                            "NOTIFICATION_SOUND_REMOVED_DURING_CALL",
                            "identifier=\(nudge.identifier)",
                            "activeCallIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
                            "source=RetentionNudgeManager.scheduleFirstDayNudgesIfNeeded",
                            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                        )
                        #endif
                    } else {
                        SoundDiagnostics.logAudioPlayRequest(
                            filename: "UNNotificationSound.default",
                            soundID: "default",
                            systemSoundID: nil,
                            avAudioPlayerURL: nil,
                            avPlayerURL: nil,
                            category: .notification,
                            callId: nil,
                            sourceFile: #fileID,
                            sourceFunction: #function,
                            line: #line
                        )
                        content.sound = .default
                    }

                    let trigger = UNTimeIntervalNotificationTrigger(
                        timeInterval: max(5, nudge.hours * 3600),
                        repeats: false
                    )
                    let request = UNNotificationRequest(
                        identifier: nudge.identifier,
                        content: content,
                        trigger: trigger
                    )
                    try? await UNUserNotificationCenter.current().add(request)
                }
            }
        }
        #endif
    }
}
