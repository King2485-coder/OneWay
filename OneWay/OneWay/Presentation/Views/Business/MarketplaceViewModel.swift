import Foundation
import Combine
import StoreKit

@MainActor
final class MarketplaceViewModel: ObservableObject {
    @Published var shops: [MarketplaceShop] = []
    @Published var products: [MarketplaceProduct] = []
    @Published var categories: [MarketplaceCategory] = MarketplaceSampleData.categories
    @Published var threads: [ShopConversation] = MarketplaceSampleData.threads
    @Published var shopMessagingSettings = ShopMessagingSettings()
    @Published var blockedShopContacts: [ShopBlockedContact] = []
    @Published var orders: [MarketplaceOrder] = []
    @Published var marketplaceProfile = MarketplaceBuyerProfile()
    @Published var marketplacePrivacy = MarketplacePrivacySettings()
    @Published var marketplaceNotifications = MarketplaceNotificationSettings()
    @Published var shippingAddresses: [MarketplaceShippingAddress] = []
    @Published var favorites: Set<UUID> = []
    @Published var followedShops: Set<UUID> = []
    @Published var cartItems: [CartItem] = []
    @Published var cartConfirmationProduct: MarketplaceProduct?
    @Published var filters = MarketplaceFilters()
    @Published var sellerShopID: UUID?
    @Published var sellerShopIDs: [UUID] = []
    @Published var sellerProductIDs: Set<UUID> = []
    @Published var sellerPaymentAccounts: [SellerPaymentAccount] = []
    @Published var platformFeeConfiguration = MarketplacePlatformFeeConfiguration()
    @Published var sellerEntitlements: [SellerEntitlement] = []
    @Published var sellerPlanTransactions: [SellerPlanTransaction] = []
    @Published var sellerPackageCatalog: [SellerPackage] = SellerPackageCatalog.defaultPackages
    @Published private(set) var sellerStoreProducts: [String: StoreKit.Product] = [:]
    @Published private(set) var sellerStoreProductsAreLoading = false
    @Published private(set) var unavailableSellerProductIDs: Set<String> = []
    @Published var showProductCapacitySheet = false
    @Published var sellerValidationMessage: String?
    @Published private(set) var catalogIsLoading = true
    @Published private(set) var catalogErrorMessage: String?
    @Published private(set) var checkoutIsLoading = false
    @Published var checkoutCompletedMessage: String?
    @Published private(set) var sellerShopIsSaving = false

    private let storefrontService: StorefrontService
    private var pendingShopCreationKey: String?

    private var shopMessagingCacheNamespace: String {
        AppEnvironment.currentUserID()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private var sellerShopKey: String { "oneway.shops.sellerShop.v2.\(shopMessagingCacheNamespace)" }
    private var sellerShopsKey: String { "oneway.shops.sellerShops.v2.\(shopMessagingCacheNamespace)" }
    private var sellerProductsKey: String { "oneway.shops.sellerProducts.v2.\(shopMessagingCacheNamespace)" }
    private var sellerPaymentAccountsKey: String { "oneway.shops.sellerPaymentAccounts.v2.\(shopMessagingCacheNamespace)" }
    private var platformFeeConfigurationKey: String { "oneway.shops.platformFeeConfiguration.v2.\(shopMessagingCacheNamespace)" }
    private var sellerEntitlementsKey: String { "oneway.shops.sellerEntitlements.v2.\(shopMessagingCacheNamespace)" }
    private var sellerPlanTransactionsKey: String { "oneway.shops.sellerPlanTransactions.v2.\(shopMessagingCacheNamespace)" }
    private var threadsKey: String { "oneway.shops.shopConversations.v2.\(shopMessagingCacheNamespace)" }
    private var legacyThreadsKey: String { "oneway.shops.messageThreads.v1" }
    private var messagingSettingsKey: String { "oneway.shops.messagingSettings.v2.\(shopMessagingCacheNamespace)" }
    private var blockedContactsKey: String { "oneway.shops.blockedContacts.v2.\(shopMessagingCacheNamespace)" }
    private var marketplaceProfileKey: String { "oneway.shops.marketplaceProfile.v1.\(shopMessagingCacheNamespace)" }
    private var marketplacePrivacyKey: String { "oneway.shops.marketplacePrivacy.v1.\(shopMessagingCacheNamespace)" }
    private var marketplaceNotificationsKey: String { "oneway.shops.marketplaceNotifications.v1.\(shopMessagingCacheNamespace)" }
    private var shippingAddressesKey: String { "oneway.shops.shippingAddresses.v1.\(shopMessagingCacheNamespace)" }
    private var followedShopsKey: String { "oneway.shops.followedShops.v1.\(shopMessagingCacheNamespace)" }
    private var favoritesKey: String { "oneway.shops.favorites.v1.\(shopMessagingCacheNamespace)" }
    private var ordersKey: String { "oneway.shops.buyerOrders.v1.\(shopMessagingCacheNamespace)" }
    private var cartKey: String { "oneway.shops.cart.v2.\(shopMessagingCacheNamespace)" }

    init(storefrontService: StorefrontService = .shared) {
        self.storefrontService = storefrontService
        loadSellerState()
        Task {
            async let storeProducts: Void = loadSellerStoreProducts()
            async let conversations: Void = syncShopConversations()
            async let marketplaceOrders: Void = syncMarketplaceOrders()
            await refreshMarketplaceCatalog()
            _ = await (storeProducts, conversations, marketplaceOrders)
        }
    }

    var sellerShop: MarketplaceShop? {
        guard let sellerShopID else { return nil }
        return shop(sellerShopID)
    }

    var sellerShops: [MarketplaceShop] {
        sellerShopIDs.compactMap { shop($0) }
    }

    var hasSellerShop: Bool { !sellerShops.isEmpty }

    var sellerToolsDestination: MarketplaceRoute {
        ShopCreationRequirements.sellerToolsDestination(shopCount: sellerShops.count)
    }

    var sellerProducts: [MarketplaceProduct] {
        products.filter { sellerProductIDs.contains($0.id) }
    }

    var activeSellerProducts: [MarketplaceProduct] {
        sellerProducts.filter { productConsumesCapacity($0) }
    }

    var sellerCapacitySummary: SellerCapacitySummary {
        SellerCapacityCalculator.summary(
            entitlements: sellerEntitlements,
            shops: sellerShops,
            products: sellerProducts
        )
    }

    var cartCount: Int { cartItems.reduce(0) { $0 + $1.quantity } }
    var subtotal: Double {
        cartItems.reduce(0) { partial, item in
            partial + ((product(item.productID)?.price ?? 0) * Double(item.quantity))
        }
    }
    var fees: Double {
        let breakdown = checkoutBreakdown
        return breakdown.tax + breakdown.shipping - breakdown.discount
    }
    var checkoutBreakdown: MarketplaceCheckoutBreakdown {
        let tax = subtotal * 0.082
        let shipping = cartItems.isEmpty ? 0 : 6.99
        let discount = 0.0
        let platformFee = platformFeeConfiguration.platformFee(for: subtotal)
        let processingFee = subtotal == 0 ? 0 : ((subtotal + tax + shipping - discount) * 0.029 + 0.30)
        return MarketplaceCheckoutBreakdown(
            subtotal: subtotal,
            tax: tax,
            shipping: shipping,
            discount: discount,
            platformFee: platformFee,
            processingFee: processingFee
        )
    }

    func shop(_ id: UUID) -> MarketplaceShop? { shops.first { $0.id == id } }
    func product(_ id: UUID) -> MarketplaceProduct? { products.first { $0.id == id } }
    func products(in category: String) -> [MarketplaceProduct] { products.filter { $0.category == category } }
    func products(for shopID: UUID) -> [MarketplaceProduct] { products.filter { $0.shopID == shopID } }

    func toggleFavorite(_ product: MarketplaceProduct) {
        MarketplaceHaptics.tap()
        if favorites.contains(product.id) { favorites.remove(product.id) } else { favorites.insert(product.id) }
        saveMarketplaceAccountState()
    }

    func toggleFollow(_ shop: MarketplaceShop) {
        MarketplaceHaptics.tap()
        if followedShops.contains(shop.id) { followedShops.remove(shop.id) } else { followedShops.insert(shop.id) }
        saveMarketplaceAccountState()
    }

    func addToCart(_ product: MarketplaceProduct, quantity: Int = 1) {
        MarketplaceHaptics.success()
        if let index = cartItems.firstIndex(where: { $0.productID == product.id }) {
            cartItems[index].quantity += quantity
        } else {
            cartItems.append(CartItem(id: UUID(), productID: product.id, quantity: quantity))
        }
        saveMarketplaceAccountState()
        cartConfirmationProduct = product
    }

    func loadMarketplaceCatalog() async {
        catalogIsLoading = true
        defer { catalogIsLoading = false }
        let managedProducts = sellerProducts
        do {
            async let remoteStores = storefrontService.fetchMarketplaceStores(limit: 100)
            async let remoteProducts = storefrontService.fetchMarketplaceProducts()
            let (storePayload, productPayload) = try await (remoteStores, remoteProducts)

            let mappedShops = storePayload.compactMap(makeMarketplaceShop)
            let shopIDs = Set(mappedShops.map(\.id))
            let mappedProducts = productPayload.compactMap { product -> MarketplaceProduct? in
                guard let id = UUID(uuidString: product.id),
                      let storeIDString = product.storeId,
                      let shopID = UUID(uuidString: storeIDString),
                      shopIDs.contains(shopID) else { return nil }
                let remoteImage = product.imageUrl.flatMap { URL(string: $0) == nil ? nil : $0 }
                let image = remoteImage.map {
                    MarketplaceProductImage(
                        productId: id,
                        sellerId: nil,
                        storageKey: $0,
                        originalFileName: $0,
                        thumbnailFileName: $0,
                        mediumFileName: $0,
                        width: 0,
                        height: 0,
                        fileSize: 0,
                        mimeType: "image/remote",
                        sortOrder: 0,
                        isPrimary: true,
                        altText: product.name,
                        uploadState: .completed,
                        progress: 1
                    )
                }
                return MarketplaceProduct(
                    id: id,
                    shopID: shopID,
                    title: product.name,
                    category: mappedShops.first(where: { $0.id == shopID })?.category ?? "Other",
                    subcategory: "All",
                    price: product.price,
                    rating: 0,
                    reviewCount: 0,
                    description: product.description,
                    specs: [],
                    colors: [],
                    imageSeed: product.name,
                    images: image.map { [$0] } ?? [],
                    privacyVerified: true
                )
            }

            shops = mappedShops
            let publicProductIDs = Set(mappedProducts.map(\.id))
            products = mappedProducts + managedProducts.filter { !publicProductIDs.contains($0.id) }
            let availableProductIDs = Set(mappedProducts.map(\.id))
            let availableShopIDs = Set(mappedShops.map(\.id))
            cartItems.removeAll { !availableProductIDs.contains($0.productID) }
            favorites.formIntersection(availableProductIDs)
            followedShops.formIntersection(availableShopIDs)
            saveMarketplaceAccountState()
            catalogErrorMessage = nil
        } catch {
            shops = []
            products = []
            catalogErrorMessage = "OneWay Shops is temporarily unavailable. Please try again later."
        }
    }

    /// Refreshes the public catalog, then restores the signed-in seller's drafts and
    /// other managed shops that are intentionally absent from the public response.
    func refreshMarketplaceCatalog() async {
        await loadMarketplaceCatalog()
        await syncManagedStorefronts()
    }

    /// Performs a server-side store-name search so results are not limited to the
    /// first page of the marketplace catalog cached on this device.
    func refreshMarketplaceSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let matches = try await storefrontService.fetchMarketplaceStores(query: trimmed, limit: 100)
            for match in matches.compactMap(makeMarketplaceShop) {
                if let index = shops.firstIndex(where: { $0.id == match.id }) {
                    shops[index] = match
                } else {
                    shops.append(match)
                }
            }
            catalogErrorMessage = nil
        } catch {
            catalogErrorMessage = "Store search is temporarily unavailable. Pull down to try again."
        }
    }

    private func makeMarketplaceShop(_ store: ShopStore) -> MarketplaceShop? {
        guard let id = UUID(uuidString: store.id) else { return nil }
        return MarketplaceShop(
            id: id,
            name: store.name,
            slug: store.slug,
            description: store.tagline ?? "OneWay seller",
            category: store.category ?? "Other",
            rating: 0,
            reviewCount: 0,
            sales: 0,
            sinceYear: Calendar.current.component(.year, from: Date()),
            privacyScore: 100,
            verified: true,
            bannerSeed: store.name,
            logoSeed: store.name,
            ownerUserID: store.ownerId
        )
    }

    func updateQuantity(productID: UUID, delta: Int) {
        guard let index = cartItems.firstIndex(where: { $0.productID == productID }) else { return }
        cartItems[index].quantity += delta
        if cartItems[index].quantity <= 0 {
            cartItems.remove(at: index)
        }
        saveMarketplaceAccountState()
    }

    func selectSellerShop(_ shop: MarketplaceShop) {
        guard sellerShopIDs.contains(shop.id) else { return }
        sellerShopID = shop.id
        _ = ensurePaymentAccount(for: shop)
        saveSellerState()
    }

    func paymentAccount(for shop: MarketplaceShop?) -> SellerPaymentAccount {
        guard let shop else {
            return SellerPaymentAccount(shopID: UUID())
        }
        return ensurePaymentAccount(for: shop)
    }

    func shopStatus(for shop: MarketplaceShop?) -> SellerShopStatus {
        guard let shop else { return .draft }
        if shop.verified { return .active }
        let status = paymentAccount(for: shop).shopStatus
        // Payment onboarding never puts a storefront into an approval queue.
        return status == .verificationPending ? .draft : status
    }

    func canPublishSellerShop(_ shop: MarketplaceShop?) -> Bool {
        guard let shop else { return false }
        let account = paymentAccount(for: shop)
        return account.onboardingStage == .complete &&
        account.verificationStatus == .complete &&
        account.bankAccountStatus == "Connected"
    }

    func beginPaymentOnboarding(for shop: MarketplaceShop?) {
        guard let shop else { return }
        var account = ensurePaymentAccount(for: shop)
        if account.stripeConnectedAccountID == nil {
            account.stripeConnectedAccountID = "acct_test_\(shop.id.uuidString.prefix(12).lowercased())"
        }
        if account.onboardingStage == .notStarted {
            account.onboardingStage = .identity
            account.verificationStatus = .pending
        }
        account.shopStatus = .draft
        account.updatedAt = Date()
        upsertPaymentAccount(account)
        print("STRIPE_CONNECT_ONBOARDING_STARTED shopId=\(shop.id.uuidString) connectedAccountId=\(account.stripeConnectedAccountID ?? "pending")")
    }

    func advancePaymentOnboarding(for shop: MarketplaceShop?) {
        guard let shop else { return }
        var account = ensurePaymentAccount(for: shop)
        switch account.onboardingStage {
        case .notStarted:
            beginPaymentOnboarding(for: shop)
            return
        case .identity:
            account.onboardingStage = .bankAccount
            account.verificationStatus = .pending
        case .bankAccount:
            account.onboardingStage = .tax
            account.bankAccountStatus = "Connected"
        case .tax:
            account.onboardingStage = .review
        case .review:
            account.onboardingStage = .complete
            account.verificationStatus = .complete
            account.bankAccountStatus = "Connected"
            account.shopStatus = .active
            account.taxDocumentsStatus = "Ready for tax year"
        case .complete:
            account.shopStatus = .active
        }
        account.updatedAt = Date()
        upsertPaymentAccount(account)
    }

    func setPayoutSchedule(_ schedule: SellerPayoutSchedule, for shop: MarketplaceShop?) {
        guard let shop else { return }
        var account = ensurePaymentAccount(for: shop)
        account.payoutSchedule = schedule
        account.updatedAt = Date()
        upsertPaymentAccount(account)
    }

    func launchSellerShop() async -> Bool {
        guard let sellerShop else { sellerValidationMessage = "Create your shop first."; return false }
        let visibleProducts = sellerProducts.filter { $0.specs.contains("Published") }
        sellerShopIsSaving = true
        defer { sellerShopIsSaving = false }
        do {
            try await storefrontService.prepareManagedStorefrontForLaunch(
                id: sellerShop.id.uuidString.lowercased(),
                products: visibleProducts
            )
            let remote = try await storefrontService.publishManagedStorefront(id: sellerShop.id.uuidString.lowercased())
            mergeManagedStorefront(remote, preserving: sellerShop)
            sellerValidationMessage = nil
            MarketplaceHaptics.success()
            await loadMarketplaceCatalog()
            return true
        } catch {
            sellerValidationMessage = error.localizedDescription
            return false
        }
    }

    func pauseSellerShop() async {
        guard let sellerShop, let index = shops.firstIndex(where: { $0.id == sellerShop.id }) else { return }
        sellerShopIsSaving = true
        defer { sellerShopIsSaving = false }
        do {
            let remote = try await storefrontService.unpublishManagedStorefront(id: sellerShop.id.uuidString.lowercased())
            mergeManagedStorefront(remote, preserving: shops[index])
            sellerValidationMessage = nil
            saveSellerState()
            await loadMarketplaceCatalog()
        } catch {
            sellerValidationMessage = error.localizedDescription
        }
    }

    func deleteSellerShop(confirmation: String) async -> Bool {
        guard let sellerShop else { return false }
        sellerShopIsSaving = true
        defer { sellerShopIsSaving = false }
        do {
            try await storefrontService.deleteManagedStorefront(
                id: sellerShop.id.uuidString.lowercased(),
                confirmation: confirmation
            )
            let shopID = sellerShop.id
            let productIDs = Set(sellerProducts.filter { $0.shopID == shopID }.map(\.id))
            shops.removeAll { $0.id == shopID }
            products.removeAll { $0.shopID == shopID }
            sellerShopIDs.removeAll { $0 == shopID }
            sellerProductIDs.subtract(productIDs)
            sellerPaymentAccounts.removeAll { $0.shopID == shopID }
            favorites.subtract(productIDs)
            followedShops.remove(shopID)
            cartItems.removeAll { productIDs.contains($0.productID) }
            threads.removeAll { $0.shopID == shopID }
            sellerShopID = sellerShopIDs.first
            sellerValidationMessage = nil
            saveSellerState()
            saveMarketplaceAccountState()
            await loadMarketplaceCatalog()
            return true
        } catch {
            sellerValidationMessage = error.localizedDescription
            return false
        }
    }

    func sellerOrdersForCurrentShop() -> [MarketplaceOrder] {
        guard let sellerShopID else { return [] }
        return orders.filter { $0.shopID == sellerShopID || $0.connectedAccountID == paymentAccount(for: sellerShop).stripeConnectedAccountID }
    }

    func acceptOrder(_ order: MarketplaceOrder) {
        updateOrder(order) { $0.status = "Accepted" }
    }

    func fulfillOrder(_ order: MarketplaceOrder) {
        updateOrder(order) { order in
            order.status = "Fulfilled"
            order.payoutStatus = .pending
        }
    }

    func refundOrder(_ order: MarketplaceOrder, full: Bool = true) {
        updateOrder(order) { order in
            order.refundStatus = full ? .full : .partial
            order.paymentStatus = .refunded
            order.status = full ? "Refunded" : "Partially refunded"
            order.refundedAmount = full ? order.total : min(order.total, order.total * 0.25)
            if full, platformFeeConfiguration.feeReversalOnRefund {
                order.platformFee = 0
            }
            order.sellerEarnings = max(0, (order.sellerGross ?? order.total) - (order.processingFee ?? 0) - (order.platformFee ?? 0) - (order.refundedAmount ?? 0) - (order.disputedAmount ?? 0))
            order.payoutAmount = order.sellerEarnings
        }
    }

    func createSecureCheckout() async -> URL? {
        guard !checkoutIsLoading else { return nil }
        guard !cartItems.isEmpty else { sellerValidationMessage = "Your cart is empty."; return nil }
        let cartShopIDs = Set(cartItems.compactMap { product($0.productID)?.shopID })
        guard cartShopIDs.count == 1 else {
            sellerValidationMessage = "Checkout can only include products from one Shop at a time."
            return nil
        }

        checkoutIsLoading = true
        defer { checkoutIsLoading = false }
        do {
            let lineItems = cartItems.map {
                CheckoutLineItem(productId: $0.productID.uuidString.lowercased(), quantity: $0.quantity)
            }
            let payload = try await storefrontService.createCheckout(
                items: lineItems,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            if payload.checkoutUrl == nil, payload.order.status == "paid" {
                let purchasedProducts = cartItems.compactMap { item -> MarketplaceProduct? in product(item.productID) }
                let shopID = purchasedProducts.first?.shopID
                orders.insert(
                    MarketplaceOrder(
                        id: UUID(uuidString: payload.order.id) ?? UUID(),
                        shopID: shopID,
                        title: purchasedProducts.map(\.title).joined(separator: ", "),
                        status: "Paid",
                        total: subtotal,
                        paymentStatus: .paid,
                        payoutStatus: .pending,
                        refundStatus: MarketplaceRefundStatus.none,
                        disputeStatus: MarketplaceDisputeStatus.none,
                        transactionID: payload.order.id,
                        createdAt: Date()
                    ),
                    at: 0
                )
                cartItems.removeAll()
                saveMarketplaceAccountState()
                checkoutCompletedMessage = "Test purchase completed successfully. Your order is now available in Orders."
                sellerValidationMessage = nil
                MarketplaceHaptics.success()
                return nil
            }
            guard let checkoutURL = payload.checkoutUrl.flatMap(URL.init(string:)),
                  checkoutURL.scheme == "https" else {
                sellerValidationMessage = "Secure checkout could not be started. No payment was taken."
                return nil
            }
            sellerValidationMessage = nil
            return checkoutURL
        } catch {
            sellerValidationMessage = error.localizedDescription
            return nil
        }
    }

    func removeFromCart(productID: UUID) {
        cartItems.removeAll { $0.productID == productID }
        saveMarketplaceAccountState()
    }

    func search(_ query: String) -> (products: [MarketplaceProduct], shops: [MarketplaceShop]) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return (products, shops) }
        let searchableShopIDs = Set(shops.filter { shopStatus(for: $0) == .active }.map(\.id))
        return (
            products.filter { product in
                searchableShopIDs.contains(product.shopID) && (
                product.title.lowercased().contains(q)
                || product.category.lowercased().contains(q)
                || product.subcategory.lowercased().contains(q)
                || (shop(product.shopID)?.name.lowercased().contains(q) == true))
            },
            shops.filter {
                shopStatus(for: $0) == .active
                && ($0.name.lowercased().contains(q) || $0.category.lowercased().contains(q) || $0.description.lowercased().contains(q))
            }
        )
    }

    func filteredProducts(base: [MarketplaceProduct]) -> [MarketplaceProduct] {
        base.filter { product in
            if let category = filters.category, product.category != category { return false }
            if product.price > filters.maxPrice { return false }
            if product.rating < filters.minimumRating { return false }
            if filters.privacyVerifiedOnly && !product.privacyVerified { return false }
            return true
        }
    }

    func sellerThreads(filter: ShopMessageInboxFilter = .all, search: String = "") -> [ShopConversation] {
        filteredThreads(forSeller: true, filter: filter, search: search)
    }

    func buyerThreads(filter: ShopMessageInboxFilter = .all, search: String = "") -> [ShopConversation] {
        filteredThreads(forSeller: false, filter: filter, search: search)
    }

    func startProductConversation(product: MarketplaceProduct) async -> UUID? {
        if let existing = threads.first(where: { $0.productID == product.id && !$0.deletedByBuyer }) {
            return existing.id
        }
        do {
            let remote = try await storefrontService.createShopConversation(
                shopID: product.shopID,
                productID: product.id,
                orderID: nil,
                type: "productInquiry"
            )
            let thread = mapRemoteConversation(remote, messages: [])
            threads.insert(thread, at: 0)
            saveMessagingState()
            MarketplaceHaptics.success()
            return thread.id
        } catch {
            sellerValidationMessage = error.localizedDescription
            return nil
        }
    }

    func startShopConversation(shop: MarketplaceShop) async -> UUID? {
        if let existing = threads.first(where: {
            $0.shopID == shop.id && $0.productID == nil && $0.orderID == nil && !$0.deletedByBuyer
        }) {
            return existing.id
        }
        if shop.ownerUserID?.caseInsensitiveCompare(AppEnvironment.currentUserID()) == .orderedSame {
            sellerValidationMessage = "This is your shop. Open Messages from Manage My Shop."
            return nil
        }
        do {
            let remote = try await storefrontService.createShopConversation(
                shopID: shop.id,
                productID: nil,
                orderID: nil,
                type: "generalShopQuestion"
            )
            let thread = mapRemoteConversation(remote, messages: [])
            threads.insert(thread, at: 0)
            saveMessagingState()
            sellerValidationMessage = nil
            MarketplaceHaptics.success()
            return thread.id
        } catch {
            sellerValidationMessage = error.localizedDescription
            return nil
        }
    }

    func startOrderSupportConversation(order: MarketplaceOrder) -> UUID? {
        if let existing = threads.first(where: { $0.orderID == order.id && !$0.deletedByBuyer }) {
            return existing.id
        }
        guard let shopID = order.shopID ?? shops.first?.id else {
            sellerValidationMessage = "Unable to start Shop support."
            return nil
        }
        let now = Date()
        let shop = shop(shopID)
        let thread = ShopConversation(
            id: UUID(),
            shopID: shopID,
            buyerName: marketplaceProfile.displayName,
            buyerHandle: "@onewaybuyer",
            sellerName: shop?.name ?? "OneWay Seller",
            orderID: order.id,
            type: .orderConversation,
            subject: "Support for \(order.title)",
            lastMessage: "Order support started.",
            unreadCount: 0,
            lastMessageAt: now,
            messages: [
                .init(text: "Order support started.", isMine: true, date: now, status: "delivered", messageType: "system")
            ]
        )
        threads.insert(thread, at: 0)
        saveMessagingState()
        MarketplaceHaptics.success()
        return thread.id
    }

    func sendShopMessage(threadID: UUID, text: String, asSeller: Bool) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = threads.firstIndex(where: { $0.id == threadID }) else { return false }
        guard !threads[index].isBlocked else {
            sellerValidationMessage = "This Shop conversation is blocked."
            return false
        }
        let recipient = asSeller ? threads[index].buyerUserID.uuidString.lowercased() : threads[index].sellerUserID.uuidString.lowercased()
        do {
            let remote = try await storefrontService.sendShopMessage(
                conversationID: threadID,
                text: trimmed,
                recipientUserID: recipient
            )
            let message = mapRemoteMessage(remote)
            threads[index].messages.append(message)
            threads[index].lastMessage = trimmed
            threads[index].lastMessageAt = message.date
            moveThreadToTop(index)
            saveMessagingState()
            sellerValidationMessage = nil
            MarketplaceHaptics.success()
            return true
        } catch {
            sellerValidationMessage = error.localizedDescription
            return false
        }
    }

    func syncShopConversations() async {
        do {
            let summaries = try await storefrontService.fetchShopConversations()
            var remoteThreads: [ShopConversation] = []
            for summary in summaries {
                let detail = try await storefrontService.fetchShopConversation(id: summary.id)
                remoteThreads.append(mapRemoteConversation(detail.conversation, messages: detail.messages))
            }
            threads = remoteThreads
            saveMessagingState()
        } catch {
            // Preserve the last successfully synchronized cache for offline viewing.
        }
    }

    func syncMarketplaceOrders() async {
        do {
            let remoteOrders = try await storefrontService.fetchMarketplaceOrders()
            orders = remoteOrders.compactMap { remote in
                guard let id = UUID(uuidString: remote.id) else { return nil }
                let title = remote.items.map { item in
                    item.quantity > 1 ? "\(item.name) × \(item.quantity)" : item.name
                }.joined(separator: ", ")
                return MarketplaceOrder(
                    id: id,
                    shopID: remote.storeId.flatMap(UUID.init(uuidString:)),
                    title: title.isEmpty ? "OneWay Shop Order" : title,
                    status: remote.status.replacingOccurrences(of: "_", with: " ").capitalized,
                    total: remote.total,
                    platformFee: Double(remote.oneWayPlatformFeeMinor) / 100,
                    sellerEarnings: Double(remote.sellerNetAmountMinor) / 100,
                    sellerGross: Double(remote.sellerGrossAmountMinor) / 100,
                    refundedAmount: Double(remote.refundedAmountMinor) / 100,
                    disputedAmount: Double(remote.disputedAmountMinor) / 100,
                    payoutAmount: Double(remote.payoutAmountMinor) / 100,
                    paymentStatus: Self.paymentStatus(remote.paymentStatus),
                    payoutStatus: Self.payoutStatus(remote.payoutStatus),
                    refundStatus: remote.refundedAmountMinor > 0 ? .partial : MarketplaceRefundStatus.none,
                    disputeStatus: remote.disputedAmountMinor > 0 ? .open : MarketplaceDisputeStatus.none,
                    transactionID: remote.id,
                    createdAt: Self.remoteDate(remote.createdAt)
                )
            }
            saveMarketplaceAccountState()
        } catch {
            // Preserve cached orders while offline.
        }
    }

    private static func paymentStatus(_ value: String) -> MarketplacePaymentStatus {
        switch value.lowercased() {
        case "paid": return .paid
        case "authorized": return .authorized
        case "refunded": return .refunded
        case "failed": return .failed
        default: return .notStarted
        }
    }

    private static func payoutStatus(_ value: String) -> MarketplacePayoutStatus {
        switch value.lowercased() {
        case "pending": return .pending
        case "in_transit", "in transit": return .inTransit
        case "paid": return .paid
        default: return .notEligible
        }
    }

    private func mapRemoteConversation(_ remote: RemoteShopConversation, messages: [RemoteShopMessage]) -> ShopConversation {
        let shopID = UUID(uuidString: remote.shopId) ?? UUID()
        let productID = remote.productId.flatMap(UUID.init(uuidString:))
        let productTitle = productID.flatMap { product($0)?.title }
        return ShopConversation(
            id: UUID(uuidString: remote.id) ?? UUID(),
            shopID: shopID,
            buyerUserID: UUID(uuidString: remote.buyerUserId) ?? UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sellerUserID: UUID(uuidString: remote.sellerUserId) ?? UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            buyerName: remote.buyerUserId == AppEnvironment.currentUserID() ? "You" : "OneWay Buyer",
            buyerHandle: "@onewaybuyer",
            sellerName: shop(shopID)?.name ?? "OneWay Seller",
            productID: productID,
            orderID: remote.orderId.flatMap(UUID.init(uuidString:)),
            type: remote.type == "orderConversation" ? .orderConversation : .productInquiry,
            state: remote.state == "blocked" ? .blocked : (remote.state == "archived" ? .archived : .open),
            subject: productTitle.map { "Question about \($0)" } ?? "Shop conversation",
            lastMessage: messages.last?.encryptedPayload ?? "Conversation started",
            unreadCount: 0,
            lastMessageAt: Self.remoteDate(remote.lastMessageAt),
            messages: messages.map(mapRemoteMessage)
        )
    }

    private func mapRemoteMessage(_ remote: RemoteShopMessage) -> ShopConversation.ShopMessage {
        ShopConversation.ShopMessage(
            id: UUID(uuidString: remote.id) ?? UUID(),
            text: remote.encryptedPayload,
            isMine: remote.senderUserId == AppEnvironment.currentUserID(),
            date: Self.remoteDate(remote.sentAt),
            status: "delivered",
            messageType: remote.messageType
        )
    }

    private static func remoteDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date()
    }

    func markShopThreadRead(_ thread: ShopConversation) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].unreadCount = 0
        saveMessagingState()
    }

    func toggleMute(_ thread: ShopConversation) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].isMuted.toggle()
        saveMessagingState()
    }

    func archiveThread(_ thread: ShopConversation, asSeller: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        if asSeller { threads[index].archivedBySeller = true } else { threads[index].archivedByBuyer = true }
        threads[index].state = .archived
        saveMessagingState()
    }

    func deleteThreadForMe(_ thread: ShopConversation, asSeller: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        if asSeller { threads[index].deletedBySeller = true } else { threads[index].deletedByBuyer = true }
        saveMessagingState()
    }

    func blockShopMessages(_ thread: ShopConversation, asSeller: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        if asSeller { threads[index].blockedBySeller = true } else { threads[index].blockedByBuyer = true }
        threads[index].state = .blocked
        let contact = ShopBlockedContact(
            id: asSeller ? threads[index].buyerUserID : threads[index].sellerUserID,
            displayName: asSeller ? threads[index].buyerName : threads[index].sellerName,
            handle: asSeller ? threads[index].buyerHandle : "@\(shop(threads[index].shopID)?.slug ?? "shop")",
            scope: "Shop messages",
            blockedAt: Date()
        )
        if !blockedShopContacts.contains(where: { $0.id == contact.id }) {
            blockedShopContacts.append(contact)
        }
        saveMessagingState()
    }

    func unblockShopContact(_ contact: ShopBlockedContact) {
        blockedShopContacts.removeAll { $0.id == contact.id }
        for index in threads.indices {
            if threads[index].buyerUserID == contact.id { threads[index].blockedBySeller = false }
            if threads[index].sellerUserID == contact.id { threads[index].blockedByBuyer = false }
            if !threads[index].isBlocked && threads[index].state == .blocked { threads[index].state = .open }
        }
        saveMessagingState()
    }

    func reportThread(_ thread: ShopConversation, reason: String, block: Bool, asSeller: Bool) {
        if block { blockShopMessages(thread, asSeller: asSeller) }
        sellerValidationMessage = "Report submitted."
        saveMessagingState()
    }

    func saveShopMessagingSettings(_ settings: ShopMessagingSettings) {
        shopMessagingSettings = settings
        saveMessagingState()
    }

    func saveMarketplaceProfile(_ profile: MarketplaceBuyerProfile) {
        marketplaceProfile = profile
        saveMarketplaceAccountState()
    }

    func saveMarketplacePrivacy(_ privacy: MarketplacePrivacySettings) {
        marketplacePrivacy = privacy
        saveMarketplaceAccountState()
    }

    func saveMarketplaceNotifications(_ notifications: MarketplaceNotificationSettings) {
        marketplaceNotifications = notifications
        saveMarketplaceAccountState()
    }

    func saveShippingAddress(_ address: MarketplaceShippingAddress) {
        var next = address
        if next.isDefault {
            for index in shippingAddresses.indices {
                shippingAddresses[index].isDefault = false
            }
        } else if shippingAddresses.isEmpty {
            next.isDefault = true
        }
        if let index = shippingAddresses.firstIndex(where: { $0.id == next.id }) {
            shippingAddresses[index] = next
        } else {
            shippingAddresses.append(next)
        }
        saveMarketplaceAccountState()
    }

    func deleteShippingAddress(_ address: MarketplaceShippingAddress) {
        let wasDefault = address.isDefault
        shippingAddresses.removeAll { $0.id == address.id }
        if wasDefault, !shippingAddresses.isEmpty {
            shippingAddresses[0].isDefault = true
        }
        saveMarketplaceAccountState()
    }

    func order(_ id: UUID) -> MarketplaceOrder? {
        orders.first { $0.id == id }
    }

    func savedShops() -> [MarketplaceShop] {
        followedShops.compactMap { shop($0) }
    }

    func createSellerShop(from draft: SellerShopDraft) async -> Bool {
        guard !sellerShopIsSaving else { return false }
        let profileName = marketplaceProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = ShopCreationRequirements.usableName(requested: draft.shopName, profileName: profileName)
        let trimmedDescription = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = ShopCreationRequirements.usableCategory(draft.category)
        sellerShopIsSaving = true
        defer { sellerShopIsSaving = false }
        let creationKey = pendingShopCreationKey ?? UUID().uuidString.lowercased()
        pendingShopCreationKey = creationKey
        let remote: ManagedStorefrontDTO
        do {
            remote = try await storefrontService.createManagedStorefront(
                name: trimmedName,
                description: trimmedDescription,
                category: trimmedCategory,
                idempotencyKey: creationKey
            )
        } catch {
            sellerValidationMessage = "OneWay couldn't create the shop. Please try again. (\(creationKey.prefix(8)))"
            return false
        }
        guard let id = UUID(uuidString: remote.id) else {
            sellerValidationMessage = "OneWay returned an invalid shop identifier."
            return false
        }
        let shop = MarketplaceShop(
            id: id,
            name: trimmedName,
            slug: remote.slug,
            description: trimmedDescription,
            category: trimmedCategory,
            rating: 0,
            reviewCount: 0,
            sales: 0,
            sinceYear: Calendar.current.component(.year, from: Date()),
            privacyScore: 100,
            verified: false,
            bannerSeed: Self.shopArtSeed(fileName: draft.bannerImageFileName, fallback: "\(trimmedName) banner"),
            logoSeed: Self.shopArtSeed(fileName: draft.badgeImageFileName, fallback: "\(trimmedName) logo"),
            ownerUserID: AppEnvironment.currentUserID()
        )
        upsertSellerShop(shop)
        pendingShopCreationKey = nil
        sellerValidationMessage = nil
        MarketplaceHaptics.success()
        return true
    }

    func updateSellerShop(from draft: SellerShopDraft) async -> Bool {
        let trimmedName = draft.shopName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = sellerShopID else { return await createSellerShop(from: draft) }
        guard !trimmedName.isEmpty else { sellerValidationMessage = "Shop name is required."; return false }
        guard !trimmedDescription.isEmpty else { sellerValidationMessage = "Shop description is required."; return false }
        guard !trimmedCategory.isEmpty else { sellerValidationMessage = "Category is required."; return false }

        sellerShopIsSaving = true
        defer { sellerShopIsSaving = false }
        let remote: ManagedStorefrontDTO
        do {
            remote = try await storefrontService.updateManagedStorefront(
                id: id.uuidString.lowercased(),
                name: trimmedName,
                description: trimmedDescription,
                category: trimmedCategory
            )
        } catch {
            sellerValidationMessage = error.localizedDescription
            return false
        }
        let existing = sellerShop
        let shop = MarketplaceShop(
            id: id,
            name: trimmedName,
            slug: remote.slug,
            description: trimmedDescription,
            category: trimmedCategory,
            rating: existing?.rating ?? 0,
            reviewCount: existing?.reviewCount ?? 0,
            sales: existing?.sales ?? 0,
            sinceYear: existing?.sinceYear ?? Calendar.current.component(.year, from: Date()),
            privacyScore: existing?.privacyScore ?? 100,
            verified: existing?.verified ?? false,
            bannerSeed: Self.shopArtSeed(fileName: draft.bannerImageFileName, fallback: existing?.bannerSeed ?? "\(trimmedName) banner"),
            logoSeed: Self.shopArtSeed(fileName: draft.badgeImageFileName, fallback: existing?.logoSeed ?? "\(trimmedName) logo")
        )
        upsertSellerShop(shop)
        sellerValidationMessage = nil
        MarketplaceHaptics.success()
        return true
    }

    private func syncManagedStorefronts() async {
        do {
            var remoteStores = try await storefrontService.fetchManagedStorefronts()
            let localOnly = sellerShops.filter { local in
                !remoteStores.contains(where: { $0.id.caseInsensitiveCompare(local.id.uuidString) == .orderedSame })
            }
            for local in localOnly {
                if let migrated = try? await storefrontService.createManagedStorefront(
                    name: local.name,
                    description: local.description,
                    category: local.category,
                    idempotencyKey: "migration-\(local.id.uuidString.lowercased())"
                ) {
                    remoteStores.append(migrated)
                }
            }
            for remote in remoteStores {
                mergeManagedStorefront(remote, preserving: sellerShops.first(where: { $0.id.uuidString.caseInsensitiveCompare(remote.id) == .orderedSame }))
            }
            saveSellerState()
        } catch {
            // Keep the local cache available offline; creation and launch still surface errors directly.
        }
    }

    private func mergeManagedStorefront(_ remote: ManagedStorefrontDTO, preserving local: MarketplaceShop?) {
        guard let id = UUID(uuidString: remote.id) else { return }
        let shop = MarketplaceShop(
            id: id,
            name: remote.name,
            slug: remote.slug,
            description: remote.description ?? remote.tagline ?? local?.description ?? "OneWay seller",
            category: remote.category ?? local?.category ?? "Other",
            rating: local?.rating ?? 0,
            reviewCount: local?.reviewCount ?? 0,
            sales: local?.sales ?? 0,
            sinceYear: local?.sinceYear ?? Calendar.current.component(.year, from: Date()),
            privacyScore: local?.privacyScore ?? 100,
            verified: remote.published,
            bannerSeed: local?.bannerSeed ?? remote.name,
            logoSeed: local?.logoSeed ?? remote.name
        )
        upsertSellerShop(shop)
        var account = ensurePaymentAccount(for: shop)
        switch remote.status?.lowercased() {
        case "paused": account.shopStatus = .paused
        case "published": account.shopStatus = .active
        default: account.shopStatus = remote.published ? .active : .draft
        }
        upsertPaymentAccount(account)
    }

    func draftForSellerShop() -> SellerShopDraft {
        guard let sellerShop else { return SellerShopDraft() }
        return SellerShopDraft(
            shopName: sellerShop.name,
            description: sellerShop.description,
            category: sellerShop.category,
            bannerImageFileName: Self.localShopArtFileName(from: sellerShop.bannerSeed),
            badgeImageFileName: Self.localShopArtFileName(from: sellerShop.logoSeed),
            location: "",
            shippingPolicy: "Ships with tracking when available.",
            returnsPolicy: "Returns accepted within 14 days.",
            processingTime: "3-5 business days",
            contactMessages: true,
            contactCalls: false,
            contactWalkie: false
        )
    }

    private static func shopArtSeed(fileName: String?, fallback: String) -> String {
        guard let fileName, !fileName.isEmpty else { return fallback }
        return "local-shop-art:\(fileName)"
    }

    private static func localShopArtFileName(from seed: String) -> String? {
        let prefix = "local-shop-art:"
        guard seed.hasPrefix(prefix) else { return nil }
        return String(seed.dropFirst(prefix.count))
    }

    func saveSellerProduct(from draft: SellerProductDraft, publish: Bool) -> Bool {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImages = normalizeProductImages(draft.images, productId: nil)
        guard let sellerShopID else { sellerValidationMessage = "Create your shop first."; return false }
        guard !trimmedTitle.isEmpty else { sellerValidationMessage = "Product title is required."; return false }
        guard let price = Double(draft.priceText), price > 0 else { sellerValidationMessage = "Enter a valid price."; return false }
        guard !trimmedCategory.isEmpty else { sellerValidationMessage = "Product category is required."; return false }
        guard !publish || canPublishAnotherProduct else {
            sellerValidationMessage = "You've used your 10 free product listings. Save this as a draft or unlock more product listings."
            showProductCapacitySheet = true
            print("PRODUCT_CAPACITY_BLOCKED active=\(sellerCapacitySummary.activeProductCount) capacity=\(sellerCapacitySummary.totalProductCapacity.map(String.init) ?? "unlimited")")
            return false
        }
        if publish && normalizedImages.primary == nil {
            sellerValidationMessage = "Add at least one uploaded product photo before publishing."
            return false
        }

        let productId = UUID()
        let product = MarketplaceProduct(
            id: productId,
            shopID: sellerShopID,
            title: trimmedTitle,
            category: trimmedCategory,
            subcategory: "Creator Goods",
            price: price,
            rating: 0,
            reviewCount: 0,
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "A creator-made product from OneWay Shops." : draft.description,
            specs: ["Inventory: \(draft.inventoryText)", draft.shippingOption, publish ? "Published" : "Draft"],
            colors: ["Purple", "Custom"],
            imageSeed: trimmedTitle,
            images: normalizeProductImages(draft.images, productId: productId).images,
            privacyVerified: draft.privacyVerified
        )
        products.insert(product, at: 0)
        sellerProductIDs.insert(product.id)
        sellerValidationMessage = nil
        // TODO: Replace local product saves with backend catalog, image upload, moderation, tax/shipping, payment, and seller settlement APIs.
        saveSellerState()
        MarketplaceHaptics.success()
        return true
    }

    func updateSellerProduct(_ product: MarketplaceProduct, from draft: SellerProductDraft, publish: Bool) -> Bool {
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImages = normalizeProductImages(draft.images, productId: product.id)
        guard sellerProductIDs.contains(product.id) else { sellerValidationMessage = "This product does not belong to your shop."; return false }
        guard !trimmedTitle.isEmpty else { sellerValidationMessage = "Product title is required."; return false }
        guard let price = Double(draft.priceText), price > 0 else { sellerValidationMessage = "Enter a valid price."; return false }
        guard !trimmedCategory.isEmpty else { sellerValidationMessage = "Product category is required."; return false }
        let currentlyConsumes = productConsumesCapacity(product)
        guard !publish || currentlyConsumes || canPublishAnotherProduct else {
            sellerValidationMessage = "You've used your available product slots. Buy more capacity or keep this listing as a draft."
            showProductCapacitySheet = true
            print("PRODUCT_CAPACITY_BLOCKED active=\(sellerCapacitySummary.activeProductCount) capacity=\(sellerCapacitySummary.totalProductCapacity.map(String.init) ?? "unlimited")")
            return false
        }
        if publish && normalizedImages.primary == nil {
            sellerValidationMessage = "Published products need one primary photo."
            return false
        }

        guard let index = products.firstIndex(where: { $0.id == product.id }) else { return false }
        products[index].title = trimmedTitle
        products[index].description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "A creator-made product from OneWay Shops." : draft.description
        products[index].price = price
        products[index].category = trimmedCategory
        products[index].specs = ["Inventory: \(draft.inventoryText)", draft.shippingOption, publish ? "Published" : "Draft"]
        products[index].images = normalizedImages.images
        products[index].imageSeed = trimmedTitle
        products[index].privacyVerified = draft.privacyVerified
        sellerValidationMessage = nil
        saveSellerState()
        MarketplaceHaptics.success()
        return true
    }

    func draft(for product: MarketplaceProduct) -> SellerProductDraft {
        SellerProductDraft(
            title: product.title,
            description: product.description,
            priceText: String(format: "%.2f", product.price),
            category: product.category,
            inventoryText: product.specs.first(where: { $0.hasPrefix("Inventory: ") })?.replacingOccurrences(of: "Inventory: ", with: "") ?? "1",
            shippingOption: product.specs.dropFirst().first ?? "Standard shipping",
            privacyVerified: product.privacyVerified,
            images: product.images
        )
    }

    func duplicateSellerProduct(_ product: MarketplaceProduct) {
        var copy = product
        let copyId = UUID()
        copy = MarketplaceProduct(
            id: copyId,
            shopID: product.shopID,
            title: "\(product.title) Copy",
            category: product.category,
            subcategory: product.subcategory,
            price: product.price,
            rating: product.rating,
            reviewCount: product.reviewCount,
            description: product.description,
            specs: product.specs,
            colors: product.colors,
            imageSeed: "\(product.imageSeed) copy",
            images: normalizeProductImages(product.images, productId: copyId).images,
            privacyVerified: product.privacyVerified
        )
        products.insert(copy, at: 0)
        sellerProductIDs.insert(copy.id)
        saveSellerState()
    }

    func loadSellerStoreProducts() async {
        guard !sellerStoreProductsAreLoading else { return }
        sellerStoreProductsAreLoading = true
        defer { sellerStoreProductsAreLoading = false }

        let identifiers = Set(
            sellerPackageCatalog
                .filter(\.active)
                .compactMap(\.appStoreProductId)
        )
        guard !identifiers.isEmpty else {
            sellerStoreProducts = [:]
            unavailableSellerProductIDs = []
            return
        }

        do {
            let products = try await StoreKit.Product.products(for: identifiers)
            sellerStoreProducts = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            unavailableSellerProductIDs = identifiers.subtracting(sellerStoreProducts.keys)
            for identifier in unavailableSellerProductIDs.sorted() {
                print("SELLER_STOREKIT_PRODUCT_MISSING productId=\(identifier)")
            }
            for package in sellerPackageCatalog where package.active && storeProduct(for: package) != nil {
                if !storeProductMatchesBilling(for: package) {
                    print("SELLER_STOREKIT_CLASSIFICATION_MISMATCH packageCode=\(package.code) productId=\(package.appStoreProductId ?? "nil") expectedBilling=\(package.billingType.rawValue) actual=\(storeClassification(for: package))")
                }
            }
        } catch {
            sellerStoreProducts = [:]
            unavailableSellerProductIDs = identifiers
            sellerValidationMessage = "Seller plans could not be loaded from the App Store. Please try again."
            print("SELLER_STOREKIT_PRODUCTS_FAILED error=\(error.localizedDescription)")
        }
    }

    func storeProduct(for package: SellerPackage) -> StoreKit.Product? {
        guard let productID = package.appStoreProductId else { return nil }
        return sellerStoreProducts[productID]
    }

    func sellerPackageIsAvailable(_ package: SellerPackage) -> Bool {
        package.active && storeProduct(for: package) != nil && storeProductMatchesBilling(for: package)
    }

    func displayedSellerPrice(for package: SellerPackage) -> String? {
        storeProduct(for: package)?.displayPrice
    }

    var nextShopSlotStorePrice: String? {
        guard let package = sellerPackageCatalog.first(where: { $0.code == "SHOP_SLOT_NEXT" }) else {
            return nil
        }
        return displayedSellerPrice(for: package)
    }

    func displayedSellerName(for package: SellerPackage) -> String {
        let storeName = storeProduct(for: package)?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return storeName?.isEmpty == false ? storeName! : package.displayName
    }

    func displayedSellerDescription(for package: SellerPackage) -> String {
        let storeDescription = storeProduct(for: package)?.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return storeDescription?.isEmpty == false ? storeDescription! : package.description
    }

    func storeClassification(for package: SellerPackage) -> String {
        guard let product = storeProduct(for: package) else {
            return "StoreKit product unavailable"
        }
        switch product.type {
        case .consumable:
            return "Consumable · one-time purchase"
        case .nonConsumable:
            return "Non-consumable · one-time purchase"
        case .autoRenewable:
            return "Auto-renewable subscription"
        case .nonRenewable:
            return "Non-renewing subscription"
        default:
            return "App Store purchase"
        }
    }

    private func storeProductMatchesBilling(for package: SellerPackage) -> Bool {
        guard let product = storeProduct(for: package) else { return false }
        switch (package.billingType, product.type) {
        case (.oneTime, .consumable), (.oneTime, .nonConsumable):
            return true
        case (.monthly, .autoRenewable), (.monthly, .nonRenewable),
             (.annual, .autoRenewable), (.annual, .nonRenewable):
            return true
        default:
            return false
        }
    }

    func buySellerPackage(_ package: SellerPackage) async {
        guard package.active,
              let productID = package.appStoreProductId,
              let product = sellerStoreProducts[productID],
              sellerPackageIsAvailable(package) else {
            sellerValidationMessage = "This package is currently unavailable from the App Store."
            print("SELLER_PURCHASE_BLOCKED_MISSING_PRODUCT packageCode=\(package.code) productId=\(package.appStoreProductId ?? "nil")")
            MarketplaceHaptics.tap()
            return
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verifiedSellerTransaction(from: verification)
                guard transaction.productID == productID else {
                    throw InAppPurchaseError.transactionUnverified
                }
                recordVerifiedSellerPurchase(transaction, product: product, package: package)
                await transaction.finish()
                sellerValidationMessage = "Purchase complete. Your capacity is updated."
                MarketplaceHaptics.success()
            case .userCancelled:
                sellerValidationMessage = "Purchase cancelled."
            case .pending:
                sellerValidationMessage = "Purchase pending approval. Capacity will update after App Store verification."
            @unknown default:
                sellerValidationMessage = "The App Store returned an unsupported purchase result."
            }
        } catch {
            sellerValidationMessage = error.localizedDescription
            print("SELLER_PURCHASE_FAILED packageCode=\(package.code) productId=\(productID) error=\(error.localizedDescription)")
            MarketplaceHaptics.tap()
        }
    }

    func restoreSellerPurchases() async {
        do {
            try await AppStore.sync()
            await loadSellerStoreProducts()
            var restoredCount = 0

            for await verification in Transaction.currentEntitlements {
                let transaction = try verifiedSellerTransaction(from: verification)
                guard transaction.revocationDate == nil,
                      let package = sellerPackageCatalog.first(where: { $0.appStoreProductId == transaction.productID }),
                      let product = storeProduct(for: package) else {
                    continue
                }
                let wasRecorded = sellerPlanTransactions.contains {
                    $0.providerTransactionId == String(transaction.id)
                }
                recordVerifiedSellerPurchase(transaction, product: product, package: package)
                if !wasRecorded { restoredCount += 1 }
            }

            sellerValidationMessage = restoredCount == 0
                ? "Purchases restored. No new restorable entitlements were found."
                : "Restored \(restoredCount) purchase\(restoredCount == 1 ? "" : "s")."
            print("SELLER_PURCHASE_RESTORED restored=\(restoredCount)")
            MarketplaceHaptics.success()
        } catch {
            sellerValidationMessage = "Purchases could not be restored: \(error.localizedDescription)"
            print("SELLER_PURCHASE_RESTORE_FAILED error=\(error.localizedDescription)")
            MarketplaceHaptics.tap()
        }
    }

    var canPublishAnotherProduct: Bool {
        let summary = sellerCapacitySummary
        return summary.hasUnlimitedProducts || (summary.availableProductSlots ?? 0) > 0
    }

    func deleteSellerProduct(_ product: MarketplaceProduct) {
        products.removeAll { $0.id == product.id }
        sellerProductIDs.remove(product.id)
        saveSellerState()
    }

    private func upsertSellerShop(_ shop: MarketplaceShop) {
        if let index = shops.firstIndex(where: { $0.id == shop.id }) {
            shops[index] = shop
        } else {
            shops.insert(shop, at: 0)
        }
        sellerShopID = shop.id
        if !sellerShopIDs.contains(shop.id) {
            sellerShopIDs.insert(shop.id, at: 0)
        }
        saveSellerState()
    }

    private func loadSellerState() {
        if let data = UserDefaults.standard.data(forKey: sellerShopsKey),
           let savedShops = try? JSONDecoder().decode([MarketplaceShop].self, from: data) {
            sellerShopIDs = savedShops.map(\.id)
            shops.removeAll { sellerShopIDs.contains($0.id) }
            shops.insert(contentsOf: savedShops, at: 0)
            sellerShopID = sellerShopIDs.first
        }
        if let data = UserDefaults.standard.data(forKey: sellerShopKey),
           let shop = try? JSONDecoder().decode(MarketplaceShop.self, from: data) {
            if !shops.contains(where: { $0.id == shop.id }) {
                shops.insert(shop, at: 0)
            }
            if !sellerShopIDs.contains(shop.id) {
                sellerShopIDs.insert(shop.id, at: 0)
            }
            if sellerShopID == nil {
                sellerShopID = shop.id
            }
        }
        if let data = UserDefaults.standard.data(forKey: sellerProductsKey),
           let savedProducts = try? JSONDecoder().decode([MarketplaceProduct].self, from: data) {
            sellerProductIDs = Set(savedProducts.map(\.id))
            products.removeAll { sellerProductIDs.contains($0.id) }
            products.insert(contentsOf: savedProducts, at: 0)
        }
        if let data = UserDefaults.standard.data(forKey: sellerPaymentAccountsKey),
           let accounts = try? JSONDecoder().decode([SellerPaymentAccount].self, from: data) {
            sellerPaymentAccounts = accounts
        }
        if let data = UserDefaults.standard.data(forKey: platformFeeConfigurationKey),
           let config = try? JSONDecoder().decode(MarketplacePlatformFeeConfiguration.self, from: data) {
            platformFeeConfiguration = config
        }
        if let data = UserDefaults.standard.data(forKey: sellerEntitlementsKey),
           let entitlements = try? JSONDecoder().decode([SellerEntitlement].self, from: data) {
            sellerEntitlements = entitlements
        }
        if let data = UserDefaults.standard.data(forKey: sellerPlanTransactionsKey),
           let transactions = try? JSONDecoder().decode([SellerPlanTransaction].self, from: data) {
            sellerPlanTransactions = transactions
        }
        ensureFreeEntitlements()
        let shopConversationData = UserDefaults.standard.data(forKey: threadsKey)
            ?? UserDefaults.standard.data(forKey: legacyThreadsKey)
        if let data = shopConversationData,
           let savedThreads = try? JSONDecoder().decode([ShopConversation].self, from: data) {
            threads = savedThreads
            if UserDefaults.standard.data(forKey: threadsKey) == nil {
                saveMessagingState()
            }
        }
        if let data = UserDefaults.standard.data(forKey: messagingSettingsKey),
           let settings = try? JSONDecoder().decode(ShopMessagingSettings.self, from: data) {
            shopMessagingSettings = settings
        }
        if let data = UserDefaults.standard.data(forKey: blockedContactsKey),
           let contacts = try? JSONDecoder().decode([ShopBlockedContact].self, from: data) {
            blockedShopContacts = contacts
        }
        if let data = UserDefaults.standard.data(forKey: marketplaceProfileKey),
           let profile = try? JSONDecoder().decode(MarketplaceBuyerProfile.self, from: data) {
            marketplaceProfile = profile
        }
        if let data = UserDefaults.standard.data(forKey: marketplacePrivacyKey),
           let privacy = try? JSONDecoder().decode(MarketplacePrivacySettings.self, from: data) {
            marketplacePrivacy = privacy
        }
        if let data = UserDefaults.standard.data(forKey: marketplaceNotificationsKey),
           let notifications = try? JSONDecoder().decode(MarketplaceNotificationSettings.self, from: data) {
            marketplaceNotifications = notifications
        }
        if let data = UserDefaults.standard.data(forKey: shippingAddressesKey),
           let addresses = try? JSONDecoder().decode([MarketplaceShippingAddress].self, from: data) {
            shippingAddresses = addresses
        }
        if let data = UserDefaults.standard.data(forKey: followedShopsKey),
           let savedShopIDs = try? JSONDecoder().decode(Set<UUID>.self, from: data) {
            followedShops = savedShopIDs
        }
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let savedProductIDs = try? JSONDecoder().decode(Set<UUID>.self, from: data) {
            favorites = savedProductIDs
        }
        if let data = UserDefaults.standard.data(forKey: ordersKey),
           let savedOrders = try? JSONDecoder().decode([MarketplaceOrder].self, from: data) {
            orders = savedOrders
        }
        if let data = UserDefaults.standard.data(forKey: cartKey),
           let savedCart = try? JSONDecoder().decode([CartItem].self, from: data) {
            cartItems = savedCart
        }
    }

    private func saveSellerState() {
        if let sellerShop,
           let data = try? JSONEncoder().encode(sellerShop) {
            UserDefaults.standard.set(data, forKey: sellerShopKey)
        } else {
            // The legacy single-shop cache must not resurrect a shop after the
            // seller permanently deletes their final storefront.
            UserDefaults.standard.removeObject(forKey: sellerShopKey)
        }
        let savedShops = sellerShops
        if let data = try? JSONEncoder().encode(savedShops) {
            UserDefaults.standard.set(data, forKey: sellerShopsKey)
        }
        let savedProducts = sellerProducts
        if let data = try? JSONEncoder().encode(savedProducts) {
            UserDefaults.standard.set(data, forKey: sellerProductsKey)
        }
        if let data = try? JSONEncoder().encode(sellerPaymentAccounts) {
            UserDefaults.standard.set(data, forKey: sellerPaymentAccountsKey)
        }
        if let data = try? JSONEncoder().encode(platformFeeConfiguration) {
            UserDefaults.standard.set(data, forKey: platformFeeConfigurationKey)
        }
        if let data = try? JSONEncoder().encode(sellerEntitlements) {
            UserDefaults.standard.set(data, forKey: sellerEntitlementsKey)
        }
        if let data = try? JSONEncoder().encode(sellerPlanTransactions) {
            UserDefaults.standard.set(data, forKey: sellerPlanTransactionsKey)
        }
        saveMessagingState()
    }

    private func ensureFreeEntitlements() {
        let required: [(SellerEntitlementType, SellerEntitlementSource, String, Int)] = [
            (.shopSlot, .freeAllowance, "free-shop-slot", 1),
            (.productSlot, .freeAllowance, "free-product-slots", 10)
        ]
        for item in required where !sellerEntitlements.contains(where: { $0.entitlementType == item.0 && $0.sourceType == item.1 && $0.sourceReferenceId == item.2 }) {
            sellerEntitlements.append(SellerEntitlement(entitlementType: item.0, sourceType: item.1, sourceReferenceId: item.2, quantity: item.3))
        }
    }

    private func productConsumesCapacity(_ product: MarketplaceProduct) -> Bool {
        let specs = product.specs.map { $0.lowercased() }
        if specs.contains(where: { $0.contains("draft") || $0.contains("archived") }) { return false }
        return specs.contains(where: { $0.contains("published") || $0.contains("paused") })
    }

    private func verifiedSellerTransaction(
        from result: VerificationResult<Transaction>
    ) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified:
            throw InAppPurchaseError.transactionUnverified
        }
    }

    private func recordVerifiedSellerPurchase(
        _ storeTransaction: Transaction,
        product: StoreKit.Product,
        package: SellerPackage
    ) {
        let providerTransactionID = String(storeTransaction.id)
        let entitlementReferenceID = package.billingType == .oneTime
            ? providerTransactionID
            : String(storeTransaction.originalID)

        if !sellerPlanTransactions.contains(where: { $0.providerTransactionId == providerTransactionID }) {
            let amount = NSDecimalNumber(decimal: product.price).doubleValue
            sellerPlanTransactions.insert(
                SellerPlanTransaction(
                    packageId: package.id,
                    transactionType: transactionType(for: package),
                    billingProvider: "APP_STORE",
                    providerTransactionId: providerTransactionID,
                    idempotencyKey: "app-store-\(providerTransactionID)",
                    amount: amount,
                    currency: product.priceFormatStyle.currencyCode
                ),
                at: 0
            )
        }

        grantEntitlement(
            for: package,
            sourceReferenceId: entitlementReferenceID,
            expiresAt: storeTransaction.expirationDate
        )
        print("SELLER_PAYMENT_SUCCEEDED packageCode=\(package.code) productId=\(product.id) transactionId=\(providerTransactionID) billingProvider=APP_STORE")
        print("SELLER_ENTITLEMENT_GRANTED packageCode=\(package.code) quantity=\(package.quantity ?? 1)")
        saveSellerState()
    }

    private func grantEntitlement(
        for package: SellerPackage,
        sourceReferenceId: String,
        expiresAt: Date? = nil
    ) {
        if let index = sellerEntitlements.firstIndex(where: { $0.sourceReferenceId == sourceReferenceId }) {
            if package.billingType != .oneTime {
                sellerEntitlements[index].expiresAt = expiresAt
                sellerEntitlements[index].status = .active
                sellerEntitlements[index].updatedAt = Date()
            }
            return
        }
        let entitlement: SellerEntitlement
        switch package.packageType {
        case .shopSlot, .shopBundle:
            entitlement = SellerEntitlement(entitlementType: package.grantedEntitlementType, sourceType: package.billingType == .oneTime ? .oneTimePurchase : .subscription, sourceReferenceId: sourceReferenceId, quantity: package.grantedCapacityQuantity, expiresAt: expiresAt)
        case .unlimitedProducts:
            entitlement = SellerEntitlement(entitlementType: package.grantedEntitlementType, sourceType: .oneTimePurchase, sourceReferenceId: sourceReferenceId, quantity: package.grantedCapacityQuantity)
        case .sellerPro:
            entitlement = SellerEntitlement(entitlementType: package.grantedEntitlementType, sourceType: .subscription, sourceReferenceId: sourceReferenceId, quantity: package.grantedCapacityQuantity, expiresAt: expiresAt)
        case .productSlot, .productBundle:
            entitlement = SellerEntitlement(entitlementType: package.grantedEntitlementType, sourceType: package.billingType == .oneTime ? .oneTimePurchase : .subscription, sourceReferenceId: sourceReferenceId, quantity: package.grantedCapacityQuantity, expiresAt: expiresAt)
        }
        sellerEntitlements.append(entitlement)
    }

    private func transactionType(for package: SellerPackage) -> String {
        switch package.packageType {
        case .shopSlot: return "SHOP_SLOT_PURCHASE"
        case .shopBundle: return "SHOP_CAPACITY_BUNDLE"
        case .sellerPro: return "SELLER_PRO_SUBSCRIPTION"
        case .unlimitedProducts, .productBundle: return "PRODUCT_CAPACITY_BUNDLE"
        case .productSlot: return "PRODUCT_SLOT_PURCHASE"
        }
    }

    private func ensurePaymentAccount(for shop: MarketplaceShop) -> SellerPaymentAccount {
        if let existing = sellerPaymentAccounts.first(where: { $0.shopID == shop.id }) {
            return existing
        }
        let account = SellerPaymentAccount(shopID: shop.id)
        sellerPaymentAccounts.insert(account, at: 0)
        saveSellerState()
        return account
    }

    private func upsertPaymentAccount(_ account: SellerPaymentAccount) {
        if let index = sellerPaymentAccounts.firstIndex(where: { $0.shopID == account.shopID }) {
            sellerPaymentAccounts[index] = account
        } else {
            sellerPaymentAccounts.insert(account, at: 0)
        }
        saveSellerState()
    }

    private func updateOrder(_ order: MarketplaceOrder, mutate: (inout MarketplaceOrder) -> Void) {
        guard let index = orders.firstIndex(where: { $0.id == order.id }) else { return }
        mutate(&orders[index])
        saveSellerState()
    }

    private func accruePaymentMetrics(_ order: MarketplaceOrder, shop: MarketplaceShop) {
        var account = ensurePaymentAccount(for: shop)
        account.pendingBalance += order.sellerEarnings ?? 0
        account.currentBalance = account.pendingBalance + account.availableBalance
        account.todaySales += order.total
        account.weekSales += order.total
        account.monthSales += order.total
        account.lifetimeSales += order.total
        account.pendingPayouts += order.sellerEarnings ?? 0
        account.platformFeesPaid += order.platformFee ?? 0
        account.refunds += order.refundedAmount ?? 0
        account.updatedAt = Date()
        upsertPaymentAccount(account)
    }

    private func saveMessagingState() {
        if let data = try? JSONEncoder().encode(threads) {
            UserDefaults.standard.set(data, forKey: threadsKey)
        }
        if let data = try? JSONEncoder().encode(shopMessagingSettings) {
            UserDefaults.standard.set(data, forKey: messagingSettingsKey)
        }
        if let data = try? JSONEncoder().encode(blockedShopContacts) {
            UserDefaults.standard.set(data, forKey: blockedContactsKey)
        }
    }

    private func saveMarketplaceAccountState() {
        if let data = try? JSONEncoder().encode(marketplaceProfile) {
            UserDefaults.standard.set(data, forKey: marketplaceProfileKey)
        }
        if let data = try? JSONEncoder().encode(marketplacePrivacy) {
            UserDefaults.standard.set(data, forKey: marketplacePrivacyKey)
        }
        if let data = try? JSONEncoder().encode(marketplaceNotifications) {
            UserDefaults.standard.set(data, forKey: marketplaceNotificationsKey)
        }
        if let data = try? JSONEncoder().encode(shippingAddresses) {
            UserDefaults.standard.set(data, forKey: shippingAddressesKey)
        }
        if let data = try? JSONEncoder().encode(followedShops) {
            UserDefaults.standard.set(data, forKey: followedShopsKey)
        }
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
        if let data = try? JSONEncoder().encode(orders) {
            UserDefaults.standard.set(data, forKey: ordersKey)
        }
        if let data = try? JSONEncoder().encode(cartItems) {
            UserDefaults.standard.set(data, forKey: cartKey)
        }
    }

    private func moveThreadToTop(_ index: Int) {
        let thread = threads.remove(at: index)
        threads.insert(thread, at: 0)
    }

    private func filteredThreads(forSeller: Bool, filter: ShopMessageInboxFilter, search: String) -> [ShopConversation] {
        let normalized = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return threads.filter { thread in
            if forSeller && thread.deletedBySeller { return false }
            if !forSeller && thread.deletedByBuyer { return false }
            switch filter {
            case .all:
                if thread.state == .archived { return false }
            case .unread:
                if thread.unreadCount == 0 { return false }
            case .productQuestions:
                if thread.type != .productInquiry { return false }
            case .orders:
                if thread.type != .orderConversation { return false }
            case .customRequests:
                if thread.type != .customRequest { return false }
            case .archived:
                if forSeller ? !thread.archivedBySeller : !thread.archivedByBuyer { return false }
            case .blocked:
                if !thread.isBlocked { return false }
            }
            guard !normalized.isEmpty else { return true }
            let linkedProduct = thread.productID.flatMap { product($0) }
            return thread.buyerName.lowercased().contains(normalized)
                || thread.buyerHandle.lowercased().contains(normalized)
                || thread.sellerName.lowercased().contains(normalized)
                || thread.subject.lowercased().contains(normalized)
                || thread.lastMessage.lowercased().contains(normalized)
                || (linkedProduct?.title.lowercased().contains(normalized) == true)
        }
        .sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    private func normalizeProductImages(_ images: [MarketplaceProductImage], productId: UUID?) -> (images: [MarketplaceProductImage], primary: MarketplaceProductImage?) {
        var next = Array(images.prefix(10)).enumerated().map { index, image in
            var copy = image
            copy.productId = productId
            copy.sortOrder = index
            copy.updatedAt = Date()
            return copy
        }
        if !next.isEmpty && !next.contains(where: { $0.isPrimary }) {
            next[0].isPrimary = true
        }
        if let primaryIndex = next.firstIndex(where: { $0.isPrimary }) {
            for index in next.indices where index != primaryIndex {
                next[index].isPrimary = false
            }
        }
        return (next, next.first(where: { $0.isPrimary && $0.isCompleted }) ?? next.first(where: { $0.isCompleted }))
    }
}

enum ShopMessageInboxFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case productQuestions = "Product Questions"
    case orders = "Orders"
    case customRequests = "Custom Requests"
    case archived = "Archived"
    case blocked = "Blocked"

    var id: String { rawValue }
}

enum MarketplaceSampleData {
    static let clay = UUID()
    static let goods = UUID()
    static let minerals = UUID()
    static let leather = UUID()
    static let scents = UUID()
    static let green = UUID()
    static let thread = UUID()

    static let shops: [MarketplaceShop] = [
        .init(id: clay, name: "Clay & Co.", slug: "clay-co", description: "Small-batch ceramics made for quiet homes and bright rituals.", category: "Home & Living", rating: 4.9, reviewCount: 428, sales: 3200, sinceYear: 2019, privacyScore: 98, verified: true, bannerSeed: "ceramic studio", logoSeed: "clay"),
        .init(id: goods, name: "OneWayGoods", slug: "onewaygoods", description: "Private-first essentials and digital creator goods built on OneWay.", category: "Art & Collectibles", rating: 4.8, reviewCount: 210, sales: 1880, sinceYear: 2024, privacyScore: 100, verified: true, bannerSeed: "purple goods", logoSeed: "plane"),
        .init(id: minerals, name: "Mystic Minerals", slug: "mystic-minerals", description: "Crystals, clusters, and calming desk pieces with secure checkout.", category: "Art & Collectibles", rating: 4.7, reviewCount: 391, sales: 2400, sinceYear: 2020, privacyScore: 95, verified: true, bannerSeed: "amethyst", logoSeed: "gem"),
        .init(id: leather, name: "LeatherCraft Co.", slug: "leathercraft", description: "Hand-stitched wallets and everyday carry goods.", category: "Vintage", rating: 4.9, reviewCount: 617, sales: 5400, sinceYear: 2017, privacyScore: 91, verified: true, bannerSeed: "leather", logoSeed: "wallet"),
        .init(id: scents, name: "Luna Scents", slug: "luna-scents", description: "Candles, diffusers, and soft fragrance rituals.", category: "Home & Living", rating: 4.8, reviewCount: 188, sales: 1250, sinceYear: 2021, privacyScore: 94, verified: false, bannerSeed: "candle", logoSeed: "moon"),
        .init(id: green, name: "GreenHaus", slug: "greenhaus", description: "Modern planters and plant-friendly home goods.", category: "Home & Living", rating: 4.6, reviewCount: 156, sales: 980, sinceYear: 2022, privacyScore: 92, verified: true, bannerSeed: "plants", logoSeed: "leaf"),
        .init(id: thread, name: "Thread & Loom", slug: "thread-loom", description: "Warm textiles, throws, and slow-made clothing.", category: "Clothing", rating: 4.9, reviewCount: 244, sales: 1700, sinceYear: 2018, privacyScore: 96, verified: true, bannerSeed: "textile", logoSeed: "thread")
    ]

    static let categories: [MarketplaceCategory] = [
        .init(name: "Home & Living", icon: "house.fill", chips: ["All", "Decor", "Kitchen", "Furniture", "Lighting"]),
        .init(name: "Jewelry", icon: "sparkles", chips: ["All", "Rings", "Necklaces", "Bracelets", "Gold"]),
        .init(name: "Art & Collectibles", icon: "paintpalette.fill", chips: ["All", "Prints", "Minerals", "Digital", "Sculpture"]),
        .init(name: "Beauty", icon: "sparkles.rectangle.stack.fill", chips: ["All", "Skincare", "Bath", "Fragrance", "Wellness"]),
        .init(name: "Tech", icon: "headphones", chips: ["All", "Audio", "Accessories", "Devices", "Smart Home"]),
        .init(name: "Clothing", icon: "tshirt.fill", chips: ["All", "Throws", "Tops", "Woven", "Accessories"]),
        .init(name: "Vintage", icon: "clock.fill", chips: ["All", "Leather", "Decor", "Rare", "Restored"])
    ]

    static let products: [MarketplaceProduct] = [
        .init(id: UUID(), shopID: goods, title: "Moon Lamp", category: "Home & Living", subcategory: "Lighting", price: 34.99, rating: 4.9, reviewCount: 184, description: "A soft purple moon lamp for desks, bedrooms, and late-night creative sessions.", specs: ["Dimmable LED glow", "USB-C rechargeable", "Gift-ready box"], colors: ["Purple", "White", "Silver"], imageSeed: "moon lamp", privacyVerified: true),
        .init(id: UUID(), shopID: minerals, title: "Amethyst Cluster", category: "Art & Collectibles", subcategory: "Minerals", price: 49.99, rating: 4.8, reviewCount: 212, description: "A hand-selected amethyst cluster with deep violet facets and natural texture.", specs: ["Natural stone", "Approx. 4 inches", "Ships padded"], colors: ["Violet", "Natural"], imageSeed: "amethyst", privacyVerified: true),
        .init(id: UUID(), shopID: leather, title: "Handmade Wallet", category: "Vintage", subcategory: "Leather", price: 59.00, rating: 4.9, reviewCount: 330, description: "Full-grain leather wallet with hand-stitched edges and minimal profile.", specs: ["Full-grain leather", "6 card slots", "Hand stitched"], colors: ["Black", "Brown", "Tan"], imageSeed: "wallet", privacyVerified: true),
        .init(id: UUID(), shopID: clay, title: "Minimal Ceramic Mug", category: "Home & Living", subcategory: "Kitchen", price: 26.00, rating: 4.7, reviewCount: 98, description: "A balanced ceramic mug for coffee, tea, and slow mornings.", specs: ["12 oz", "Dishwasher safe", "Wheel-thrown"], colors: ["Cream", "Stone", "Purple"], imageSeed: "mug", privacyVerified: true),
        .init(id: UUID(), shopID: clay, title: "Speckled Bowl", category: "Home & Living", subcategory: "Kitchen", price: 34.00, rating: 4.8, reviewCount: 143, description: "A speckled ceramic bowl with a satin glaze and handmade shape.", specs: ["Food safe", "7 inch diameter", "Small batch"], colors: ["Speckled", "Charcoal"], imageSeed: "bowl", privacyVerified: true),
        .init(id: UUID(), shopID: clay, title: "Tall Ceramic Vase", category: "Home & Living", subcategory: "Decor", price: 48.00, rating: 4.9, reviewCount: 87, description: "A tall handmade vase with clean lines and a quiet sculptural presence.", specs: ["Watertight", "11 inches tall", "Matte glaze"], colors: ["Ivory", "Lilac"], imageSeed: "vase", privacyVerified: true),
        .init(id: UUID(), shopID: scents, title: "Aroma Diffuser", category: "Home & Living", subcategory: "Decor", price: 39.00, rating: 4.6, reviewCount: 72, description: "A compact diffuser with soft light and calm fragrance flow.", specs: ["Quiet mist", "6 hour runtime", "Auto shutoff"], colors: ["Black", "White"], imageSeed: "diffuser", privacyVerified: false),
        .init(id: UUID(), shopID: scents, title: "Soy Candle", category: "Home & Living", subcategory: "Decor", price: 19.00, rating: 4.8, reviewCount: 119, description: "Hand-poured soy candle with a soft lunar lavender scent.", specs: ["Soy wax", "40 hour burn", "Reusable jar"], colors: ["Lavender", "Amber"], imageSeed: "candle", privacyVerified: true),
        .init(id: UUID(), shopID: green, title: "Modern Planter", category: "Home & Living", subcategory: "Decor", price: 28.00, rating: 4.7, reviewCount: 64, description: "A modern planter with drainage and a purple glazed base.", specs: ["Drainage hole", "Ceramic", "Fits 4 inch plants"], colors: ["Purple", "Moss"], imageSeed: "planter", privacyVerified: true),
        .init(id: UUID(), shopID: thread, title: "Cozy Knit Throw", category: "Clothing", subcategory: "Throws", price: 54.00, rating: 4.9, reviewCount: 201, description: "A cozy knit throw for couches, cabins, and quiet nights in.", specs: ["Cotton blend", "Machine washable", "50 x 60 inches"], colors: ["Plum", "Cloud", "Graphite"], imageSeed: "throw", privacyVerified: true)
    ]

    static var threads: [ShopConversation] {
        [
            .init(id: UUID(), shopID: clay, subject: "Custom mug glaze", lastMessage: "We can make that in lilac.", unreadCount: 1, messages: [
                .init(text: "Can you make the mug in lilac?", isMine: true, date: Date().addingTimeInterval(-3600)),
                .init(text: "We can make that in lilac.", isMine: false, date: Date().addingTimeInterval(-1800))
            ]),
            .init(id: UUID(), shopID: leather, subject: "Wallet initials", lastMessage: "Monogramming is available.", unreadCount: 0, messages: [
                .init(text: "Do you offer initials?", isMine: true, date: Date().addingTimeInterval(-7200)),
                .init(text: "Monogramming is available.", isMine: false, date: Date().addingTimeInterval(-6500))
            ])
        ]
    }

    static let orders: [MarketplaceOrder] = [
        .init(title: "Moon Lamp", status: "Delivered privately", total: 34.99, tax: 0, shipping: 0, discount: 0, platformFee: 0.30, processingFee: 1.31, sellerEarnings: 33.38, sellerGross: 34.99, refundedAmount: 0, disputedAmount: 0, payoutAmount: 33.38, paymentStatus: .paid, payoutStatus: .paid, refundStatus: MarketplaceRefundStatus.none, disputeStatus: MarketplaceDisputeStatus.none),
        .init(title: "Minimal Ceramic Mug", status: "Processing", total: 26.00, tax: 0, shipping: 0, discount: 0, platformFee: 0.30, processingFee: 1.05, sellerEarnings: 24.65, sellerGross: 26.00, refundedAmount: 0, disputedAmount: 0, payoutAmount: 24.65, paymentStatus: .paid, payoutStatus: .pending, refundStatus: MarketplaceRefundStatus.none, disputeStatus: MarketplaceDisputeStatus.none)
    ]
}
