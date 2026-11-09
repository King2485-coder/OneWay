import SwiftUI

struct BrowserDownloadsView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                BrowserPanelBackground()

                if viewModel.downloads.isEmpty {
                    BrowserEmptyState(icon: "arrow.down.circle.fill", title: "No Quantum Downloads", subtitle: "Files you download in OneWay Quantum will appear here.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.downloads) { download in
                                HStack(spacing: 12) {
                                    OneWayResolvedIcon(systemName: "doc.fill")
                                        .font(.title3.weight(.black))
                                        .foregroundStyle(Color(hex: 0xA66BFF))
                                        .frame(width: 44, height: 44)
                                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(download.filename)
                                            .font(.headline.weight(.black))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(download.sourceURL)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.white.opacity(0.58))
                                            .lineLimit(1)
                                        Text("\(download.status.rawValue) • \(download.date.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.green.opacity(0.9))
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .browserPanelCard()
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .navigationTitle("Quantum Downloads")
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
            }
        }
    }
}
