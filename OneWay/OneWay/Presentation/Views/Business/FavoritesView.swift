import SwiftUI

struct FavoritesView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onRoute: (MarketplaceRoute) -> Void

    var favoriteProducts: [MarketplaceProduct] {
        viewModel.products.filter { viewModel.favorites.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Favorites").font(.largeTitle.weight(.black)).foregroundStyle(MarketplaceTheme.text)
                if favoriteProducts.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(favoriteProducts) { product in
                            Button { onRoute(.product(product.id)) } label: {
                                MarketplaceProductCard(product: product, shop: viewModel.shop(product.shopID), isFavorite: true) {
                                    viewModel.toggleFavorite(product)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            OneWayResolvedIcon(systemName: "heart").font(.system(size: 48, weight: .black)).foregroundStyle(MarketplaceTheme.purple)
            Text("No favorites yet").font(.title3.weight(.black)).foregroundStyle(MarketplaceTheme.text)
            Text("Tap hearts on products to save them here.").foregroundStyle(MarketplaceTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
