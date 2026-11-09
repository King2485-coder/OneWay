import SwiftUI

struct SiteSettingsView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    @State private var draft: OneWayBuilderSite
    let onRoute: (SitesRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var ownedShops: [ManagedStorefrontDTO] = []
    @State private var shopsError: String?

    init(viewModel: OneWaySitesViewModel, site: OneWayBuilderSite, onRoute: @escaping (SitesRoute) -> Void) {
        self.viewModel = viewModel
        self._draft = State(initialValue: site)
        self.onRoute = onRoute
    }

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MarketplaceBackBar(title: "Site Settings") { dismiss() } trailing: { EmptyView() }
                    settingsField("Site name", text: $draft.name)
                    settingsField("SEO title", text: $draft.seoTitle)
                    settingsField("SEO description", text: $draft.seoDescription)
                    settingsField("Contact form destination", text: $draft.contactEmail)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect your shop").font(.headline.bold())
                        Picker("Shop", selection: Binding(get: { draft.linkedShopSlug ?? "" }, set: { slug in
                            draft.linkedShopSlug = slug.isEmpty ? nil : slug
                            draft.linkedShopName = ownedShops.first { $0.slug == slug }?.name
                            if slug.isEmpty { draft.shopLinkEnabled = false }
                        })) {
                            Text("Choose your shop").tag("")
                            if let slug = draft.linkedShopSlug, !ownedShops.contains(where: { $0.slug == slug }) { Text(draft.linkedShopName ?? slug).tag(slug) }
                            ForEach(ownedShops, id: \.id) { shop in Text(shop.name + (shop.published ? "" : " · draft")).tag(shop.slug) }
                        }
                        Toggle("Show my shop on my website", isOn: Binding(get: { draft.shopLinkEnabled == true }, set: { draft.shopLinkEnabled = $0 }))
                            .disabled(draft.linkedShopSlug?.isEmpty != false)
                        Text("Save settings and publish the website to update its shop link. Publish the shop before sharing it with visitors.").font(.caption).foregroundStyle(.secondary)
                        if let shopsError { Text(shopsError).font(.caption).foregroundStyle(.orange) }
                    }.padding(14).oneWayCallGlass(cornerRadius: 18)

                    Button("Domain Settings") { onRoute(.domain(draft.id)) }
                        .settingsActionStyle()
                    Button("Form Submissions") { onRoute(.submissions(draft.id)) }
                        .settingsActionStyle()

                    Button {
                        viewModel.upsert(draft)
                    } label: {
                        OneWayResolvedLabel("Save Settings", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .padding()
                    .background(OneWayCallTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 18))

                    Button(role: .destructive) { confirmDelete = true } label: {
                        OneWayResolvedLabel("Delete Site", systemImage: "trash.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .font(.headline.weight(.black))
                    .padding()
                    .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
                }
                .padding(18)
                .padding(.bottom, 120)
            }
        }
        .navigationBarHidden(true)
        .task {
            do { ownedShops = try await StorefrontService.shared.fetchManagedStorefronts() }
            catch { shopsError = "Your shops could not load. Existing link settings are preserved." }
        }
        .confirmationDialog("Delete this site?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Site", role: .destructive) {
                viewModel.delete(draft)
                dismiss()
            }
        }
    }

    private func settingsField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.black)).oneWayReadableText(.title)
            TextField(title, text: text)
                .padding(13)
                .oneWayReadableText(.body)
                .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(OneWayCallTheme.border, lineWidth: 1))
        }
        .padding(14)
        .oneWayCallGlass(cornerRadius: 18)
    }
}

private extension View {
    func settingsActionStyle() -> some View {
        font(.headline.weight(.black))
            .foregroundStyle(OneWayCallTheme.purple)
            .frame(maxWidth: .infinity)
            .padding()
            .background(OneWayCallTheme.lavenderSurface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(OneWayCallTheme.border, lineWidth: 1))
    }
}
