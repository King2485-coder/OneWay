import SwiftUI
import Combine

struct MyDomainsView: View {
    @StateObject private var viewModel: MyDomainsViewModel
    private let domainService: DomainService
    private let siteService: SiteService

    init(domainService: DomainService, siteService: SiteService) {
        self._viewModel = StateObject(wrappedValue: MyDomainsViewModel(domainService: domainService))
        self.domainService = domainService
        self.siteService = siteService
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.85))
                    }

                    if viewModel.isLoading && viewModel.domains.isEmpty {
                        ProgressView().tint(Theme.accentGold).padding(.top, 32)
                    } else if viewModel.domains.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 12) {
                            ForEach(viewModel.domains) { domain in
                                NavigationLink {
                                    DomainDetailView(
                                        domain: domain,
                                        siteService: siteService
                                    )
                                } label: {
                                    row(for: domain)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Your Domains")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    RegisterDomainView(domainService: domainService)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.accentGold)
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Each one is yours for a year — renew anytime before it expires.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "paperplane.circle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textMuted)
            Text("No domains yet.")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Register your first *.oneway.app to start publishing.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            NavigationLink {
                RegisterDomainView(domainService: domainService)
            } label: {
                Text("Register a domain")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func row(for domain: OneWayDomain) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(domain.fullDomain)
                    .font(.headline)
                    .foregroundStyle(Theme.accentGold)
                Text("Expires \(domain.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            statusBadge(for: domain.status)
            Image(systemName: "chevron.right").foregroundStyle(Theme.textMuted)
        }
        .padding(16)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private func statusBadge(for status: DomainStatus) -> some View {
        let (bg, fg, label) = badgeStyle(for: status)
        return Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
    }

    private func badgeStyle(for status: DomainStatus) -> (Color, Color, String) {
        switch status {
        case .active:    return (Color.green.opacity(0.18), Color.green, "Active")
        case .expired:   return (Color.red.opacity(0.18), Color.red, "Expired")
        case .suspended: return (Color.orange.opacity(0.18), Color.orange, "Suspended")
        case .pending:   return (Theme.glassSurface, Theme.textSecondary, "Pending")
        }
    }
}
