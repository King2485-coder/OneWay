import SwiftUI

struct ProductDetailView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let product: MarketplaceProduct
    let onBack: () -> Void
    var onOpenThread: ((UUID) -> Void)?
    @State private var selectedColor = ""
    @State private var quantity = 1
    @State private var fullScreenImage: MarketplaceProductImage?
    @State private var showPolicies = false

    var shop: MarketplaceShop? { viewModel.shop(product.shopID) }

    var body: some View {
        ZStack(alignment: .bottom) {
            MarketplaceTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    productGallery
                    .frame(height: 330)
                    .tabViewStyle(.page)
                    titleBlock
                    descriptionBlock
                    colorSelector
                    quantitySelector
                }
                .padding(18)
                .padding(.bottom, 104)
            }
            purchaseBar
        }
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) {
            MarketplaceBackBar(title: "Product", onBack: onBack) {
                HStack(spacing: 14) {
                    ShareLink(item: "\(product.title) on OneWay Shops") {
                        OneWayResolvedIcon(systemName: "square.and.arrow.up")
                    }
                    Button { viewModel.toggleFavorite(product) } label: {
                        OneWayResolvedIcon(systemName: viewModel.favorites.contains(product.id) ? "heart.fill" : "heart")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { if selectedColor.isEmpty { selectedColor = product.colors.first ?? "Purple" } }
        .fullScreenCover(item: $fullScreenImage) { image in
            ProductPhotoFullScreenViewer(image: image)
        }
        .sheet(isPresented: $showPolicies) {
            NavigationStack {
                BuyerShopPoliciesView(
                    viewModel: viewModel,
                    shopID: product.shopID,
                    onBack: { showPolicies = false },
                    onMessage: { threadID in
                        showPolicies = false
                        onOpenThread?(threadID)
                    }
                )
            }
        }
    }

    private var productGallery: some View {
        TabView {
            if product.images.isEmpty {
                MarketplaceProductArt(seed: product.imageSeed, height: 320)
                MarketplaceProductArt(seed: product.imageSeed + " detail", height: 320)
            } else {
                ForEach(product.images.sorted { $0.sortOrder < $1.sortOrder }) { image in
                    Button {
                        fullScreenImage = image
                    } label: {
                        // Use the shared image renderer here as well as in catalog
                        // cards. Buyer products carry HTTPS-backed image records,
                        // while seller drafts may still use local files.
                        MarketplaceProductImageView(
                            product: productWithPrimaryImage(image),
                            height: 320,
                            cornerRadius: 26
                        )
                        .accessibilityLabel(image.altText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func productWithPrimaryImage(_ selectedImage: MarketplaceProductImage) -> MarketplaceProduct {
        var selectedProduct = product
        selectedProduct.images = product.images.map { image in
            var updated = image
            updated.isPrimary = image.id == selectedImage.id
            return updated
        }
        return selectedProduct
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(product.title)
                .font(.largeTitle.weight(.black))
                .foregroundStyle(MarketplaceTheme.text)
            HStack {
                Text(shop?.name ?? "OneWay Creator")
                if shop?.verified == true { OneWayResolvedIcon(systemName: "checkmark.seal.fill").foregroundStyle(MarketplaceTheme.purple) }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(MarketplaceTheme.muted)
            HStack {
                Text(product.price.currency).font(.title2.weight(.black))
                Spacer()
                OneWayResolvedLabel("\(String(format: "%.1f", product.rating)) (\(product.reviewCount))", systemImage: "star.fill")
            }
            .foregroundStyle(MarketplaceTheme.text)
        }
    }

    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Description").font(.headline.weight(.black)).foregroundStyle(MarketplaceTheme.text)
            Text(product.description).foregroundStyle(MarketplaceTheme.muted)
            ForEach(product.specs, id: \.self) { spec in
                OneWayResolvedLabel(spec, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.text)
            }
            Button("Read Shop Policies") { showPolicies = true }
                .font(.subheadline.weight(.black))
                .foregroundStyle(MarketplaceTheme.purple)
        }
        .padding(16)
        .marketplaceCard()
    }

    private var colorSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color").font(.headline.weight(.black)).foregroundStyle(MarketplaceTheme.text)
            HStack {
                ForEach(product.colors, id: \.self) { color in
                    Button { selectedColor = color } label: {
                        Text(color)
                            .font(.caption.weight(.black))
                            .foregroundStyle(selectedColor == color ? .white : MarketplaceTheme.purple)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(selectedColor == color ? MarketplaceTheme.purple : MarketplaceTheme.lavenderCard, in: Capsule())
                            .overlay(Capsule().stroke(MarketplaceTheme.border, lineWidth: 1))
                    }
                }
            }
        }
    }

    private var quantitySelector: some View {
        HStack {
            Text("Quantity").font(.headline.weight(.black)).foregroundStyle(MarketplaceTheme.text)
            Spacer()
            Button { quantity = max(1, quantity - 1) } label: { OneWayResolvedIcon(systemName: "minus") }
            Text("\(quantity)").font(.headline.weight(.black)).frame(width: 34)
            Button { quantity += 1 } label: { OneWayResolvedIcon(systemName: "plus") }
        }
        .foregroundStyle(MarketplaceTheme.text)
        .padding(16)
        .marketplaceCard()
    }

    private var purchaseBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Total").font(.caption.weight(.bold)).foregroundStyle(MarketplaceTheme.muted)
                Text((product.price * Double(quantity)).currency).font(.headline.weight(.black)).foregroundStyle(MarketplaceTheme.text)
            }
            Spacer()
            Button {
                viewModel.addToCart(product, quantity: quantity)
            } label: {
                Text("Add to Cart")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 14)
                    .background(MarketplaceTheme.gradient, in: Capsule())
            }
            Button {
                Task {
                    if let threadID = await viewModel.startProductConversation(product: product) {
                        onOpenThread?(threadID)
                    }
                }
            } label: {
                OneWayResolvedIcon(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.headline.weight(.black))
                    .foregroundStyle(MarketplaceTheme.purple)
                    .frame(width: 46, height: 46)
                    .background(MarketplaceTheme.lavenderCard, in: Circle())
                    .overlay(Circle().stroke(MarketplaceTheme.border, lineWidth: 1))
            }
        }
        .padding(16)
        .background(OneWayDesignSystem.Colors.surface)
        .overlay(Rectangle().fill(MarketplaceTheme.border).frame(height: 1), alignment: .top)
        .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: -6)
    }
}
