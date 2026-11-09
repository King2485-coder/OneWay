import SwiftUI

struct SitePrimaryActionsView: View {
    let onAI: () -> Void
    let onTemplate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            primaryCard(
                title: "Build with AI",
                subtitle: "Describe your idea and let OneWay build it.",
                icon: "sparkles",
                action: onAI
            )
            primaryCard(
                title: "Choose a Template",
                subtitle: "Start with a professional design.",
                icon: "rectangle.on.rectangle.angled",
                action: onTemplate
            )
        }
    }

    private func primaryCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.title3.weight(.black))
                    .foregroundStyle(OneWayCallTheme.purple)
                    .frame(width: 48, height: 48)
                    .background(OneWayCallTheme.lavenderSurface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(OneWayCallTheme.border, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.black))
                        .oneWayReadableText(.title)
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .oneWayReadableText(.subtitle)
                        .lineLimit(2)
                }
                Spacer()
                OneWayResolvedIcon(systemName: "chevron.right")
                    .font(.caption.weight(.black))
                    .oneWayReadableText(.muted)
            }
            .padding(16)
            .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(OneWayCallTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
