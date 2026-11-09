import Foundation

protocol SiteService {
    func sites() async throws -> [OneWaySite]
    func site(forSlug slug: String) async throws -> OneWaySite?
    func publishedSite(forSlug slug: String) async throws -> OneWaySite?
    func upsert(site: SiteDraft) async throws -> OneWaySite
    func publish(site: OneWaySite) async throws -> OneWaySite
    func uploadSiteImage(domainSlug: String, fileName: String, mimeType: String, data: Data) async throws -> SiteAsset
    func generateAISite(prompt: String, domainSlug: String, title: String) async throws -> String
}

struct SiteAsset: Equatable, Codable {
    let url: String
    let path: String?
    let mimeType: String
    let byteCount: Int
}

struct SiteDraft: Equatable {
    var domainSlug: String
    var title: String
    var description: String
    var mode: SiteMode
    var htmlContent: String
    var blocks: [SiteBlock]
    var aiPrompt: String
}

enum SiteStoreInventoryStatus: String, Codable, CaseIterable, Identifiable {
    case inStock = "in_stock"
    case soldOut = "sold_out"
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inStock: return "Available"
        case .soldOut: return "Sold out"
        case .hidden: return "Hidden"
        }
    }
}

enum SiteStoreCheckoutMode: String, Codable, CaseIterable, Identifiable {
    case contact
    case paymentLink = "payment_link"
    case oneWayWallet = "oneway_wallet"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contact: return "Contact to buy"
        case .paymentLink: return "Payment link"
        case .oneWayWallet: return "OneWay Wallet"
        }
    }
}

enum SiteStoreStripeConnectStatus: String, Codable, CaseIterable, Identifiable {
    case notStarted = "not_started"
    case pending
    case connected
    case restricted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .pending: return "Pending"
        case .connected: return "Connected"
        case .restricted: return "Needs attention"
        }
    }
}

struct SiteStoreProduct: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var description: String
    var priceCents: Int
    var imageUrl: String
    var inventoryCount: Int? = nil
    var trackInventory: Bool? = nil
    var lowStockThreshold: Int? = nil
    var paymentMode: SiteStoreCheckoutMode? = nil
    var paymentLinkUrl: String? = nil
    var inventoryStatus: SiteStoreInventoryStatus
    var sortOrder: Int

    var formattedPrice: String {
        let amount = Decimal(priceCents) / Decimal(100)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$\(priceCents / 100)"
    }
}

struct SiteStore: Equatable, Codable {
    var domain: String
    var storeEnabled: Bool
    var storeName: String
    var storeDescription: String
    var currency: String
    var products: [SiteStoreProduct]
    var contactToBuyEnabled: Bool
    var checkoutMode: SiteStoreCheckoutMode
    var paymentLinkUrl: String
    var paymentsEnabled: Bool
    var stripeConnectStatus: SiteStoreStripeConnectStatus
    var defaultPaymentMode: SiteStoreCheckoutMode
    var defaultPaymentLinkUrl: String
    var contactEmail: String
    var contactPhone: String
    var pickupEnabled: Bool
    var localDeliveryEnabled: Bool
    var shippingEnabled: Bool
    var digitalDeliveryEnabled: Bool
    var pickupInstructions: String
    var shippingNote: String
    var deliveryAreaNote: String
    var fulfillmentNote: String
    var marketplaceListed: Bool
    var published: Bool
    var publishedAt: String?
    var updatedAt: String?

    init(
        domain: String,
        storeEnabled: Bool,
        storeName: String,
        storeDescription: String,
        currency: String = "USD",
        products: [SiteStoreProduct] = [],
        contactToBuyEnabled: Bool = true,
        checkoutMode: SiteStoreCheckoutMode = .contact,
        paymentLinkUrl: String = "",
        paymentsEnabled: Bool = false,
        stripeConnectStatus: SiteStoreStripeConnectStatus = .notStarted,
        defaultPaymentMode: SiteStoreCheckoutMode = .contact,
        defaultPaymentLinkUrl: String = "",
        contactEmail: String = "",
        contactPhone: String = "",
        pickupEnabled: Bool = false,
        localDeliveryEnabled: Bool = false,
        shippingEnabled: Bool = false,
        digitalDeliveryEnabled: Bool = false,
        pickupInstructions: String = "",
        shippingNote: String = "",
        deliveryAreaNote: String = "",
        fulfillmentNote: String = "",
        marketplaceListed: Bool = false,
        published: Bool = false,
        publishedAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.domain = domain
        self.storeEnabled = storeEnabled
        self.storeName = storeName
        self.storeDescription = storeDescription
        self.currency = currency
        self.products = products
        self.contactToBuyEnabled = contactToBuyEnabled
        self.checkoutMode = checkoutMode
        self.paymentLinkUrl = paymentLinkUrl
        self.paymentsEnabled = paymentsEnabled
        self.stripeConnectStatus = stripeConnectStatus
        self.defaultPaymentMode = defaultPaymentMode
        self.defaultPaymentLinkUrl = defaultPaymentLinkUrl
        self.contactEmail = contactEmail
        self.contactPhone = contactPhone
        self.pickupEnabled = pickupEnabled
        self.localDeliveryEnabled = localDeliveryEnabled
        self.shippingEnabled = shippingEnabled
        self.digitalDeliveryEnabled = digitalDeliveryEnabled
        self.pickupInstructions = pickupInstructions
        self.shippingNote = shippingNote
        self.deliveryAreaNote = deliveryAreaNote
        self.fulfillmentNote = fulfillmentNote
        self.marketplaceListed = marketplaceListed
        self.published = published
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(String.self, forKey: .domain)
        storeEnabled = try container.decodeIfPresent(Bool.self, forKey: .storeEnabled) ?? true
        storeName = try container.decodeIfPresent(String.self, forKey: .storeName) ?? ""
        storeDescription = try container.decodeIfPresent(String.self, forKey: .storeDescription) ?? ""
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        products = try container.decodeIfPresent([SiteStoreProduct].self, forKey: .products) ?? []
        contactToBuyEnabled = try container.decodeIfPresent(Bool.self, forKey: .contactToBuyEnabled) ?? true
        checkoutMode = try container.decodeIfPresent(SiteStoreCheckoutMode.self, forKey: .checkoutMode) ?? .contact
        paymentLinkUrl = try container.decodeIfPresent(String.self, forKey: .paymentLinkUrl) ?? ""
        paymentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .paymentsEnabled) ?? false
        stripeConnectStatus = try container.decodeIfPresent(SiteStoreStripeConnectStatus.self, forKey: .stripeConnectStatus) ?? .notStarted
        defaultPaymentMode = try container.decodeIfPresent(SiteStoreCheckoutMode.self, forKey: .defaultPaymentMode) ?? .contact
        defaultPaymentLinkUrl = try container.decodeIfPresent(String.self, forKey: .defaultPaymentLinkUrl) ?? ""
        contactEmail = try container.decodeIfPresent(String.self, forKey: .contactEmail) ?? ""
        contactPhone = try container.decodeIfPresent(String.self, forKey: .contactPhone) ?? ""
        pickupEnabled = try container.decodeIfPresent(Bool.self, forKey: .pickupEnabled) ?? false
        localDeliveryEnabled = try container.decodeIfPresent(Bool.self, forKey: .localDeliveryEnabled) ?? false
        shippingEnabled = try container.decodeIfPresent(Bool.self, forKey: .shippingEnabled) ?? false
        digitalDeliveryEnabled = try container.decodeIfPresent(Bool.self, forKey: .digitalDeliveryEnabled) ?? false
        pickupInstructions = try container.decodeIfPresent(String.self, forKey: .pickupInstructions) ?? ""
        shippingNote = try container.decodeIfPresent(String.self, forKey: .shippingNote) ?? ""
        deliveryAreaNote = try container.decodeIfPresent(String.self, forKey: .deliveryAreaNote) ?? ""
        fulfillmentNote = try container.decodeIfPresent(String.self, forKey: .fulfillmentNote) ?? ""
        marketplaceListed = try container.decodeIfPresent(Bool.self, forKey: .marketplaceListed) ?? false
        published = try container.decodeIfPresent(Bool.self, forKey: .published) ?? false
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

enum SiteStoreInquiryStatus: String, Codable, CaseIterable, Identifiable {
    case new
    case replied
    case archived
    case orderRequested = "order_requested"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .new: return "New"
        case .replied: return "Replied"
        case .archived: return "Archived"
        case .orderRequested: return "Order request"
        }
    }
}

struct SiteStoreInquiry: Identifiable, Equatable, Codable {
    var id: String
    var domain: String
    var customerName: String
    var customerEmail: String
    var customerPhone: String
    var productName: String
    var message: String
    var quantity: Int
    var fulfillmentPreference: String
    var status: SiteStoreInquiryStatus
    var ownerReply: String
    var replyProvider: String?
    var replyProviderMessageId: String?
    var replyStatus: String?
    var repliedAt: String?
    var convertedAt: String?
    var orderRequestNote: String
    var emailMessages: [SiteStoreEmailMessage]
    var createdAt: String
    var updatedAt: String

    var displayName: String {
        let trimmed = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !customerEmail.isEmpty { return customerEmail }
        if !customerPhone.isEmpty { return customerPhone }
        return "Store visitor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        domain = try container.decode(String.self, forKey: .domain)
        customerName = try container.decodeIfPresent(String.self, forKey: .customerName) ?? ""
        customerEmail = try container.decodeIfPresent(String.self, forKey: .customerEmail) ?? ""
        customerPhone = try container.decodeIfPresent(String.self, forKey: .customerPhone) ?? ""
        productName = try container.decodeIfPresent(String.self, forKey: .productName) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        quantity = try container.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        fulfillmentPreference = try container.decodeIfPresent(String.self, forKey: .fulfillmentPreference) ?? ""
        status = try container.decodeIfPresent(SiteStoreInquiryStatus.self, forKey: .status) ?? .new
        ownerReply = try container.decodeIfPresent(String.self, forKey: .ownerReply) ?? ""
        replyProvider = try container.decodeIfPresent(String.self, forKey: .replyProvider)
        replyProviderMessageId = try container.decodeIfPresent(String.self, forKey: .replyProviderMessageId)
        replyStatus = try container.decodeIfPresent(String.self, forKey: .replyStatus)
        repliedAt = try container.decodeIfPresent(String.self, forKey: .repliedAt)
        convertedAt = try container.decodeIfPresent(String.self, forKey: .convertedAt)
        orderRequestNote = try container.decodeIfPresent(String.self, forKey: .orderRequestNote) ?? ""
        emailMessages = try container.decodeIfPresent([SiteStoreEmailMessage].self, forKey: .emailMessages) ?? []
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

struct SiteStoreEmailMessage: Identifiable, Equatable, Codable {
    var id: String
    var domain: String
    var orderRequestId: String?
    var inquiryId: String?
    var direction: String
    var fromEmail: String
    var toEmail: String
    var subject: String
    var bodyText: String
    var provider: String
    var providerMessageId: String?
    var status: String
    var createdAt: String

    var isOutbound: Bool { direction == "outbound" }
}

struct SiteStoreStatusEvent: Identifiable, Equatable, Codable {
    var id: String { "\(status)-\(at)" }
    var status: String
    var at: String
}

enum SiteStoreNotificationStatus: String, Codable, CaseIterable, Identifiable {
    case unread
    case read
    case dismissed

    var id: String { rawValue }
}

struct SiteStoreNotification: Identifiable, Equatable, Codable {
    var id: String
    var domain: String
    var type: String
    var title: String
    var body: String
    var status: SiteStoreNotificationStatus
    var relatedInquiryId: String?
    var relatedOrderRequestId: String?
    var createdAt: String
    var readAt: String?

    var isUnread: Bool { status == .unread }
}

enum SiteStoreAnalyticsRange: String, Codable, CaseIterable, Identifiable {
    case today
    case sevenDays = "7d"
    case thirtyDays = "30d"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        }
    }
}

enum SiteStoreAnalyticsEventType: String, Codable {
    case storefrontView = "storefront_view"
    case productView = "product_view"
    case requestToBuyStarted = "request_to_buy_started"
    case requestToBuySubmitted = "request_to_buy_submitted"
    case buyNowClicked = "buy_now_clicked"
    case shareClicked = "share_clicked"
    case oneWayWalletCheckoutStarted = "oneway_wallet_checkout_started"
    case oneWayWalletPaymentCompleted = "oneway_wallet_payment_completed"
    case oneWayWalletPaymentFailed = "oneway_wallet_payment_failed"
}

struct SiteStoreAnalyticsCards: Equatable, Codable {
    var views: Int
    var productViews: Int
    var requests: Int
    var buyClicks: Int
    var shares: Int
    var conversionRate: Double
}

struct SiteStoreTopProduct: Identifiable, Equatable, Codable {
    var productId: String
    var count: Int

    var id: String { productId }
}

struct SiteStoreAnalyticsSummary: Equatable, Codable {
    var range: SiteStoreAnalyticsRange
    var since: String
    var cards: SiteStoreAnalyticsCards
    var topProducts: [SiteStoreTopProduct]
    var empty: Bool
}

enum SiteStoreOrderRequestStatus: String, Codable, CaseIterable, Identifiable {
    case requested
    case accepted
    case completed
    case canceled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .requested: return "Requested"
        case .accepted: return "Accepted"
        case .completed: return "Completed"
        case .canceled: return "Canceled"
        }
    }
}

enum SiteStoreOrderPaymentStatus: String, Codable, CaseIterable, Identifiable {
    case notRequested = "not_requested"
    case paymentLinkSent = "payment_link_sent"
    case paidManual = "paid_manual"
    case refunded
    case failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notRequested: return "Not requested"
        case .paymentLinkSent: return "Payment link sent"
        case .paidManual: return "Paid"
        case .refunded: return "Refunded"
        case .failed: return "Payment failed"
        }
    }
}

enum SiteStoreWalletPaymentStatus: String, Codable, CaseIterable, Identifiable {
    case notStarted = "not_started"
    case pending
    case authorized
    case paid
    case failed
    case refunded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .pending: return "Pending"
        case .authorized: return "Authorized"
        case .paid: return "Paid"
        case .failed: return "Payment failed"
        case .refunded: return "Refunded"
        }
    }
}

struct SiteStoreOrderRequest: Identifiable, Equatable, Codable {
    var id: String
    var domain: String
    var inquiryId: String?
    var productId: String?
    var customerName: String
    var customerEmail: String
    var customerPhone: String
    var productName: String
    var paymentMode: SiteStoreCheckoutMode
    var paymentLinkUrl: String?
    var message: String
    var quantity: Int
    var fulfillmentPreference: String
    var note: String
    var status: SiteStoreOrderRequestStatus
    var paymentStatus: SiteStoreOrderPaymentStatus
    var paidAt: String?
    var walletPaymentStatus: SiteStoreWalletPaymentStatus
    var walletPaymentId: String?
    var buyerWalletUserId: String?
    var sellerWalletUserId: String?
    var walletPaidAt: String?
    var walletRefundedAt: String?
    var totalCents: Int
    var currency: String
    var sellerReply: String
    var replyProvider: String?
    var replyProviderMessageId: String?
    var replyStatus: String?
    var repliedAt: String?
    var inventoryApplied: Bool
    var statusTimeline: [SiteStoreStatusEvent]
    var emailMessages: [SiteStoreEmailMessage]
    var createdAt: String
    var updatedAt: String

    var displayName: String {
        let trimmed = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !customerEmail.isEmpty { return customerEmail }
        if !customerPhone.isEmpty { return customerPhone }
        return "Customer"
    }

    var fulfillmentLabel: String {
        switch fulfillmentPreference {
        case "pickup": return "Pickup"
        case "local_delivery": return "Local delivery"
        case "shipping": return "Shipping"
        case "digital": return "Digital"
        default: return fulfillmentPreference.isEmpty ? "Not specified" : fulfillmentPreference
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        domain = try container.decode(String.self, forKey: .domain)
        inquiryId = try container.decodeIfPresent(String.self, forKey: .inquiryId)
        productId = try container.decodeIfPresent(String.self, forKey: .productId)
        customerName = try container.decodeIfPresent(String.self, forKey: .customerName) ?? ""
        customerEmail = try container.decodeIfPresent(String.self, forKey: .customerEmail) ?? ""
        customerPhone = try container.decodeIfPresent(String.self, forKey: .customerPhone) ?? ""
        productName = try container.decodeIfPresent(String.self, forKey: .productName) ?? ""
        paymentMode = try container.decodeIfPresent(SiteStoreCheckoutMode.self, forKey: .paymentMode) ?? .contact
        paymentLinkUrl = try container.decodeIfPresent(String.self, forKey: .paymentLinkUrl)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        quantity = try container.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        fulfillmentPreference = try container.decodeIfPresent(String.self, forKey: .fulfillmentPreference) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        status = try container.decodeIfPresent(SiteStoreOrderRequestStatus.self, forKey: .status) ?? .requested
        paymentStatus = try container.decodeIfPresent(SiteStoreOrderPaymentStatus.self, forKey: .paymentStatus) ?? .notRequested
        paidAt = try container.decodeIfPresent(String.self, forKey: .paidAt)
        walletPaymentStatus = try container.decodeIfPresent(SiteStoreWalletPaymentStatus.self, forKey: .walletPaymentStatus) ?? .notStarted
        walletPaymentId = try container.decodeIfPresent(String.self, forKey: .walletPaymentId)
        buyerWalletUserId = try container.decodeIfPresent(String.self, forKey: .buyerWalletUserId)
        sellerWalletUserId = try container.decodeIfPresent(String.self, forKey: .sellerWalletUserId)
        walletPaidAt = try container.decodeIfPresent(String.self, forKey: .walletPaidAt)
        walletRefundedAt = try container.decodeIfPresent(String.self, forKey: .walletRefundedAt)
        totalCents = try container.decodeIfPresent(Int.self, forKey: .totalCents) ?? 0
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        sellerReply = try container.decodeIfPresent(String.self, forKey: .sellerReply) ?? ""
        replyProvider = try container.decodeIfPresent(String.self, forKey: .replyProvider)
        replyProviderMessageId = try container.decodeIfPresent(String.self, forKey: .replyProviderMessageId)
        replyStatus = try container.decodeIfPresent(String.self, forKey: .replyStatus)
        repliedAt = try container.decodeIfPresent(String.self, forKey: .repliedAt)
        inventoryApplied = try container.decodeIfPresent(Bool.self, forKey: .inventoryApplied) ?? false
        statusTimeline = try container.decodeIfPresent([SiteStoreStatusEvent].self, forKey: .statusTimeline) ?? []
        emailMessages = try container.decodeIfPresent([SiteStoreEmailMessage].self, forKey: .emailMessages) ?? []
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

protocol SiteStoreService {
    func store(forSlug slug: String) async throws -> SiteStore
    func save(store: SiteStore, domainSlug: String) async throws -> SiteStore
    func addProduct(_ product: SiteStoreProduct, domainSlug: String) async throws -> SiteStore
    func updateProduct(_ product: SiteStoreProduct, domainSlug: String) async throws -> SiteStore
    func deleteProduct(productId: String, domainSlug: String) async throws -> SiteStore
    func publish(domainSlug: String) async throws -> SiteStore
    func uploadProductImage(domainSlug: String, fileName: String, mimeType: String, data: Data) async throws -> SiteAsset
    func inquiries(domainSlug: String) async throws -> [SiteStoreInquiry]
    func updateInquiryStatus(domainSlug: String, inquiryId: String, status: SiteStoreInquiryStatus) async throws -> SiteStoreInquiry
    func replyToInquiry(domainSlug: String, inquiryId: String, message: String) async throws -> SiteStoreInquiry
    func convertInquiryToOrderRequest(domainSlug: String, inquiryId: String, note: String) async throws -> SiteStoreInquiry
    func notifications(domainSlug: String) async throws -> [SiteStoreNotification]
    func updateNotificationStatus(domainSlug: String, notificationId: String, status: SiteStoreNotificationStatus) async throws -> SiteStoreNotification
    func markAllNotificationsRead(domainSlug: String) async throws
    func orderRequests(domainSlug: String, statuses: [SiteStoreOrderRequestStatus]?) async throws -> [SiteStoreOrderRequest]
    func order(domainSlug: String, orderId: String) async throws -> (order: SiteStoreOrderRequest, emailDeliveryConfigured: Bool)
    func replyToOrder(domainSlug: String, orderId: String, message: String) async throws -> (order: SiteStoreOrderRequest, emailDeliveryConfigured: Bool, message: String?)
    func updateOrderRequestStatus(domainSlug: String, orderRequestId: String, status: SiteStoreOrderRequestStatus) async throws -> SiteStoreOrderRequest
    func sendPaymentLink(domainSlug: String, orderId: String) async throws -> (order: SiteStoreOrderRequest, emailDeliveryConfigured: Bool, message: String?)
    func updateOrderPaymentStatus(domainSlug: String, orderId: String, paymentStatus: SiteStoreOrderPaymentStatus, paymentLinkUrl: String?) async throws -> SiteStoreOrderRequest
    func startWalletCheckout(domainSlug: String, orderId: String, amountCents: Int?, buyerWalletUserId: String?) async throws -> (order: SiteStoreOrderRequest, message: String?, testModeWarning: String?)
    func refundWalletPayment(domainSlug: String, orderId: String) async throws -> (order: SiteStoreOrderRequest, message: String?, testModeWarning: String?)
    func analytics(domainSlug: String, range: SiteStoreAnalyticsRange) async throws -> SiteStoreAnalyticsSummary
    func trackEvent(domainSlug: String, eventType: SiteStoreAnalyticsEventType, productId: String?, metadata: [String: String]) async throws
}

extension SiteStoreService {
    func orderRequests(domainSlug: String) async throws -> [SiteStoreOrderRequest] {
        try await orderRequests(domainSlug: domainSlug, statuses: nil)
    }
}
