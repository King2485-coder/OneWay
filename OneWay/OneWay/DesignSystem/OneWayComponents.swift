import SwiftUI

struct OneWaySignatureCard<Content: View>: View {
    var variant: Variant = .standard
    var status: OneWayStatusKind? = nil
    var livingLight = true
    @ViewBuilder var content: Content

    enum Variant {
        case hero
        case standard
        case compact
        case list
        case warning
        case security
        case loading

        var padding: CGFloat {
            switch self {
            case .hero: return 20
            case .standard, .warning, .security, .loading: return 16
            case .compact, .list: return 12
            }
        }

        var shadowOpacity: Double {
            switch self {
            case .hero: return 0.34
            case .warning: return 0.20
            case .loading, .list: return 0.10
            default: return 0.16
            }
        }
    }

    var body: some View {
        content
            .padding(variant.padding)
            .background(cardBackground)
            .clipShape(OneWaySignatureCardShape())
            .overlay(OneWaySignatureCardShape().stroke(borderColor, lineWidth: 1))
            .oneWayCardGlow(glowColor, opacity: variant.shadowOpacity)
            .modifier(LivingLightGate(enabled: livingLight, color: glowColor))
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                OneWayDS.ColorToken.backgroundGlass,
                OneWayDS.ColorToken.backgroundElevated.opacity(0.88)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var borderColor: Color {
        status?.color.opacity(0.44) ?? OneWayDS.ColorToken.borderStandard
    }

    private var glowColor: Color {
        status?.color ?? OneWayDS.ColorToken.oneWayPurpleGlow
    }
}

private struct LivingLightGate: ViewModifier {
    let enabled: Bool
    let color: Color

    func body(content: Content) -> some View {
        if enabled {
            content.oneWayLivingLight(color: color, intensity: 0.10)
        } else {
            content
        }
    }
}

struct OneWayGlassSurface<Content: View>: View {
    var radius: CGFloat = OneWayDS.Radius.xl
    var padding: CGFloat = OneWayDS.Spacing.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(OneWayDS.ColorToken.backgroundGlass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(OneWayDS.ColorToken.borderSubtle, lineWidth: 1))
            .oneWayCardGlow()
    }
}

struct OneWayStatusCard: View {
    let title: String
    let value: String
    let subtitle: String
    let status: OneWayStatusKind
    let icon: String
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button {
                    OneWayHaptics.lightTap()
                    action()
                } label: {
                    content
                }
                .buttonStyle(OneWayCardButtonStyle())
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value). \(subtitle). \(status.text).")
    }

    private var content: some View {
        OneWaySignatureCard(variant: .compact, status: status, livingLight: false) {
            VStack(alignment: .leading, spacing: OneWayDS.Spacing.sm) {
                OneWayIconContainer(systemName: icon, color: status.color, size: .medium)
                Text(title)
                    .font(OneWayDS.Typography.caption)
                    .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(value)
                    .font(OneWayDS.Typography.amountMedium)
                    .foregroundStyle(OneWayDS.ColorToken.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                HStack(spacing: OneWayDS.Spacing.xs) {
                    Text(subtitle)
                    Spacer(minLength: 2)
                    if action != nil {
                        OneWayResolvedIcon(systemName: "chevron.right")
                    }
                }
                .font(OneWayDS.Typography.metadata)
                .foregroundStyle(status.color)
            }
        }
    }
}

struct OneWayActionTile: View {
    let title: String
    let icon: String
    var isEnabled = true
    var isLoading = false
    var status: OneWayStatusKind? = nil
    let action: () -> Void

    var body: some View {
        Button {
            OneWayHaptics.lightTap()
            action()
        } label: {
            VStack(spacing: OneWayDS.Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .tint(OneWayDS.ColorToken.oneWayPurpleBright)
                        .frame(width: 42, height: 42)
                } else {
                    OneWayIconContainer(systemName: icon, color: isEnabled ? OneWayDS.ColorToken.oneWayPurpleBright : OneWayDS.ColorToken.textDisabled, size: .large)
                }
                Text(title)
                    .font(OneWayDS.Typography.metadata)
                    .foregroundStyle(isEnabled ? OneWayDS.ColorToken.textPrimary : OneWayDS.ColorToken.textDisabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let status {
                    Text(status.text)
                        .font(OneWayDS.Typography.metadata)
                        .foregroundStyle(status.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, OneWayDS.Spacing.md)
            .background(OneWayDS.ColorToken.backgroundGlass, in: RoundedRectangle(cornerRadius: OneWayDS.Radius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OneWayDS.Radius.large).stroke(OneWayDS.ColorToken.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(OneWayCardButtonStyle())
        .disabled(isLoading)
        .accessibilityLabel(title)
    }
}

struct OneWayPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OneWayDS.Typography.buttonPrimary)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: OneWayDS.Spacing.buttonHeight)
            .background(
                LinearGradient(colors: [OneWayDS.ColorToken.oneWayPurpleGlow, OneWayDS.ColorToken.oneWayPurplePrimary, OneWayDS.ColorToken.oneWayPurpleSoft], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule()
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(OneWayDS.Motion.buttonPress, value: configuration.isPressed)
            .oneWayFocusedGlow()
    }
}

struct OneWaySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OneWayDS.Typography.buttonSecondary)
            .foregroundStyle(OneWayDS.ColorToken.textPrimary)
            .frame(maxWidth: .infinity, minHeight: OneWayDS.Spacing.buttonHeight)
            .background(OneWayDS.ColorToken.backgroundGlass, in: Capsule())
            .overlay(Capsule().stroke(OneWayDS.ColorToken.borderStandard, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(OneWayDS.Motion.buttonPress, value: configuration.isPressed)
    }
}

struct OneWayTertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OneWayDS.Typography.buttonSecondary)
            .foregroundStyle(OneWayDS.ColorToken.oneWayPurpleGlow)
            .padding(.horizontal, OneWayDS.Spacing.md)
            .padding(.vertical, OneWayDS.Spacing.sm)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(OneWayDS.Motion.buttonPress, value: configuration.isPressed)
    }
}

struct OneWayDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OneWayDS.Typography.buttonSecondary)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: OneWayDS.Spacing.buttonHeight)
            .background(OneWayDS.ColorToken.error, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(OneWayDS.Motion.buttonPress, value: configuration.isPressed)
            .shadow(color: OneWayDS.Shadow.danger, radius: 18, x: 0, y: 8)
    }
}

struct OneWayCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .shadow(color: OneWayDS.ColorToken.oneWayPurpleGlow.opacity(configuration.isPressed ? 0.2 : 0), radius: configuration.isPressed ? 18 : 0, x: 0, y: 10)
            .animation(OneWayDS.Motion.buttonPress, value: configuration.isPressed)
    }
}

enum OneWayIconSize {
    case small
    case medium
    case large
    case hero

    var frame: CGFloat {
        switch self {
        case .small: return 28
        case .medium: return 34
        case .large: return 42
        case .hero: return 58
        }
    }

    var font: Font {
        switch self {
        case .small: return .caption.weight(.black)
        case .medium: return .subheadline.weight(.black)
        case .large: return .title3.weight(.black)
        case .hero: return .title.weight(.black)
        }
    }
}

struct OneWayIconContainer: View {
    let systemName: String
    var color: Color = OneWayDS.ColorToken.oneWayPurpleBright
    var size: OneWayIconSize = .medium

    var body: some View {
        Group {
            if let role = OneWayIconRole.resolve(systemName: systemName) {
                OneWayPhysicalIcon(
                    role: role,
                    size: size.frame,
                    container: .feature,
                    accessibilityLabel: role.defaultAccessibilityLabel,
                    glowIntensity: 0.08
                )
            } else {
                OneWayResolvedIcon(systemName: systemName)
                    .font(size.font)
                    .foregroundStyle(color)
                    .frame(width: size.frame, height: size.frame)
                    .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size.frame * 0.32, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size.frame * 0.32).stroke(color.opacity(0.30), lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }
}

struct OneWayNavigationBar<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let onBack: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: OneWayDS.Spacing.navBarSpacing) {
            if let onBack {
                Button {
                    OneWayHaptics.lightTap()
                    onBack()
                } label: {
                    OneWayResolvedIcon(systemName: "chevron.left")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayDS.ColorToken.textPrimary)
                        .frame(width: 42, height: 42)
                        .background(OneWayDS.ColorToken.backgroundGlass, in: Circle())
                        .overlay(Circle().stroke(OneWayDS.ColorToken.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(OneWayCardButtonStyle())
                .accessibilityLabel("Back")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OneWayDS.Typography.pageTitle)
                    .foregroundStyle(OneWayDS.ColorToken.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let subtitle {
                    Text(subtitle)
                        .font(OneWayDS.Typography.caption)
                        .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            Spacer(minLength: OneWayDS.Spacing.sm)
            trailing
        }
    }
}

struct OneWayTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var validation: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: OneWayDS.Spacing.sm) {
            Text(title)
                .font(OneWayDS.Typography.caption)
                .foregroundStyle(OneWayDS.ColorToken.textSecondary)
            TextField(placeholder, text: $text)
                .foregroundStyle(OneWayDS.ColorToken.textPrimary)
                .tint(OneWayDS.ColorToken.oneWayPurpleBright)
                .padding(OneWayDS.Spacing.md)
                .background(OneWayDS.ColorToken.backgroundGlass, in: RoundedRectangle(cornerRadius: OneWayDS.Radius.medium, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OneWayDS.Radius.medium).stroke(validation == nil ? OneWayDS.ColorToken.borderSubtle : OneWayDS.ColorToken.error, lineWidth: 1))
            if let validation {
                OneWayResolvedLabel(validation, systemImage: "exclamationmark.circle.fill")
                    .font(OneWayDS.Typography.caption)
                    .foregroundStyle(OneWayDS.ColorToken.error)
            }
        }
    }
}

struct OneWayNavigationRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let status: OneWayStatusKind?
    var showChevron = true
    let action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Group {
            if let action {
                Button {
                    OneWayHaptics.lightTap()
                    action()
                } label: {
                    rowContent
                }
                .buttonStyle(OneWayCardButtonStyle())
            } else {
                rowContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, subtitle, status?.text].compactMap { $0 }.joined(separator: ", "))
    }

    private var rowContent: some View {
        HStack(spacing: OneWayDS.Spacing.md) {
            OneWayIconContainer(systemName: icon, color: status?.color ?? OneWayDS.ColorToken.oneWayPurpleBright)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OneWayDS.Typography.bodyLarge)
                    .foregroundStyle(OneWayDS.ColorToken.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(OneWayDS.Typography.caption)
                        .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            trailing
            if let status {
                OneWayStatusBadge(status: status)
            }
            if showChevron, action != nil {
                OneWayResolvedIcon(systemName: "chevron.right")
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayDS.ColorToken.textTertiary)
            }
        }
        .frame(minHeight: OneWayDS.Spacing.rowMinHeight)
        .padding(.vertical, OneWayDS.Spacing.xs)
    }
}

extension OneWayNavigationRow where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil, status: OneWayStatusKind? = nil, showChevron: Bool = true, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.showChevron = showChevron
        self.action = action
        self.trailing = EmptyView()
    }
}

struct OneWayEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        OneWayGlassSurface {
            VStack(spacing: OneWayDS.Spacing.md) {
                OneWayIconContainer(systemName: icon, color: OneWayDS.ColorToken.oneWayPurpleBright, size: .hero)
                Text(title)
                    .font(OneWayDS.Typography.cardTitle)
                    .foregroundStyle(OneWayDS.ColorToken.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(OneWayDS.Typography.body)
                    .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                    .multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle) {
                        OneWayHaptics.lightTap()
                        action()
                    }
                    .buttonStyle(OneWayPrimaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct OneWayErrorState: View {
    let title: String
    let message: String
    var status: OneWayStatusKind = .warning
    var retry: (() -> Void)? = nil

    var body: some View {
        OneWaySignatureCard(variant: .warning, status: status, livingLight: false) {
            VStack(alignment: .leading, spacing: OneWayDS.Spacing.md) {
                HStack(alignment: .top, spacing: OneWayDS.Spacing.md) {
                    OneWayIconContainer(systemName: status.icon, color: status.color, size: .large)
                    VStack(alignment: .leading, spacing: OneWayDS.Spacing.xs) {
                        Text(title)
                            .font(OneWayDS.Typography.cardTitle)
                            .foregroundStyle(OneWayDS.ColorToken.textPrimary)
                        Text(message)
                            .font(OneWayDS.Typography.body)
                            .foregroundStyle(OneWayDS.ColorToken.textSecondary)
                    }
                }
                if let retry {
                    Button {
                        OneWayHaptics.lightTap()
                        retry()
                    } label: {
                        OneWayResolvedLabel("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(OneWaySecondaryButtonStyle())
                }
            }
        }
    }
}

struct OneWaySkeletonCard: View {
    var height: CGFloat = 118
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: OneWayDS.Radius.xl, style: .continuous)
            .fill(OneWayDS.ColorToken.backgroundGlass)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: OneWayDS.Spacing.sm) {
                    RoundedRectangle(cornerRadius: 4).fill(OneWayDS.ColorToken.textTertiary.opacity(0.24)).frame(width: 84, height: 9)
                    RoundedRectangle(cornerRadius: 5).fill(OneWayDS.ColorToken.textSecondary.opacity(0.18)).frame(width: 132, height: 18)
                    RoundedRectangle(cornerRadius: 4).fill(OneWayDS.ColorToken.textTertiary.opacity(0.18)).frame(width: 96, height: 8)
                }
                .padding(OneWayDS.Spacing.lg)
            }
            .overlay {
                if !reduceMotion {
                    LinearGradient(colors: [.clear, .white.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom)
                        .rotationEffect(.degrees(18))
                        .offset(x: shimmer ? 220 : -220)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: OneWayDS.Radius.xl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: OneWayDS.Radius.xl).stroke(OneWayDS.ColorToken.borderSubtle, lineWidth: 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    shimmer = true
                }
            }
    }
}
