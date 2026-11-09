import SwiftUI

struct CategoryProductsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let categoryName: String
    let onRoute: (MarketplaceRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedChip = "All"
    @State private var showFilter = false

    private var category: MarketplaceCategory? { viewModel.categories.first { $0.name == categoryName } }
    private var products: [MarketplaceProduct] {
        let base = viewModel.products(in: categoryName).filter {
            selectedChip == "All" || $0.subcategory == selectedChip
        }.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
        }
        return viewModel.filteredProducts(base: base)
    }
    private var matchingShops: [MarketplaceShop] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return viewModel.search(search).shops
    }

    var body: some View {
        ZStack {
            MarketplaceTheme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    MarketplaceSearchBar(text: $search, onSearch: {}, onFilter: { showFilter = true })
                    chips
                    if !matchingShops.isEmpty {
                        Text("Shops")
                            .font(.headline.weight(.black))
                            .foregroundStyle(MarketplaceTheme.text)
                        ForEach(matchingShops) { shop in
                            Button { onRoute(.shop(shop.id)) } label: {
                                HStack(spacing: 12) {
                                    OneWayPhysicalIcon(role: .storefront, size: 48, container: .feature, accessibilityLabel: shop.name)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(shop.name)
                                            .font(.headline.weight(.black))
                                            .foregroundStyle(MarketplaceTheme.text)
                                        Text(shop.description)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(MarketplaceTheme.muted)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    OneWayResolvedIcon(systemName: "chevron.right")
                                        .foregroundStyle(MarketplaceTheme.purple)
                                }
                                .padding(14)
                                .marketplaceCard()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if products.isEmpty && matchingShops.isEmpty {
                        VStack(spacing: 12) {
                            OneWayPhysicalIcon(role: categoryRole, size: 78, container: .showcase)
                            Text("No products found")
                                .font(.title3.weight(.black))
                                .foregroundStyle(.white)
                            Text("Try another filter or search.")
                                .foregroundStyle(MarketplaceTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(28)
                        .marketplaceCard(cornerRadius: 24)
                    } else {
                        ForEach(products) { product in
                            MarketplaceProductRow(
                                product: product,
                                shop: viewModel.shop(product.shopID),
                                isFavorite: viewModel.favorites.contains(product.id),
                                onFavorite: { viewModel.toggleFavorite(product) },
                                onAdd: { viewModel.addToCart(product) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onRoute(.product(product.id)) }
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 118)
            }
        }
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) {
            MarketplaceBackBar(title: categoryName, onBack: { dismiss() }) {
                Button { onRoute(.cart) } label: {
                    OneWayPhysicalIcon(
                        role: .shops,
                        size: 42,
                        container: .toolbar,
                        accessibilityLabel: "Cart",
                        badgeCount: viewModel.cartCount > 0 ? viewModel.cartCount : nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showFilter) {
            MarketplaceFilterSheet(filters: $viewModel.filters, categories: viewModel.categories)
                .presentationDetents([.medium, .large])
        }
        .task {
            await viewModel.refreshMarketplaceCatalog()
        }
        .task(id: search) {
            guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await viewModel.refreshMarketplaceSearch(query: search)
        }
        .refreshable {
            await viewModel.refreshMarketplaceCatalog()
            await viewModel.refreshMarketplaceSearch(query: search)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(category?.chips ?? ["All"], id: \.self) { chip in
                    Button {
                        selectedChip = chip
                    } label: {
                        Text(chip)
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(selectedChip == chip ? MarketplaceTheme.purple : MarketplaceTheme.card, in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(
                                        selectedChip == chip ? MarketplaceTheme.purple : MarketplaceTheme.border,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 18)
        }
    }

    private var categoryRole: OneWayIconRole {
        switch categoryName {
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
