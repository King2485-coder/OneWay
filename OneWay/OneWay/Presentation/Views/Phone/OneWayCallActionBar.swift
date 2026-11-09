import SwiftUI

struct OneWayCallActionBar: View {
    var height: CGFloat = 82
    var buttonDiameter: CGFloat = 84
    var labelSize: CGFloat = 20
    var isStarting = false
    let onCall: () -> Void
    let onVideo: () -> Void
    let onDelete: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            action("Call", role: .call, fill: Color.green, action: onCall)
            action("Video", role: .video, fill: OneWayCallTheme.purple, action: onVideo)
            action("Delete", role: .deleteDigit, fill: Color.red.opacity(0.88), action: onDelete)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in onClear() })
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .oneWayCallGlass(cornerRadius: 26)
    }

    private func action(_ title: String, role: OneWayIconRole, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(fill)
                        .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 1))
                    OneWayPhysicalIcon(
                        role: role,
                        size: buttonDiameter * 0.66,
                        state: role == .call ? .success : (role == .deleteDigit ? .destructive : .selected),
                        container: .none,
                        accessibilityLabel: title,
                        glowIntensity: 0
                    )
                }
                .frame(width: buttonDiameter, height: buttonDiameter)
                .shadow(color: fill.opacity(0.24), radius: 9, x: 0, y: 5)
                Text(isStarting && role != .deleteDigit ? "Starting…" : title)
                    .font(.system(size: labelSize, weight: .black, design: .rounded))
                    .foregroundStyle(OneWayCallTheme.text)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(minWidth: 76, minHeight: buttonDiameter + labelSize + 12)
        .disabled(isStarting && role != .deleteDigit)
        .opacity(isStarting && role != .deleteDigit ? 0.55 : 1)
        .accessibilityLabel(accessibilityLabel(for: role))
        .accessibilityHint(role == .deleteDigit ? "Deletes the last entered character. Long press clears all." : "")
    }

    private func accessibilityLabel(for role: OneWayIconRole) -> String {
        switch role {
        case .call: return "Start audio call"
        case .video: return "Start video call"
        case .deleteDigit: return "Delete last digit"
        default: return role.defaultAccessibilityLabel
        }
    }
}
