import SwiftUI

enum OneWayDS {
    enum ColorToken {
        static let oneWayPurplePrimary = Color(hex: 0x8B5CF6)
        static let oneWayPurpleBright = Color(hex: 0xA855F7)
        static let oneWayPurpleDeep = Color(hex: 0x2E1065)
        static let oneWayPurpleSoft = Color(hex: 0x6D28D9)
        static let oneWayPurpleGlow = Color(hex: 0xC084FC)

        static let backgroundPrimary = Color(hex: 0x02030B)
        static let backgroundSecondary = Color(hex: 0x070B1B)
        static let backgroundElevated = Color(hex: 0x11152E)
        static let backgroundGlass = Color(hex: 0x171A34).opacity(0.82)
        static let backgroundOverlay = Color.black.opacity(0.42)

        static let textPrimary = Color.white
        static let textSecondary = Color(hex: 0xCBC3EE)
        static let textTertiary = Color(hex: 0x958DB5)
        static let textDisabled = Color(hex: 0x6B6383)
        static let textInverse = Color(hex: 0x171321)

        static let borderSubtle = Color(hex: 0x7D48FF).opacity(0.28)
        static let borderStandard = Color(hex: 0x8B5CF6).opacity(0.42)
        static let borderFocused = Color(hex: 0xC084FC)
        static let borderElevated = Color.white.opacity(0.18)

        static let success = Color(hex: 0x22C55E)
        static let warning = Color(hex: 0xF59E0B)
        static let error = Color(hex: 0xEF4444)
        static let info = Color(hex: 0x60A5FA)
        static let transfer = Color(hex: 0x4F8CFF)
        static let pending = warning
        static let security = oneWayPurpleBright
        static let neutral = Color(hex: 0xA7A1BC)
    }

    enum Typography {
        static let displayLarge = Font.system(size: 44, weight: .black, design: .rounded)
        static let displayMedium = Font.system(size: 36, weight: .black, design: .rounded)
        static let pageTitle = Font.system(size: 28, weight: .black, design: .rounded)
        static let sectionTitle = Font.system(size: 22, weight: .bold, design: .rounded)
        static let cardTitle = Font.system(size: 18, weight: .bold, design: .rounded)
        static let bodyLarge = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 15, weight: .regular)
        static let bodySmall = Font.system(size: 13, weight: .regular)
        static let caption = Font.system(size: 12, weight: .semibold)
        static let metadata = Font.system(size: 11, weight: .bold)
        static let amountHero = Font.system(size: 38, weight: .black, design: .rounded)
        static let amountLarge = Font.system(size: 28, weight: .black, design: .rounded)
        static let amountMedium = Font.system(size: 21, weight: .black, design: .rounded)
        static let amountSmall = Font.system(size: 15, weight: .bold, design: .rounded)
        static let buttonPrimary = Font.system(size: 16, weight: .black)
        static let buttonSecondary = Font.system(size: 14, weight: .bold)
        static let statusLabel = Font.system(size: 12, weight: .black)
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        static let giant: CGFloat = 40
        static let huge: CGFloat = 48
        static let massive: CGFloat = 64

        static let screenPadding: CGFloat = 18
        static let sectionSpacing: CGFloat = 24
        static let cardPadding: CGFloat = 16
        static let rowMinHeight: CGFloat = 56
        static let iconLabelGap: CGFloat = 10
        static let buttonHeight: CGFloat = 52
        static let navBarSpacing: CGFloat = 12
    }

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 18
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let pill: CGFloat = 999
        static let signature: CGFloat = 28
    }

    enum Shadow {
        static let card = ColorToken.oneWayPurpleGlow.opacity(0.16)
        static let elevated = ColorToken.oneWayPurpleGlow.opacity(0.24)
        static let focused = ColorToken.oneWayPurpleGlow.opacity(0.38)
        static let danger = ColorToken.error.opacity(0.22)
    }

    enum Motion {
        static let instant: Double = 0.08
        static let quick: Double = 0.18
        static let standard: Double = 0.28
        static let relaxed: Double = 0.45
        static let ambient: Double = 3.8

        static let buttonPress = Animation.spring(response: 0.24, dampingFraction: 0.82)
        static let cardLift = Animation.spring(response: 0.30, dampingFraction: 0.86)
        static let sheetOpen = Animation.spring(response: 0.38, dampingFraction: 0.88)
        static let contentReveal = Animation.easeOut(duration: standard)
        static let statusChange = Animation.easeInOut(duration: quick)
    }
}

enum OneWayStatusKind: String, CaseIterable, Identifiable {
    case available
    case pending
    case processing
    case active
    case complete
    case secure
    case warning
    case failed
    case blocked
    case offline
    case disabled
    case scheduled
    case paused
    case suspended

    var id: String { rawValue }

    var text: String {
        switch self {
        case .available: return "Available"
        case .pending: return "Pending"
        case .processing: return "Processing"
        case .active: return "Active"
        case .complete: return "Complete"
        case .secure: return "Secure"
        case .warning: return "Needs Review"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .offline: return "Offline"
        case .disabled: return "Disabled"
        case .scheduled: return "Scheduled"
        case .paused: return "Paused"
        case .suspended: return "Suspended"
        }
    }

    var icon: String {
        switch self {
        case .available, .complete: return "checkmark.circle.fill"
        case .pending, .processing, .scheduled: return "clock.fill"
        case .active: return "bolt.circle.fill"
        case .secure: return "lock.shield.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed, .blocked: return "xmark.octagon.fill"
        case .offline: return "wifi.slash"
        case .disabled: return "minus.circle.fill"
        case .paused: return "pause.circle.fill"
        case .suspended: return "hand.raised.fill"
        }
    }

    var color: Color {
        switch self {
        case .available, .complete, .secure: return OneWayDS.ColorToken.success
        case .pending, .processing, .scheduled, .warning: return OneWayDS.ColorToken.warning
        case .active: return OneWayDS.ColorToken.oneWayPurpleBright
        case .failed, .blocked, .suspended: return OneWayDS.ColorToken.error
        case .offline, .disabled, .paused: return OneWayDS.ColorToken.textTertiary
        }
    }

    var accessibilityDescription: String {
        "\(text) status"
    }
}

enum OneWayHaptics {
    static func lightTap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    static func error() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}
