import SwiftUI

struct SearchResultsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let query: String
    let onBack: () -> Void
    let onRoute: (MarketplaceRoute) -> Void

    private var results: (products: [MarketplaceProduct], shops: [MarketplaceShop]) {
        viewModel.search(query)
    }

    var body: some View {
        ZStack {
            MarketplaceTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Results for “\(query)”")
                        .font(.headline.weight(.black))
                        .foregroundStyle(MarketplaceTheme.muted)

                    if viewModel.catalogIsLoading && results.products.isEmpty && results.shops.isEmpty {
                        ProgressView("Searching OneWay Shops…")
                            .tint(MarketplaceTheme.purple)
                            .foregroundStyle(MarketplaceTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 70)
                    } else if results.products.isEmpty && results.shops.isEmpty {
                        empty
                    } else {
                        if !results.shops.isEmpty {
                            Text("Shops").font(.headline.weight(.black)).foregroundStyle(MarketplaceTheme.text)
                            ForEach(results.shops) { shop in
                                Button { onRoute(.shop(shop.id)) } label: {
                                    HStack {
                                        MarketplaceLogo(size: 46)
                                        VStack(alignment: .leading) {
                                            Text(shop.name).font(.headline.weight(.black))
                                            Text(shop.description).font(.caption).foregroundStyle(MarketplaceTheme.muted).lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .foregroundStyle(MarketplaceTheme.text)
                                    .padding(14)
                                    .marketplaceCard()
                                }
                            }
                        }
                        if !results.products.isEmpty {
                            Text("Products").font(.headline.weight(.black)).foregroundStyle(MarketplaceTheme.text)
                            ForEach(results.products) { product in
                                Button { onRoute(.product(product.id)) } label: {
                                    MarketplaceProductRow(product: product, shop: viewModel.shop(product.shopID), isFavorite: viewModel.favorites.contains(product.id), onFavorite: { viewModel.toggleFavorite(product) }, onAdd: { viewModel.addToCart(product) })
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 90)
            }
        }
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) {
            MarketplaceBackBar(title: "Search", onBack: onBack)
        }
        .task(id: query) {
            await viewModel.refreshMarketplaceCatalog()
            await viewModel.refreshMarketplaceSearch(query: query)
        }
        .refreshable {
            await viewModel.refreshMarketplaceCatalog()
            await viewModel.refreshMarketplaceSearch(query: query)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            OneWayResolvedIcon(systemName: "magnifyingglass").font(.system(size: 44, weight: .black)).foregroundStyle(MarketplaceTheme.purple)
            Text("No results found").font(.title3.weight(.black)).foregroundStyle(MarketplaceTheme.text)
            Text("Try another product, shop, or category.").foregroundStyle(MarketplaceTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}
