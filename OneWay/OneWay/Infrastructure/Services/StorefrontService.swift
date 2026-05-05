import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
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
    let name: String
    let slug: String
    let tagline: String?
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

struct StorefrontSnapshot: Codable {
    let store: ShopStore
    let products: [ShopProduct]
    let featured: [ShopProduct]
    let heroTitle: String?
    let heroSubtitle: String?
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

    func createCheckout(for product: ShopProduct) async throws -> CheckoutPayload {
        struct CheckoutRequest: Encodable {
            struct Item: Encodable {
                let productId: String
                let quantity: Int
            }

            let items: [Item]
        }

        return try await client.post(
            "api/orders",
            body: CheckoutRequest(items: [.init(productId: product.id, quantity: 1)])
        )
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
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }

            let nudges: [(identifier: String, hours: Double, title: String, body: String)] = [
                ("oneway.nudge.1h", 1, "Someone just went live", "🔥 Someone just went live — don’t miss it"),
                ("oneway.nudge.6h", 6, "New deals dropped", "💸 New deals just dropped"),
                ("oneway.nudge.24h", 24, "Trending lives are moving", "🚀 You’re missing trending lives right now")
            ]

            for nudge in nudges {
                let content = UNMutableNotificationContent()
                content.title = nudge.title
                content.body = nudge.body
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(5, nudge.hours * 3600),
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: nudge.identifier,
                    content: content,
                    trigger: trigger
                )
                center.add(request)
            }
        }
        #endif
    }
}
