import SwiftUI

struct OneWayBackButton: View {
    var title: String = "Back"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            OneWayResolvedLabel(title, systemImage: "chevron.left")
                .font(.subheadline.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(OneWayDesignSystem.Colors.elevatedSurface, in: Capsule())
                .overlay(Capsule().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                .shadow(color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.18), radius: 14, x: 0, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
