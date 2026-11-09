import SwiftUI
import Combine

enum Theme {
    static let backgroundTop = Color(hex: 0x05040C)
    static let backgroundMid = Color(hex: 0x0B0816)
    static let backgroundViolet = Color(hex: 0x120B23)
    static let backgroundHighlight = Color(hex: 0x7C3DCE)
    static let accentGold = Color(hex: 0xF5C542)
    static let primaryBlue = Color(hex: 0x9B5CFF)
    static let accentStart = Color(hex: 0x9B5CFF)
    static let accentEnd = Color(hex: 0x7C3DCE)
    static let glassSurface = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.12)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color(hex: 0xC8C1EA)
    static let textMuted = Color(hex: 0xA59ABF)
    static let glassShadow = Color.black.opacity(0.25)

    static let appBackground = LinearGradient(
        colors: [backgroundTop, backgroundMid, backgroundViolet, backgroundTop],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accentGradient = LinearGradient(
        colors: [accentStart, accentEnd],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.primaryBlue.opacity(configuration.isPressed ? 0.88 : 1.0))
            )
            .foregroundStyle(Color.white.opacity(0.95))
            .shadow(color: Theme.primaryBlue.opacity(configuration.isPressed ? 0.18 : 0.28), radius: 10, x: 0, y: 5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
