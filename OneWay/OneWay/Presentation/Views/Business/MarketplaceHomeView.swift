import SwiftUI
import Combine

struct MarketplaceHomeView: View {
    @ObservedObject var viewModel: BusinessViewModel
    let isOwner: Bool
    let onManage: () -> Void
    let onAskAI: () -> Void
    let onViewStore: (_ store: Storefront?) -> Void
    let onSelectCategory: (_ category: String) -> Void

    private let featuredProducts: [Product] = [
        Product(id: UUID(), name: "Featured Hoodie", summary: "Soft fleece", price: "$68", images: [], tags: ["Apparel"], isFeatured: true, collectionIDs: []),
        Product(id: UUID(), name: "Wireless Buds", summary: "ANC + 24h battery", price: "$129", images: [], tags: ["Audio"], isFeatured: true, collectionIDs: [])
    ]

    private let categories = ["Apparel", "Electronics", "Wellness", "Services", "Gifts"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchBar
                searchResultsSection
                featuredDeals
                topCategories
                featuredStores

                if isOwner {
                    ownerCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background { SideMenuBackground() }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
            TextField("Search products, stores, categories", text: $viewModel.searchQuery)
                .onChange(of: viewModel.searchQuery) { _, newValue in
                    viewModel.searchState = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .typing
                    Task { await viewModel.search(mode: .shop) }
                }
                .submitLabel(.search)
            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.thinMaterial))
    }

    private var searchResultsSection: some View {
        Group {
            switch viewModel.searchState {
            case .idle, .typing:
                EmptyView()
            case .loading:
                HStack {
                    ProgressView()
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .empty:
                Text("No results yet.")
                    .foregroundStyle(.secondary)
            case .error(let message):
                Text(message).foregroundStyle(.red)
            case .results:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Results")
                        .font(.headline)
                    ForEach(viewModel.searchResults) { result in
                        Button {
                            handleResultTap(result)
                        } label: {
                            HStack {
                                Image(systemName: icon(for: result.kind))
                                VStack(alignment: .leading) {
                                    Text(result.title)
                                        .font(.subheadline.weight(.semibold))
                                    if let subtitle = result.subtitle {
                                        Text(subtitle)
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                    }
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var featuredDeals: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Featured Deals")
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(featuredProducts) { product in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).frame(width: 160, height: 110)
                            Text(product.name).font(.headline)
                            Text(product.price).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(width: 160)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.glassSurface))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var topCategories: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Categories")
                .font(.title3.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(categories, id: \.self) { cat in
                    Text(cat)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
                        .onTapGesture {
                            viewModel.searchQuery = cat
                            Task { await viewModel.search(mode: .shop) }
                            onSelectCategory(cat)
                        }
                }
            }
        }
    }

    private var featuredStores: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Featured Stores")
                .font(.title3.weight(.semibold))
            if let store = viewModel.publishedStorefront ?? viewModel.storefront {
                storeTile(store)
            } else {
                Text("No featured stores yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func storeTile(_ store: Storefront) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.business.name).font(.headline)
            Text(store.business.tagline).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("View Store") { onViewStore(store) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.glassSurface))
    }

    private var ownerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manage your storefront")
                .font(.headline)
            HStack {
                Button("View Live Store") { onViewStore(viewModel.publishedStorefront ?? viewModel.storefront) }
                Button("Manage Store") { onManage() }
                Button("Ask AI") { onAskAI() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.glassSurface))
    }

    private func handleResultTap(_ result: SearchResult) {
        switch result.kind {
        case .storefront:
            onViewStore(result.storefront ?? viewModel.storefront)
        case .product, .collection:
            onViewStore(result.storefront ?? viewModel.storefront)
        case .category:
            if let category = result.category {
                viewModel.searchQuery = category
                Task { await viewModel.search(mode: .shop) }
                onSelectCategory(category)
            }
        }
    }

    private func icon(for kind: SearchResultKind) -> String {
        switch kind {
        case .product: return "bag.fill"
        case .storefront: return "building.2.fill"
        case .category: return "square.grid.3x3.fill"
        case .collection: return "square.stack.3d.up.fill"
        }
    }
}
