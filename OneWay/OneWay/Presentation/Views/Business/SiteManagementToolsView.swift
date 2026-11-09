import SwiftUI

struct SiteManagementToolsView: View {
    let onRoute: (SitesRoute) -> Void

    private let tools: [(String, String, String?, SitesRoute)] = [
        ("Domains", "globe", "SSL ready", .domains),
        ("Analytics", "chart.line.uptrend.xyaxis", nil, .analytics),
        ("Forms", "tray.full.fill", "Inbox", .forms),
        ("Blog & CMS", "newspaper.fill", nil, .cms),
        ("Hosting", "cloud.fill", "CDN on", .hosting),
        ("Media", "photo.on.rectangle.angled", "Library", .cms),
        ("Site Health", "stethoscope", "Healthy", .hosting),
        ("Import", "square.and.arrow.down", nil, .importSite)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Management Tools")
                .font(.title3.weight(.black))
                .foregroundStyle(OneWayCallTheme.text)
                .lineLimit(1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(tools, id: \.0) { tool in
                    toolRow(title: tool.0, icon: tool.1, status: tool.2) {
                        onRoute(tool.3)
                    }
                }
            }
        }
        .padding(12)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private func toolRow(title: String, icon: String, status: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayCallTheme.purple)
                    .frame(width: 30, height: 30)
                    .background(OneWayCallTheme.lavenderSurface, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    if let status {
                        Text(status)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color(hex: 0xAFA7D8))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                OneWayResolvedIcon(systemName: "chevron.right")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(Color(hex: 0xAFA7D8))
            }
            .padding(10)
            .frame(minHeight: 58)
            .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(OneWayCallTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
