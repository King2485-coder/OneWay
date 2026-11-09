import SwiftUI

enum OneWayCallTheme {
    static let backgroundColor = OneWayDesignSystem.Colors.warmWhite
    static let surface = OneWayDesignSystem.Colors.surface
    static let elevatedSurface = OneWayDesignSystem.Colors.elevatedSurface
    static let lavenderSurface = OneWayDesignSystem.Colors.lavender
    static let border = OneWayDesignSystem.Colors.border
    static let purple = OneWayDesignSystem.Colors.purple
    static let deepPurple = OneWayDesignSystem.Colors.deepPurple
    static let violet = Color(hex: 0x8A52FF)
    static let text = OneWayDesignSystem.Colors.text
    static let muted = OneWayDesignSystem.Colors.secondaryText
    static let faint = OneWayDesignSystem.Colors.faintText

    static let background = LinearGradient(
        colors: [
            OneWayDesignSystem.Colors.backgroundPrimary,
            OneWayDesignSystem.Colors.backgroundSecondary,
            OneWayDesignSystem.Colors.deepPurple,
            Color.black
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let purpleGradient = LinearGradient(
        colors: [violet, purple, Color(hex: 0xD35CFF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct OneWayCallLogo: View {
    var size: CGFloat = 44

    var body: some View {
        OneWayLogoView(
            size: size,
            containerStyle: .roundedSquare,
            fillMode: .fullBleed,
            showsGlow: true,
            showsBorder: false
        )
    }
}

struct OneWayStarField: View {
    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            ZStack {
                ForEach(0..<38, id: \.self) { index in
                    Circle()
                        .fill(OneWayCallTheme.purple.opacity(index.isMultiple(of: 4) ? 0.12 : 0.06))
                        .frame(width: CGFloat((index % 3) + 2), height: CGFloat((index % 3) + 2))
                        .position(
                            x: CGFloat((index * 47) % Int(width)),
                            y: CGFloat((index * 83) % Int(height))
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func oneWayCallGlass(cornerRadius: CGFloat = 26) -> some View {
        self
            .background(.ultraThinMaterial.opacity(0.24), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(OneWayCallTheme.purple.opacity(0.13), lineWidth: 1)
            )
            .shadow(color: OneWayCallTheme.deepPurple.opacity(0.08), radius: 24, x: 0, y: 14)
    }
}

enum OneWayLightTheme {
    static let appBackground = OneWayDesignSystem.Colors.background
    static let background = OneWayDesignSystem.Colors.background
    static let cardBackground = OneWayDesignSystem.Colors.surface
    static let surface = OneWayDesignSystem.Colors.surface
    static let lavenderCard = OneWayDesignSystem.Colors.lavender
    static let lavenderSurface = OneWayDesignSystem.Colors.lavender
    static let primaryPurple = OneWayDesignSystem.Colors.purple
    static let textPrimary = OneWayDesignSystem.Colors.text
    static let textSecondary = OneWayDesignSystem.Colors.secondaryText
    static let textMuted = OneWayDesignSystem.Colors.faintText
    static let border = OneWayDesignSystem.Colors.border
    static let green = OneWayDesignSystem.Colors.mint
    static let warning = OneWayDesignSystem.Colors.warning
    static let danger = OneWayDesignSystem.Colors.danger
    static let cardRadius: CGFloat = 28
}
