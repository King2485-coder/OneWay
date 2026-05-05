import SwiftUI

struct CallStatsOverlay: View {
    let latency: Int
    let quality: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\u{1F4E1} \(quality)")
            Text("Latency: \(latency) ms")
        }
        .font(.caption)
        .foregroundColor(.white)
        .padding(8)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview { CallStatsOverlay(latency: 80, quality: "Good") }
