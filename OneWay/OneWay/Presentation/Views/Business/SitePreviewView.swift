import SwiftUI

struct SitePreviewView: View {
    let site: OneWayBuilderSite
    @Environment(\.dismiss) private var dismiss
    @State private var mode: SitePreviewMode = .mobile

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                MarketplaceBackBar(title: "Preview") { dismiss() } trailing: {
                    Picker("Mode", selection: $mode) {
                        ForEach(SitePreviewMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ScrollView {
                    SiteRendererView(site: site, mode: mode)
                        .frame(maxWidth: mode == .mobile ? 390 : (mode == .tablet ? 720 : .infinity))
                        .clipShape(RoundedRectangle(cornerRadius: mode == .desktop ? 0 : 28, style: .continuous))
                        .shadow(color: OneWayCallTheme.purple.opacity(0.25), radius: 24)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 120)
                }
            }
        }
        .navigationBarHidden(true)
    }
}
