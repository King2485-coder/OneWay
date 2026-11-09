import SwiftUI

struct AIBuilderArtworkView: View {
    let animate: Bool

    var body: some View {
        ZStack {
            purpleBloom(x: 18, y: 22, radius: 78)
            monitor
                .rotation3DEffect(.degrees(-8), axis: (x: 1, y: -0.7, z: 0))
                .offset(x: animate ? -4 : 4, y: animate ? 0 : 4)
            floatingPanel(width: 42, height: 28)
                .offset(x: 46, y: animate ? -38 : -30)
            floatingPanel(width: 34, height: 22)
                .offset(x: -58, y: animate ? -28 : -20)
            aiTypingCursor
                .offset(x: animate ? 16 : -26, y: 0)
            magicWand
                .offset(x: 62, y: 30)
                .rotationEffect(.degrees(animate ? -18 : -28))
            sparkleCluster
                .opacity(animate ? 1 : 0.55)
                .scaleEffect(animate ? 1.08 : 0.94)
        }
    }

    private var monitor: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(hex: 0x17132B), Color(hex: 0x3B1C72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(Color.white.opacity(0.18)).frame(width: 38, height: 5)
                        Capsule().fill(OneWayCallTheme.purple).frame(width: 54, height: 7)
                        Capsule().fill(Color.white.opacity(0.2)).frame(width: 44, height: 5)
                    }
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.88)).frame(width: 84, height: 46)
                        HStack {
                            Capsule().fill(OneWayCallTheme.purple).frame(width: 28, height: 8)
                            Capsule().fill(Color.white.opacity(0.25)).frame(width: 26, height: 8)
                        }
                    }
                }
                .padding(12)
            }
            .frame(width: 164, height: 88)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.22), lineWidth: 1))
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(hex: 0x2C1550), Color(hex: 0x0A0615)], startPoint: .top, endPoint: .bottom))
                .frame(width: 56, height: 12)
        }
        .shadow(color: OneWayCallTheme.purple.opacity(0.48), radius: 18, x: 0, y: 10)
    }

    private var magicWand: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [.white.opacity(0.8), OneWayCallTheme.purple], startPoint: .top, endPoint: .bottom))
            .frame(width: 7, height: 58)
            .overlay(Rectangle().fill(.white.opacity(0.5)).frame(width: 1).offset(x: -2))
    }

    private var aiTypingCursor: some View {
        VStack(spacing: 3) {
            Text("AI")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.white)
            Circle().fill(OneWayCallTheme.purple).frame(width: 7, height: 7)
        }
        .opacity(animate ? 1 : 0.45)
        .shadow(color: OneWayCallTheme.purple, radius: 10)
    }
}

struct TemplateArtworkView: View {
    let animate: Bool

    var body: some View {
        ZStack {
            purpleBloom(x: 0, y: 18, radius: 90)
            templateCard(title: "BISTRO", color: Color(hex: 0xF5A524), width: 88, height: 72)
                .rotationEffect(.degrees(-13))
                .offset(x: animate ? -54 : -48, y: animate ? 2 : 7)
            templateCard(title: "MODERN", color: OneWayCallTheme.purple, width: 106, height: 82)
                .offset(x: 0, y: animate ? -8 : -2)
                .zIndex(2)
            templateCard(title: "STUDIO", color: Color(hex: 0x55D6FF), width: 86, height: 68)
                .rotationEffect(.degrees(12))
                .offset(x: animate ? 54 : 48, y: animate ? 8 : 3)
            Text("247")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(OneWayCallTheme.purple.opacity(0.42), in: Capsule())
                .offset(x: 54, y: -44)
        }
    }

    private func templateCard(title: String, color: Color, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(hex: 0x101225), color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(.white.opacity(0.72)).frame(width: width * 0.38, height: 4)
                Text(title)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                HStack(spacing: 3) {
                    Capsule().fill(color).frame(width: width * 0.28, height: 5)
                    Capsule().fill(.white.opacity(0.2)).frame(width: width * 0.22, height: 5)
                }
            }
            .padding(9)
        }
        .frame(width: width, height: height)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: color.opacity(0.35), radius: 16, x: 0, y: 8)
    }
}

struct DomainArtworkView: View {
    let animate: Bool

    var body: some View {
        ZStack {
            purpleBloom(x: 0, y: 12, radius: 88)
            Circle()
                .stroke(OneWayCallTheme.purple.opacity(0.18), lineWidth: 1)
                .frame(width: 156, height: 156)
                .rotationEffect(.degrees(animate ? 15 : -10))
            globe
                .rotationEffect(.degrees(animate ? 8 : -8))
            domainPill("brand.oneway.site")
                .offset(x: animate ? -48 : -56, y: -38)
            domainPill("studio.io")
                .offset(x: animate ? 55 : 48, y: 34)
            sslShield
                .offset(x: 58, y: -38)
            connectionPulse
                .opacity(animate ? 1 : 0.35)
        }
    }

    private var globe: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xB56BFF), Color(hex: 0x45158F), Color(hex: 0x12071F)], center: .topLeading, startRadius: 10, endRadius: 78))
                .frame(width: 110, height: 110)
            ForEach([-28, 0, 28], id: \.self) { x in
                Ellipse().stroke(.white.opacity(0.22), lineWidth: 1).frame(width: CGFloat(32 + abs(x)), height: 110).offset(x: CGFloat(x) * 0.18)
            }
            ForEach([-24, 0, 24], id: \.self) { y in
                Capsule().stroke(.white.opacity(0.18), lineWidth: 1).frame(width: 96, height: 1).offset(y: CGFloat(y))
            }
        }
        .shadow(color: OneWayCallTheme.purple.opacity(0.55), radius: 24)
    }

    private var connectionPulse: some View {
        Circle()
            .trim(from: 0.02, to: 0.18)
            .stroke(Color.green.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 150, height: 150)
            .rotationEffect(.degrees(animate ? 300 : 20))
            .shadow(color: .green.opacity(0.5), radius: 10)
    }
}

struct AnalyticsArtworkView: View {
    let animate: Bool

    var body: some View {
        ZStack {
            purpleBloom(x: 14, y: 20, radius: 90)
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Color(hex: 0x111426), Color(hex: 0x2A1558)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 166, height: 92)
                .rotation3DEffect(.degrees(-10), axis: (x: 1, y: -0.5, z: 0))
                .overlay(dashboardContent.offset(y: 2))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: OneWayCallTheme.purple.opacity(0.36), radius: 18, x: 0, y: 10)
        }
    }

    private var dashboardContent: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(.white.opacity(0.22)).frame(width: 32, height: 4)
                animatedLine
                    .frame(width: 76, height: 34)
                HStack(spacing: 4) {
                    ForEach([0.45, 0.62, 0.35, 0.78], id: \.self) { value in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(OneWayCallTheme.purple.opacity(0.85))
                            .frame(width: 8, height: 24 * value + (animate ? 5 : 0))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(animate ? "12,540" : "12,318")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                Text("+20%")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.green)
                ZStack {
                    Circle().stroke(.white.opacity(0.14), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: animate ? 0.78 : 0.58)
                        .stroke(OneWayCallTheme.purple, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 42, height: 42)
                Text("LIVE")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.green)
            }
        }
    }

    private var animatedLine: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 26))
            path.addCurve(to: CGPoint(x: 25, y: animate ? 11 : 18), control1: CGPoint(x: 8, y: 18), control2: CGPoint(x: 15, y: 8))
            path.addCurve(to: CGPoint(x: 50, y: animate ? 18 : 10), control1: CGPoint(x: 34, y: 20), control2: CGPoint(x: 40, y: 26))
            path.addCurve(to: CGPoint(x: 76, y: animate ? 8 : 16), control1: CGPoint(x: 58, y: 8), control2: CGPoint(x: 66, y: 5))
        }
        .stroke(LinearGradient(colors: [OneWayCallTheme.purple, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing), lineWidth: 3)
    }
}

private func purpleBloom(x: CGFloat, y: CGFloat, radius: CGFloat) -> some View {
    RadialGradient(colors: [OneWayCallTheme.purple.opacity(0.55), .clear], center: .center, startRadius: 2, endRadius: radius)
        .frame(width: radius * 2, height: radius * 2)
        .offset(x: x, y: y)
}

private func floatingPanel(width: CGFloat, height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 8)
        .fill(Color.white.opacity(0.12))
        .frame(width: width, height: height)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .shadow(color: OneWayCallTheme.purple.opacity(0.24), radius: 12)
}

private var sparkleCluster: some View {
    ZStack {
        sparkle(size: 12).offset(x: 44, y: -40)
        sparkle(size: 8).offset(x: 22, y: -25)
        sparkle(size: 6).offset(x: 66, y: -18)
    }
}

private func sparkle(size: CGFloat) -> some View {
    ZStack {
        Capsule().fill(Color(hex: 0xCFA8FF)).frame(width: size * 0.28, height: size)
        Capsule().fill(Color(hex: 0xCFA8FF)).frame(width: size, height: size * 0.28)
    }
    .shadow(color: OneWayCallTheme.purple, radius: 8)
}

private func domainPill(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 8, weight: .black))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.42), in: Capsule())
        .overlay(Capsule().stroke(OneWayCallTheme.purple.opacity(0.45), lineWidth: 1))
}

private var sslShield: some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.green.opacity(0.18))
            .frame(width: 32, height: 38)
            .clipShape(ShieldShape())
        Text("SSL")
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(.green)
    }
}

private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.24))
        path.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 3, y: rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.24))
        path.closeSubpath()
        return path
    }
}
