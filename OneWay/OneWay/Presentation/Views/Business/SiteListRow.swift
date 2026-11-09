import SwiftUI

struct SiteListRow: View {
    let site: OneWayBuilderSite
    let lastEdited: String
    let onOpen: () -> Void
    let onPreview: () -> Void
    let onOpenQuantum: () -> Void
    let onEdit: () -> Void
    let onSettings: () -> Void
    let onDomain: () -> Void
    let onSubmissions: () -> Void
    let onPublishToggle: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ViewThatFits(in: .horizontal) {
                horizontalLayout
                compactLayout
            }
            .padding(9)
            .frame(minHeight: 112)
            .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(OneWayCallTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var horizontalLayout: some View {
        HStack(spacing: 10) {
            SiteDashboardThumbnail(site: site)
                .frame(width: 108, height: 74)
            siteInfo
            actionButtons
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SiteDashboardThumbnail(site: site)
                    .frame(width: 96, height: 64)
                siteInfo
            }
            actionButtons
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var siteInfo: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(site.name)
                .font(.subheadline.weight(.black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(site.oneWayPublicAddress)
                .font(.caption.weight(.bold))
                .oneWayReadableText(.subtitle)
                .lineLimit(1)
                .truncationMode(.tail)
            if let customDomain = site.customDomainDisplay {
                Text(customDomain)
                    .font(.caption2.weight(.bold))
                    .oneWayReadableText(.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 6) {
                siteStatusBadge(site.status)
                    .fixedSize(horizontal: true, vertical: true)
                Text("Edited \(lastEdited)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color(hex: 0xAFA7D8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(2)
    }

    private var actionButtons: some View {
        HStack(spacing: 5) {
            rowIcon("eye.fill", action: onPreview)
            rowIcon("pencil", action: onEdit)
            Menu {
                Button(site.status == .published ? "Unpublish" : "Publish", action: onPublishToggle)
                Button("Open in Quantum", action: onOpenQuantum)
                Button("Settings", action: onSettings)
                Button("Domain", action: onDomain)
                Button("Forms", action: onSubmissions)
            } label: {
                OneWayResolvedIcon(systemName: "ellipsis")
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayCallTheme.purple)
                    .frame(width: 30, height: 30)
                    .background(OneWayCallTheme.lavenderSurface, in: Circle())
            }
        }
    }

    private func rowIcon(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            OneWayResolvedIcon(systemName: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
                .frame(width: 30, height: 30)
                .background(OneWayCallTheme.lavenderSurface, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct SiteDashboardThumbnail: View {
    let site: OneWayBuilderSite

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [primary, accent.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Circle().fill(.white.opacity(0.92)).frame(width: 5, height: 5)
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.55)).frame(width: 34, height: 5)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.72)).frame(width: 22, height: 5)
                }
                RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 74, height: 8)
                RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.62)).frame(width: 96, height: 6)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.95)).frame(width: 34, height: 16)
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.28)).frame(width: 28, height: 16)
                }
                Spacer(minLength: 0)
            }
            .padding(11)

            HStack(spacing: 5) {
                OneWayResolvedIcon(systemName: thumbnailIcon)
                    .font(.caption.weight(.black))
                Text(foundation)
                    .font(.caption2.weight(.black))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.28), in: Capsule())
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OneWayCallTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 6)
        .accessibilityLabel("\(site.name) website preview")
    }

    private var primary: Color {
        Color(hexString: site.theme.primaryHex) ?? Color(hex: 0x111827)
    }

    private var accent: Color {
        Color(hexString: site.theme.accentHex) ?? OneWayCallTheme.purple
    }

    private var foundation: String {
        site.designSystem?.foundation ?? "Website"
    }

    private var thumbnailIcon: String {
        let foundation = foundation.lowercased()
        if foundation.contains("logistics") { return "box.truck.fill" }
        if foundation.contains("restaurant") { return "fork.knife" }
        if foundation.contains("portfolio") { return "camera.fill" }
        if foundation.contains("store") { return "bag.fill" }
        if foundation.contains("service") { return "briefcase.fill" }
        return "globe"
    }
}

func siteStatusBadge(_ status: SitePublishStatus) -> some View {
    Text(status.rawValue)
        .font(.caption2.weight(.black))
        .foregroundStyle(status == .published ? .green : OneWayCallTheme.purple)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((status == .published ? Color.green : OneWayCallTheme.purple).opacity(0.14), in: Capsule())
}

private extension Color {
    init?(hexString: String) {
        let raw = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = Int(raw, radix: 16) else { return nil }
        self = Color(hex: UInt32(value))
    }
}
