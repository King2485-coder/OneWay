import SwiftUI

struct OneWayMenuHeader<Leading: View, Trailing: View>: View {
    let title: String
    private let leading: Leading
    private let trailing: Trailing

    init(
        title: String,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x2A1459),
                                Color(hex: 0x3B1D74),
                                Color(hex: 0x1A103E)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(.ultraThinMaterial.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color(hex: 0x7B5CFF, alpha: 0.24), radius: 24, x: 0, y: 10)

                Circle()
                    .fill(Color(hex: 0xA685FF, alpha: 0.22))
                    .frame(width: 180, height: 180)
                    .blur(radius: 30)
                    .offset(y: 10)
                    .allowsHitTesting(false)

                VStack(spacing: 10) {
                    HStack {
                        leading
                        Spacer()
                        trailing
                    }

                    Text(title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
        }
        .frame(height: 126)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}

struct OneWayMenuHeader_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                OneWayMenuHeader(title: "Settings") {
                    Button {
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                } trailing: {
                    Button {
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                }

                Spacer()
            }
        }
    }
}
