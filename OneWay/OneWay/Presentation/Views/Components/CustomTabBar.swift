import SwiftUI
import UIKit

enum RootTab: String, CaseIterable, Identifiable {
    case quantum = "Quantum"
    case chats = "Chats"
    case communities = "Community"
    case create = "Create"
    case calls = "Calls"
    case wallet = "Wallet"
    case shops = "Shops"
    case sites = "Sites"
    case ai = "AI"
    case settings = "Settings"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .quantum: return "atom"
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .communities: return "person.3.fill"
        case .create: return "plus"
        case .calls: return "phone.fill"
        case .wallet: return "wallet.pass.fill"
        case .shops: return "storefront.fill"
        case .sites: return "network"
        case .ai: return "sparkles"
        case .settings: return "gearshape.fill"
        }
    }

    var physicalIconRole: OneWayIconRole {
        switch self {
        case .quantum: return .quantum
        case .chats: return .messages
        case .communities: return .community
        case .create: return .create
        case .calls: return .calls
        case .wallet: return .wallet
        case .shops: return .shops
        case .sites: return .sites
        case .ai: return .workspace
        case .settings: return .settings
        }
    }

    var displayTitle: String { self == .create ? "" : rawValue }
    var isToolbarAssignable: Bool { self != .create && self != .settings }
    var accessibilityLabel: String {
        switch self {
        case .quantum: return "Open OneWay Quantum"
        case .create: return "Create"
        default: return "Open \(displayTitle)"
        }
    }

    static let defaultToolbar: [RootTab] = [.quantum, .communities, .create, .calls, .shops]
    static let legacyWalletDefaultToolbar: [RootTab] = [.quantum, .communities, .create, .calls, .wallet]

    static func fromStoredValue(_ value: String) -> RootTab? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "quantum", "oneway quantum", "oneway", "home", "browser", "web":
            return .quantum
        case "communities":
            return .communities
        default:
            return RootTab(rawValue: value)
        }
    }
}

struct CustomTabBar: View {
    @Binding var selection: RootTab
    @ObservedObject var preferencesStore: OneWayToolbarPreferencesStore
    var onQuickAction: () -> Void = {}
    var onSelectFeature: (OneWayFeature) -> Void

    @State private var editingSlot: OneWayToolbarSlot?
    @State private var pressedSlotID: String?
    @State private var suppressNextTapSlotID: String?

    private var slots: [OneWayToolbarSlot] {
        preferencesStore.slots(for: .main)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(OneWayDesignSystem.Colors.panelGlass)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    OneWayDesignSystem.Colors.purpleGlow.opacity(0.30),
                                    Color.white.opacity(0.12),
                                    OneWayDesignSystem.Colors.purple.opacity(0.32)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.42), radius: 24, x: 0, y: 16)
                .shadow(color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.06), radius: 14, x: 0, y: 8)

            HStack(spacing: 0) {
                shortcut(at: 0)
                shortcut(at: 1)
                createButton
                shortcut(at: 2)
                shortcut(at: 3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, OneWayToolbarMetrics.verticalPadding)
        }
        .frame(height: 72)
        .sheet(item: $editingSlot) { slot in
            OneWayShortcutPickerSheet(
                store: preferencesStore,
                context: .main,
                slotID: slot.id
            )
            .presentationDetents([.large])
        }
    }

    @ViewBuilder
    private func shortcut(at index: Int) -> some View {
        if slots.indices.contains(index) {
            let slot = slots[index]
            let feature = slot.feature
            let selected = isSelected(feature)

            Button {
                if suppressNextTapSlotID == slot.id {
                    suppressNextTapSlotID = nil
                    return
                }
                onSelectFeature(feature)
            } label: {
                VStack(spacing: 4) {
                    OneWayNavigationIcon(
                        role: feature.physicalIconRole,
                        selected: selected,
                        size: OneWayToolbarMetrics.iconSize,
                        accessibilityLabel: feature.accessibilityLabel
                    )
                    Text(feature.displayName)
                        .font(OneWayDesignSystem.Typography.tabLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity, minHeight: OneWayToolbarMetrics.itemHeight)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(OneWayDesignSystem.Colors.purple.opacity(0.14))
                            .frame(
                                width: OneWayToolbarMetrics.selectedWidth,
                                height: OneWayToolbarMetrics.selectedHeight
                            )
                            .blur(radius: 12)
                    }
                }
                .scaleEffect(pressedSlotID == slot.id ? 1.08 : 1)
                .opacity(editingSlot != nil && editingSlot?.id != slot.id ? 0.45 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: pressedSlotID)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(feature.accessibilityLabel)
            .accessibilityHint("Double tap to open. Long press to change this shortcut.")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: Text("Change shortcut")) {
                beginEditing(slot)
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
    }

    private var createButton: some View {
        OneWayHubButton(isDimmed: editingSlot != nil) {
            onQuickAction()
        }
    }

    private func beginEditing(_ slot: OneWayToolbarSlot) {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        editingSlot = slot
    }

    private func isSelected(_ feature: OneWayFeature) -> Bool {
        if feature == .calls {
            return selection == .calls
        }
        if case .rootTab(let tab) = feature.navigationDestination {
            return selection == tab
        }
        return false
    }

    static func validToolbarOrder(_ order: [RootTab]) -> [RootTab] {
        var seen: Set<RootTab> = []
        var assignable = order.filter(\.isToolbarAssignable).filter { seen.insert($0).inserted }
        for fallback in RootTab.defaultToolbar.filter(\.isToolbarAssignable)
        where assignable.count < 4 && !assignable.contains(fallback) {
            assignable.append(fallback)
        }
        assignable = Array(assignable.prefix(4))
        return [assignable[0], assignable[1], .create, assignable[2], assignable[3]]
    }
}
