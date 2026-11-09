import SwiftUI
import UIKit

enum OneWayIconRole: String, CaseIterable, Hashable {
    case quantum
    case quantumOrb
    case newSite
    case siteBuilderConsole
    case websiteBuilderDesktop
    case aiBuilder
    case newShop
    case shopBuilderTerminal
    case onlineStorefrontBuilder
    case storeBuilder
    case community
    case create
    case calls
    case shops
    case messages
    case videoCall
    case chirp
    case contacts
    case wallet
    case cloud
    case workspace
    case sites
    case storefront
    case product
    case package
    case orders
    case receipt
    case sellerID
    case plans
    case capacity
    case permanentCapacity
    case privacy
    case encryption
    case settings
    case profile
    case notifications
    case search
    case back
    case forward
    case history
    case bookmarks
    case downloads
    case email
    case calendar
    case files
    case camera
    case microphone
    case speaker
    case endCall
    case addPerson
    case group
    case block
    case report
    case delete
    case edit
    case share
    case success
    case warning
    case error
    case homeLiving
    case decor
    case kitchen
    case furniture
    case lighting
    case jewelry
    case artCollectibles
    case beauty
    case tech
    case clothing
    case vintage
    case messageSettings
    case productQuestion
    case customRequest
    case orderMessage
    case attachments
    case links
    case autoClose
    case orderNumber
    case unread
    case blocked
    case seller
    case paymentSetup
    case sales
    case visitors
    case favorites
    case savedShops
    case paymentPrivacy
    case shopSettings
    case cameraSearch
    case quickAdd
    case dialerDevice
    case oneWayID
    case secureContact
    case privacyShield
    case keypadDigit
    case call
    case video
    case deleteDigit
    case recents
    case keypad
    case voicemail
    case backToHome
    case phoneFavorites
    case account
    case oneWayApp
    case chevron
    case templates
    case media
    case analytics
    case oneWayAds
    case uploadFile

    var assetName: String? {
        if self == .oneWayApp { return OneWayBrandAsset.appLogoFullBleed.imageName }
        return OneWaySculptedCatalog.roleAssets[rawValue].map { "OneWaySculpted" + $0 }
    }

    var fallbackSystemName: String {
        switch self {
        case .quantum, .quantumOrb: return "atom"
        case .newSite, .siteBuilderConsole, .websiteBuilderDesktop: return "macwindow"
        case .aiBuilder: return "sparkles"
        case .newShop, .shopBuilderTerminal, .onlineStorefrontBuilder, .storeBuilder: return "storefront.fill"
        case .community, .group: return "person.3.fill"
        case .create: return "plus"
        case .calls: return "phone.fill"
        case .shops, .storefront: return "storefront.fill"
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .videoCall, .camera: return "video.fill"
        case .chirp: return "dot.radiowaves.left.and.right"
        case .contacts: return "person.crop.rectangle.stack.fill"
        case .wallet: return "wallet.pass.fill"
        case .cloud: return "cloud.fill"
        case .workspace: return "rectangle.3.group.fill"
        case .sites: return "macwindow"
        case .product, .package: return "shippingbox.fill"
        case .orders: return "list.clipboard.fill"
        case .receipt, .history: return "receipt.fill"
        case .sellerID: return "tag.fill"
        case .plans: return "checklist"
        case .capacity: return "square.grid.2x2.fill"
        case .permanentCapacity, .success: return "checkmark.seal.fill"
        case .privacy: return "shield.fill"
        case .encryption: return "lock.fill"
        case .settings: return "gearshape.fill"
        case .profile: return "person.crop.circle.fill"
        case .notifications: return "bell.fill"
        case .search: return "magnifyingglass"
        case .back: return "chevron.left"
        case .forward: return "chevron.right"
        case .bookmarks: return "bookmark.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .email: return "envelope.fill"
        case .calendar: return "calendar"
        case .files: return "folder.fill"
        case .microphone: return "mic.fill"
        case .speaker: return "speaker.wave.2.fill"
        case .endCall: return "phone.down.fill"
        case .addPerson: return "person.badge.plus"
        case .block: return "hand.raised.fill"
        case .report, .warning: return "exclamationmark.triangle.fill"
        case .delete: return "trash.fill"
        case .edit: return "pencil"
        case .share: return "square.and.arrow.up"
        case .error: return "xmark.octagon.fill"
        case .homeLiving, .decor, .furniture: return "house.fill"
        case .kitchen: return "cup.and.saucer.fill"
        case .lighting: return "lamp.floor.fill"
        case .jewelry: return "sparkles"
        case .artCollectibles: return "paintpalette.fill"
        case .beauty: return "bubbles.and.sparkles.fill"
        case .tech: return "headphones"
        case .clothing: return "tshirt.fill"
        case .vintage: return "camera.fill"
        case .messageSettings, .shopSettings: return "slider.horizontal.3"
        case .productQuestion: return "questionmark.square.fill"
        case .customRequest: return "note.text"
        case .orderMessage: return "list.clipboard.fill"
        case .attachments: return "paperclip"
        case .links: return "link"
        case .autoClose: return "clock.fill"
        case .orderNumber: return "number.square.fill"
        case .unread: return "envelope.badge.fill"
        case .blocked: return "hand.raised.fill"
        case .seller, .savedShops: return "storefront.fill"
        case .paymentSetup, .paymentPrivacy: return "creditcard.fill"
        case .sales: return "cashregister.fill"
        case .visitors: return "person.3.fill"
        case .favorites: return "heart.fill"
        case .cameraSearch: return "camera.fill"
        case .quickAdd: return "plus.circle.fill"
        case .dialerDevice: return "phone.fill"
        case .oneWayID: return "tag.fill"
        case .secureContact: return "person.crop.circle.fill"
        case .privacyShield: return "shield.fill"
        case .keypadDigit, .keypad: return "circle.grid.3x3.fill"
        case .call: return "phone.fill"
        case .video: return "video.fill"
        case .deleteDigit: return "delete.left.fill"
        case .recents: return "clock.arrow.circlepath"
        case .voicemail: return "recordingtape"
        case .backToHome: return "chevron.left"
        case .phoneFavorites: return "star.fill"
        case .account: return "person.crop.circle.fill"
        case .oneWayApp: return "app.fill"
        case .chevron: return "chevron.right"
        case .templates: return "square.grid.2x2.fill"
        case .media: return "photo.on.rectangle.angled"
        case .analytics: return "chart.line.uptrend.xyaxis"
        case .oneWayAds: return "megaphone.fill"
        case .uploadFile: return "icloud.and.arrow.up.fill"
        }
    }

    var defaultAccessibilityLabel: String {
        rawValue
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    func opticalScale(for container: OneWayPhysicalIconContainerStyle) -> CGFloat {
        self == .oneWayApp ? 1.04 : 1
    }

    static func resolve(systemName: String) -> OneWayIconRole? {
        let value = systemName.lowercased()
        if value.contains("square.and.arrow.up") { return .share }
        if value.contains("arrow.down") { return .downloads }
        if value.contains("bookmark") { return .bookmarks }
        if value.contains("paperclip") { return .attachments }
        if value == "link" { return .links }
        if value.contains("heart") || value.contains("star") { return .favorites }
        if value.contains("house") { return .homeLiving }
        if value.contains("photo") { return .media }
        if value.contains("chart") { return .analytics }
        if value.contains("megaphone") { return .oneWayAds }
        if value.contains("creditcard") { return .paymentSetup }
        if value.contains("keypad") || value.contains("circle.grid.3x3") { return .keypad }
        if value.contains("phone") { return value.contains("down") ? .endCall : .calls }
        if value.contains("clock") || value.contains("history") { return .recents }
        if value.contains("video") || value.contains("camera") { return .videoCall }
        if value.contains("radiowaves") { return .chirp }
        if value.contains("mic") { return .microphone }
        if value.contains("speaker") { return .speaker }
        if value.contains("storefront") || value.contains("building.2") { return .shops }
        if value.contains("shippingbox") || value.contains("cube") { return .product }
        if value.contains("bag") || value.contains("cart") { return .shops }
        if value.contains("bubble") || value.contains("message") || value.contains("paperplane") { return .messages }
        if value.contains("person.3") || value.contains("person.2") { return .community }
        if value.contains("person.badge.plus") { return .addPerson }
        if value.contains("person") { return .profile }
        if value.contains("wallet") || value.contains("creditcard") || value.contains("banknote") { return .wallet }
        if value.contains("cloud") { return .cloud }
        if value.contains("macwindow") || value.contains("network") { return .sites }
        if value.contains("desktop") || value.contains("rectangle.3") { return .workspace }
        if value.contains("envelope") { return .email }
        if value.contains("tag") { return .sellerID }
        if value.contains("receipt") { return .receipt }
        if value.contains("list.clipboard") || value.contains("checklist") { return .plans }
        if value.contains("calendar") { return .calendar }
        if value.contains("doc") || value.contains("folder") || value.contains("tray") || value.contains("archivebox") { return .files }
        if value.contains("shield") || value.contains("lock") || value.contains("key") { return .privacy }
        if value.contains("gear") || value.contains("slider") { return .settings }
        if value.contains("checkmark") { return .success }
        if value.contains("exclamation") { return .warning }
        if value.contains("xmark.octagon") { return .error }
        if value.contains("trash") { return .delete }
        if value.contains("magnifyingglass") { return .search }
        if value.contains("bell") { return .notifications }
        if value.contains("chevron.left") || value.contains("arrow.left") { return .back }
        if value.contains("chevron.right") || value.contains("arrow.right") { return .forward }
        if value.contains("plus") { return .create }
        if value.contains("atom") || value.contains("globe") || value.contains("compass") { return .quantum }
        if value.contains("pencil") { return .edit }
        if value.contains("square.and.arrow.up") { return .share }
        return nil
    }
}

enum OneWayPhysicalIconContainerStyle {
    case none
    case navigation
    case feature
    case toolbar
    case status
    case showcase
}

enum OneWayPhysicalIconState {
    case normal
    case selected
    case disabled
    case success
    case warning
    case destructive
}

private enum OneWayPhysicalIconCache {
    static let images = NSCache<NSString, UIImage>()
    static var missingNames: Set<String> = []
    static let lock = NSLock()

    static func image(named name: String) -> UIImage? {
        if let cached = images.object(forKey: name as NSString) { return cached }
        guard let loaded = UIImage(named: name) else {
            #if DEBUG
            lock.lock()
            let shouldLog = missingNames.insert(name).inserted
            lock.unlock()
            if shouldLog { print("ONEWAY_PHYSICAL_ICON_MISSING asset=\(name)") }
            #endif
            return nil
        }
        images.setObject(loaded, forKey: name as NSString)
        return loaded
    }
}

/// Compatibility bridge for existing views. All direct symbol requests flow through
/// the semantic provider so app-owned concepts receive physical assets while
/// clarity-critical system controls retain their centrally defined SF fallback.
struct OneWayResolvedIcon: View {
    let systemName: String
    var accessibilityLabel: String? = nil

    @ViewBuilder
    var body: some View {
        if systemName.hasPrefix("pin") {
            OneWayPinIcon(isPinned: systemName.contains("fill"), size: 24)
                .accessibilityLabel(accessibilityLabel ?? "Pin")
        } else if let asset = OneWaySculptedCatalog.utilityAsset(for: systemName) {
            Image(asset.name)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(asset.rotation))
                .opacity(asset.isOutline ? 0.62 : 1)
                .accessibilityLabel(accessibilityLabel ?? readableFallbackLabel)
        } else if let role = OneWayIconRole.resolve(systemName: systemName), role.assetName != nil {
            OneWayPhysicalIcon(
                role: role, size: 24, container: .none,
                accessibilityLabel: accessibilityLabel ?? role.defaultAccessibilityLabel,
                glowIntensity: 0.08
            )
        } else {
            OneWaySculptedSymbol(systemName: systemName)
                .accessibilityLabel(accessibilityLabel ?? readableFallbackLabel)
        }
    }

    private var readableFallbackLabel: String {
        systemName
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

/// Label-compatible semantic bridge. Because the implementation remains a real
/// SwiftUI `Label`, existing `.labelStyle(.iconOnly)` and menu behavior are retained.
struct OneWayResolvedLabel: View {
    private let title: Text
    let systemName: String

    init(_ titleKey: LocalizedStringKey, systemImage: String) {
        title = Text(titleKey)
        self.systemName = systemImage
    }

    init<S>(_ title: S, systemImage: String) where S: StringProtocol {
        self.title = Text(String(title))
        self.systemName = systemImage
    }

    var body: some View {
        Label {
            title
        } icon: {
            OneWayResolvedIcon(systemName: systemName)
                .accessibilityHidden(true)
        }
    }
}

struct OneWayResolvedButton: View {
    private let title: Text
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void

    init(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        title = Text(titleKey)
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    init<S>(
        _ title: S,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) where S: StringProtocol {
        self.title = Text(String(title))
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label {
                title
            } icon: {
                OneWayResolvedIcon(systemName: systemImage)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct OneWayPhysicalIcon: View {
    let role: OneWayIconRole
    var size: CGFloat = 44
    var state: OneWayPhysicalIconState = .normal
    var container: OneWayPhysicalIconContainerStyle = .none
    var assetNameOverride: String? = nil
    var accessibilityLabel: String? = nil
    var badgeCount: Int? = nil
    var glowIntensity: Double = 0.18

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            containerSurface
            iconImage
                .padding(iconPadding)
                .frame(
                    width: max(0, size - iconPadding * 2),
                    height: max(0, size - iconPadding * 2),
                    alignment: .center
                )
                .scaleEffect(role.opticalScale(for: container))
                .clipShape(iconClipShape)

            if let badgeCount, badgeCount > 0 {
                Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                    .font(.system(size: max(8, size * 0.19), weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: max(17, size * 0.30), minHeight: max(17, size * 0.30))
                    .background(Color.red, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))
                    .offset(x: size * 0.38, y: -size * 0.38)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .opacity(state == .disabled ? 0.42 : 1)
        .saturation(state == .disabled ? 0.35 : 1)
        .scaleEffect(state == .selected ? 1.06 : 1)
        .shadow(color: glowColor.opacity(effectiveGlow), radius: size * 0.18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? role.defaultAccessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var iconImage: some View {
        if let assetName = assetNameOverride ?? role.assetName,
           let image = OneWayPhysicalIconCache.image(named: assetName) {
            Image(uiImage: image)
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: role == .oneWayApp ? .fill : .fit)
                .rotationEffect(.degrees(role == .forward || role == .chevron ? 180 : 0))
        } else {
            OneWaySculptedSymbol(systemName: role.fallbackSystemName)
        }
    }

    @ViewBuilder
    private var containerSurface: some View {
        if role == .oneWayApp {
            oneWayAppContainerSurface
        } else {
            defaultContainerSurface
        }
    }

    @ViewBuilder
    private var oneWayAppContainerSurface: some View {
        switch container {
        case .none:
            Color.clear
        case .navigation, .status:
            Circle()
                .fill(Color.clear)
                .overlay(Circle().stroke(Color.purple.opacity(state == .selected ? 0.56 : 0.24), lineWidth: 1))
        case .feature:
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.clear)
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(Color.purple.opacity(0.34), lineWidth: contrast == .increased ? 1.5 : 1))
        case .toolbar:
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.clear)
                .overlay(RoundedRectangle(cornerRadius: size * 0.24).stroke(Color.white.opacity(contrast == .increased ? 0.42 : 0.14), lineWidth: 1))
        case .showcase:
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(Color.clear)
                .overlay(RoundedRectangle(cornerRadius: size * 0.30).stroke(Color.purple.opacity(0.48), lineWidth: 1))
        }
    }

    @ViewBuilder
    private var defaultContainerSurface: some View {
        switch container {
        case .none:
            Color.clear
        case .navigation:
            Circle()
                .fill(state == .selected ? Color.purple.opacity(reduceTransparency ? 0.34 : 0.18) : .clear)
                .overlay(Circle().stroke(Color.purple.opacity(state == .selected ? 0.46 : 0), lineWidth: 1))
        case .feature:
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(red: 0.025, green: 0.032, blue: 0.085).opacity(reduceTransparency ? 1 : 0.94))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(Color.purple.opacity(0.34), lineWidth: contrast == .increased ? 1.5 : 1))
        case .toolbar:
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color(red: 0.035, green: 0.042, blue: 0.10))
                .overlay(RoundedRectangle(cornerRadius: size * 0.24).stroke(Color.white.opacity(contrast == .increased ? 0.42 : 0.16), lineWidth: 1))
        case .status:
            Circle()
                .fill(glowColor.opacity(0.14))
                .overlay(Circle().stroke(glowColor.opacity(0.42), lineWidth: 1))
        case .showcase:
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.055, green: 0.065, blue: 0.15), Color(red: 0.018, green: 0.022, blue: 0.065)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: size * 0.30).stroke(Color.purple.opacity(0.48), lineWidth: 1))
        }
    }

    private var iconPadding: CGFloat {
        if role == .oneWayApp {
            switch container {
            case .none: return 0
            case .navigation, .feature, .toolbar, .status, .showcase: return 0
            }
        }
        switch container {
        case .none: return size * 0.04
        case .navigation: return size * 0.10
        case .feature, .toolbar, .showcase: return size * 0.13
        case .status: return size * 0.12
        }
    }

    private var iconClipShape: AnyShape {
        switch container {
        case .none:
            return AnyShape(Rectangle())
        case .navigation, .status:
            return AnyShape(Circle())
        case .feature:
            return AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        case .toolbar:
            return AnyShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        case .showcase:
            return AnyShape(RoundedRectangle(cornerRadius: size * 0.30, style: .continuous))
        }
    }

    private var glowColor: Color {
        switch state {
        case .success: return .green
        case .warning: return .orange
        case .destructive: return .red
        case .normal, .selected, .disabled: return .purple
        }
    }

    private var fallbackColor: Color {
        if role == .backToHome {
            return .white
        }
        switch state {
        case .success: return .green
        case .warning: return .orange
        case .destructive: return .red
        case .normal, .selected: return Color(red: 0.60, green: 0.34, blue: 1)
        case .disabled: return .gray
        }
    }

    private var effectiveGlow: Double {
        state == .disabled ? 0 : min(max(glowIntensity, 0), 0.8)
    }

    private var accessibilityValue: String {
        switch state {
        case .selected: return "Selected"
        case .disabled: return "Disabled"
        case .success: return "Success"
        case .warning: return "Warning"
        case .destructive: return "Destructive"
        case .normal: return ""
        }
    }
}

struct OneWayIconBadge: View {
    let role: OneWayIconRole
    var size: CGFloat = 52
    var state: OneWayPhysicalIconState = .normal
    var badgeCount: Int? = nil

    var body: some View {
        OneWayPhysicalIcon(role: role, size: size, state: state, container: .feature, badgeCount: badgeCount)
    }
}

struct OneWayNavigationIcon: View {
    let role: OneWayIconRole
    var selected = false
    var size: CGFloat = 38
    var badgeCount: Int? = nil
    var accessibilityLabel: String? = nil

    var body: some View {
        OneWayPhysicalIcon(
            role: role,
            size: size,
            state: selected ? .selected : .normal,
            container: .navigation,
            accessibilityLabel: accessibilityLabel,
            badgeCount: badgeCount,
            glowIntensity: selected ? 0.30 : 0.04
        )
    }
}

struct OneWayFeatureIcon: View {
    let role: OneWayIconRole
    var size: CGFloat = 62
    var accessibilityLabel: String? = nil

    var body: some View {
        OneWayPhysicalIcon(role: role, size: size, container: .feature, accessibilityLabel: accessibilityLabel, glowIntensity: 0.14)
    }
}

struct OneWayToolbarIcon: View {
    let role: OneWayIconRole
    var state: OneWayPhysicalIconState = .normal
    var accessibilityLabel: String? = nil

    var body: some View {
        OneWayPhysicalIcon(
            role: role,
            size: OneWayToolbarMetrics.iconSize,
            state: state,
            container: .toolbar,
            accessibilityLabel: accessibilityLabel,
            glowIntensity: 0.08
        )
    }
}

struct OneWayStatusIcon: View {
    let role: OneWayIconRole
    var size: CGFloat = 24
    var state: OneWayPhysicalIconState = .normal
    var accessibilityLabel: String? = nil

    var body: some View {
        OneWayPhysicalIcon(role: role, size: size, state: state, container: .status, accessibilityLabel: accessibilityLabel, glowIntensity: 0.04)
    }
}

struct OneWayIconButton: View {
    let role: OneWayIconRole
    let accessibilityLabel: String
    var accessibilityHint: String? = nil
    var state: OneWayPhysicalIconState = .normal
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            OneWayToolbarIcon(role: role, state: state, accessibilityLabel: accessibilityLabel)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(state == .disabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
    }
}


/// Approved Sculpted Violet art. Aliases share artwork only for the same concept.
enum OneWaySculptedCatalog {
    static let roleAssets: [String: String] = [
        "quantum": "Quantum",
        "quantumOrb": "Quantum",
        "aiBuilder": "Quantum",
        "newSite": "Sites",
        "siteBuilderConsole": "Sites",
        "websiteBuilderDesktop": "Sites",
        "sites": "Sites",
        "newShop": "Shops",
        "shopBuilderTerminal": "Shops",
        "onlineStorefrontBuilder": "Shops",
        "storeBuilder": "Shops",
        "shops": "Shops",
        "storefront": "Shops",
        "seller": "Shops",
        "savedShops": "Shops",
        "community": "Community",
        "contacts": "Community",
        "group": "Community",
        "visitors": "Community",
        "create": "Create",
        "quickAdd": "Create",
        "calls": "Calls",
        "call": "Calls",
        "dialerDevice": "Calls",
        "messages": "Messages",
        "orderMessage": "Messages",
        "productQuestion": "Messages",
        "videoCall": "Video",
        "video": "Video",
        "media": "Media",
        "chirp": "Chirp",
        "wallet": "Wallet",
        "sales": "Wallet",
        "cloud": "Cloud",
        "uploadFile": "Cloud",
        "workspace": "Workspace",
        "product": "Product",
        "package": "Product",
        "orders": "Orders",
        "receipt": "Orders",
        "orderNumber": "Orders",
        "sellerID": "SellerID",
        "oneWayID": "SellerID",
        "plans": "Calendar",
        "calendar": "Calendar",
        "autoClose": "History",
        "recents": "History",
        "history": "History",
        "capacity": "Capacity",
        "permanentCapacity": "Capacity",
        "privacy": "Privacy",
        "encryption": "Privacy",
        "privacyShield": "Privacy",
        "paymentPrivacy": "Privacy",
        "settings": "Settings",
        "messageSettings": "Settings",
        "shopSettings": "Settings",
        "profile": "Profile",
        "secureContact": "Profile",
        "account": "Profile",
        "addPerson": "Profile",
        "notifications": "Notifications",
        "unread": "Email",
        "search": "Search",
        "cameraSearch": "Search",
        "back": "Back",
        "forward": "Back",
        "backToHome": "Back",
        "chevron": "Back",
        "deleteDigit": "Backspace",
        "bookmarks": "Bookmarks",
        "downloads": "Download",
        "email": "Email",
        "files": "Files",
        "customRequest": "Files",
        "camera": "Camera",
        "microphone": "Microphone",
        "speaker": "Speaker",
        "endCall": "EndCall",
        "block": "Block",
        "blocked": "Block",
        "report": "Warning",
        "warning": "Warning",
        "delete": "Delete",
        "edit": "Edit",
        "share": "Share",
        "success": "Success",
        "error": "Error",
        "homeLiving": "Home",
        "decor": "Home",
        "furniture": "Furniture",
        "kitchen": "Kitchen",
        "lighting": "Lighting",
        "jewelry": "Jewelry",
        "artCollectibles": "Art",
        "beauty": "Beauty",
        "tech": "Tech",
        "clothing": "Clothing",
        "vintage": "Vintage",
        "attachments": "Attachment",
        "links": "Link",
        "paymentSetup": "Payment",
        "favorites": "Favorites",
        "phoneFavorites": "Favorites",
        "keypadDigit": "Keypad",
        "keypad": "Keypad",
        "voicemail": "Voicemail",
        "templates": "Templates",
        "analytics": "Analytics",
        "oneWayAds": "Ads"
]

    struct UtilityAsset {
        let name: String
        var rotation: Double = 0
        var isOutline = false
    }

    static func utilityAsset(for systemName: String) -> UtilityAsset? {
        let name = systemName.lowercased()
        switch name {
        case "chevron.left", "arrow.left", "chevron.backward": return .init(name: "OneWaySculptedBack")
        case "chevron.right", "arrow.right", "chevron.forward": return .init(name: "OneWaySculptedBack", rotation: 180)
        case "chevron.up": return .init(name: "OneWaySculptedBack", rotation: 90)
        case "chevron.down": return .init(name: "OneWaySculptedBack", rotation: -90)
        case "heart", "heart.fill": return .init(name: "OneWaySculptedHeart", isOutline: name == "heart")
        case "star", "star.fill": return .init(name: "OneWaySculptedFavorites", isOutline: name == "star")
        case "camera", "camera.fill", "camera.badge.ellipsis": return .init(name: "OneWaySculptedCamera")
        case "phone.down", "phone.down.fill": return .init(name: "OneWaySculptedEndCall")
        case "paperclip": return .init(name: "OneWaySculptedAttachment")
        case "link": return .init(name: "OneWaySculptedLink")
        default: return nil
        }
    }
}

/// Fine utility glyphs retain their established meaning and inherit the same
/// violet/silver material. SF Symbols supply the shapes, including dynamic ones.
struct OneWaySculptedSymbol: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(
                LinearGradient(
                    colors: [Color(red: 0.94, green: 0.88, blue: 1), Color(red: 0.67, green: 0.32, blue: 1), Color(red: 0.38, green: 0.14, blue: 0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .shadow(color: Color.white.opacity(0.2), radius: 0.4, x: -0.4, y: -0.5)
            .shadow(color: Color.purple.opacity(0.3), radius: 1.2, x: 0.5, y: 1)
    }
}

struct OneWayPinIcon: View {
    let isPinned: Bool
    var size: CGFloat = 24

    var body: some View {
        Image("OneWaySculptedPin")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .saturation(isPinned ? 1 : 0.35)
            .opacity(isPinned ? 1 : 0.75)
            .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
    }
}
