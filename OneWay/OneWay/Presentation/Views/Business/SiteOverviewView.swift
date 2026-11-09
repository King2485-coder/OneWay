import SwiftUI

struct SiteOverviewView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    let site: OneWayBuilderSite
    let visitors: Int
    let seoScore: Int
    let performanceScore: Int
    let onRoute: (SitesRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentSite: OneWayBuilderSite

    init(
        viewModel: OneWaySitesViewModel,
        site: OneWayBuilderSite,
        visitors: Int,
        seoScore: Int,
        performanceScore: Int,
        onRoute: @escaping (SitesRoute) -> Void
    ) {
        self.viewModel = viewModel
        self.site = site
        self.visitors = visitors
        self.seoScore = seoScore
        self.performanceScore = performanceScore
        self.onRoute = onRoute
        self._currentSite = State(initialValue: site)
    }

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MarketplaceBackBar(title: "Site Overview") { dismiss() } trailing: { EmptyView() }

                    SiteRendererView(site: currentSite, mode: .mobile)
                        .frame(maxWidth: .infinity)
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 26).stroke(OneWayCallTheme.border, lineWidth: 1))

                    summaryCard
                    primaryActions
                    metricsGrid
                    recentActivity
                }
                .padding(18)
                .padding(.bottom, 120)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            currentSite = viewModel.site(site.id) ?? site
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(currentSite.name)
                        .font(.title2.weight(.black))
                        .oneWayReadableText(.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(currentSite.oneWayPublicAddress)
                        .font(.subheadline.weight(.bold))
                        .oneWayReadableText(.subtitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let customDomain = currentSite.customDomainDisplay {
                        Text("Custom domain: \(customDomain)")
                            .font(.caption.weight(.semibold))
                            .oneWayReadableText(.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                siteStatusBadge(currentSite.status)
            }
            OneWayResolvedLabel(currentSite.domain.sslStatus, systemImage: "lock.shield.fill")
                .font(.caption.weight(.black))
                .foregroundStyle(.green)
        }
        .padding(16)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private var primaryActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            overviewAction(currentSite.status == .published ? "Unpublish" : "Publish", "icloud.and.arrow.up.fill", primary: true) {
                if currentSite.status == .published {
                    viewModel.unpublish(currentSite)
                } else {
                    _ = viewModel.publish(currentSite)
                }
                currentSite = viewModel.site(currentSite.id) ?? currentSite
            }
            overviewAction("Open Quantum", "paperplane.fill") { onRoute(.quantum(currentSite.id)) }
            overviewAction("Edit Site", "pencil") { onRoute(.editor(currentSite.id)) }
            overviewAction("Ask AI", "sparkles") { onRoute(.ai) }
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metric("Visitors", "\(visitors)", "person.2.fill")
            metric("SEO", "\(seoScore)", "magnifyingglass")
            metric("Performance", "\(performanceScore)", "bolt.fill")
            metric("Forms", "\(viewModel.submissions(for: currentSite).count)", "tray.full.fill")
            metric("Domain Health", currentSite.domain.sslStatus.contains("Active") ? "Good" : "Ready", "globe")
            metric("Pages", "\(currentSite.pages.count)", "doc.text.fill")
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Activity")
                .font(.headline.weight(.black))
                .oneWayReadableText(.title)
            activity("Site saved", "Your latest edits are stored locally.", "checkmark.circle.fill")
            activity(currentSite.status == .published ? "Published" : "Draft", currentSite.domain.publishStatus, "globe")
            activity("Forms", "\(viewModel.submissions(for: currentSite).count) recent submissions", "envelope.fill")
        }
        .padding(16)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private func overviewAction(_ title: String, _ icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.headline.weight(.black))
                Text(title)
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(primary ? .white : OneWayCallTheme.purple)
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(primary ? AnyShapeStyle(OneWayCallTheme.purple) : AnyShapeStyle(OneWayCallTheme.elevatedSurface), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(primary ? Color.clear : OneWayCallTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .foregroundStyle(OneWayCallTheme.purple)
                .frame(width: 30, height: 30)
                .background(OneWayCallTheme.lavenderSurface, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.weight(.black))
                    .oneWayReadableText(.title)
                    .lineLimit(1)
                Text(title)
                    .font(.caption.weight(.bold))
                    .oneWayReadableText(.subtitle)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private func activity(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
                .frame(width: 28, height: 28)
                .background(OneWayCallTheme.lavenderSurface, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.black))
                    .oneWayReadableText(.title)
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .oneWayReadableText(.subtitle)
            }
            Spacer()
        }
    }
}
