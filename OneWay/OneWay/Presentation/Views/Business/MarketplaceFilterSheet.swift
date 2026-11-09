import SwiftUI

struct MarketplaceFilterSheet: View {
    @Binding var filters: MarketplaceFilters
    let categories: [MarketplaceCategory]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                MarketplaceTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Category").font(.headline.weight(.black)).foregroundStyle(.white)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            categoryButton(nil, "All")
                            ForEach(categories) { category in categoryButton(category.name, category.name) }
                        }

                        VStack(alignment: .leading) {
                            Text("Max Price: \(filters.maxPrice.currency)")
                                .font(.headline.weight(.black))
                                .foregroundStyle(.white)
                            Slider(value: $filters.maxPrice, in: 10...120, step: 5)
                                .tint(MarketplaceTheme.purple)
                        }

                        VStack(alignment: .leading) {
                            Text("Minimum Rating: \(String(format: "%.1f", filters.minimumRating))")
                                .font(.headline.weight(.black))
                                .foregroundStyle(.white)
                            Slider(value: $filters.minimumRating, in: 0...5, step: 0.5)
                                .tint(MarketplaceTheme.purple)
                        }

                        Toggle("Ships from / local pickup", isOn: $filters.localPickup)
                        Toggle("Privacy verified only", isOn: $filters.privacyVerifiedOnly)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(18)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { filters = MarketplaceFilters() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") { dismiss() }
                }
            }
        }
    }

    private func categoryButton(_ value: String?, _ title: String) -> some View {
        Button {
            filters.category = value
        } label: {
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(filters.category == value ? MarketplaceTheme.purple : MarketplaceTheme.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
