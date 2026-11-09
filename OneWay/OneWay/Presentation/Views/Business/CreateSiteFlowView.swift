import SwiftUI

struct CreateSiteFlowView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    let onRoute: (SitesRoute) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MarketplaceBackBar(title: "Create Your Site") { dismiss() } trailing: {
                        EmptyView()
                    }

                    Text("What would you like to build?")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .oneWayReadableText(.title)
                    Text("Create a full website with OneWay AI, start from a professional template, open a blank canvas, or prepare an import.")
                        .font(.subheadline.weight(.semibold))
                        .oneWayReadableText(.subtitle)
                        .fixedSize(horizontal: false, vertical: true)

                    createCard(
                        title: "Build with OneWay AI",
                        subtitle: "Tell us the business. OneWay asks smart questions, creates pages, copy, forms, SEO, and preview-ready layouts.",
                        icon: "sparkles",
                        tint: OneWayCallTheme.purple
                    ) { onRoute(.ai) }

                    createCard(
                        title: "Choose a Template",
                        subtitle: "Use an industry-ready starting point for services, logistics, restaurants, shops, creators, and nonprofits.",
                        icon: "rectangle.on.rectangle.angled",
                        tint: .blue
                    ) { onRoute(.templates) }

                    createCard(
                        title: "Start Blank",
                        subtitle: "Open the editor with a clean canvas and basic required pages.",
                        icon: "square.grid.2x2.fill",
                        tint: .green
                    ) {
                        let site = viewModel.createBlank()
                        onRoute(.editor(site.id))
                    }

                    createCard(
                        title: "Import Existing Site",
                        subtitle: "Paste a domain or upload content. Import analysis is staged here until the backend crawler is connected.",
                        icon: "square.and.arrow.down.on.square.fill",
                        tint: .orange
                    ) { onRoute(.importSite) }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Try")
                            .font(.caption.weight(.black))
                            .oneWayReadableText(.muted)
                        ForEach(["A trucking company site with quote requests", "A restaurant site with menu and reservations", "A local service business with booking", "A nonprofit site with donations"], id: \.self) { prompt in
                            HStack {
                                OneWayResolvedIcon(systemName: "wand.and.stars")
                                    .foregroundStyle(OneWayCallTheme.purple)
                                Text(prompt)
                                    .font(.subheadline.weight(.bold))
                                    .oneWayReadableText(.body)
                                Spacer()
                            }
                            .padding(12)
                            .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(OneWayCallTheme.border, lineWidth: 1))
                        }
                    }
                    .padding(14)
                    .oneWayCallGlass(cornerRadius: 18)
                }
                .padding(18)
                .padding(.bottom, 120)
            }
        }
        .navigationBarHidden(true)
    }

    private func createCard(title: String, subtitle: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.title.weight(.black))
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline.weight(.black))
                        .oneWayReadableText(.title)
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .oneWayReadableText(.subtitle)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                OneWayResolvedIcon(systemName: "chevron.right")
                    .oneWayReadableText(.muted)
            }
            .padding(16)
            .oneWayCallGlass(cornerRadius: 22)
        }
        .buttonStyle(.plain)
    }
}
