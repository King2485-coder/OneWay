import SwiftUI
import UIKit

struct ShopProfileView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let shop: MarketplaceShop
    var onOpenFeature: ((OneWayFeature) -> Void)?
    var onOpenHub: (() -> Void)?
    let onBack: () -> Void
    let onRoute: (MarketplaceRoute) -> Void

    @State private var tab: ShopProfileTab = .shop
    @State private var isStartingConversation = false
    @State private var messageError: String?

    private var products: [MarketplaceProduct] { viewModel.products(for: shop.id) }
    private var isFollowing: Bool { viewModel.followedShops.contains(shop.id) }

    var body: some View {
        ZStack {
            ShopProfilePalette.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    topBar
                    hero
                    identity
                    stats
                    tabs
                    selectedTabContent
                    trustSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 112)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Unable to Message Seller", isPresented: Binding(
            get: { messageError != nil },
            set: { if !$0 { messageError = nil } }
        )) {
            Button("OK", role: .cancel) { messageError = nil }
        } message: {
            Text(messageError ?? "Please try again.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShopProfileDock(
                activeFeature: .shops,
                onFeature: openFeature,
                onHub: { onOpenHub?() }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            ShopProfileIconButton(systemName: "chevron.left") {
                onBack()
            }

            HStack(spacing: 8) {
                Text(shop.name)
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                if shop.verified {
                    OneWayResolvedIcon(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(ShopProfilePalette.purple)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShareLink(item: "https://oneway.is/@\(shop.slug)") {
                OneWayResolvedIcon(systemName: "square.and.arrow.up")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ShopProfilePalette.purple)
                    .frame(width: 52, height: 52)
                    .shopProfileGlass(cornerRadius: 14)
            }

            Button { viewModel.toggleFollow(shop) } label: {
                OneWayResolvedIcon(systemName: isFollowing ? "heart.fill" : "heart")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(ShopProfilePalette.purple)
                    .frame(width: 52, height: 52)
                    .shopProfileGlass(cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            heroImage
                .frame(height: 174)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.08), .black.opacity(0.18), ShopProfilePalette.deep.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(ShopProfilePalette.purple.opacity(0.56), lineWidth: 1)
                )

            ShopProfileAvatar(assetName: shopLogoAssetName, customImage: customBadgeImage, size: 94)
                .offset(x: 14, y: 46)
        }
        .padding(.top, 2)
        .padding(.bottom, 48)
    }

    @ViewBuilder
    private var heroImage: some View {
        if let customBannerImage {
            Image(uiImage: customBannerImage)
                .resizable()
                .scaledToFill()
        } else {
            Image(shopHeroAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFill()
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shop.name)
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                if shop.verified {
                    OneWayResolvedIcon(systemName: "checkmark.seal.fill")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(ShopProfilePalette.purple)
                }
            }

            Text(shop.description)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(ShopProfilePalette.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                viewModel.toggleFollow(shop)
            } label: {
                HStack(spacing: 10) {
                    OneWayResolvedIcon(systemName: isFollowing ? "checkmark" : "person.fill")
                    Text(isFollowing ? "Following" : "Follow")
                }
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(height: 54)
                .background(ShopProfilePalette.buttonGradient, in: Capsule())
                .shadow(color: ShopProfilePalette.purple.opacity(0.35), radius: 18, x: 0, y: 9)
            }
            .buttonStyle(.plain)

            Button {
                onRoute(.buyerShopPolicies(shop.id))
            } label: {
                HStack(spacing: 10) {
                    OneWayResolvedIcon(systemName: "doc.text.fill")
                    Text("Shop Policies")
                }
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(ShopProfilePalette.purple)
                .padding(.horizontal, 22)
                .frame(height: 50)
                .overlay(Capsule().stroke(ShopProfilePalette.purple, lineWidth: 2))
            }
            .buttonStyle(.plain)

            if isCurrentSeller {
                Button {
                    onRoute(.sellerMessages)
                } label: {
                    HStack(spacing: 10) {
                        OneWayResolvedIcon(systemName: "bubble.left.and.bubble.right.fill")
                        Text("Shop Messages")
                    }
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 54)
                    .background(ShopProfilePalette.buttonGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shop Messages")
            } else {
                Button {
                    guard !isStartingConversation else { return }
                    isStartingConversation = true
                    Task {
                        if let threadID = await viewModel.startShopConversation(shop: shop) {
                            onRoute(.chat(threadID))
                        } else {
                            messageError = viewModel.sellerValidationMessage ?? "The seller conversation could not be opened."
                        }
                        isStartingConversation = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isStartingConversation {
                            ProgressView().tint(.white)
                        } else {
                            OneWayResolvedIcon(systemName: "bubble.left.and.bubble.right.fill")
                        }
                        Text(isStartingConversation ? "Opening…" : "Message Seller")
                    }
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 54)
                    .background(ShopProfilePalette.buttonGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isStartingConversation)
            }
        }
    }

    private var isCurrentSeller: Bool {
        guard let ownerUserID = shop.ownerUserID else { return false }
        return ownerUserID.caseInsensitiveCompare(AppEnvironment.currentUserID()) == .orderedSame
    }

    private var stats: some View {
        HStack(spacing: 0) {
            ShopProfileStat(icon: "star.fill", value: String(format: "%.1f", shop.rating), label: "Rating\n(\(shop.reviewCount) reviews)")
            ShopProfileDivider()
            ShopProfileStat(icon: "bag.fill", value: "\(shop.sales)", label: "Sales")
            ShopProfileDivider()
            ShopProfileStat(icon: "calendar", value: "\(shop.sinceYear)", label: "Since")
            ShopProfileDivider()
            ShopProfileStat(icon: "lock.shield.fill", value: "\(shop.privacyScore)%", label: "Privacy")
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .shopProfileGlass(cornerRadius: 22)
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(ShopProfileTab.allCases) { item in
                Button { tab = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(tab == item ? .white : ShopProfilePalette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background {
                            if tab == item {
                                Capsule().fill(ShopProfilePalette.buttonGradient)
                            } else {
                                Capsule().fill(ShopProfilePalette.glass)
                            }
                        }
                        .overlay(
                            Capsule()
                                .stroke(ShopProfilePalette.purple.opacity(tab == item ? 0 : 0.34), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch tab {
        case .shop:
            shopTab
        case .about:
            infoCard(
                title: "About \(shop.name)",
                body: "\(shop.name) is a verified OneWay creator shop focused on private checkout, quick creator support, and secure customer conversations."
            )
        case .reviews:
            infoCard(
                title: "Reviews",
                body: shop.reviewCount == 0
                    ? "No reviews yet. Follow the shop or make a secure purchase to be one of the first."
                    : "Customers rate this shop \(String(format: "%.1f", shop.rating)) stars for fast replies, careful packaging, and private checkout."
            )
        case .policies:
            infoCard(
                title: "Policies",
                body: "Secure payment processing, messaging, clear seller policies, and OneWay support are built into every shop."
            )
        }
    }

    private var shopTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            collectionCard
            if !products.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Products")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(products.count)")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(ShopProfilePalette.purple)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(products.prefix(4)) { product in
                            Button { onRoute(.product(product.id)) } label: {
                                ShopProfileProductTile(product: product)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var collectionCard: some View {
        HStack(spacing: 16) {
            Image(collectionAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 146, height: 138)
                .frame(maxWidth: .infinity)
                .background(ShopProfilePalette.glow.opacity(0.2), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text(shop.name)
                    .font(.system(size: 23, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                Text(collectionDescription)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(ShopProfilePalette.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                OneWayResolvedLabel("\(max(products.count, 1)) Products", systemImage: "shippingbox.fill")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(ShopProfilePalette.purple)

                Button {
                    if let product = products.first {
                        onRoute(.product(product.id))
                    }
                } label: {
                    HStack(spacing: 10) {
                        OneWayResolvedIcon(systemName: "bag.fill")
                        Text("Shop Collection")
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(ShopProfilePalette.buttonGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .shopProfileGlass(cornerRadius: 22)
    }

    private var trustSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why shop here")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ShopProfileTrustChip(icon: "checkmark.shield.fill", title: "Secure\nShopping")
                ShopProfileTrustChip(icon: "lock.fill", title: "Private by\nDefault")
                ShopProfileTrustChip(icon: "truck.box.fill", title: "Fast\nDelivery")
                ShopProfileTrustChip(icon: "headphones", title: "Support\n24/7")
            }
        }
    }

    private func infoCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Text(body)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(ShopProfilePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shopProfileGlass(cornerRadius: 22)
    }

    private func openFeature(_ feature: OneWayFeature) {
        onBack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            onOpenFeature?(feature)
        }
    }

    private var shopHeroAssetName: String {
        let name = shop.name.lowercased()
        if name.contains("holiday") || name.contains("card") { return "OneWayShopHolidayCardsBanner" }
        return "OneWayShopsHeroShowcase"
    }

    private var shopLogoAssetName: String {
        let name = shop.name.lowercased()
        if name.contains("holiday") || name.contains("card") { return "OneWayShopHolidayCardsBadge" }
        return "OneWaySculptedShops"
    }

    private var customBannerImage: UIImage? {
        ShopArtworkLocalStore.image(fromSeed: shop.bannerSeed)
    }

    private var customBadgeImage: UIImage? {
        ShopArtworkLocalStore.image(fromSeed: shop.logoSeed)
    }

    private var collectionAssetName: String {
        let name = shop.name.lowercased()
        if name.contains("holiday") || name.contains("card") { return "OneWayShopHolidayCardsCollection" }
        if name.contains("moon") { return "OneWayShopsProductMoonLamp" }
        if name.contains("jewel") || name.contains("gem") { return "OneWaySculptedJewelry" }
        return products.first.flatMap { productAssetName(for: $0) } ?? "OneWayShopsHeroShowcase"
    }

    private var collectionDescription: String {
        let name = shop.name.lowercased()
        if name.contains("holiday") || name.contains("card") {
            return "Beautiful, customizable holiday cards for every occasion."
        }
        return "Curated products from this secure OneWay creator shop."
    }

    private func productAssetName(for product: MarketplaceProduct) -> String? {
        let seed = product.imageSeed.lowercased()
        if seed.contains("moon lamp") { return "OneWayShopsProductMoonLamp" }
        if seed.contains("amethyst") { return "OneWayShopsProductAmethyst" }
        if seed.contains("mug") { return "OneWayShopsProductMug" }
        if seed.contains("bowl") { return "OneWayShopsProductBowl" }
        if seed.contains("vase") { return "OneWayShopsProductVase" }
        if seed.contains("diffuser") { return "OneWayShopsProductDiffuser" }
        return nil
    }
}

private enum ShopProfileTab: String, CaseIterable, Identifiable {
    case shop = "Shop"
    case about = "About"
    case reviews = "Reviews"
    case policies = "Policies"

    var id: String { rawValue }
}

private enum ShopProfilePalette {
    static let deep = Color(hex: 0x020415)
    static let panel = Color(hex: 0x0B1025)
    static let glass = Color(hex: 0x14142E).opacity(0.74)
    static let stroke = Color(hex: 0x8B4CFF).opacity(0.34)
    static let purple = Color(hex: 0xA85BFF)
    static let brightPurple = Color(hex: 0xD06BFF)
    static let secondary = Color(hex: 0xD7C9FF)
    static let muted = Color(hex: 0xA79BBB)
    static let green = Color(hex: 0x22E87C)
    static let glow = Color(hex: 0x8438FF)
    static let background = LinearGradient(
        colors: [Color(hex: 0x020415), Color(hex: 0x07051A), Color(hex: 0x15082D), Color(hex: 0x030413)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let buttonGradient = LinearGradient(
        colors: [Color(hex: 0x7C35FF), Color(hex: 0xC866FF)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

private extension View {
    func shopProfileGlass(cornerRadius: CGFloat) -> some View {
        self
            .background(
                LinearGradient(
                    colors: [ShopProfilePalette.panel.opacity(0.94), ShopProfilePalette.glass],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ShopProfilePalette.stroke, lineWidth: 1)
            )
            .shadow(color: ShopProfilePalette.glow.opacity(0.14), radius: 22, x: 0, y: 12)
    }
}

private struct ShopProfileIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: systemName)
                .font(.system(size: 26, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .shopProfileGlass(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .zIndex(100)
        .accessibilityLabel(systemName == "chevron.left" ? "Back" : systemName)
    }
}

private struct ShopProfileAvatar: View {
    let assetName: String
    let customImage: UIImage?
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.black.opacity(0.72))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(ShopProfilePalette.purple, lineWidth: 3))
                .shadow(color: ShopProfilePalette.glow.opacity(0.5), radius: 18, x: 0, y: 8)

            if let customImage {
                Image(uiImage: customImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(size * 0.16)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }

            Circle()
                .fill(ShopProfilePalette.green)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(ShopProfilePalette.deep, lineWidth: 3))
                .padding(5)
        }
    }
}

private struct ShopProfileStat: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(ShopProfilePalette.purple)
                .frame(height: 24)
            Text(value)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(ShopProfilePalette.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.68)
                .frame(minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ShopProfileDivider: View {
    var body: some View {
        Rectangle()
            .fill(ShopProfilePalette.stroke)
            .frame(width: 1, height: 76)
    }
}

private struct ShopProfileProductTile: View {
    let product: MarketplaceProduct

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MarketplaceProductImageView(product: product, height: 118, cornerRadius: 18)
            Text(product.title)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.74)
            Text(product.price, format: .currency(code: "USD"))
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(ShopProfilePalette.purple)
        }
        .padding(10)
        .shopProfileGlass(cornerRadius: 20)
    }
}

private struct ShopProfileTrustChip: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(ShopProfilePalette.purple)
                .frame(width: 34)
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .shopProfileGlass(cornerRadius: 16)
    }
}

private struct ShopProfileDock: View {
    let activeFeature: OneWayFeature
    let onFeature: (OneWayFeature) -> Void
    let onHub: () -> Void

    private let features: [OneWayFeature] = [.shopHome, .communities, .shopMessages, .shops, .shopAccount]

    var body: some View {
        HStack(spacing: 0) {
            dockItem(.shopHome)
            dockItem(.communities)
            OneWayHubButton(action: onHub)
                .frame(maxWidth: .infinity)
            dockItem(.shops)
            dockItem(.shopAccount)
        }
        .frame(height: 82)
        .padding(.horizontal, 8)
        .shopProfileGlass(cornerRadius: 28)
    }

    private func dockItem(_ feature: OneWayFeature) -> some View {
        Button { onFeature(feature) } label: {
            VStack(spacing: 5) {
                OneWayPhysicalIcon(
                    role: feature.physicalIconRole,
                    size: feature == activeFeature || feature == .shops ? 34 : 30,
                    state: feature == activeFeature || feature == .shops ? .selected : .normal,
                    container: .none,
                    accessibilityLabel: feature.displayName,
                    glowIntensity: feature == activeFeature || feature == .shops ? 0.22 : 0.08
                )
                Text(dockTitle(for: feature))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(feature == activeFeature || feature == .shops ? ShopProfilePalette.purple : ShopProfilePalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
        }
        .buttonStyle(.plain)
    }

    private func dockTitle(for feature: OneWayFeature) -> String {
        switch feature {
        case .shopHome: return "Home"
        case .shopAccount: return "Profile"
        default: return feature.displayName
        }
    }
}
