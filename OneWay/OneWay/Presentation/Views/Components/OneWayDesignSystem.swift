import SwiftUI
import UIKit

enum OneWayDesignSystem {
    enum Colors {
        static let backgroundPrimary = Color(hex: 0x05040C)
        static let backgroundSecondary = Color(hex: 0x0B0816)
        static let panel = Color(hex: 0x110D21)
        static let panelElevated = Color(hex: 0x1B1430)
        static let panelGlass = Color(hex: 0x110D21).opacity(0.72)
        static let purplePrimary = Color(hex: 0x9B5CFF)
        static let purpleGlow = Color(hex: 0xB86CFF)
        static let purpleSoft = Color(hex: 0x4B2C96)
        static let textPrimary = Color(hex: 0xFFFFFF)
        static let textSecondary = Color(hex: 0xC8C1EA)
        static let textMuted = Color(hex: 0x8D86AA)
        static let borderSubtle = Color(hex: 0x8F5CEB).opacity(0.30)
        static let warmWhite = backgroundPrimary
        static let frost = backgroundSecondary
        static let background = backgroundPrimary
        static let surface = panel
        static let elevatedSurface = panelElevated
        static let lavender = Color(hex: 0x211846)
        static let purple = purplePrimary
        static let deepPurple = Color(hex: 0x120728)
        static let mint = Color(hex: 0x22C55E)
        static let warning = Color(hex: 0xF59E0B)
        static let danger = Color(hex: 0xEF4444)
        static let success = mint
        static let text = textPrimary
        static let secondaryText = textSecondary
        static let faintText = textMuted
        static let border = borderSubtle
        static let purpleGradient = LinearGradient(
            colors: [Color(hex: 0xC76BFF), Color(hex: 0x7C3DFF), Color(hex: 0x4A27D9)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    enum Spacing {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
        static let xl: CGFloat = 30
        static let xxl: CGFloat = 42
        static let page: CGFloat = 18
        static let card: CGFloat = 16
    }

    enum Radius {
        static let small: CGFloat = 12
        static let medium: CGFloat = 18
        static let large: CGFloat = 24
        static let extraLarge: CGFloat = 32
        static let pill: CGFloat = 999
        static let card: CGFloat = 24
        static let control: CGFloat = 18
    }

    enum Typography {
        static let heroTitle = Font.system(size: 42, weight: .black, design: .rounded)
        static let sectionTitle = Font.system(.title2, design: .rounded, weight: .bold)
        static let cardTitle = Font.system(.title3, design: .rounded, weight: .bold)
        static let body = Font.body
        static let secondary = Font.subheadline.weight(.semibold)
        static let caption = Font.caption.weight(.bold)
        static let tabLabel = Font.caption2.weight(.bold)
    }
}

struct OneWayTitleText: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(OneWayDesignSystem.Colors.text)
    }
}

struct OneWayBodyText: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(OneWayDesignSystem.Colors.text)
    }
}

struct OneWaySecondaryText: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
    }
}

struct OneWayFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(OneWayDesignSystem.Colors.text)
            .tint(OneWayDesignSystem.Colors.purple)
            .padding(12)
            .background(OneWayDesignSystem.Colors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
    }
}

struct OneWayCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(OneWayDesignSystem.Colors.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
            .shadow(color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.06), radius: 12, x: 0, y: 6)
    }
}

struct OneWaySectionHeader: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.headline.weight(.black))
            .foregroundStyle(OneWayDesignSystem.Colors.text)
    }
}

struct OneWayLightBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                OneWayDesignSystem.Colors.backgroundPrimary,
                OneWayDesignSystem.Colors.backgroundSecondary,
                OneWayDesignSystem.Colors.deepPurple,
                Color.black
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            Circle()
                .fill(OneWayDesignSystem.Colors.purpleGlow.opacity(0.10))
                .frame(width: 360, height: 180)
                .blur(radius: 72)
                .offset(y: 120)
        }
        .ignoresSafeArea()
    }
}

typealias OneWayScreenBackground = OneWayLightBackground

struct OneWayLogoMark: View {
    var size: CGFloat = 38
    var body: some View {
        OneWayLogoView(
            size: size,
            containerStyle: .roundedSquare,
            fillMode: .fullBleed,
            showsGlow: true,
            showsBorder: false
        )
    }
}

struct OneWayCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder var content: Content

    init(padding: CGFloat = OneWayDesignSystem.Spacing.card, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .oneWayCinematicGlass(cornerRadius: OneWayDesignSystem.Radius.card)
    }
}

typealias OneWayGlassCard = OneWayCard

enum OneWayReadableTextRole {
    case title
    case body
    case subtitle
    case muted
    case inverse
    case buttonOnPurple
}

struct OneWayReadableText: ViewModifier {
    let role: OneWayReadableTextRole

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }

    private var color: Color {
        switch role {
        case .title, .body:
            return OneWayDesignSystem.Colors.text
        case .subtitle:
            return OneWayDesignSystem.Colors.secondaryText
        case .muted:
            return OneWayDesignSystem.Colors.faintText
        case .inverse, .buttonOnPurple:
            return .white
        }
    }
}

extension View {
    func oneWayReadableText(_ role: OneWayReadableTextRole = .body) -> some View {
        modifier(OneWayReadableText(role: role))
    }

    func oneWayTitleText() -> some View { modifier(OneWayTitleText()) }
    func oneWayBodyText() -> some View { modifier(OneWayBodyText()) }
    func oneWaySecondaryText() -> some View { modifier(OneWaySecondaryText()) }
    func oneWayLightFieldStyle() -> some View { modifier(OneWayFieldStyle()) }
    func oneWayCardStyle(cornerRadius: CGFloat = 24) -> some View { modifier(OneWayCardStyle(cornerRadius: cornerRadius)) }
    func oneWaySectionHeader() -> some View { modifier(OneWaySectionHeader()) }

    /// Shared keyboard protection for OneWay input surfaces. Scroll views
    /// inherit interactive dismissal, Return resigns the active field, and a
    /// native keyboard toolbar always provides an explicit Done action.
    func oneWayKeyboardManaged() -> some View {
        modifier(OneWayKeyboardManagementModifier())
    }
}

private struct OneWayKeyboardManagementModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .onSubmit { OneWayKeyboard.dismiss() }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { OneWayKeyboard.dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("keyboard.done")
                }
            }
    }
}

enum OneWayKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

struct OneWaySearchBar: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: "magnifyingglass")
                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            TextField(placeholder, text: $text)
                .foregroundStyle(OneWayDesignSystem.Colors.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.asciiCapable)
            OneWayResolvedIcon(systemName: "sparkles")
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OneWayDesignSystem.Colors.surface, in: Capsule())
        .overlay(Capsule().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
    }
}

struct OneWayChip: View {
    let title: String
    var isSelected: Bool = false

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(isSelected ? .white : OneWayDesignSystem.Colors.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isSelected ? AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient) : AnyShapeStyle(OneWayDesignSystem.Colors.surface), in: Capsule())
            .overlay(Capsule().stroke(isSelected ? Color.clear : OneWayDesignSystem.Colors.border, lineWidth: 1))
    }
}

struct OneWayAvatar: View {
    let name: String
    var size: CGFloat = 52
    var verified: Bool = false
    var online: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [OneWayDesignSystem.Colors.lavender, OneWayDesignSystem.Colors.elevatedSurface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay {
                    Text(initials)
                        .font(.system(size: size * 0.34, weight: .black))
                        .foregroundStyle(OneWayDesignSystem.Colors.purple)
                }
                .overlay(Circle().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))

            if online {
                Circle()
                    .fill(OneWayDesignSystem.Colors.mint)
                    .frame(width: size * 0.22, height: size * 0.22)
                    .overlay(Circle().stroke(OneWayDesignSystem.Colors.elevatedSurface, lineWidth: 2))
            }

            if verified {
                OneWayResolvedIcon(systemName: "checkmark.seal.fill")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                    .background(OneWayDesignSystem.Colors.elevatedSurface, in: Circle())
                    .offset(x: -size * 0.52, y: size * 0.02)
            }
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "OW" : String(letters)
    }
}

/// A shared field surface for native forms; keeps the platform's input behavior.
struct OneWayFormFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .foregroundStyle(OneWayDesignSystem.Colors.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(OneWayDesignSystem.Colors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
    }
}
