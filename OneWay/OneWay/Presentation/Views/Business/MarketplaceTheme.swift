import SwiftUI

enum MarketplaceTheme {
    static let background = LinearGradient(
        colors: [
            OneWayDesignSystem.Colors.warmWhite,
            OneWayDesignSystem.Colors.lavender.opacity(0.72),
            OneWayDesignSystem.Colors.warmWhite
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let purple = OneWayDesignSystem.Colors.purple
    static let vividPurple = Color(hex: 0xB56CFF)
    static let deepPurple = Color(hex: 0x2A0B55)
    static let card = OneWayDesignSystem.Colors.surface
    static let lavenderCard = OneWayDesignSystem.Colors.lavender
    static let border = OneWayDesignSystem.Colors.border
    static let text = OneWayDesignSystem.Colors.text
    static let muted = OneWayDesignSystem.Colors.secondaryText
    static let faint = OneWayDesignSystem.Colors.faintText
    static let gradient = LinearGradient(colors: [Color(hex: 0x7B36FF), Color(hex: 0xC471FF)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension View {
    func marketplaceCard(cornerRadius: CGFloat = 24) -> some View {
        self
            .background(MarketplaceTheme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MarketplaceTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 10)
    }
}

enum MarketplaceHaptics {
    static func tap() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
