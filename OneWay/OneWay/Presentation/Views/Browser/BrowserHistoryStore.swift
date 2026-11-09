import SwiftUI

struct BrowserHistoryPanel: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                BrowserPanelBackground()

                if viewModel.history.isEmpty {
                    BrowserEmptyState(icon: "clock.arrow.circlepath", title: "No Quantum History", subtitle: "Non-private Quantum history stays local on this device.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.history) { page in
                                Button {
                                    if let url = page.url {
                                        viewModel.open(url)
                                        dismiss()
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(page.title)
                                            .font(.headline.weight(.black))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(page.urlString)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.white.opacity(0.58))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .browserPanelCard()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .navigationTitle("Quantum History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        OneWayResolvedLabel("Back", systemImage: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        BrowserHistoryStore.clear()
                        viewModel.history = []
                    }
                }
            }
        }
    }
}

struct BrowserBookmarksPanel: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var bookmarks: [BrowserStoredPage] = BrowserBookmarkStore.load()

    var body: some View {
        NavigationStack {
            ZStack {
                BrowserPanelBackground()

                if bookmarks.isEmpty {
                    BrowserEmptyState(icon: "bookmark.fill", title: "No Quantum Bookmarks", subtitle: "Bookmarked OneWay Sites and websites will appear here.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(bookmarks) { page in
                                bookmarkRow(page)
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .navigationTitle("Quantum Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        OneWayResolvedLabel("Back", systemImage: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        BrowserBookmarkStore.clear()
                        bookmarks = []
                    }
                }
            }
        }
    }

    private func bookmarkRow(_ page: BrowserStoredPage) -> some View {
        HStack(spacing: 12) {
            Button {
                if let url = page.url {
                    viewModel.open(url)
                    dismiss()
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(page.urlString)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                if let url = page.url {
                    _ = BrowserBookmarkStore.toggle(url: url, title: page.title)
                    bookmarks = BrowserBookmarkStore.load()
                }
            } label: {
                OneWayResolvedIcon(systemName: "trash")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Bookmark")
        }
        .padding(14)
        .browserPanelCard()
    }
}

struct BrowserPanelBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.black, Color(hex: 0x080312), Color(hex: 0x24104D)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct BrowserEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 42, weight: .black))
                .foregroundStyle(Color(hex: 0xA66BFF))
            Text(title)
                .font(.title3.weight(.black))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 28)
        }
    }
}

extension View {
    func browserPanelCard(isActive: Bool = false) -> some View {
        self
            .background(.ultraThinMaterial.opacity(0.42), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isActive ? Color(hex: 0xA66BFF).opacity(0.75) : Color.white.opacity(0.13), lineWidth: 1)
            )
            .shadow(color: Color(hex: 0xA66BFF).opacity(isActive ? 0.24 : 0.10), radius: 18, x: 0, y: 10)
    }
}
