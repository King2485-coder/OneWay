import Foundation

struct MarketplaceShop: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var name: String
    var slug: String
    var description: String
    var category: String
    var rating: Double
    var reviewCount: Int
    var sales: Int
    var sinceYear: Int
    var privacyScore: Int
    var verified: Bool
    var bannerSeed: String
    var logoSeed: String
    /// Stable authenticated account identifier returned by the backend.
    /// This is intentionally a String because authentication providers are not
    /// required to use UUID-shaped subjects.
    var ownerUserID: String? = nil
}

struct MarketplaceProduct: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var shopID: UUID
    var title: String
    var category: String
    var subcategory: String
    var price: Double
    var rating: Double
    var reviewCount: Int
    var description: String
    var specs: [String]
    var colors: [String]
    var imageSeed: String
    var images: [MarketplaceProductImage] = []
    var privacyVerified: Bool

    var primaryImage: MarketplaceProductImage? {
        images.first(where: \.isPrimary) ?? images.sorted { $0.sortOrder < $1.sortOrder }.first
    }
}

struct MarketplaceProductImage: Identifiable, Equatable, Codable, Hashable {
    enum UploadState: String, Codable, Hashable {
        case selected
        case preparing
        case uploading
        case processing
        case completed
        case failed
    }

    var id = UUID()
    var productId: UUID?
    var sellerId: UUID?
    var storageKey: String
    var originalFileName: String
    var thumbnailFileName: String
    var mediumFileName: String
    var width: Double
    var height: Double
    var fileSize: Int
    var mimeType: String
    var sortOrder: Int
    var isPrimary: Bool
    var altText: String
    var uploadState: UploadState
    var progress: Double
    var errorMessage: String?
    var createdAt = Date()
    var updatedAt = Date()

    var isCompleted: Bool { uploadState == .completed }
}

struct MarketplaceCategory: Identifiable, Equatable, Codable, Hashable {
    var id = UUID()
    var name: String
    var icon: String
    var chips: [String]
}

struct CartItem: Identifiable, Equatable, Codable {
    let id: UUID
    var productID: UUID
    var quantity: Int
}

struct ShopConversation: Identifiable, Equatable, Codable, Hashable {
    enum ConversationType: String, CaseIterable, Codable, Hashable {
        case productInquiry = "Product Inquiry"
        case orderConversation = "Order Conversation"
        case generalQuestion = "General Shop Question"
        case customRequest = "Custom Request"
    }

    enum ConversationState: String, CaseIterable, Codable, Hashable {
        case open = "Open"
        case archived = "Archived"
        case blocked = "Blocked"
        case deleted = "Deleted"
    }

    struct ShopMessage: Identifiable, Equatable, Codable, Hashable {
        var id = UUID()
        var text: String
        var isMine: Bool
        var date: Date
        var status: String = "sent"
        var messageType: String = "userMessage"
        var deletedForMe = false
    }

    typealias Message = ShopMessage

    let id: UUID
    var shopID: UUID
    var buyerUserID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    var sellerUserID: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    var buyerName: String = "Ari Buyer"
    var buyerHandle: String = "@buyer"
    var sellerName: String = "OneWay Seller"
    var productID: UUID?
    var orderID: UUID?
    var type: ConversationType = .generalQuestion
    var state: ConversationState = .open
    var subject: String
    var lastMessage: String
    var unreadCount: Int
    var isMuted = false
    var blockedByBuyer = false
    var blockedBySeller = false
    var archivedByBuyer = false
    var archivedBySeller = false
    var deletedByBuyer = false
    var deletedBySeller = false
    var lastMessageAt = Date()
    var messages: [ShopMessage]

    var isBlocked: Bool { blockedByBuyer || blockedBySeller || state == .blocked }
}

typealias MessageThread = ShopConversation

struct ShopMessagingSettings: Equatable, Codable, Hashable {
    enum SellerPermission: String, CaseIterable, Codable, Hashable {
        case anyone = "Anyone"
        case engagedBuyers = "Viewed or favorited"
        case orderBuyers = "Active or previous order"
        case approvedOnly = "Approved buyers only"
        case nobody = "Nobody"
    }

    enum BuyerPermission: String, CaseIterable, Codable, Hashable {
        case sellersIContacted = "Sellers I contacted"
        case purchasedFrom = "Sellers I purchased from"
        case activeOrdersOnly = "Active orders only"
        case approvedOnly = "Approved sellers only"
        case nobody = "Nobody"
    }

    var sellerPermission: SellerPermission = .anyone
    var allowProductQuestions = true
    var allowCustomRequests = true
    var allowOrderOnlyMessages = true
    var allowMessagesFromNewAccounts = true
    var sellerAllowAttachments = true
    var sellerAllowLinks = false
    var autoCloseInactive = false
    var requireOrderNumberForSupport = false

    var buyerPermission: BuyerPermission = .sellersIContacted
    var allowOrderUpdates = true
    var allowPromotionalMessages = false
    var allowFollowUpAfterOrder = false
    var allowCustomOfferMessages = true
    var buyerAllowAttachments = true
    var buyerAllowLinks = false
    var showReadReceipts = false
    var showTypingIndicator = true
    var showActivityStatus = false
}

struct ShopBlockedContact: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var displayName: String
    var handle: String
    var scope: String
    var blockedAt: Date
}

struct Review: Identifiable, Equatable, Codable {
    var id = UUID()
    var productID: UUID
    var author: String
    var rating: Double
    var text: String
}

struct MarketplaceOrder: Identifiable, Equatable, Codable {
    var id = UUID()
    var shopID: UUID? = nil
    var title: String
    var status: String
    var total: Double
    var tax: Double?
    var shipping: Double?
    var discount: Double?
    var couponCode: String?
    var platformFee: Double?
    var processingFee: Double?
    var sellerEarnings: Double?
    var sellerGross: Double?
    var refundedAmount: Double?
    var disputedAmount: Double?
    var payoutAmount: Double?
    var paymentStatus: MarketplacePaymentStatus?
    var payoutStatus: MarketplacePayoutStatus?
    var refundStatus: MarketplaceRefundStatus?
    var disputeStatus: MarketplaceDisputeStatus?
    var transactionID: String?
    var connectedAccountID: String?
    var createdAt: Date?
}

struct MarketplaceBuyerProfile: Equatable, Codable, Hashable {
    var displayName = "OneWay Shopper"
    var profileImageName: String? = nil
    var useMarketplaceName = true
    var accountStatus = "Active"
    var receiptPreference = "Digital receipts"
    var defaultPaymentPreference = "Secure checkout"
}

struct MarketplacePrivacySettings: Equatable, Codable, Hashable {
    var hidePurchaseHistory = true
    var hideSavedShops = true
    var hideMarketplaceActivity = true
    var useMarketplaceDisplayName = true
    var limitSellerProfileAccess = true
    var hidePhoneNumber = true
    var hidePersonalOneWayID = true
    var sellersUseShopMessagesOnly = true
    var requireOrderContextForSupport = true

    var badgeTitle: String {
        let enabled = [
            hidePurchaseHistory,
            hideSavedShops,
            hideMarketplaceActivity,
            useMarketplaceDisplayName,
            limitSellerProfileAccess,
            hidePhoneNumber,
            hidePersonalOneWayID,
            sellersUseShopMessagesOnly,
            requireOrderContextForSupport
        ].filter { $0 }.count
        if enabled >= 8 { return "Private by Default" }
        if enabled >= 4 { return "Custom Privacy" }
        return "Standard Visibility"
    }
}

struct MarketplaceNotificationSettings: Equatable, Codable, Hashable {
    var newShopMessage = true
    var sellerReply = true
    var orderUpdates = true
    var shippingUpdates = true
    var delivery = true
    var refundsAndReturns = true
    var savedShopUpdates = false
    var promotionalNotifications = false
}

struct MarketplaceShippingAddress: Identifiable, Equatable, Codable, Hashable {
    var id = UUID()
    var label = "Home"
    var recipient = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var region = ""
    var postalCode = ""
    var country = "US"
    var isDefault = false

    var summary: String {
        [line1, city, region, postalCode].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum MarketplacePaymentStatus: String, CaseIterable, Codable, Hashable {
    case notStarted = "Not Started"
    case authorized = "Authorized"
    case paid = "Paid"
    case failed = "Failed"
    case refunded = "Refunded"
}

enum MarketplacePayoutStatus: String, CaseIterable, Codable, Hashable {
    case notEligible = "Not Eligible"
    case pending = "Pending"
    case inTransit = "In Transit"
    case paid = "Paid"
}

enum MarketplaceRefundStatus: String, CaseIterable, Codable, Hashable {
    case none = "None"
    case requested = "Requested"
    case partial = "Partial"
    case full = "Full"
}

enum MarketplaceDisputeStatus: String, CaseIterable, Codable, Hashable {
    case none = "None"
    case open = "Open"
    case evidenceRequested = "Evidence Requested"
    case submitted = "Submitted"
    case won = "Won"
    case lost = "Lost"
    case resolved = "Resolved"
}

enum SellerShopStatus: String, CaseIterable, Codable, Hashable {
    case draft = "Draft"
    case paymentSetupRequired = "Payment Setup Required"
    case verificationPending = "Verification Pending"
    case active = "Active"
    case paused = "Paused"
    case restricted = "Restricted"
    case archived = "Archived"
}

enum SellerVerificationStatus: String, CaseIterable, Codable, Hashable {
    case notStarted = "Not Started"
    case pending = "Verification Pending"
    case complete = "Verification Complete"
    case moreInformationRequired = "More Information Required"
    case restricted = "Restricted"
    case disabled = "Disabled"
}

enum SellerPaymentOnboardingStage: String, CaseIterable, Codable, Hashable {
    case notStarted = "Not Started"
    case identity = "Identity Verification"
    case bankAccount = "Bank Account"
    case tax = "Tax Information"
    case review = "Review"
    case complete = "Complete"
}

enum SellerPayoutSchedule: String, CaseIterable, Codable, Hashable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case manual = "Manual"
}

struct MarketplacePlatformFeeConfiguration: Equatable, Codable, Hashable {
    var feeType: String = "FIXED"
    var percentage: Double = 0
    var fixedFee: Double = 0.30
    var currency: String = "USD"
    var active: Bool = true
    var minimumCheckoutAmount: Double = 1.00
    var minimumPayout: Double = 5.00
    var maximumTransactionAmount: Double = 10_000
    var feeReversalOnRefund = true

    func platformFee(for subtotal: Double) -> Double {
        guard active && subtotal > 0 else { return 0 }
        return fixedFee
    }
}

struct MarketplaceCheckoutBreakdown: Equatable, Codable, Hashable {
    var subtotal: Double
    var tax: Double
    var shipping: Double
    var discount: Double
    var platformFee: Double
    var processingFee: Double = 0

    var customerTotal: Double { max(0, subtotal + tax + shipping - discount) }
    var sellerGross: Double { max(0, customerTotal - tax) }
    var sellerEarnings: Double { max(0, sellerGross - processingFee - platformFee) }
}

struct SellerPaymentAccount: Identifiable, Equatable, Codable, Hashable {
    var id = UUID()
    var shopID: UUID
    var stripeConnectedAccountID: String?
    var onboardingStage: SellerPaymentOnboardingStage = .notStarted
    var verificationStatus: SellerVerificationStatus = .notStarted
    var shopStatus: SellerShopStatus = .paymentSetupRequired
    var bankAccountStatus = "Not connected"
    var payoutSchedule: SellerPayoutSchedule = .weekly
    var currentBalance: Double = 0
    var pendingBalance: Double = 0
    var availableBalance: Double = 0
    var todaySales: Double = 0
    var weekSales: Double = 0
    var monthSales: Double = 0
    var lifetimeSales: Double = 0
    var pendingPayouts: Double = 0
    var completedPayouts: Double = 0
    var refunds: Double = 0
    var disputes: Int = 0
    var platformFeesPaid: Double = 0
    var taxDocumentsStatus = "Not available"
    var updatedAt = Date()

    var canReceivePayments: Bool {
        onboardingStage == .complete && verificationStatus == .complete && bankAccountStatus == "Connected" && shopStatus == .active
    }
}

enum SellerEntitlementType: String, CaseIterable, Codable, Hashable {
    case productSlot = "PRODUCT_SLOT"
    case unlimitedProducts = "UNLIMITED_PRODUCTS"
    case shopSlot = "SHOP_SLOT"
    case sellerPro = "SELLER_PRO"
    case advancedAnalytics = "ADVANCED_ANALYTICS"
    case aiListingTools = "AI_LISTING_TOOLS"
    case featuredSearchCredits = "FEATURED_SEARCH_CREDITS"
    case transactionFeeDiscount = "TRANSACTION_FEE_DISCOUNT"
}

enum SellerEntitlementSource: String, CaseIterable, Codable, Hashable {
    case freeAllowance = "FREE_ALLOWANCE"
    case oneTimePurchase = "ONE_TIME_PURCHASE"
    case subscription = "SUBSCRIPTION"
    case adminGrant = "ADMIN_GRANT"
    case promotion = "PROMOTION"
    case migration = "MIGRATION"
    case refundReversal = "REFUND_REVERSAL"
}

enum SellerEntitlementStatus: String, CaseIterable, Codable, Hashable {
    case pending = "PENDING"
    case active = "ACTIVE"
    case expired = "EXPIRED"
    case revoked = "REVOKED"
    case refunded = "REFUNDED"
    case paymentFailed = "PAYMENT_FAILED"
}

struct SellerEntitlement: Identifiable, Equatable, Codable, Hashable {
    var id = UUID()
    var userId = "local-seller"
    var entitlementType: SellerEntitlementType
    var sourceType: SellerEntitlementSource
    var sourceReferenceId: String
    var quantity: Int
    var startsAt = Date()
    var expiresAt: Date?
    var status: SellerEntitlementStatus = .active
    var createdAt = Date()
    var updatedAt = Date()
}

enum SellerPackageType: String, CaseIterable, Codable, Hashable {
    case productSlot = "PRODUCT_SLOT"
    case productBundle = "PRODUCT_BUNDLE"
    case unlimitedProducts = "UNLIMITED_PRODUCTS"
    case shopSlot = "SHOP_SLOT"
    case shopBundle = "SHOP_BUNDLE"
    case sellerPro = "SELLER_PRO"
}

enum SellerPackageBillingType: String, CaseIterable, Codable, Hashable {
    case oneTime = "ONE_TIME"
    case monthly = "MONTHLY"
    case annual = "ANNUAL"
}

struct SellerPackage: Identifiable, Equatable, Codable, Hashable {
    var id: String
    var code: String
    var displayName: String
    var description: String
    var packageType: SellerPackageType
    var billingType: SellerPackageBillingType
    var quantity: Int?
    var priceAmount: Double
    var currency = "USD"
    var active = true
    var sortOrder: Int
    var appStoreProductId: String?

    var priceLabel: String {
        let base = priceAmount.currency
        switch billingType {
        case .oneTime: return "\(base) one-time"
        case .monthly: return "\(base)/mo"
        case .annual: return "\(base)/yr"
        }
    }

    var grantedEntitlementType: SellerEntitlementType {
        switch packageType {
        case .shopSlot, .shopBundle:
            return .shopSlot
        case .unlimitedProducts:
            return .unlimitedProducts
        case .sellerPro:
            return .sellerPro
        case .productSlot, .productBundle:
            return .productSlot
        }
    }

    var grantedCapacityQuantity: Int {
        switch packageType {
        case .unlimitedProducts, .sellerPro:
            return 1
        case .shopSlot, .shopBundle, .productSlot, .productBundle:
            return quantity ?? 1
        }
    }
}

struct SellerPlanTransaction: Identifiable, Equatable, Codable, Hashable {
    var id = UUID()
    var packageId: String
    var transactionType: String
    var billingProvider: String
    var providerTransactionId: String?
    var idempotencyKey: String
    var amount: Double
    var currency = "USD"
    var paymentStatus = "SUCCEEDED"
    var entitlementStatus = "ACTIVE"
    var refundedAmount: Double = 0
    var purchasedAt = Date()
}

struct SellerCapacitySummary: Equatable, Codable, Hashable {
    var freeShopSlots = 1
    var purchasedShopSlots = 0
    var subscriptionShopSlots = 0
    var totalShopCapacity = 1
    var usedShopSlots = 0
    var availableShopSlots = 1
    var nextShopSlotPrice: Double = 1
    var freeProductSlots = 10
    var purchasedProductSlots = 0
    var subscriptionProductSlots = 0
    var totalProductCapacity: Int? = 10
    var activeProductCount = 0
    var availableProductSlots: Int? = 10
    var hasUnlimitedProducts = false
    var sellerProStatus = "inactive"
    var sellerProRenewsAt: Date?
    var sellerProEndsAt: Date?
    var isOverShopCapacity = false
    var isOverProductCapacity = false
}

enum SellerCapacityCalculator {
    static func summary(entitlements: [SellerEntitlement], shops: [MarketplaceShop], products: [MarketplaceProduct]) -> SellerCapacitySummary {
        let activeEntitlements = entitlements.filter { entitlement in
            entitlement.status == .active && (entitlement.expiresAt == nil || entitlement.expiresAt! > Date())
        }
        let sellerPro = activeEntitlements.contains { $0.entitlementType == .sellerPro }
        let freeShopSlots = sum(activeEntitlements, type: .shopSlot, source: .freeAllowance)
        let permanentShopSlots = sum(activeEntitlements, type: .shopSlot, sources: [.oneTimePurchase, .adminGrant, .migration, .promotion])
        let subscriptionShopSlots = sellerPro ? max(0, 10 - freeShopSlots - permanentShopSlots) : sum(activeEntitlements, type: .shopSlot, source: .subscription)
        let totalShopCapacity = freeShopSlots + permanentShopSlots + subscriptionShopSlots
        let usedShopSlots = shops.count
        let freeProductSlots = sum(activeEntitlements, type: .productSlot, source: .freeAllowance)
        let permanentProductSlots = sum(activeEntitlements, type: .productSlot, sources: [.oneTimePurchase, .adminGrant, .migration, .promotion])
        let subscriptionProductSlots = sellerPro ? 0 : sum(activeEntitlements, type: .productSlot, source: .subscription)
        let activeProductCount = products.filter(productConsumesCapacity).count
        let hasUnlimitedProducts = sellerPro || activeEntitlements.contains { $0.entitlementType == .unlimitedProducts }
        let totalProductCapacity = hasUnlimitedProducts ? nil : freeProductSlots + permanentProductSlots + subscriptionProductSlots
        let availableProducts = totalProductCapacity.map { max(0, $0 - activeProductCount) }

        return SellerCapacitySummary(
            freeShopSlots: freeShopSlots,
            purchasedShopSlots: permanentShopSlots,
            subscriptionShopSlots: subscriptionShopSlots,
            totalShopCapacity: totalShopCapacity,
            usedShopSlots: usedShopSlots,
            availableShopSlots: max(0, totalShopCapacity - usedShopSlots),
            nextShopSlotPrice: usedShopSlots < 4 ? 1 : 3,
            freeProductSlots: freeProductSlots,
            purchasedProductSlots: permanentProductSlots,
            subscriptionProductSlots: subscriptionProductSlots,
            totalProductCapacity: totalProductCapacity,
            activeProductCount: activeProductCount,
            availableProductSlots: availableProducts,
            hasUnlimitedProducts: hasUnlimitedProducts,
            sellerProStatus: sellerPro ? "active" : "inactive",
            sellerProRenewsAt: sellerPro ? activeEntitlements.first(where: { $0.entitlementType == .sellerPro })?.expiresAt : nil,
            sellerProEndsAt: nil,
            isOverShopCapacity: usedShopSlots > totalShopCapacity,
            isOverProductCapacity: !hasUnlimitedProducts && activeProductCount > (totalProductCapacity ?? 0)
        )
    }

    private static func sum(_ entitlements: [SellerEntitlement], type: SellerEntitlementType, source: SellerEntitlementSource) -> Int {
        sum(entitlements, type: type, sources: [source])
    }

    private static func sum(_ entitlements: [SellerEntitlement], type: SellerEntitlementType, sources: Set<SellerEntitlementSource>) -> Int {
        entitlements
            .filter { $0.entitlementType == type && sources.contains($0.sourceType) }
            .reduce(0) { $0 + max(0, $1.quantity) }
    }

    private static func productConsumesCapacity(_ product: MarketplaceProduct) -> Bool {
        let specs = product.specs.map { $0.lowercased() }
        if specs.contains(where: { $0.contains("draft") || $0.contains("archived") }) { return false }
        return specs.contains(where: { $0.contains("published") || $0.contains("paused") })
    }
}

enum SellerPackageCatalog {
    static let defaultPackages: [SellerPackage] = [
        .init(id: "pkg_product_1", code: "PRODUCT_SLOT_1", displayName: "+1 Product Slot", description: "Adds one permanent active product listing slot.", packageType: .productSlot, billingType: .oneTime, quantity: 1, priceAmount: 0.99, sortOrder: 10, appStoreProductId: "oneway.seller.product_slot_1"),
        .init(id: "pkg_product_10", code: "PRODUCT_BUNDLE_10", displayName: "+10 Product Slots", description: "Adds ten permanent active product listing slots.", packageType: .productBundle, billingType: .oneTime, quantity: 10, priceAmount: 5, sortOrder: 20, appStoreProductId: "oneway.seller.product_slots_10"),
        .init(id: "pkg_product_25", code: "PRODUCT_BUNDLE_25", displayName: "+25 Product Slots", description: "Adds twenty-five permanent active product listing slots.", packageType: .productBundle, billingType: .oneTime, quantity: 25, priceAmount: 10, sortOrder: 30, appStoreProductId: "oneway.seller.product_slots_25"),
        .init(id: "pkg_product_50", code: "PRODUCT_BUNDLE_50", displayName: "+50 Product Slots", description: "Adds fifty permanent active product listing slots.", packageType: .productBundle, billingType: .oneTime, quantity: 50, priceAmount: 18, sortOrder: 40, appStoreProductId: "oneway.seller.product_slots_50"),
        .init(id: "pkg_product_100", code: "PRODUCT_BUNDLE_100", displayName: "+100 Product Slots", description: "Adds one hundred permanent active product listing slots.", packageType: .productBundle, billingType: .oneTime, quantity: 100, priceAmount: 30, sortOrder: 50, appStoreProductId: "oneway.seller.product_slots_100"),
        .init(id: "pkg_product_unlimited", code: "UNLIMITED_PRODUCTS", displayName: "Unlimited Products", description: "Unlocks unlimited active product listings permanently.", packageType: .unlimitedProducts, billingType: .oneTime, quantity: nil, priceAmount: 99, sortOrder: 60, appStoreProductId: "oneway.seller.unlimited_products"),
        .init(id: "pkg_product_10_monthly", code: "PRODUCT_BUNDLE_10_MONTHLY", displayName: "+10 Monthly", description: "Adds ten active listing slots while active.", packageType: .productBundle, billingType: .monthly, quantity: 10, priceAmount: 0.99, sortOrder: 70, appStoreProductId: "oneway.seller.product_slots_10_monthly"),
        .init(id: "pkg_product_25_monthly", code: "PRODUCT_BUNDLE_25_MONTHLY", displayName: "+25 Monthly", description: "Adds twenty-five active listing slots while active.", packageType: .productBundle, billingType: .monthly, quantity: 25, priceAmount: 1.99, sortOrder: 80, appStoreProductId: "oneway.seller.product_slots_25_monthly"),
        .init(id: "pkg_product_50_monthly", code: "PRODUCT_BUNDLE_50_MONTHLY", displayName: "+50 Monthly", description: "Adds fifty active listing slots while active.", packageType: .productBundle, billingType: .monthly, quantity: 50, priceAmount: 2.99, sortOrder: 90, appStoreProductId: "oneway.seller.product_slots_50_monthly"),
        .init(id: "pkg_shop_next", code: "SHOP_SLOT_NEXT", displayName: "Next Shop Slot", description: "Unlocks your next permanent Shop slot.", packageType: .shopSlot, billingType: .oneTime, quantity: 1, priceAmount: 1, sortOrder: 100, appStoreProductId: "oneway.seller.shop_slot_next"),
        .init(id: "pkg_shop_3", code: "SHOP_BUNDLE_3", displayName: "3 Shop Slots", description: "Adds three permanent Shop slots.", packageType: .shopBundle, billingType: .oneTime, quantity: 3, priceAmount: 7, sortOrder: 110, appStoreProductId: "oneway.seller.shop_slots_3"),
        .init(id: "pkg_shop_5", code: "SHOP_BUNDLE_5", displayName: "5 Shop Slots", description: "Adds five permanent Shop slots.", packageType: .shopBundle, billingType: .oneTime, quantity: 5, priceAmount: 12, sortOrder: 120, appStoreProductId: "oneway.seller.shop_slots_5"),
        .init(id: "pkg_shop_10", code: "SHOP_BUNDLE_10", displayName: "10 Shop Slots", description: "Adds ten permanent Shop slots.", packageType: .shopBundle, billingType: .oneTime, quantity: 10, priceAmount: 20, sortOrder: 130, appStoreProductId: "oneway.seller.shop_slots_10"),
        .init(id: "pkg_seller_pro", code: "SELLER_PRO_MONTHLY", displayName: "Seller Pro", description: "Unlimited product listings, capacity for up to 10 Shops, advanced analytics, and future AI listing tools.", packageType: .sellerPro, billingType: .monthly, quantity: 1, priceAmount: 14.99, sortOrder: 140, appStoreProductId: "oneway.seller.pro.monthly")
    ]
}

struct MarketplaceFilters: Equatable {
    var category: String?
    var maxPrice: Double = 100
    var minimumRating: Double = 0
    var localPickup = false
    var privacyVerifiedOnly = false
}

struct SellerShopDraft: Equatable, Codable {
    var shopName = ""
    var description = ""
    var category = ""
    var bannerImageFileName: String?
    var badgeImageFileName: String?
    var location = ""
    var shippingPolicy = ""
    var returnsPolicy = ""
    var processingTime = "3-5 business days"
    var contactMessages = true
    var contactCalls = false
    var contactWalkie = false
}

enum ShopCreationRequirements {
    static func usableName(requested: String, profileName: String) -> String {
        let requested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requested.isEmpty { return requested }
        let profile = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return profile.isEmpty ? "My OneWay Shop" : "\(profile)'s Shop"
    }

    static func usableCategory(_ requested: String) -> String {
        let category = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        return category.isEmpty ? "General" : category
    }

    static func sellerToolsDestination(shopCount: Int) -> MarketplaceRoute {
        if shopCount == 0 { return .createShop }
        if shopCount > 1 { return .myShops }
        return .manageShop
    }
}

struct SellerProductDraft: Equatable, Codable {
    var title = ""
    var description = ""
    var priceText = ""
    var category = ""
    var inventoryText = "1"
    var shippingOption = "Standard shipping"
    var privacyVerified = true
    var images: [MarketplaceProductImage] = []
}

enum MarketplaceRoute: Hashable {
    case shop(UUID)
    case category(String)
    case product(UUID)
    case search(String)
    case chat(UUID)
    case sellerChat(UUID)
    case cart
    case checkout
    case createShop
    case myShops
    case manageShop
    case sellerPayments
    case sellerPaymentSetup
    case sellerPlans
    case addProduct
    case manageProducts
    case editProduct(UUID)
    case editStore
    case shopPolicies(UUID?)
    case buyerShopPolicies(UUID)
    case sellerOrderDetail(UUID)
    case sellerOrders
    case sellerMessages
    case marketplaceProfile
    case marketplacePrivacy
    case orderHistory
    case orderDetail(UUID)
    case savedShops
    case shopNotifications
    case shippingAddresses
    case paymentPrivacy
    case shopMessagePreferences
    case returnsRefunds
    case marketplaceSupport
}
