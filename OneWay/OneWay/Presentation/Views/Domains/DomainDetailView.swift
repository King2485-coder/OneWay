import SwiftUI

struct DomainDetailView: View {
    let domain: OneWayDomain
    private let siteService: SiteService

    @State private var site: OneWaySite?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var visitURL: URL?

    init(domain: OneWayDomain, siteService: SiteService) {
        self.domain = domain
        self.siteService = siteService
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero

                    if let error = errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.85))
                    }

                    if isLoading {
                        ProgressView().tint(Theme.accentGold).padding(.top, 32)
                    } else if let site {
                        siteCard(site)
                    } else {
                        emptyCard
                    }

                    actionButtons
                }
                .padding(20)
            }
        }
        .navigationTitle(domain.slug)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSite() }
        .refreshable { await loadSite() }
        .navigationDestination(item: $visitURL) { url in
            SiteWebView(url: url)
                .navigationTitle(url.host ?? "")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(domain.fullDomain)
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(Theme.accentGold)

            HStack(spacing: 8) {
                statusBadge
                Text("Expires \(domain.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var statusBadge: some View {
        let (bg, fg, label) = badgeStyle(for: domain.status)
        return Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
    }

    private func siteCard(_ site: OneWaySite) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(site.title.isEmpty ? "Untitled site" : site.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if site.published {
                    Text("PUBLISHED")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.green)
                } else {
                    Text("DRAFT")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.glassSurface, in: Capsule())
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if !site.description.isEmpty {
                Text(site.description)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 8) {
                Label(site.mode.label, systemImage: modeIcon(site.mode))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.glassSurface, in: Capsule())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textMuted)
            Text("No site yet.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Build your page in code, blocks, or with AI.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            NavigationLink {
                EditSiteView(siteService: siteService, domainSlug: domain.slug)
            } label: {
                Label(
                    site == nil ? "Create site" : "Edit site",
                    systemImage: "pencil"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())

            if let site, site.published, let url = URL(string: "https://\(domain.fullDomain)") {
                Button {
                    visitURL = url
                } label: {
                    Label("Visit live site", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.glassSurface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func loadSite() async {
        isLoading = true
        defer { isLoading = false }
        do {
            site = try await siteService.site(forSlug: domain.slug)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load this site."
        }
    }

    private func badgeStyle(for status: DomainStatus) -> (Color, Color, String) {
        switch status {
        case .active:    return (Color.green.opacity(0.18), Color.green, "Active")
        case .expired:   return (Color.red.opacity(0.18), Color.red, "Expired")
        case .suspended: return (Color.orange.opacity(0.18), Color.orange, "Suspended")
        case .pending:   return (Theme.glassSurface, Theme.textSecondary, "Pending")
        }
    }

    private func modeIcon(_ mode: SiteMode) -> String {
        switch mode {
        case .nocode: return "square.grid.2x2"
        case .code:   return "chevron.left.forwardslash.chevron.right"
        case .ai:     return "sparkles"
        }
    }
}
