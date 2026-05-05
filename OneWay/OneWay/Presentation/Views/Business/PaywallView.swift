import SwiftUI

struct PaywallView: View {
    let onStartTrial: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .black,
                    Color(red: 0.04, green: 0.08, blue: 0.16),
                    .black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 42, height: 5)
                    .padding(.top, 10)

                Text("Unlock Premium")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    Text("Sell faster. Earn more.")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("🔥 2,300 sellers upgraded today")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))

                    Text("💰 Avg earnings +42%")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }

                VStack(spacing: 14) {
                    FeatureRow(icon: "bolt.fill", text: "Boost your products")
                    FeatureRow(icon: "chart.bar.fill", text: "Advanced analytics")
                    FeatureRow(icon: "star.fill", text: "Priority placement")
                }

                Button("Start Free Trial") {
                    onStartTrial()
                }
                .buttonStyle(PrimaryButtonStyle())

                Text("7-day free trial • Cancel anytime")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(Color(red: 0.04, green: 0.52, blue: 1.0))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())

            Text(text)
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.52, blue: 1.0),
                        Color(red: 0.19, green: 0.82, blue: 0.35)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(), value: configuration.isPressed)
    }
}
