import SwiftUI
import UIKit

struct MarketplaceLogo: View {
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle().fill(MarketplaceTheme.gradient)
            OneWayResolvedIcon(systemName: "paperplane.fill")
                .font(.system(size: size * 0.42, weight: .black))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-8))
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
    }
}

struct MarketplaceProductArt: View {
    let seed: String
    var height: CGFloat = 140

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    MarketplaceTheme.deepPurple,
                    MarketplaceTheme.purple.opacity(0.62),
                    Color.white.opacity(0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            decorativeSymbol
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var decorativeSymbol: some View {
        OneWayResolvedIcon(systemName: iconName)
            .font(.system(size: height * 0.34, weight: .black))
            .foregroundStyle(.white.opacity(0.84))
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 6)
    }

    private var iconName: String {
        let lower = seed.lowercased()
        if lower.contains("lamp") { return "moon.stars.fill" }
        if lower.contains("amethyst") { return "diamond.fill" }
        if lower.contains("wallet") { return "wallet.pass.fill" }
        if lower.contains("mug") { return "cup.and.saucer.fill" }
        if lower.contains("bowl") { return "circle.grid.cross.fill" }
        if lower.contains("vase") { return "flame.fill" }
        if lower.contains("diffuser") { return "wind" }
        if lower.contains("candle") { return "lightbulb.fill" }
        if lower.contains("planter") { return "leaf.fill" }
        if lower.contains("throw") { return "squareshape.split.3x3" }
        return "bag.fill"
    }
}

struct MarketplaceProductImageView: View {
    let product: MarketplaceProduct
    var height: CGFloat = 140
    var cornerRadius: CGFloat = 20

    var body: some View {
        if let remoteURL {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    MarketplaceProductArt(seed: product.imageSeed, height: height)
                default:
                    ProgressView().tint(.white)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(MarketplaceTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.white.opacity(0.18), lineWidth: 1))
        } else if let image = product.primaryImage,
           let uiImage = ProductPhotoLocalStore.image(named: image.mediumFileName) ?? ProductPhotoLocalStore.image(named: image.originalFileName) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text("Primary")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(8)
                }
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.white.opacity(0.18), lineWidth: 1))
                .clipped()
        } else if let referenceAssetName {
            Image(referenceAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(
                    LinearGradient(
                        colors: [
                            OneWayDesignSystem.Colors.backgroundSecondary,
                            OneWayDesignSystem.Colors.deepPurple.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(MarketplaceTheme.purple.opacity(0.22), lineWidth: 1)
                )
        } else {
            MarketplaceProductArt(seed: product.imageSeed, height: height)
                .onAppear {
                    #if DEBUG
                    print("ONEWAY_SHOPS_PRODUCT_IMAGE_MISSING product=\(product.id) seed=\(product.imageSeed)")
                    #endif
                }
        }
    }

    private var remoteURL: URL? {
        guard let image = product.primaryImage,
              image.mimeType == "image/remote",
              let url = URL(string: image.storageKey),
              url.scheme == "https" else { return nil }
        return url
    }

    private var referenceAssetName: String? {
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

struct MarketplaceHeader: View {
    let onQuantumHome: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            OneWayPhysicalIcon(
                role: .shops,
                size: 56,
                state: .selected,
                container: .feature,
                accessibilityLabel: "OneWay Shops",
                glowIntensity: 0.22
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("OneWay Shops")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .foregroundStyle(MarketplaceTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("Built on OneWay")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(MarketplaceTheme.muted)
            }
            Spacer()
            Button(action: onQuantumHome) {
                OneWayPhysicalIcon(
                    role: .quantum,
                    size: 48,
                    container: .toolbar,
                    accessibilityLabel: "Return to Quantum home",
                    glowIntensity: 0.16
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return to Quantum home")
        }
    }
}

struct MarketplaceSearchBar: View {
    @Binding var text: String
    let onSearch: () -> Void
    let onFilter: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(MarketplaceTheme.purple)
                .frame(width: 32, height: 32)
            TextField("Search for anything...", text: $text)
                .font(.system(size: 18, weight: .semibold))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                .onSubmit(onSearch)
                .foregroundStyle(MarketplaceTheme.text)
            Button(action: onFilter) {
                OneWayPhysicalIcon(
                    role: .camera,
                    size: 46,
                    container: .toolbar,
                    accessibilityLabel: "Visual search and filters",
                    glowIntensity: 0.15
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            OneWayDesignSystem.Colors.panelGlass,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(MarketplaceTheme.purple.opacity(0.62), lineWidth: 1)
        )
        .shadow(color: MarketplaceTheme.purple.opacity(0.10), radius: 14, y: 6)
    }
}

struct MarketplaceProductCard: View {
    let product: MarketplaceProduct
    let shop: MarketplaceShop?
    let isFavorite: Bool
    let onFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                MarketplaceProductImageView(product: product, height: 190, cornerRadius: 21)
                Button(action: onFavorite) {
                    OneWayResolvedIcon(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isFavorite ? MarketplaceTheme.purple : .white)
                        .frame(width: 42, height: 42)
                        .background(OneWayDesignSystem.Colors.panelGlass, in: Circle())
                        .overlay(Circle().stroke(MarketplaceTheme.purple.opacity(0.44)))
                    }
                .buttonStyle(.plain)
                .padding(8)
            }

            Text(product.title)
                .font(.headline.weight(.black))
                .foregroundStyle(MarketplaceTheme.text)
                .lineLimit(1)
            Text(shop?.name ?? "OneWay Creator")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MarketplaceTheme.muted)
                .lineLimit(1)
            HStack(spacing: 4) {
                OneWayResolvedIcon(systemName: "star.fill").foregroundStyle(MarketplaceTheme.purple)
                Text(String(format: "%.1f", product.rating))
                Text("(\(product.reviewCount))")
                    .foregroundStyle(MarketplaceTheme.faint)
                Spacer()
                Text(product.price.currency)
                    .fontWeight(.black)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(MarketplaceTheme.text)
        }
        .padding(11)
        .frame(width: 194)
        .background(
            OneWayDesignSystem.Colors.panelGlass,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(MarketplaceTheme.purple.opacity(0.52), lineWidth: 1)
        )
        .shadow(color: MarketplaceTheme.purple.opacity(0.10), radius: 14, y: 7)
    }
}

struct MarketplaceProductRow: View {
    let product: MarketplaceProduct
    let shop: MarketplaceShop?
    let isFavorite: Bool
    let onFavorite: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            MarketplaceProductImageView(product: product, height: 94)
                .frame(width: 104)

            VStack(alignment: .leading, spacing: 6) {
                Text(product.title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(MarketplaceTheme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(shop?.name ?? "OneWay Creator")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
                HStack(spacing: 4) {
                    OneWayResolvedIcon(systemName: "star.fill")
                    Text(String(format: "%.1f", product.rating))
                    Text(product.price.currency)
                        .font(.subheadline.weight(.black))
                        .padding(.leading, 6)
                    Spacer()
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(MarketplaceTheme.purple)
            }

            VStack(spacing: 10) {
                Button(action: onFavorite) {
                    OneWayPhysicalIcon(
                        role: .favorites,
                        size: 44,
                        state: isFavorite ? .selected : .normal,
                        container: .toolbar,
                        accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                        glowIntensity: isFavorite ? 0.20 : 0.04
                    )
                }
                Button(action: onAdd) {
                    OneWayPhysicalIcon(
                        role: .quickAdd,
                        size: 44,
                        state: .selected,
                        container: .toolbar,
                        accessibilityLabel: "Add \(product.title) to cart",
                        glowIntensity: 0.20
                    )
                }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .marketplaceCard(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(product.title), \(shop?.name ?? "OneWay Creator"), rated \(String(format: "%.1f", product.rating)), \(product.price.currency)"
        )
    }
}

struct MarketplaceBadge: View {
    let title: String
    let icon: String

    var body: some View {
        OneWayResolvedLabel(title, systemImage: icon)
            .font(.caption.weight(.black))
            .foregroundStyle(MarketplaceTheme.purple)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(MarketplaceTheme.lavenderCard, in: Capsule())
            .overlay(Capsule().stroke(MarketplaceTheme.border, lineWidth: 1))
    }
}

struct MarketplaceBackBar<Trailing: View>: View {
    let title: String
    let backTitle: String
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        backTitle: String = "Back",
        onBack: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.backTitle = backTitle
        self.onBack = onBack
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            MarketplaceBackButton(accessibilityLabel: backTitle, action: onBack)

            Text(title)
                .font(.title3.weight(.black))
                .foregroundStyle(MarketplaceTheme.text)
                .lineLimit(1)

            Spacer(minLength: 8)

            trailing()
                .font(.headline.weight(.black))
                .foregroundStyle(MarketplaceTheme.purple)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OneWayDesignSystem.Colors.surface)
        .overlay(Rectangle().fill(MarketplaceTheme.border).frame(height: 1), alignment: .bottom)
        .zIndex(50)
    }
}

struct MarketplaceBackButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    init(accessibilityLabel: String = "Back", action: @escaping () -> Void) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: "chevron.left")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(MarketplaceTheme.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(MarketplaceTheme.purple.opacity(0.52), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .zIndex(100)
        .accessibilityLabel(accessibilityLabel)
    }
}

extension Double {
    var currency: String {
        formatted(.currency(code: "USD"))
    }
}
