import SwiftUI

enum OneWayBrandAsset {
    case appLogo
    case appLogoFullBleed
    case quantum

    var imageName: String {
        switch self {
        case .appLogo:
            return "OneWayOfficialLogo"
        case .appLogoFullBleed:
            return "OneWayLogoFullBleed"
        case .quantum:
            return "OneWaySculptedQuantum"
        }
    }
}

enum OneWayLogoContainerStyle {
    case none
    case roundedSquare
    case circle
}

enum OneWayLogoFillMode {
    case fullBleed
    case fit

    var contentMode: ContentMode {
        switch self {
        case .fullBleed: return .fill
        case .fit: return .fit
        }
    }
}

struct OneWayLogoView: View {
    var size: CGFloat = 44
    var containerStyle: OneWayLogoContainerStyle = .roundedSquare
    var fillMode: OneWayLogoFillMode = .fullBleed
    var selected: Bool = false
    var showsGlow: Bool = true
    var showsBorder: Bool = true
    var accessibilityLabel: String? = "OneWay"
    var decorative: Bool = false

    var body: some View {
        logo
            .frame(width: size, height: size)
            .clipShape(containerShape)
            .overlay(containerBorder)
            .shadow(
                color: OneWayDS.ColorToken.oneWayPurpleGlow.opacity(showsGlow ? (selected ? 0.36 : 0.22) : 0),
                radius: selected ? size * 0.26 : size * 0.18,
                x: 0,
                y: size * 0.08
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel ?? "OneWay")
            .accessibilityHidden(decorative)
    }

    private var logo: some View {
        Image(OneWayBrandAsset.appLogoFullBleed.imageName)
            .resizable()
            .renderingMode(.original)
            .aspectRatio(contentMode: fillMode.contentMode)
            .frame(width: size, height: size, alignment: .center)
            .clipped()
    }

    @ViewBuilder
    private var containerBorder: some View {
        if showsBorder {
            containerShape
                .stroke(OneWayDS.ColorToken.oneWayPurpleGlow.opacity(selected ? 0.62 : 0.34), lineWidth: 1)
        }
    }

    private var containerShape: AnyShape {
        switch containerStyle {
        case .none, .roundedSquare:
            return AnyShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        case .circle:
            return AnyShape(Circle())
        }
    }
}

struct OneWaySignatureCardShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = min(28, rect.height * 0.24)
        let notch: CGFloat = min(24, rect.width * 0.08)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius - notch, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX - notch * 0.18, y: rect.minY + radius * 0.9),
            control1: CGPoint(x: rect.maxX - radius * 0.5, y: rect.minY + radius * 0.08),
            control2: CGPoint(x: rect.maxX - notch * 0.44, y: rect.minY + radius * 0.08)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

enum OneWayCoreState: String, CaseIterable, Identifiable {
    case idle
    case active
    case receiving
    case sending
    case protected
    case pending
    case syncing
    case offline
    case error
    case completed
    case problem

    var id: String { rawValue }

    var colors: [Color] {
        switch self {
        case .idle:
            return [OneWayDS.ColorToken.oneWayPurpleBright, OneWayDS.ColorToken.oneWayPurpleSoft]
        case .active, .syncing:
            return [OneWayDS.ColorToken.oneWayPurpleGlow, OneWayDS.ColorToken.oneWayPurplePrimary]
        case .receiving, .completed:
            return [OneWayDS.ColorToken.success, OneWayDS.ColorToken.oneWayPurpleBright]
        case .sending:
            return [OneWayDS.ColorToken.transfer, OneWayDS.ColorToken.oneWayPurpleBright]
        case .protected:
            return [OneWayDS.ColorToken.oneWayPurpleBright, OneWayDS.ColorToken.success]
        case .pending:
            return [OneWayDS.ColorToken.warning, OneWayDS.ColorToken.oneWayPurpleSoft]
        case .offline:
            return [OneWayDS.ColorToken.textTertiary, OneWayDS.ColorToken.oneWayPurpleSoft.opacity(0.55)]
        case .error, .problem:
            return [OneWayDS.ColorToken.error, OneWayDS.ColorToken.oneWayPurpleSoft]
        }
    }

    var icon: String? {
        switch self {
        case .protected: return "shield.fill"
        case .completed: return "checkmark"
        case .error, .problem: return "exclamationmark"
        case .offline: return "wifi.slash"
        default: return nil
        }
    }
}

struct OneWayCoreView: View {
    let state: OneWayCoreState
    var size: CGFloat = 96
    var accent: Color? = nil
    var intensity: Double = 1
    var animated: Bool = true
    var accessibilityLabel: String = "OneWay Core"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotate = false
    @State private var breathe = false

    init(state: OneWayCoreState,
         size: CGFloat = 96,
         accent: Color? = nil,
         intensity: Double = 1,
         animated: Bool = true,
         accessibilityLabel: String = "OneWay Core") {
        self.state = state
        self.size = size
        self.accent = accent
        self.intensity = intensity
        self.animated = animated
        self.accessibilityLabel = accessibilityLabel
    }

    init(state: OneWayCoreState, reduceMotion: Bool) {
        self.init(state: state, animated: !reduceMotion)
    }

    var body: some View {
        let colors = adjustedColors

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [colors[0].opacity(0.9 * intensity), colors[1].opacity(0.5 * intensity), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: size * 0.58
                    )
                )
                .blur(radius: state == .offline ? 10 : 6)
                .scaleEffect(breathe ? 1.06 : 0.96)

            OneWayCinematicAssetView(
                asset: .oneWayCore,
                motion: animated ? .orbital : .none,
                intensity: intensity
            )
            .frame(width: size * 1.14, height: size * 1.14)
            .opacity(state == .offline ? 0.45 : 0.94)
            .accessibilityHidden(true)

            Circle()
                .stroke(colors[0].opacity(0.35), lineWidth: 1.2)
                .padding(size * 0.07)

            Circle()
                .trim(from: 0.05, to: 0.58)
                .stroke(
                    AngularGradient(colors: [colors[0], colors[1], .clear], center: .center),
                    style: StrokeStyle(lineWidth: max(2, size * 0.042), lineCap: .round)
                )
                .padding(size * 0.10)
                .rotationEffect(.degrees(rotate ? 360 : 0))

            Circle()
                .trim(from: 0.68, to: 0.9)
                .stroke(Color.white.opacity(0.34), style: StrokeStyle(lineWidth: max(1.2, size * 0.02), lineCap: .round))
                .padding(size * 0.23)
                .rotationEffect(.degrees(rotate ? -260 : 0))

            if let icon = state.icon {
                OneWayResolvedIcon(systemName: icon)
                    .font(.system(size: size * 0.24, weight: .black))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: colors[0].opacity(0.6), radius: size * 0.1, x: 0, y: 0)
            } else {
                Circle()
                    .fill(Color.white.opacity(state == .offline ? 0.2 : 0.72))
                    .frame(width: size * 0.15, height: size * 0.15)
                    .shadow(color: colors[0].opacity(0.75), radius: size * 0.13, x: 0, y: 0)
            }
        }
        .frame(width: size, height: size)
        .opacity(state == .offline ? 0.64 : 1)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            guard animated, !reduceMotion else { return }
            withAnimation(.linear(duration: state == .pending ? 5.5 : 8.5).repeatForever(autoreverses: false)) {
                rotate = true
            }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    private var adjustedColors: [Color] {
        guard let accent else { return state.colors }
        return [accent, state.colors.last ?? accent]
    }
}

struct OneWayLivingLight: ViewModifier {
    var color: Color = OneWayDS.ColorToken.oneWayPurpleGlow
    var intensity: Double = 0.16
    var focused: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    func body(content: Content) -> some View {
        content
            .overlay {
                LinearGradient(colors: [.clear, color.opacity(focused ? intensity * 1.7 : intensity), .clear], startPoint: .top, endPoint: .bottom)
                    .rotationEffect(.degrees(22))
                    .offset(x: sweep && !reduceMotion ? 260 : -260)
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: OneWayDS.Motion.ambient).repeatForever(autoreverses: false)) {
                    sweep = true
                }
            }
    }
}

struct OneWayStatusBadge: View {
    let status: OneWayStatusKind

    var body: some View {
        OneWayResolvedLabel(status.text, systemImage: status.icon)
            .font(OneWayDS.Typography.statusLabel)
            .foregroundStyle(status.color)
            .padding(.horizontal, OneWayDS.Spacing.md)
            .padding(.vertical, OneWayDS.Spacing.sm)
            .background(status.color.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(status.color.opacity(0.34), lineWidth: 1))
            .accessibilityLabel(status.accessibilityDescription)
    }
}

extension View {
    func oneWayLivingLight(color: Color = OneWayDS.ColorToken.oneWayPurpleGlow,
                           intensity: Double = 0.16,
                           focused: Bool = false) -> some View {
        modifier(OneWayLivingLight(color: color, intensity: intensity, focused: focused))
    }

    func oneWayCardGlow(_ color: Color = OneWayDS.ColorToken.oneWayPurpleGlow, opacity: Double = 0.16) -> some View {
        shadow(color: color.opacity(opacity), radius: 24, x: 0, y: 14)
    }

    func oneWayFocusedGlow(_ color: Color = OneWayDS.ColorToken.oneWayPurpleGlow) -> some View {
        shadow(color: color.opacity(0.36), radius: 24, x: 0, y: 12)
    }
}
