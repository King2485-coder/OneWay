import SwiftUI
import Combine

struct BrowserHomeView: View {
    @StateObject private var viewModel: BrowserViewModel
    private let domainService: DomainService
    private let siteService: SiteService

    @State private var visitURL: URL?

    init(domainService: DomainService, siteService: SiteService) {
        self._viewModel = StateObject(wrappedValue: BrowserViewModel(domainService: domainService))
        self.domainService = domainService
        self.siteService = siteService
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero

                    addressBar

                    actionRow

                    NavigationLink {
                        DirectoryView(domainService: domainService)
                    } label: {
                        directoryCard
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        MyDomainsView(
                            domainService: domainService,
                            siteService: siteService
                        )
                    } label: {
                        myDomainsCard
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
        }
        .navigationTitle("OneWay")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(item: $visitURL) { url in
            SiteWebView(url: url)
                .navigationTitle(url.host ?? "")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OneWay Browser".uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(Theme.textSecondary)
            Text("The private web,\nyours to own.")
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
            Text("Anything ending in `.oneway.app` opens here. No trackers, no JS soup, just one page.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textMuted)
                TextField("name.oneway.app", text: $viewModel.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.go)
                    .onSubmit(go)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.divider, lineWidth: 1)
            )

            Button(action: go) {
                Text("Open")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(viewModel.resolvedURL == nil)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            quickAction(symbol: "globe", label: "home.oneway.app") {
                visitURL = URL(string: "https://home.oneway.app")
            }
            quickAction(symbol: "list.bullet", label: "Directory") {
                // navigation handled by NavigationLink card below; this is a quick alternative
            }
        }
    }

    @ViewBuilder
    private func quickAction(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(label).lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.glassSurface, in: Capsule())
            .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var directoryCard: some View {
        cardLink(
            symbol: "books.vertical",
            title: "Browse the directory",
            subtitle: "See every active site on OneWay."
        )
    }

    private var myDomainsCard: some View {
        cardLink(
            symbol: "person.crop.square.filled.and.at.rectangle",
            title: "Your domains",
            subtitle: "Register, edit, and publish your own *.oneway.app sites."
        )
    }

    private func cardLink(symbol: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accentGold)
                .frame(width: 44, height: 44)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.textMuted)
        }
        .padding(16)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private func go() {
        guard let url = viewModel.resolvedURL else { return }
        visitURL = url
    }
}
