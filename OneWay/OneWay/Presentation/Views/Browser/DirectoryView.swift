import SwiftUI
import Combine

struct DirectoryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: BrowserViewModel
    private let siteService: SiteService
    @State private var visitURL: URL?

    init(domainService: DomainService, siteService: SiteService) {
        self._viewModel = StateObject(wrappedValue: BrowserViewModel(domainService: domainService))
        self.siteService = siteService
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        OneWayResolvedLabel("Back", systemImage: "chevron.left")
                            .font(.subheadline.weight(.black))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(Theme.glassSurface, in: Capsule())
                            .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if viewModel.isLoadingDirectory && viewModel.directory.isEmpty {
                            ProgressView().tint(Theme.accentGold)
                                .padding(.top, 32)
                        } else if viewModel.directory.isEmpty {
                            Text("No sites yet — be the first to publish one.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 32)
                        } else {
                            ForEach(viewModel.directory) { entry in
                                Button {
                                    open(URL(string: "https://\(entry.slug).oneway.app"))
                                } label: {
                                    row(for: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("Directory")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadDirectory() }
        .refreshable { await viewModel.loadDirectory() }
        .navigationDestination(item: $visitURL) { url in
            BrowserPageView(url: url, siteService: siteService)
        }
    }

    private func row(for entry: DirectoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(entry.slug).oneway.app")
                .font(.headline)
                .foregroundStyle(Theme.accentGold)
            if let title = entry.title, !title.isEmpty {
                Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
            }
            if let desc = entry.description, !desc.isEmpty {
                Text(desc).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(2)
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

    private func open(_ url: URL?) {
        guard let url else { return }
        BrowserRecentSiteStore.record(url)
        visitURL = url
    }
}
