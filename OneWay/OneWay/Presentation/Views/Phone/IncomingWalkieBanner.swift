import SwiftUI

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct IncomingWalkieBanner: View {
    let incoming: WalkieChannel
    let onJoin: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        let title = incoming.fromWalkieName.nonEmpty
        ?? incoming.fromDisplayName.nonEmpty
        ?? incoming.fromOneWayId.nonEmpty
        ?? "OneWay User"

        let subtitle = incoming.fromNumber.nonEmpty
        ?? incoming.fromOneWayId.nonEmpty
        ?? "OneWay"

        VStack {
            HStack(spacing: 12) {
                OneWayResolvedIcon(systemName: "dot.radiowaves.left.and.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Incoming Chirp")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text([title, subtitle].filter { !$0.isEmpty }.joined(separator: "  "))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }

                Spacer()

                Button("Ignore") { onIgnore() }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.2))

                Button("Join") { onJoin() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}
