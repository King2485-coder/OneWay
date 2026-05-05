import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ShopFeedView: View {
    @AppStorage("oneway.has_seen_premium_paywall") private var hasSeenPremiumPaywall = false
    @AppStorage("oneway.has_completed_first_value_action") private var hasCompletedFirstValueAction = false

    @State private var products: [ShopProduct] = []
    @State private var featuredProducts: [ShopProduct] = []
    @State private var featuredStores: [ShopStore] = []
    @State private var trendingProducts: [ShopProduct] = []
    @State private var sponsoredEntries: [SponsoredFeedEntry] = []
    @State private var avatarFeed: [AIAvatarFeedItem] = []
    @State private var trendingLives: [TrendingLiveSession] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var focusedFeedItemID: String?
    @State private var showPaywall = false

    private let service: StorefrontService
    private let onManage: (() -> Void)?

    init(service: StorefrontService = .shared, onManage: (() -> Void)? = nil) {
        self.service = service
        self.onManage = onManage
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .black,
                    Color(red: 0.03, green: 0.05, blue: 0.12),
                    .black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        header
                        launchBanner
                        searchBar

                        if let errorMessage {
                            errorCard(errorMessage)
                        }

                        if !featuredProducts.isEmpty {
                            featuredCarousel
                        }

                        if !featuredStores.isEmpty {
                            featuredStoresRow
                        }

                        if !avatarFeed.isEmpty {
                            creatorRow
                        }

                        if !trendingLives.isEmpty {
                            trendingLivesRow
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("For You")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)

                            ForEach(Array(feedItems.enumerated()), id: \.element.id) { index, item in
                                switch item {
                                case .product(let product):
                                    ProductCard(product: product) {
                                        registerMeaningfulInteraction(triggerPaywall: true)
                                    }
                                        .scaleEffect(focusedFeedItemID == item.id ? 1 : 0.985)
                                        .opacity(focusedFeedItemID == nil || focusedFeedItemID == item.id ? 1 : 0.92)
                                        .onTapGesture {
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                focusedFeedItemID = focusedFeedItemID == item.id ? nil : item.id
                                            }
                                        }
                                case .sponsored(let entry):
                                    SponsoredProductCard(entry: entry) {
                                        registerMeaningfulInteraction(triggerPaywall: true)
                                    }
                                        .scaleEffect(focusedFeedItemID == item.id ? 1 : 0.985)
                                        .opacity(focusedFeedItemID == nil || focusedFeedItemID == item.id ? 1 : 0.92)
                                        .onTapGesture {
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                                focusedFeedItemID = focusedFeedItemID == item.id ? nil : item.id
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
                }
                .refreshable {
                    await load()
                }
            }
        }
        .task {
            await load()
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView {
                ShopHaptics.impact()
                showPaywall = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shop")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Discover products from live storefronts.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))
                }

                Spacer()

                if let onManage {
                    Button(action: onManage) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(ShopPressStyle())
                }
            }
        }
    }

    private var launchBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Launch Sprint")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))

            Text("Invite 2 friends. Join 1 live. Unlock faster growth.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text(LaunchGrowthManager.shared.referralRewardText())
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 12) {
                ShareLink(item: LaunchGrowthManager.shared.inviteLink(for: "creator-launch")) {
                    Label("Invite Creators", systemImage: "person.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.04, green: 0.52, blue: 1.0))
                        .clipShape(Capsule())
                }
                .buttonStyle(ShopPressStyle())

                Button {
                    ShopHaptics.impact()
                    AIInfluencerManager.shared.schedulePost()
                } label: {
                    Label("Post Daily Clip", systemImage: "sparkles.tv")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.09))
                        .clipShape(Capsule())
                }
                .buttonStyle(ShopPressStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.blue.opacity(0.12),
                    Color.mint.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.45))

            TextField("Search products...", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var featuredCarousel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Featured Deals")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(featuredProducts) { product in
                        FeaturedProductTile(product: product)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var featuredStoresRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Featured Stores")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(featuredStores) { store in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.name)
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(store.tagline ?? store.slug)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(2)
                        }
                        .frame(width: 180, alignment: .leading)
                        .padding(16)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var creatorRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Creators")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(avatarFeed) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            AIAvatarView(avatarName: item.avatar.name)
                            Text(item.hook)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text(item.caption)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                        }
                        .frame(width: 220, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var trendingLivesRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trending Lives")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(trendingLives) { live in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("LIVE")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color(red: 1.0, green: 0.27, blue: 0.23))
                                    .clipShape(Capsule())

                                Spacer()

                                Text(LaunchGrowthManager.shared.fomoMessage(for: live.viewerCount))
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.74))
                            }

                            Text(live.title)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            Text("with \(live.avatar.name)")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))

                            if let product = live.product {
                                Text(product.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
                            }
                        }
                        .frame(width: 248, alignment: .leading)
                        .padding(16)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .onTapGesture {
                            ShopHaptics.impact()
                            registerMeaningfulInteraction(triggerPaywall: true)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var filteredProducts: [ShopProduct] {
        let base = featuredProducts + products.filter { product in
            !featuredProducts.contains(where: { $0.id == product.id })
        }
        let ranked = base + trendingProducts.filter { trend in
            !base.contains(where: { $0.id == trend.id })
        }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ranked
        }
        let query = searchText.lowercased()
        return ranked.filter {
            $0.name.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    private var feedItems: [FeedItem] {
        var items: [FeedItem] = []
        let ads = sponsoredEntries
        for (index, product) in filteredProducts.enumerated() {
            items.append(.product(product))
            if index % 5 == 4, let ad = ads[safe: index / 5] {
                items.append(.sponsored(ad))
            }
        }
        return items
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(Color(red: 1.0, green: 0.27, blue: 0.23))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @MainActor
    func load() async {
        do {
            async let productsTask = service.fetchProducts()
            async let featuredTask = service.fetchFeatured()
            async let trendingTask = service.fetchTrendingProducts()
            async let sponsoredTask = service.fetchSponsoredFeed()
            async let avatarTask = service.fetchAvatarFeed()
            async let livesTask = service.fetchTrendingLives()

            let (loadedProducts, featured, trending, sponsored, avatars, lives) = try await (productsTask, featuredTask, trendingTask, sponsoredTask, avatarTask, livesTask)
            withAnimation(.easeInOut(duration: 0.25)) {
                products = loadedProducts
                featuredProducts = featured.products
                featuredStores = featured.stores
                trendingProducts = trending
                sponsoredEntries = sponsored
                avatarFeed = avatars
                trendingLives = lives
                errorMessage = nil
                isLoading = false
            }
            await MainActor.run {
                LaunchTelemetry.shared.track("store_viewed", parameters: [
                    "products_count": String(loadedProducts.count),
                    "featured_count": String(featured.products.count),
                    "live_count": String(lives.count)
                ])
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCannotFindHost {
                errorMessage = "The storefront server could not be found. Verify that api.oneway.app is live and reachable over HTTPS."
            } else {
                errorMessage = "Could not load storefront products."
            }
            isLoading = false
            await MainActor.run {
                LaunchTelemetry.shared.capture(error: error, context: "storefront_load")
                LaunchTelemetry.shared.track("storefront_load_failed")
            }
        }
    }

    @MainActor
    private func registerMeaningfulInteraction(triggerPaywall: Bool) {
        LaunchTelemetry.shared.track("product_clicked")

        if !hasCompletedFirstValueAction {
            hasCompletedFirstValueAction = true
            RetentionNudgeManager.shared.scheduleFirstDayNudgesIfNeeded()
        }

        guard triggerPaywall, !hasSeenPremiumPaywall else { return }
        hasSeenPremiumPaywall = true
        showPaywall = true
        LaunchTelemetry.shared.track("paywall_shown")
    }
}

private struct ProductCard: View {
    let product: ShopProduct
    let onEngagement: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    LinearGradient(
                        colors: [
                            Color.gray.opacity(0.3),
                            Color.blue.opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "bag.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            .frame(height: 320)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.18), .black.opacity(0.86)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                if product.featured {
                    Text("FEATURED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.04, green: 0.52, blue: 1.0))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)

                Text(product.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text(product.description)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(2)

                HStack {
                    Text("$\(product.price, specifier: "%.2f")")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))

                    Spacer()

                    Button("Buy Now") {
                        Task { await checkout() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.04, green: 0.52, blue: 1.0))
                    .clipShape(Capsule())
                    .buttonStyle(ShopPressStyle())
                }
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 12)
    }

    private var imageURL: URL? {
        guard let imageUrl = product.imageUrl else { return nil }
        return URL(string: imageUrl)
    }

    @MainActor
    private func checkout() async {
        ShopHaptics.impact()
        onEngagement()
        LaunchTelemetry.shared.track("checkout_tapped", parameters: [
            "product_id": product.id,
            "product_name": product.name
        ])
        if ApplePayManager.sharedStartApplePayAvailable {
            ApplePayManager.shared.startApplePay(for: product)
            return
        }

        if let payload = try? await StorefrontService.shared.createCheckout(for: product),
           let checkoutURLString = payload.checkoutUrl,
           let checkoutURL = URL(string: checkoutURLString) {
            ApplePayManager.shared.openExternalCheckout(url: checkoutURL)
        }
    }
}

private struct FeaturedProductTile: View {
    let product: ShopProduct

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: product.imageUrl.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    LinearGradient(
                        colors: [Color.blue.opacity(0.35), Color.black.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(width: 188, height: 144)
            .clipped()

            Text(product.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)

            Text("$\(product.price, specifier: "%.2f")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
        }
        .frame(width: 188, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct SponsoredProductCard: View {
    let entry: SponsoredFeedEntry
    let onEngagement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sponsored")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)

            ProductCard(product: entry.product, onEngagement: onEngagement)
        }
    }
}

struct AIAvatarView: View {
    let avatarName: String

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.blue, .mint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "sparkles")
                        .foregroundStyle(.white)
                )

            Text(avatarName)
                .font(.headline)
                .foregroundStyle(.white)
        }
    }
}

private struct ShopPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private enum ShopHaptics {
    static func impact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

private enum FeedItem: Identifiable {
    case product(ShopProduct)
    case sponsored(SponsoredFeedEntry)

    var id: String {
        switch self {
        case .product(let product):
            return "product-\(product.id)"
        case .sponsored(let entry):
            return "sponsored-\(entry.id)"
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension ApplePayManager {
    static var sharedStartApplePayAvailable: Bool {
        #if canImport(PassKit)
        return true
        #else
        return false
        #endif
    }
}
