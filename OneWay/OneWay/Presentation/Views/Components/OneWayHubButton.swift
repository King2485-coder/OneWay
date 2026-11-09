import SwiftUI
import UIKit

struct OneWayHubButton: View {
    var isDimmed = false
    var action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(OneWayDesignSystem.Colors.purpleGradient)
                    .frame(width: 64, height: 64)
                    .shadow(
                        color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.58),
                        radius: 24,
                        x: 0,
                        y: 8
                    )
                OneWayPhysicalIcon(
                    role: .create,
                    size: 52,
                    state: .selected,
                    accessibilityLabel: "Open OneWay Hub",
                    glowIntensity: 0.24
                )
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .opacity(isDimmed ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open OneWay Hub")
        .accessibilityHint("Access all OneWay features and creation tools.")
    }
}
