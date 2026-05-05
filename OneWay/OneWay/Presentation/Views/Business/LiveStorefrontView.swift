import SwiftUI

struct LiveStorefrontView: View {
    let storefront: Storefront
    let onMessageSeller: () -> Void
    let onShare: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sellerHeader
                categories
                featuredSection
                productGrid
                about
                reviewsPlaceholder
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background { SideMenuBackground() }
        .navigationTitle(storefront.business.name)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Share") { onShare() }
                Button("Message") { onMessageSeller() }
            }
        }
    }

    private var sellerHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(storefront.business.name)
                .font(.largeTitle.weight(.bold))
            Text(storefront.business.tagline)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categories: some View {
        let cats = storefront.sections.filter { $0.type == .products || $0.type == .services }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(cats, id: \.id) { section in
                    Text(section.title)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.glassSurface))
                }
            }
        }
    }

    private var featuredSection: some View {
        if let hero = storefront.sections.first(where: { $0.type == .hero }) {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text(hero.title).font(.title.weight(.semibold))
                    if let body = hero.body {
                        Text(body).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.glassSurface))
            )
        }
        return AnyView(EmptyView())
    }

    private var productGrid: some View {
        let items = storefront.sections.first(where: { $0.type == .products })?.items ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Text("Products")
                .font(.title3.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial).frame(height: 120)
                        Text(item.name).font(.headline)
                        Text(item.price).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.title3.weight(.semibold))
            Text(storefront.business.description)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
    }

    private var reviewsPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reviews")
                .font(.title3.weight(.semibold))
            Text("Reviews coming soon.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
    }
}
