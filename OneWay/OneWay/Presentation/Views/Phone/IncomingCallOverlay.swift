import SwiftUI

@MainActor
struct IncomingCallOverlay: View {
    let callerName: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color.blue.opacity(0.16),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                VStack(spacing: 10) {
                    Text(callerName)
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)

                    Text("Incoming Call…")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.66))
                }

                Spacer()

                HStack(spacing: 60) {
                    callActionButton(
                        color: .red,
                        systemImage: "phone.down.fill",
                        action: onDecline
                    )

                    callActionButton(
                        color: .green,
                        systemImage: "phone.fill",
                        action: onAccept
                    )
                }

                Spacer()
            }
            .padding(.vertical, 36)
        }
        .transition(.opacity)
    }

    private func callActionButton(
        color: Color,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: systemImage)
                        .foregroundColor(.white)
                        .font(.title2.weight(.bold))
                )
                .shadow(color: color.opacity(0.35), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
    }
}
