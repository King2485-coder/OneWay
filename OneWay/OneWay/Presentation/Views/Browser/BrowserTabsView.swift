import SwiftUI

struct BrowserTabsView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                BrowserPanelBackground()

                if viewModel.tabs.isEmpty {
                    BrowserEmptyState(icon: "square.on.square", title: "No Quantum Tabs", subtitle: "Start a Quantum tab from the OneWay Quantum home screen.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.tabs) { tab in
                                tabCard(tab)
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .navigationTitle("Quantum Tabs")
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
                    Button {
                        viewModel.newTab()
                        dismiss()
                    } label: {
                        OneWayResolvedIcon(systemName: "plus")
                    }
                }
            }
        }
    }

    private func tabCard(_ tab: BrowserTab) -> some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: tab.isPrivate ? "flame.fill" : "globe")
                .font(.title3.weight(.black))
                .foregroundStyle(tab.isPrivate ? Color(hex: 0xA66BFF) : .cyan)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(tab.displayURL)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer()

            if tab.id == viewModel.activeTabID {
                OneWayResolvedIcon(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Button {
                viewModel.closeTab(tab)
            } label: {
                OneWayResolvedIcon(systemName: "xmark")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectTab(tab)
            dismiss()
        }
        .padding(14)
        .browserPanelCard(isActive: tab.id == viewModel.activeTabID)
    }
}
