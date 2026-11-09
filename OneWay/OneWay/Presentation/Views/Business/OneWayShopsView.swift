import SwiftUI

enum OneWayShopNavigationPolicy {
    static func resolvedRoute(_ requested: MarketplaceRoute, hasSellerShop: Bool) -> MarketplaceRoute {
        guard !hasSellerShop else { return requested }
        switch requested {
        case .myShops, .manageShop, .sellerPayments, .sellerPaymentSetup,
             .sellerPlans, .addProduct, .manageProducts, .editStore,
             .sellerOrders, .sellerMessages, .shopPolicies:
            return .createShop
        default:
            return requested
        }
    }
}

struct OneWayShopsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case home = "Home"
        case categories = "Categories"
        case favorites = "Favorites"
        case messages = "Messages"
        case account = "Account"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .categories: return "square.grid.2x2.fill"
            case .favorites: return "heart.fill"
            case .messages: return "bubble.left.and.bubble.right.fill"
            case .account: return "person.fill"
            }
        }

        var physicalRole: OneWayIconRole? {
            switch self {
            case .home: return .shops
            case .categories: return .product
            case .favorites: return .favorites
            case .messages: return .messages
            case .account: return .profile
            }
        }
    }

    @StateObject private var viewModel = MarketplaceViewModel()
    @ObservedObject private var toolbarPreferences: OneWayToolbarPreferencesStore
    @State private var selectedTab: Tab = .home
    @State private var previousTab: Tab = .home
    // A typed, single source of truth makes every push and one-level pop
    // observable by this NavigationStack. Child screens never mutate a copy.
    @State private var path: [MarketplaceRoute] = []
    @State private var searchText = ""
    @State private var showFilterSheet = false
    @State private var showAdsManager = false
    @State private var pendingInitialRoute: MarketplaceRoute?
    @State private var editingToolbarSlot: OneWayToolbarSlot?
    @State private var pressedToolbarSlotID: String?
    @State private var suppressNextToolbarTapSlotID: String?

    var onManage: (() -> Void)?
    var onOpenCommunity: (() -> Void)?
    var onOpenFeature: ((OneWayFeature) -> Void)?
    var onOpenHub: (() -> Void)?

    init(
        initialTab: Tab = .home,
        initialRoute: MarketplaceRoute? = nil,
        toolbarPreferences: OneWayToolbarPreferencesStore? = nil,
        onManage: (() -> Void)? = nil,
        onOpenCommunity: (() -> Void)? = nil,
        onOpenFeature: ((OneWayFeature) -> Void)? = nil,
        onOpenHub: (() -> Void)? = nil
    ) {
        _toolbarPreferences = ObservedObject(
            wrappedValue: toolbarPreferences
                ?? OneWayToolbarPreferencesStore(userID: AppEnvironment.currentUserID())
        )
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let debugRoute: MarketplaceRoute?
        let debugTab: Tab
        if arguments.contains("-qa-seller-plans") {
            debugRoute = .sellerPlans
        } else if arguments.contains("-qa-my-shops") {
            debugRoute = .myShops
        } else if arguments.contains("-qa-shop-category") {
            debugRoute = .category("Home & Living")
        } else if arguments.contains("-qa-manage-shop") {
            debugRoute = .manageShop
        } else {
            debugRoute = nil
        }
        if arguments.contains("-qa-shop-categories") {
            debugTab = .categories
        } else if arguments.contains("-qa-shop-messages") || arguments.contains("-qa-message-settings") {
            debugTab = .messages
        } else if arguments.contains("-qa-shop-account") {
            debugTab = .account
        } else {
            debugTab = initialTab
        }
        _selectedTab = State(initialValue: debugTab)
        _pendingInitialRoute = State(initialValue: initialRoute ?? debugRoute)
#else
        _selectedTab = State(initialValue: initialTab)
        _pendingInitialRoute = State(initialValue: initialRoute)
#endif
        self.onManage = onManage
        self.onOpenCommunity = onOpenCommunity
        self.onOpenFeature = onOpenFeature
        self.onOpenHub = onOpenHub
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                MarketplaceTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    selectedContent
                    bottomNavigation
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: MarketplaceRoute.self) { route in
                routeView(route)
            }
            .sheet(isPresented: $showFilterSheet) {
                MarketplaceFilterSheet(filters: $viewModel.filters, categories: viewModel.categories)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showAdsManager) {
                OneWayAdsManagerView {
                    showAdsManager = false
                }
            }
            .confirmationDialog(
                viewModel.cartConfirmationProduct.map { "\($0.title) was added to your cart." } ?? "Added to Cart",
                isPresented: Binding(
                    get: { viewModel.cartConfirmationProduct != nil },
                    set: { if !$0 { viewModel.cartConfirmationProduct = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Keep Shopping") {
                    viewModel.cartConfirmationProduct = nil
                }
                Button("View Cart") {
                    viewModel.cartConfirmationProduct = nil
                    path.append(MarketplaceRoute.cart)
                }
                Button("Checkout") {
                    viewModel.cartConfirmationProduct = nil
                    path.append(MarketplaceRoute.checkout)
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cartConfirmationProduct = nil
                }
            }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-qa-manage-shop"),
                   !viewModel.hasSellerShop {
                    var draft = SellerShopDraft()
                    draft.shopName = "Holiday Cards"
                    draft.description = "Seasonal cards and keepsakes created on OneWay."
                    draft.category = "Art & Collectibles"
                    Task { _ = await viewModel.createSellerShop(from: draft) }
                }
                #endif
                guard let pendingInitialRoute else { return }
                self.pendingInitialRoute = nil
                path.append(shopAwareRoute(pendingInitialRoute))
            }
            .sheet(item: $editingToolbarSlot) { slot in
                OneWayToolbarEditorSheet(
                    store: toolbarPreferences,
                    context: .shops,
                    slotID: slot.id
                )
                .presentationDetents([.large])
            }
        }
    }

    private func shopAwareRoute(_ requested: MarketplaceRoute) -> MarketplaceRoute {
        OneWayShopNavigationPolicy.resolvedRoute(requested, hasSellerShop: viewModel.hasSellerShop)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .home:
            ShopsHomeView(
                viewModel: viewModel,
                searchText: $searchText,
                onSearch: { openSearch() },
                onFilter: { showFilterSheet = true },
                onCategories: { selectTab(.categories) },
                onQuantumHome: {
                    onOpenFeature?(.quantum)
                    NotificationCenter.default.post(name: Notification.Name("OneWayQuantumHomeRequested"), object: nil)
                },
                onRoute: { path.append($0) }
            )
        case .categories:
            CategoriesLandingView(viewModel: viewModel) { category in
                path.append(MarketplaceRoute.category(category.name))
            }
        case .favorites:
            FavoritesView(viewModel: viewModel) { path.append($0) }
        case .messages:
            ShopsMessagesView(viewModel: viewModel, onBack: {
                let destination = previousTab == .messages ? .home : previousTab
                selectTab(destination)
            }) { path.append($0) }
        case .account:
            ShopsAccountView(viewModel: viewModel) { path.append($0) }
        }
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            toolbarShortcut(at: 0)
            toolbarShortcut(at: 1)
            shopsHubButton
            toolbarShortcut(at: 2)
            toolbarShortcut(at: 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, OneWayToolbarMetrics.verticalPadding)
        .background(
            OneWayDesignSystem.Colors.panelGlass,
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(MarketplaceTheme.purple.opacity(0.58), lineWidth: 1)
        )
        .shadow(color: MarketplaceTheme.purple.opacity(0.16), radius: 18, y: -4)
        .frame(height: 72)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func toolbarShortcut(at index: Int) -> some View {
        let slots = toolbarPreferences.slots(for: .shops)
        if slots.indices.contains(index) {
            let slot = slots[index]
            let feature = slot.feature
            let tab = shopsTab(for: feature)
            let isSelected = tab == selectedTab

            Button {
                if suppressNextToolbarTapSlotID == slot.id {
                    suppressNextToolbarTapSlotID = nil
                    return
                }
                MarketplaceHaptics.tap()
                openToolbarFeature(feature)
            } label: {
                VStack(spacing: 0) {
                    OneWayPhysicalIcon(
                        role: feature.physicalIconRole,
                        size: OneWayToolbarMetrics.iconSize,
                        state: isSelected ? .selected : .normal,
                        container: .none,
                        accessibilityLabel: feature.accessibilityLabel,
                        glowIntensity: isSelected ? 0.22 : 0.06
                    )
                    Text(feature.displayName)
                        .font(OneWayDesignSystem.Typography.tabLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }
                .foregroundStyle(isSelected ? MarketplaceTheme.purple : MarketplaceTheme.faint)
                .frame(maxWidth: .infinity, minHeight: OneWayToolbarMetrics.itemHeight)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(OneWayDesignSystem.Colors.purple.opacity(0.24))
                            .frame(
                                width: OneWayToolbarMetrics.selectedWidth,
                                height: OneWayToolbarMetrics.selectedHeight
                            )
                            .blur(radius: 12)
                    }
                }
                .scaleEffect(pressedToolbarSlotID == slot.id ? 1.08 : 1)
                .opacity(editingToolbarSlot != nil && editingToolbarSlot?.id != slot.id ? 0.45 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: pressedToolbarSlotID)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(feature.accessibilityLabel)
            .accessibilityHint("Double tap to open. Long press to customize this Shops shortcut.")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: Text("Customize shortcut")) {
                beginEditingToolbar(slot)
            }
            .onLongPressGesture(
                minimumDuration: 0.45,
                maximumDistance: 24,
                pressing: { pressing in
                    pressedToolbarSlotID = pressing ? slot.id : nil
                },
                perform: {
                    suppressNextToolbarTapSlotID = slot.id
                    beginEditingToolbar(slot)
                }
            )
        } else {
            Spacer(minLength: 0)
                .frame(maxWidth: .infinity)
        }
    }

    private var shopsHubButton: some View {
        OneWayHubButton(isDimmed: editingToolbarSlot != nil) {
            onOpenHub?()
        }
    }

    private func shopsTab(for feature: OneWayFeature) -> Tab? {
        if case .shopsTab(let tab) = feature.navigationDestination {
            return tab
        }
        return nil
    }

    private func openToolbarFeature(_ feature: OneWayFeature) {
        if let tab = shopsTab(for: feature) {
            selectTab(tab)
        } else {
            onOpenFeature?(feature)
        }
    }

    private func beginEditingToolbar(_ slot: OneWayToolbarSlot) {
        MarketplaceHaptics.tap()
        editingToolbarSlot = slot
    }

    private func openSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        path.append(MarketplaceRoute.search(trimmed))
    }

    @ViewBuilder
    private func routeView(_ route: MarketplaceRoute) -> some View {
        switch route {
        case .shop(let id):
            if let shop = viewModel.shop(id) {
                ShopProfileView(
                    viewModel: viewModel,
                    shop: shop,
                    onOpenFeature: openToolbarFeature,
                    onOpenHub: { onOpenHub?() },
                    onBack: popOneRoute
                ) { path.append($0) }
            }
        case .category(let category):
            CategoryProductsView(viewModel: viewModel, categoryName: category) { path.append($0) }
        case .product(let id):
            if let product = viewModel.product(id) {
                ProductDetailView(viewModel: viewModel, product: product, onBack: popOneRoute) { threadID in
                    path.append(MarketplaceRoute.chat(threadID))
                }
            }
        case .search(let query):
            SearchResultsView(viewModel: viewModel, query: query, onBack: popOneRoute) { path.append($0) }
        case .chat(let id):
            if let thread = viewModel.threads.first(where: { $0.id == id }) {
                MarketplaceChatView(viewModel: viewModel, thread: thread, mode: .buyer, onBack: popOneRoute)
            }
        case .sellerChat(let id):
            if let thread = viewModel.threads.first(where: { $0.id == id }) {
                MarketplaceChatView(viewModel: viewModel, thread: thread, mode: .seller, onBack: popOneRoute)
            }
        case .cart:
            CartView(viewModel: viewModel, onRoute: { path.append($0) }, onBack: popOneRoute)
        case .checkout:
            MarketplaceCheckoutView(viewModel: viewModel, onBack: popOneRoute)
        case .createShop:
            CreateShopView(viewModel: viewModel, onCreated: {
                path.removeLast()
                path.append(MarketplaceRoute.manageShop)
            }, onBack: popOneRoute)
        case .myShops:
            MyShopsView(
                viewModel: viewModel,
                onOpenAds: { showAdsManager = true },
                onRoute: { path.append($0) }
            )
        case .manageShop:
            ManageMyShopView(viewModel: viewModel, onRoute: { path.append($0) }, onBack: popOneRoute)
        case .sellerPayments:
            SellerPaymentsView(viewModel: viewModel) { path.append($0) }
        case .sellerPaymentSetup:
            SellerPaymentSetupView(viewModel: viewModel)
        case .sellerPlans:
            SellerPlansCapacityView(viewModel: viewModel)
        case .addProduct:
            AddProductView(viewModel: viewModel)
        case .manageProducts:
            ManageProductsView(viewModel: viewModel, onRoute: { path.append($0) }, onBack: popOneRoute)
        case .editProduct(let id):
            if let product = viewModel.product(id) {
                EditProductView(viewModel: viewModel, product: product)
            }
        case .editStore:
            EditStoreView(viewModel: viewModel, onBack: popOneRoute)
        case .shopPolicies(let requestedShopID):
            ShopPoliciesView(
                viewModel: viewModel,
                requestedShopID: requestedShopID,
                onCreateShop: { path.append(.createShop) },
                onBack: popOneRoute
            )
        case .buyerShopPolicies(let shopID):
            BuyerShopPoliciesView(
                viewModel: viewModel,
                shopID: shopID,
                onBack: popOneRoute,
                onMessage: { threadID in path.append(.chat(threadID)) }
            )
        case .sellerOrderDetail(let id):
            if let order = viewModel.orders.first(where: { $0.id == id }) {
                SellerOrderDetailView(viewModel: viewModel, order: order)
            }
        case .sellerOrders:
            SellerOrdersView(viewModel: viewModel, onRoute: { path.append($0) }, onBack: popOneRoute)
        case .sellerMessages:
            SellerMessagesView(viewModel: viewModel, onBack: popOneRoute) { path.append($0) }
        case .marketplaceProfile:
            MarketplaceProfileView(viewModel: viewModel)
        case .marketplacePrivacy:
            MarketplacePrivacySettingsView(viewModel: viewModel)
        case .orderHistory:
            MarketplaceOrderHistoryView(viewModel: viewModel) { order in
                path.append(MarketplaceRoute.orderDetail(order.id))
            }
        case .orderDetail(let id):
            if let order = viewModel.order(id) {
                MarketplaceOrderDetailView(viewModel: viewModel, order: order) { route in
                    path.append(route)
                }
            }
        case .savedShops:
            SavedShopsListView(viewModel: viewModel) { shop in
                path.append(MarketplaceRoute.shop(shop.id))
            }
        case .shopNotifications:
            ShopNotificationsSettingsView(viewModel: viewModel)
        case .shippingAddresses:
            ShippingAddressesView(viewModel: viewModel)
        case .paymentPrivacy:
            PaymentPrivacyView(viewModel: viewModel)
        case .shopMessagePreferences:
            ShopMessagePreferencesView(viewModel: viewModel)
        case .returnsRefunds:
            ReturnsRefundsView(viewModel: viewModel) { order in
                path.append(MarketplaceRoute.orderDetail(order.id))
            }
        case .marketplaceSupport:
            MarketplaceSupportView(viewModel: viewModel, onBack: popOneRoute) { path.append($0) }
        }
    }

    private func popOneRoute() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    private func selectTab(_ tab: Tab) {
        guard tab != selectedTab else { return }
        previousTab = selectedTab
        selectedTab = tab
    }
}

struct ShopsHomeView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Binding var searchText: String
    let onSearch: () -> Void
    let onFilter: () -> Void
    let onCategories: () -> Void
    let onQuantumHome: () -> Void
    let onRoute: (MarketplaceRoute) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                MarketplaceHeader(
                    onQuantumHome: onQuantumHome
                )
                MarketplaceSearchBar(text: $searchText, onSearch: onSearch, onFilter: onFilter)
                    .onTapGesture { MarketplaceHaptics.tap() }
                hero
                categories
                popularPicks
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
    }

    private var hero: some View {
        TabView {
            ForEach(0..<3, id: \.self) { index in
                GeometryReader { proxy in
                    HStack(spacing: 4) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(
                                "Shop unique.\nSupport creators.\nStay \(Text("OneWay.").foregroundStyle(MarketplaceTheme.purple))"
                            )
                            .foregroundStyle(MarketplaceTheme.text)
                            .font(.system(size: 21, weight: .black, design: .rounded))
                            .minimumScaleFactor(0.82)
                            .fixedSize(horizontal: false, vertical: true)

                            Button {
                                onRoute(.category(index == 1 ? "Jewelry" : (index == 2 ? "Art & Collectibles" : "Home & Living")))
                            } label: {
                                HStack(spacing: 9) {
                                    Text("Explore Now")
                                    OneWayResolvedIcon(systemName: "chevron.right")
                                        .font(.caption.weight(.black))
                                }
                                .font(.caption.weight(.black))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .background(MarketplaceTheme.gradient, in: Capsule())
                                .shadow(color: MarketplaceTheme.purple.opacity(0.35), radius: 12, y: 4)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: proxy.size.width * 0.43, alignment: .leading)

                        Spacer(minLength: 0)

                        Image("OneWayShopsHeroShowcase")
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: proxy.size.width * 0.55)
                            .shadow(color: MarketplaceTheme.purple.opacity(0.40), radius: 18, y: 8)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [
                                OneWayDesignSystem.Colors.panel.opacity(0.98),
                                OneWayDesignSystem.Colors.deepPurple.opacity(0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(MarketplaceTheme.purple.opacity(0.58), lineWidth: 1)
                    )
                    .shadow(color: MarketplaceTheme.purple.opacity(0.12), radius: 18, y: 8)
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(height: 238)
        .tabViewStyle(.page(indexDisplayMode: .always))
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Categories", actionTitle: "View All", action: onCategories)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(referenceCategories.enumerated()), id: \.offset) { _, category in
                        Button {
                            onRoute(.category(category.route))
                        } label: {
                            VStack(spacing: 6) {
                                Image(category.asset)
                                    .resizable()
                                    .renderingMode(.original)
                                    .scaledToFit()
                                    .frame(height: 66)
                                    .shadow(color: MarketplaceTheme.purple.opacity(0.26), radius: 9, y: 5)
                                Text(category.title)
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(MarketplaceTheme.text)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.66)
                            }
                            .padding(6)
                            .frame(width: 86, height: 116)
                            .background(
                                OneWayDesignSystem.Colors.panelGlass,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(MarketplaceTheme.purple.opacity(0.52), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var popularPicks: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "Popular Picks",
                actionTitle: "View All",
                action: { onRoute(.category("Home & Living")) }
            )
            if viewModel.catalogIsLoading {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Loading live products…")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(MarketplaceTheme.muted)
                }
                .padding(16)
                .marketplaceCard(cornerRadius: 20)
            } else if let error = viewModel.catalogErrorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(MarketplaceTheme.muted)
                    Button("Try Again") {
                        Task { await viewModel.loadMarketplaceCatalog() }
                    }
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(MarketplaceTheme.purple)
                }
                .padding(16)
                .marketplaceCard(cornerRadius: 20)
            } else if viewModel.products.isEmpty {
                Text("No products are available right now.")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .padding(16)
                    .marketplaceCard(cornerRadius: 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.products.prefix(8)) { product in
                            Button {
                                onRoute(.product(product.id))
                            } label: {
                                MarketplaceProductCard(
                                    product: product,
                                    shop: viewModel.shop(product.shopID),
                                    isFavorite: viewModel.favorites.contains(product.id),
                                    onFavorite: { viewModel.toggleFavorite(product) }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.black))
                .foregroundStyle(MarketplaceTheme.text)
            Spacer()
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(actionTitle)
                    OneWayResolvedIcon(systemName: "chevron.right")
                        .font(.caption.weight(.black))
                }
                .font(.subheadline.weight(.black))
                .foregroundStyle(MarketplaceTheme.purple)
            }
            .buttonStyle(.plain)
        }
    }

    private var referenceCategories: [(title: String, route: String, asset: String)] {
        [
            ("Home & Living", "Home & Living", "OneWaySculptedHome"),
            ("Jewelry", "Jewelry", "OneWaySculptedJewelry"),
            ("Art & Collectibles", "Art & Collectibles", "OneWaySculptedArt"),
            ("Beauty", "Beauty", "OneWaySculptedBeauty"),
            ("Tech", "Tech", "OneWaySculptedTech"),
        ]
    }
}

struct CategoriesLandingView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onSelect: (MarketplaceCategory) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    OneWayPhysicalIcon(role: .product, size: 62, state: .selected, container: .feature)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Categories")
                            .font(.largeTitle.weight(.black))
                            .foregroundStyle(MarketplaceTheme.text)
                        Text("Find something made for you.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MarketplaceTheme.muted)
                    }
                }
                ForEach(viewModel.categories) { category in
                    Button { onSelect(category) } label: {
                        HStack(spacing: 14) {
                            OneWayPhysicalIcon(
                                role: role(for: category.name),
                                size: 82,
                                container: .showcase,
                                accessibilityLabel: category.name
                            )
                            VStack(alignment: .leading, spacing: 6) {
                                Text(category.name)
                                    .font(.title3.weight(.black))
                                Text(category.chips.dropFirst().joined(separator: " • "))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(MarketplaceTheme.muted)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            OneWayResolvedIcon(systemName: "chevron.right")
                                .foregroundStyle(MarketplaceTheme.purple)
                        }
                        .foregroundStyle(MarketplaceTheme.text)
                        .padding(14)
                        .frame(minHeight: 110)
                        .marketplaceCard(cornerRadius: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(category.name). \(category.chips.dropFirst().joined(separator: ", ")).")
                    .accessibilityHint("Opens \(category.name) products.")
                }
            }
            .padding(18)
            .padding(.bottom, 112)
        }
    }

    private func role(for category: String) -> OneWayIconRole {
        switch category {
        case "Home & Living": return .homeLiving
        case "Jewelry": return .jewelry
        case "Art & Collectibles": return .artCollectibles
        case "Beauty": return .beauty
        case "Tech": return .tech
        case "Clothing": return .clothing
        case "Vintage": return .vintage
        default: return .product
        }
    }
}
