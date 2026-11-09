import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum PhoneSection: String, CaseIterable, Identifiable {
    case favorites = "Favorites"
    case recents = "Recents"
    case walkie = "Chirp"
    case contacts = "Contacts"
    case keypad = "Keypad"
    case voicemail = "Voicemail"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .favorites: return "star.fill"
        case .recents: return "clock.arrow.circlepath"
        case .walkie: return "dot.radiowaves.left.and.right"
        case .contacts: return "person.crop.circle.fill"
        case .keypad: return "circle.grid.3x3.fill"
        case .voicemail: return "recordingtape"
        }
    }

    var physicalRole: OneWayIconRole {
        switch self {
        case .favorites: return .phoneFavorites
        case .recents: return .recents
        case .walkie: return .chirp
        case .contacts: return .contacts
        case .keypad: return .keypad
        case .voicemail: return .voicemail
        }
    }
}

struct PhoneSubTabBar: View {
    @Binding var selected: PhoneSection
    @ObservedObject var preferencesStore: OneWayToolbarPreferencesStore
    var voicemailUnreadCount: Int = 0
    var onOpenFeature: (OneWayFeature) -> Void
    var onOpenHub: () -> Void

    @State private var editingSlot: OneWayToolbarSlot?
    @State private var pressedSlotID: String?
    @State private var suppressNextTapSlotID: String?

    private var slots: [OneWayToolbarSlot] {
        preferencesStore.slots(for: .calls)
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 400
            let inactiveIconSize = OneWayToolbarMetrics.iconSize
            let activeIconSize = OneWayToolbarMetrics.iconSize
            let labelSize: CGFloat = compact ? 9 : 10
            let contentHeight: CGFloat = compact ? 90 : 96
            let itemMaxWidth: CGFloat = .infinity
            let splitIndex = min(3, max(2, slots.count / 2))
            let leadingSlots = Array(slots.prefix(splitIndex))
            let trailingSlots = Array(slots.dropFirst(splitIndex))

            HStack(spacing: 0) {
                ForEach(leadingSlots) { slot in
                    toolbarButton(
                        for: slot,
                        inactiveIconSize: inactiveIconSize,
                        activeIconSize: activeIconSize,
                        labelSize: labelSize,
                        itemMaxWidth: itemMaxWidth
                    )
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
                }

                OneWayHubButton(isDimmed: editingSlot != nil) {
                    onOpenHub()
                }
                .frame(maxWidth: .infinity)

                ForEach(trailingSlots) { slot in
                    toolbarButton(
                        for: slot,
                        inactiveIconSize: inactiveIconSize,
                        activeIconSize: activeIconSize,
                        labelSize: labelSize,
                        itemMaxWidth: itemMaxWidth
                    )
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
                }
            }
            .animation(
                .spring(response: 0.34, dampingFraction: 0.78),
                value: slots
            )
            .padding(.horizontal, compact ? 4 : 7)
            .padding(.vertical, 6)
            .frame(height: contentHeight)
            .background(.ultraThinMaterial.opacity(isWalkieStyle ? 0.22 : 0.28), in: Capsule())
            .background(
                isWalkieStyle ? Color(hex: 0x070711).opacity(0.94) : OneWayCallTheme.surface,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isWalkieStyle ? Color.white.opacity(0.10) : OneWayCallTheme.purple.opacity(0.14), lineWidth: 1)
            )
            .shadow(
                color: isWalkieStyle ? Color.black.opacity(0.34) : OneWayCallTheme.deepPurple.opacity(0.10),
                radius: 22,
                x: 0,
                y: 12
            )
            .padding(.horizontal, compact ? 7 : 12)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 110)
        .sheet(item: $editingSlot) { slot in
            OneWayToolbarEditorSheet(
                store: preferencesStore,
                context: .calls,
                slotID: slot.id
            )
            .presentationDetents([.large])
        }
    }

    private func toolbarButton(
        for slot: OneWayToolbarSlot,
        inactiveIconSize: CGFloat,
        activeIconSize: CGFloat,
        labelSize: CGFloat,
        itemMaxWidth: CGFloat
    ) -> some View {
        let feature = slot.feature
        let isSelected = selectedSection(for: feature) == selected

        return Button {
            if suppressNextTapSlotID == slot.id {
                suppressNextTapSlotID = nil
                return
            }
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            open(feature)
        } label: {
            toolbarButtonLabel(
                slot: slot,
                isSelected: isSelected,
                inactiveIconSize: inactiveIconSize,
                activeIconSize: activeIconSize,
                labelSize: labelSize
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: itemMaxWidth)
        .accessibilityLabel(feature.accessibilityLabel)
        .accessibilityHint("Double tap to open. Long press to move, remove, or replace this shortcut.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Change shortcut")) {
            beginEditing(slot)
        }
        .accessibilityAction(named: Text("Move left")) {
            move(slot, by: -1)
        }
        .accessibilityAction(named: Text("Move right")) {
            move(slot, by: 1)
        }
        .accessibilityAction(named: Text("Remove shortcut")) {
            remove(slot)
        }
        .onLongPressGesture(
            minimumDuration: 0.45,
            maximumDistance: 24,
            pressing: { pressing in
                pressedSlotID = pressing ? slot.id : nil
            },
            perform: {
                suppressNextTapSlotID = slot.id
                beginEditing(slot)
            }
        )
    }

    private func toolbarButtonLabel(
        slot: OneWayToolbarSlot,
        isSelected: Bool,
        inactiveIconSize: CGFloat,
        activeIconSize: CGFloat,
        labelSize: CGFloat
    ) -> some View {
        let feature = slot.feature

        return VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                OneWayPhysicalIcon(
                    role: feature.physicalIconRole,
                    size: isSelected ? activeIconSize : inactiveIconSize,
                    state: isSelected ? .selected : .normal,
                    container: .none,
                    accessibilityLabel: feature.accessibilityLabel,
                    glowIntensity: isSelected ? 0.22 : 0.02
                )
                if feature == .voicemail && voicemailUnreadCount > 0 {
                    Text("\(voicemailUnreadCount)")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Color.red, in: Circle())
                        .offset(x: 10, y: -8)
                }
            }

            Text(feature.displayName)
                .font(.system(size: labelSize, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .foregroundColor(foregroundColor(isSelected: isSelected))
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(.vertical, 6)
        .background(
            activeBackground(isSelected: isSelected),
            in: RoundedRectangle(cornerRadius: isWalkieStyle ? 24 : 20, style: .continuous)
        )
        .shadow(
            color: isWalkieStyle && isSelected ? Color(hex: 0x8E5CFF).opacity(0.36) : .clear,
            radius: 18,
            x: 0,
            y: 8
        )
        .scaleEffect(pressedSlotID == slot.id ? 1.08 : 1)
        .opacity(editingSlot != nil && editingSlot?.id != slot.id ? 0.45 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: pressedSlotID)
        .contentShape(Rectangle())
    }

    private var isWalkieStyle: Bool {
        selected == .walkie
    }

    private func selectedSection(for feature: OneWayFeature) -> PhoneSection? {
        if case .phoneSection(let section) = feature.navigationDestination {
            return section
        }
        return nil
    }

    private func foregroundColor(isSelected: Bool) -> Color {
        guard isWalkieStyle else {
            return isSelected ? OneWayCallTheme.purple : OneWayCallTheme.faint
        }
        return isSelected ? .white : Color.white.opacity(0.58)
    }

    private func activeBackground(isSelected: Bool) -> AnyShapeStyle {
        guard isSelected else {
            return AnyShapeStyle(Color.clear)
        }
        if isWalkieStyle {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(hex: 0xB26CFF), Color(hex: 0x8E5CFF), Color(hex: 0x5D38FF)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(OneWayCallTheme.lavenderSurface)
    }

    private func open(_ feature: OneWayFeature) {
        if let section = selectedSection(for: feature) {
            selected = section
        } else {
            onOpenFeature(feature)
        }
    }

    private func beginEditing(_ slot: OneWayToolbarSlot) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        #endif
        editingSlot = slot
    }

    private func move(_ slot: OneWayToolbarSlot, by offset: Int) {
        guard let position = preferencesStore.move(
            slotID: slot.id,
            by: offset,
            in: .calls
        ) else {
            return
        }
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(slot.feature.displayName) moved to position \(position + 1)"
        )
        #endif
    }

    private func remove(_ slot: OneWayToolbarSlot) {
        guard slots.count > 1 else {
            #if canImport(UIKit)
            UIAccessibility.post(
                notification: .announcement,
                argument: "At least one toolbar shortcut is required."
            )
            #endif
            return
        }
        guard let removed = preferencesStore.remove(slotID: slot.id, in: .calls) else {
            return
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(removed.displayName) removed"
        )
        #endif
    }
}

struct PhonePanel<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(OneWayCallTheme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(OneWayCallTheme.muted)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .oneWayCallGlass(cornerRadius: 26)
    }
}

struct PhoneLightHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var iconSize: CGFloat = 62
    var symbolFont: Font = .title2.weight(.black)

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: min(22, iconSize * 0.36), style: .continuous)
                    .fill(OneWayCallTheme.lavenderSurface)
                    .frame(width: iconSize, height: iconSize)
                OneWayResolvedIcon(systemName: symbol)
                    .font(symbolFont)
                    .foregroundStyle(OneWayCallTheme.purple)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(OneWayCallTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OneWayCallTheme.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PhoneCallActionButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(tint)
                .clipShape(Circle())
                .shadow(color: tint.opacity(0.24), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

struct PhoneEmptyState: View {
    var symbol: String = "phone.circle"
    let title: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .center, spacing: 11) {
            OneWayResolvedIcon(systemName: symbol)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(OneWayCallTheme.purple)
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayCallTheme.text)
                .multilineTextAlignment(.center)
            Text(bodyText)
                .font(.subheadline)
                .foregroundStyle(OneWayCallTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }
}

struct PhoneBackendBanner: View {
    let state: BackendConnectionState

    var body: some View {
        if let message = state.message {
            HStack(spacing: 10) {
                OneWayResolvedIcon(systemName: state == .checking ? "bolt.horizontal.circle" : "wifi.exclamationmark")
                    .foregroundStyle(state == .checking ? .blue : .orange)
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(OneWayCallTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(OneWayCallTheme.border, lineWidth: 1))
        }
    }
}
