import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct OneWayDialButton: View {
    let value: String
    let letters: String
    var size: CGFloat = 88
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            action()
        } label: {
            ZStack {
                OneWayKeypadMetalFace()
                if contrast == .increased {
                    Circle().stroke(.white.opacity(0.7), lineWidth: 2)
                }

                VStack(spacing: 1) {
                    Text(value)
                        .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(letters)
                        .font(.system(size: max(10, size * 0.13), weight: .black))
                        .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                        .frame(height: size * 0.18)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: OneWayCallTheme.purple.opacity(0.04), radius: 9, x: 0, y: 5)
            .shadow(color: Color.black.opacity(0.38), radius: 6, x: 0, y: 5)
        }
        .buttonStyle(DialHardwarePressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Enters \(value)")
    }

    private var accessibilityLabel: String {
        guard !letters.isEmpty else {
            if value == "*" { return "Star" }
            if value == "#" { return "Pound" }
            return "Digit \(value)"
        }
        return "Digit \(value), \(letters)"
    }
}

private struct DialHardwarePressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .offset(y: configuration.isPressed ? 2 : 0)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.10),
                value: configuration.isPressed
            )
    }
}

/// A softer satin finish for phone controls, leaving glyphs at full contrast.
struct OneWayKeypadMetalFace: View {
    var body: some View {
        Image("ChirpMetalBackplate")
            .resizable().scaledToFit()
            .contrast(0.65)
            .brightness(-0.08)
            .saturation(0.85)
            .accessibilityHidden(true)
    }
}
