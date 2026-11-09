import SwiftUI

struct SitesDomainsView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    let onRoute: (SitesRoute) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        platformScaffold(title: "Domains", dismiss: dismiss) {
            platformHero("Register, transfer, connect, and secure every domain from OneWay.", icon: "globe")
            ForEach(viewModel.sites) { site in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(site.name)
                                .font(.headline.weight(.black))
                                .oneWayReadableText(.title)
                            Text(site.domain.customDomain.isEmpty ? site.domain.subdomain : site.domain.customDomain)
                                .font(.caption.weight(.semibold))
                                .oneWayReadableText(.subtitle)
                        }
                        Spacer()
                        Text(site.domain.sslStatus)
                            .font(.caption2.weight(.black))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }
                    HStack {
                        platformMiniMetric("DNS", "Ready", "server.rack")
                        platformMiniMetric("SSL", "Auto", "lock.shield.fill")
                        platformMiniMetric("CDN", "On", "bolt.fill")
                    }
                    Button("Manage Domain") { onRoute(.domain(site.id)) }
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(OneWayCallTheme.purple, in: Capsule())
                }
                .padding(16)
                .oneWayCallGlass(cornerRadius: 20)
            }
            platformTodoList(["Register domains", "Transfer domains", "DNS records", "Automatic SSL", "OneWay subdomains"])
        }
    }
}

struct SitesAnalyticsView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        platformScaffold(title: "Analytics", dismiss: dismiss) {
            platformHero("Track traffic, conversions, sources, forms, and performance.", icon: "chart.bar.xaxis")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                platformMetric("Visitors", "\(max(viewModel.sites.count, 1) * 842)", "arrow.up.right")
                platformMetric("Form Leads", "\(max(viewModel.sites.count, 1) * 18)", "envelope.fill")
                platformMetric("Avg. Speed", "96", "bolt.fill")
                platformMetric("SEO Score", "92", "magnifyingglass")
            }
            platformTodoList(["Google Analytics", "Meta Pixel", "Open Graph previews", "Core Web Vitals", "Conversion events"])
        }
    }
}

struct SitesCMSView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        platformScaffold(title: "CMS") {
            dismiss()
        } content: {
            platformHero("Create blogs, media libraries, categories, tags, authors, and drafts.", icon: "newspaper.fill")
            cmsRow("Blog Editor", "Draft and publish SEO-ready articles.", "text.alignleft")
            cmsRow("Media Library", "Organize images, videos, and downloadable files.", "photo.on.rectangle.angled")
            cmsRow("Collections", "Power portfolios, galleries, products, and resources.", "square.stack.3d.up.fill")
            platformTodoList(["Article manager", "Categories and tags", "Author profiles", "Draft workflow", "Media optimization"])
        }
    }

    private func cmsRow(_ title: String, _ copy: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: icon)
                .foregroundStyle(OneWayCallTheme.purple)
                .frame(width: 34, height: 34)
                .background(OneWayCallTheme.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline.weight(.black)).oneWayReadableText(.title)
                Text(copy).font(.caption.weight(.semibold)).oneWayReadableText(.subtitle)
            }
            Spacer()
        }
        .padding(16)
        .oneWayCallGlass(cornerRadius: 18)
    }
}

struct SitesFormsManagerView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    let onRoute: (SitesRoute) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        platformScaffold(title: "Forms", dismiss: dismiss) {
            platformHero("Contact forms, quote requests, bookings, and lead capture in one inbox.", icon: "tray.full.fill")
            ForEach(viewModel.sites) { site in
                Button { onRoute(.submissions(site.id)) } label: {
                    HStack(spacing: 12) {
                        OneWayResolvedIcon(systemName: "envelope.badge.fill")
                            .foregroundStyle(OneWayCallTheme.purple)
                            .frame(width: 40, height: 40)
                            .background(OneWayCallTheme.purple.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(site.name).font(.headline.weight(.black)).oneWayReadableText(.title)
                            Text("\(viewModel.submissions(for: site).count) submissions")
                                .font(.caption.weight(.bold))
                                .oneWayReadableText(.subtitle)
                        }
                        Spacer()
                        OneWayResolvedIcon(systemName: "chevron.right").oneWayReadableText(.muted)
                    }
                    .padding(16)
                    .oneWayCallGlass(cornerRadius: 18)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SitesHostingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        platformScaffold(title: "Hosting") {
            dismiss()
        } content: {
            platformHero("One-click publishing with CDN, compression, caching, SSL, and image optimization.", icon: "cloud.fill")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                platformMetric("CDN", "Global", "network")
                platformMetric("SSL", "Auto", "lock.shield.fill")
                platformMetric("Cache", "Smart", "externaldrive.fill")
                platformMetric("Images", "Optimized", "photo.fill")
            }
            platformTodoList(["Static publish pipeline", "CDN invalidation", "Compression", "Image transforms", "Rollback history"])
        }
    }
}

struct SitesImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""

    var body: some View {
        platformScaffold(title: "Import Site") {
            dismiss()
        } content: {
            platformHero("Bring an existing website into OneWay Sites. Paste a URL now and the import analyzer will prepare pages, assets, SEO, and redirects when backend crawling is enabled.", icon: "square.and.arrow.down.on.square.fill")
            VStack(alignment: .leading, spacing: 10) {
                Text("Existing website")
                    .font(.caption.weight(.black))
                    .oneWayReadableText(.title)
                TextField("https://example.com", text: $domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(14)
                    .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(OneWayCallTheme.border, lineWidth: 1))
                    .oneWayReadableText(.body)
                Button {
                    domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
                } label: {
                    OneWayResolvedLabel("Analyze Site", systemImage: "magnifyingglass")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(OneWayCallTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .oneWayCallGlass(cornerRadius: 20)

            VStack(alignment: .leading, spacing: 10) {
                Text("Import Plan")
                    .font(.headline.weight(.black))
                    .oneWayReadableText(.title)
                ForEach(["Detect pages and navigation", "Copy SEO titles and descriptions", "Map forms and calls to action", "Import images into Media Library", "Create redirect checklist"], id: \.self) { item in
                    OneWayResolvedLabel(item, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .oneWayReadableText(.subtitle)
                }
            }
            .padding(16)
            .oneWayCallGlass(cornerRadius: 18)
        }
    }
}

@ViewBuilder
private func platformScaffold<Content: View>(title: String, dismiss: DismissAction, @ViewBuilder content: () -> Content) -> some View {
    ZStack {
        OneWayCallTheme.background.ignoresSafeArea()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MarketplaceBackBar(title: title) { dismiss() } trailing: { EmptyView() }
                content()
            }
            .padding(18)
            .padding(.bottom, 120)
        }
    }
    .navigationBarHidden(true)
}

@ViewBuilder
private func platformScaffold<Content: View>(title: String, dismissAction: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
    ZStack {
        OneWayCallTheme.background.ignoresSafeArea()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MarketplaceBackBar(title: title) { dismissAction() } trailing: { EmptyView() }
                content()
            }
            .padding(18)
            .padding(.bottom, 120)
        }
    }
    .navigationBarHidden(true)
}

private func platformHero(_ copy: String, icon: String) -> some View {
    HStack(spacing: 14) {
        OneWayResolvedIcon(systemName: icon)
            .font(.title.weight(.black))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(OneWayCallTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 16))
        Text(copy)
            .font(.headline.weight(.bold))
            .oneWayReadableText(.title)
            .fixedSize(horizontal: false, vertical: true)
        Spacer()
    }
    .padding(16)
    .oneWayCallGlass(cornerRadius: 22)
}

private func platformMetric(_ title: String, _ value: String, _ icon: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        OneWayResolvedIcon(systemName: icon)
            .font(.headline.weight(.black))
            .foregroundStyle(OneWayCallTheme.purple)
        Text(value)
            .font(.title2.weight(.black))
            .oneWayReadableText(.title)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        Text(title)
            .font(.caption.weight(.black))
            .oneWayReadableText(.subtitle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .oneWayCallGlass(cornerRadius: 18)
}

private func platformMiniMetric(_ title: String, _ value: String, _ icon: String) -> some View {
    HStack(spacing: 5) {
        OneWayResolvedIcon(systemName: icon)
        Text(title)
        Text(value).foregroundStyle(.green)
    }
    .font(.caption2.weight(.black))
    .foregroundStyle(OneWayCallTheme.purple)
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(OneWayCallTheme.lavenderSurface, in: Capsule())
    .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
}

private func platformTodoList(_ items: [String]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("Production Platform")
            .font(.headline.weight(.black))
            .oneWayReadableText(.title)
        ForEach(items, id: \.self) { item in
            OneWayResolvedLabel(item, systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.bold))
                .oneWayReadableText(.subtitle)
        }
        Text("Backend integrations are staged for hosting, domain registration, DNS, SSL, analytics, CMS storage, commerce, exports, and AI editing.")
            .font(.caption.weight(.semibold))
            .oneWayReadableText(.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .oneWayCallGlass(cornerRadius: 18)
}
