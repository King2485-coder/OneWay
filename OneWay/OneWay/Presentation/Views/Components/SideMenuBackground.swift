import SwiftUI

struct SideMenuBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let dotCount = max(70, Int((proxy.size.width * proxy.size.height) / 12000))

            ZStack {
                Theme.appBackground

                ForEach(0..<dotCount, id: \.self) { idx in
                    Circle()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: (idx % 4 == 0) ? 1.6 : 1.1, height: (idx % 4 == 0) ? 1.6 : 1.1)
                        .position(
                            x: pseudoRandom(in: 0...proxy.size.width, seed: idx * 29 + 17),
                            y: pseudoRandom(in: 0...proxy.size.height, seed: idx * 41 + 23)
                        )
                        .blur(radius: 0.2)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
    }

    private func pseudoRandom(in range: ClosedRange<Double>, seed: Int) -> Double {
        let x = sin(Double(seed) * 12.9898) * 43758.5453
        let frac = x - floor(x)
        return range.lowerBound + (range.upperBound - range.lowerBound) * frac
    }
}
