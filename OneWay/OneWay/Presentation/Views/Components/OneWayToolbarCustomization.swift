import SwiftUI
import UIKit
import Combine

enum OneWayToolbarContext: String, Codable, CaseIterable, Identifiable {
    case main
    case calls
    case shops

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .main: return "Main Toolbar"
        case .calls: return "Calls Toolbar"
        case .shops: return "Shops Toolbar"
        }
    }
}

enum OneWayToolbarMetrics {
    static let iconSize: CGFloat = 40
    static let itemHeight: CGFloat = 58
    static let selectedWidth: CGFloat = 72
    static let selectedHeight: CGFloat = 58
    static let verticalPadding: CGFloat = 4
}

enum OneWayFeature: String, Codable, CaseIterable, Identifiable, Hashable {
    case messages
    case calls
    case video
    case chirp
    case contacts
    case communities
    case quantum
    case shops
    case sites
    case wallet
    case cloud
    case workspace
    case email
    case calendar
    case files
    case settings
    case favorites
    case recents
    case keypad
    case voicemail
    case ads
    case shopHome
    case shopCategories
    case shopMessages
    case shopAccount

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .messages: return "Messages"
        case .calls: return "Calls"
        case .video: return "Video"
        case .chirp: return "Chirp"
        case .contacts: return "Contacts"
        case .communities: return "Communities"
        case .quantum: return "Quantum"
        case .shops: return "Shops"
        case .sites: return "Sites"
        case .wallet: return "Wallet"
        case .cloud: return "Cloud"
        case .workspace: return "Workspace"
        case .email: return "Email"
        case .calendar: return "Calendar"
        case .files: return "Files"
        case .settings: return "Settings"
        case .favorites: return "Favorites"
        case .recents: return "Recents"
        case .keypad: return "Keypad"
        case .voicemail: return "Voicemail"
        case .ads: return "OneWay Ads"
        case .shopHome: return "Shop Home"
        case .shopCategories: return "Categories"
        case .shopMessages: return "Messages"
        case .shopAccount: return "Account"
        }
    }

    var shortDescription: String {
        switch self {
        case .messages: return "Open private conversations."
        case .calls: return "Open OneWay calling."
        case .video: return "Start from the video calling area."
        case .chirp: return "Open private push-to-talk."
        case .contacts: return "Open OneWay contacts."
        case .communities: return "Open secure community spaces."
        case .quantum: return "Browse privately with Quantum."
        case .shops: return "Explore OneWay Shops."
        case .sites: return "Manage your OneWay sites."
        case .wallet: return "Pay, send, receive, and manage funds."
        case .cloud, .files: return "Open private OneWay files."
        case .workspace: return "Open the Creator workspace."
        case .email: return "Open OneWay email."
        case .calendar: return "Open OneWay calendar."
        case .settings: return "Manage OneWay preferences."
        case .favorites: return "Open favorite calling contacts."
        case .recents: return "Open recent calls."
        case .keypad: return "Open the OneWay keypad."
        case .voicemail: return "Open private voicemail."
        case .ads: return "Open OneWay Ads Manager."
        case .shopHome: return "Open the Shops home page."
        case .shopCategories: return "Browse Shop categories."
        case .shopMessages: return "Open marketplace messages."
        case .shopAccount: return "Open your Shops account."
        }
    }

    var physicalIconRole: OneWayIconRole {
        switch self {
        case .messages: return .messages
        case .calls: return .calls
        case .video: return .videoCall
        case .chirp: return .chirp
        case .contacts: return .contacts
        case .communities: return .community
        case .quantum: return .quantum
        case .shops, .shopHome: return .shops
        case .sites: return .sites
        case .wallet: return .wallet
        case .cloud: return .cloud
        case .workspace: return .workspace
        case .email: return .email
        case .calendar: return .calendar
        case .files: return .files
        case .settings: return .settings
        case .favorites: return .favorites
        case .recents: return .recents
        case .keypad: return .keypad
        case .voicemail: return .voicemail
        case .ads: return .sales
        case .shopCategories: return .product
        case .shopMessages: return .messages
        case .shopAccount: return .profile
        }
    }

    var accessibilityLabel: String {
        "Open \(displayName)"
    }

    var allowsDuplicates: Bool { false }

    var navigationDestination: OneWayFeatureDestination {
        switch self {
        case .messages: return .rootTab(.chats)
        case .calls: return .phoneSection(.keypad)
        case .video: return .rootTab(.calls)
        case .communities: return .rootTab(.communities)
        case .quantum: return .rootTab(.quantum)
        case .shops: return .rootTab(.shops)
        case .wallet: return .rootTab(.wallet)
        case .sites: return .quickAction(.mySites)
        case .cloud, .files: return .quickAction(.uploadFile)
        case .workspace: return .quickAction(.askAI)
        case .settings: return .quickAction(.appSettings)
        case .ads: return .quickAction(.oneWayAds)
        case .email, .calendar:
            return .quickAction(.askAI)
        case .favorites: return .phoneSection(.favorites)
        case .recents: return .phoneSection(.recents)
        case .chirp: return .phoneSection(.walkie)
        case .contacts: return .phoneSection(.contacts)
        case .keypad: return .phoneSection(.keypad)
        case .voicemail: return .phoneSection(.voicemail)
        case .shopHome: return .shopsTab(.home)
        case .shopCategories: return .shopsTab(.categories)
        case .shopMessages: return .shopsTab(.messages)
        case .shopAccount: return .shopsTab(.account)
        }
    }
}

enum OneWayFeatureDestination {
    case rootTab(RootTab)
    case quickAction(OneWayQuickAction)
    case phoneSection(PhoneSection)
    case shopsTab(OneWayShopsView.Tab)
}

struct OneWayToolbarSlot: Identifiable, Codable, Equatable {
    let id: String
    var feature: OneWayFeature
}

struct OneWayToolbarPreferences: Codable, Equatable {
    static let currentVersion = 5

    var version: Int
    var layoutsByContext: [String: [OneWayToolbarSlot]]
}

enum OneWayFeatureRegistry {
    static func eligibleFeatures(for context: OneWayToolbarContext) -> [OneWayFeature] {
        let hubFeatures = unique(
            OneWayQuickAction.allCases.compactMap(\.toolbarFeature)
        )

        let contextual: [OneWayFeature]
        switch context {
        case .main:
            contextual = [.quantum]
        case .calls:
            contextual = [
                .favorites, .recents, .chirp, .contacts, .keypad, .voicemail,
                .calls, .video, .messages, .communities, .quantum, .shops,
                .wallet, .cloud, .workspace, .email, .calendar, .files, .settings
            ]
        case .shops:
            contextual = [.shopHome, .shopCategories, .shopMessages, .quantum, .shopAccount, .favorites]
        }

        return unique(contextual + hubFeatures)
    }

    static func defaultSlots(for context: OneWayToolbarContext) -> [OneWayToolbarSlot] {
        switch context {
        case .main:
            return [
                .init(id: "main.leading.0", feature: .quantum),
                .init(id: "main.leading.1", feature: .communities),
                .init(id: "main.trailing.0", feature: .calls),
                .init(id: "main.trailing.1", feature: .shops),
            ]
        case .calls:
            return [
                .init(id: "calls.0", feature: .favorites),
                .init(id: "calls.1", feature: .recents),
                .init(id: "calls.2", feature: .chirp),
                .init(id: "calls.3", feature: .contacts),
                .init(id: "calls.4", feature: .keypad),
                .init(id: "calls.5", feature: .voicemail),
            ]
        case .shops:
            return [
                .init(id: "shops.0", feature: .shopHome),
                .init(id: "shops.1", feature: .shopCategories),
                .init(id: "shops.2", feature: .shopMessages),
                .init(id: "shops.3", feature: .shopAccount),
            ]
        }
    }

    static func maximumSlotCount(for context: OneWayToolbarContext) -> Int {
        defaultSlots(for: context).count
    }

    private static func unique(_ features: [OneWayFeature]) -> [OneWayFeature] {
        var seen: Set<OneWayFeature> = []
        return features.filter { seen.insert($0).inserted }
    }
}

extension OneWayQuickAction {
    var toolbarFeature: OneWayFeature? {
        switch self {
        case .newMessage: return .messages
        case .newCommunity, .createPost, .events: return .communities
        case .newCall: return .calls
        case .newSite, .mySites: return .sites
        case .uploadFile: return .files
        case .createShop, .myShops, .editShop, .manageProducts, .addProduct,
             .shopOrders, .shopMessages, .shopAnalytics, .shopPolicies,
             .shopLifecycle, .deleteShop: return .shops
        case .siteAnalytics: return .sites
        case .sellerPayments: return .wallet
        case .oneWayAds: return .ads
        case .wallet: return .wallet
        case .askAI: return .quantum
        case .appSettings: return .settings
        case .signOut: return nil
        }
    }
}

@MainActor
final class OneWayToolbarPreferencesStore: ObservableObject {
    @Published private(set) var preferences: OneWayToolbarPreferences

    let userID: String
    private let defaults: UserDefaults
    private let storageKey: String
    private var canImportLegacyMainLayout: Bool

    init(userID: String, defaults: UserDefaults = .standard) {
        self.userID = userID
        self.defaults = defaults
        self.storageKey = "oneway.toolbar.preferences.v1.\(Self.storageNamespace(for: userID))"

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(OneWayToolbarPreferences.self, from: data) {
            preferences = decoded
            canImportLegacyMainLayout = false
        } else {
            preferences = OneWayToolbarPreferences(
                version: OneWayToolbarPreferences.currentVersion,
                layoutsByContext: [:]
            )
            canImportLegacyMainLayout = true
        }

        normalizeAndPersist()
    }

    func slots(for context: OneWayToolbarContext) -> [OneWayToolbarSlot] {
        preferences.layoutsByContext[context.rawValue]
            ?? OneWayFeatureRegistry.defaultSlots(for: context)
    }

    func contains(_ feature: OneWayFeature, in context: OneWayToolbarContext) -> Bool {
        slots(for: context).contains { $0.feature == feature }
    }

    func importLegacyMainLayout(_ tabs: [RootTab]) {
        guard canImportLegacyMainLayout else { return }
        canImportLegacyMainLayout = false

        let features = tabs.compactMap(\.toolbarFeature)
        guard features.count >= 4 else { return }

        let defaultSlots = OneWayFeatureRegistry.defaultSlots(for: .main)
        preferences.layoutsByContext[OneWayToolbarContext.main.rawValue] =
            zip(defaultSlots, features.prefix(4)).map {
                OneWayToolbarSlot(id: $0.0.id, feature: $0.1)
            }
        normalizeAndPersist()
    }

    func replace(
        slotID: String,
        with feature: OneWayFeature,
        in context: OneWayToolbarContext
    ) {
        var current = slots(for: context)
        guard let targetIndex = current.firstIndex(where: { $0.id == slotID }) else { return }

        if !feature.allowsDuplicates,
           let existingIndex = current.firstIndex(where: { $0.feature == feature }),
           existingIndex != targetIndex {
            let displacedFeature = current[targetIndex].feature
            current[targetIndex].feature = feature
            current[existingIndex].feature = displacedFeature
        } else {
            current[targetIndex].feature = feature
        }

        preferences.layoutsByContext[context.rawValue] = current
        persist()
    }

    @discardableResult
    func move(
        slotID: String,
        by offset: Int,
        in context: OneWayToolbarContext
    ) -> Int? {
        var current = slots(for: context)
        guard let sourceIndex = current.firstIndex(where: { $0.id == slotID }) else {
            return nil
        }
        let destinationIndex = min(max(sourceIndex + offset, 0), current.count - 1)
        guard destinationIndex != sourceIndex else { return sourceIndex }

        let slot = current.remove(at: sourceIndex)
        current.insert(slot, at: destinationIndex)
        preferences.layoutsByContext[context.rawValue] = current
        persist()
        return destinationIndex
    }

    @discardableResult
    func remove(
        slotID: String,
        in context: OneWayToolbarContext
    ) -> OneWayFeature? {
        var current = slots(for: context)
        let minimumCount = context == .shops ? 2 : 1
        guard current.count > minimumCount,
              let index = current.firstIndex(where: { $0.id == slotID })
        else {
            return nil
        }

        let removed = current.remove(at: index).feature
        preferences.layoutsByContext[context.rawValue] = current
        persist()
        return removed
    }

    @discardableResult
    func add(
        _ feature: OneWayFeature,
        to context: OneWayToolbarContext
    ) -> Bool {
        var current = slots(for: context)
        guard current.count < OneWayFeatureRegistry.maximumSlotCount(for: context),
              OneWayFeatureRegistry.eligibleFeatures(for: context).contains(feature),
              feature.allowsDuplicates || !current.contains(where: { $0.feature == feature })
        else {
            return false
        }

        current.append(
            OneWayToolbarSlot(
                id: "\(context.rawValue).custom.\(UUID().uuidString)",
                feature: feature
            )
        )
        preferences.layoutsByContext[context.rawValue] = current
        persist()
        return true
    }

    func reset(slotID: String, in context: OneWayToolbarContext) {
        let current = slots(for: context)
        let defaults = OneWayFeatureRegistry.defaultSlots(for: context)
        guard let index = current.firstIndex(where: { $0.id == slotID }),
              defaults.indices.contains(index)
        else {
            return
        }
        replace(slotID: slotID, with: defaults[index].feature, in: context)
    }

    func reset(context: OneWayToolbarContext) {
        preferences.layoutsByContext[context.rawValue] =
            OneWayFeatureRegistry.defaultSlots(for: context)
        persist()
    }

    private func normalizeAndPersist() {
        let loadedVersion = preferences.version
        preferences.version = OneWayToolbarPreferences.currentVersion

        for context in OneWayToolbarContext.allCases {
            let defaults = OneWayFeatureRegistry.defaultSlots(for: context)
            let stored = preferences.layoutsByContext[context.rawValue] ?? defaults

            if context == .shops, loadedVersion < 5 {
                preferences.layoutsByContext[context.rawValue] = defaults
                continue
            }

            if context == .calls || context == .shops {
                let eligible = Set(OneWayFeatureRegistry.eligibleFeatures(for: context))
                var seenFeatures: Set<OneWayFeature> = []
                var seenSlotIDs: Set<String> = []
                let normalized = stored.filter { slot in
                    eligible.contains(slot.feature)
                        && seenSlotIDs.insert(slot.id).inserted
                        && (slot.feature.allowsDuplicates || seenFeatures.insert(slot.feature).inserted)
                }
                .prefix(OneWayFeatureRegistry.maximumSlotCount(for: context))

                preferences.layoutsByContext[context.rawValue] =
                    normalized.count < (context == .shops ? 2 : 1) ? defaults : Array(normalized)
                continue
            }

            var seen: Set<OneWayFeature> = []

            let normalized = defaults.map { defaultSlot in
                guard let storedSlot = stored.first(where: { $0.id == defaultSlot.id }),
                      OneWayFeatureRegistry.eligibleFeatures(for: context).contains(storedSlot.feature),
                      storedSlot.feature.allowsDuplicates || seen.insert(storedSlot.feature).inserted
                else {
                    _ = seen.insert(defaultSlot.feature)
                    return defaultSlot
                }
                return storedSlot
            }
            preferences.layoutsByContext[context.rawValue] = normalized
        }

        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
    }

    private static func storageNamespace(for userID: String) -> String {
        Data(userID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension RootTab {
    var toolbarFeature: OneWayFeature? {
        switch self {
        case .quantum: return .quantum
        case .chats: return .messages
        case .communities: return .communities
        case .create: return nil
        case .calls: return .calls
        case .wallet: return .wallet
        case .shops: return .shops
        case .sites: return .sites
        case .ai: return .workspace
        case .settings: return .settings
        }
    }
}

struct OneWayShortcutPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: OneWayToolbarPreferencesStore
    let context: OneWayToolbarContext
    let slotID: String?

    @State private var confirmResetAll = false

    private var slot: OneWayToolbarSlot? {
        guard let slotID else { return nil }
        return store.slots(for: context).first { $0.id == slotID }
    }

    private var isAdding: Bool { slotID == nil }

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayScreenBackground()

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Choose a Shortcut")
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                            Text("Select the OneWay feature you want in this toolbar position.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                            Text(context.displayName)
                                .font(.caption.weight(.black))
                                .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06), in: Capsule())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)

                        ForEach(OneWayFeatureRegistry.eligibleFeatures(for: context)) { feature in
                            let selected = slot?.feature == feature
                            let alreadyPresent = store.contains(feature, in: context)
                            let isAvailable = !isAdding || feature.allowsDuplicates || !alreadyPresent
                            Button {
                                if let slotID {
                                    store.replace(slotID: slotID, with: feature, in: context)
                                } else {
                                    guard store.add(feature, to: context) else { return }
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                UIAccessibility.post(
                                    notification: .announcement,
                                    argument: isAdding
                                        ? "\(feature.displayName) added to the toolbar"
                                        : "\(feature.displayName) assigned"
                                )
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    OneWayPhysicalIcon(
                                        role: feature.physicalIconRole,
                                        size: 48,
                                        state: selected ? .selected : .normal,
                                        container: .toolbar,
                                        accessibilityLabel: feature.accessibilityLabel,
                                        glowIntensity: selected ? 0.22 : 0.06
                                    )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(feature.displayName)
                                            .font(.headline.weight(.black))
                                            .foregroundStyle(.white)
                                        Text(feature.shortDescription)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                                            .multilineTextAlignment(.leading)
                                    }

                                    Spacer(minLength: 8)

                                    if selected {
                                        OneWayResolvedIcon(systemName: "checkmark.circle.fill")
                                            .font(.title2.weight(.black))
                                            .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)
                                    } else if !isAvailable {
                                        Text("In Toolbar")
                                            .font(.caption2.weight(.black))
                                            .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                                    }
                                }
                                .padding(14)
                                .background(
                                    OneWayDesignSystem.Colors.panelGlass,
                                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(
                                            selected
                                                ? OneWayDesignSystem.Colors.purpleGlow
                                                : OneWayDesignSystem.Colors.border,
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!isAvailable)
                            .opacity(isAvailable ? 1 : 0.52)
                            .accessibilityLabel(feature.displayName)
                            .accessibilityHint(
                                !isAvailable
                                    ? "Already present in this toolbar."
                                    : selected
                                    ? "Currently assigned to this position."
                                    : "Assigns this feature. If already present, the two shortcuts swap."
                            )
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }

                        if let slotID {
                            VStack(spacing: 10) {
                                Button {
                                    store.reset(slotID: slotID, in: context)
                                    dismiss()
                                } label: {
                                    OneWayResolvedLabel("Reset This Position", systemImage: "arrow.uturn.backward.circle")
                                        .font(.headline.weight(.black))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                }
                                .buttonStyle(.bordered)

                                Button(role: .destructive) {
                                    confirmResetAll = true
                                } label: {
                                    OneWayResolvedLabel("Reset Entire Toolbar", systemImage: "arrow.counterclockwise")
                                        .font(.headline.weight(.black))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Reset \(context.displayName)?",
                isPresented: $confirmResetAll,
                titleVisibility: .visible
            ) {
                Button("Reset to Default", role: .destructive) {
                    store.reset(context: context)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This restores the intended default shortcuts for this toolbar.")
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct OneWayToolbarEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: OneWayToolbarPreferencesStore
    let context: OneWayToolbarContext
    let slotID: String

    @State private var showsPicker = false
    @State private var pickerAddsShortcut = false
    @State private var confirmsResetAll = false
    @State private var showsMinimumWarning = false

    private var slots: [OneWayToolbarSlot] { store.slots(for: context) }
    private var slot: OneWayToolbarSlot? { slots.first { $0.id == slotID } }
    private var slotIndex: Int? { slots.firstIndex { $0.id == slotID } }
    private var canAdd: Bool {
        slots.count < OneWayFeatureRegistry.maximumSlotCount(for: context)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayScreenBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        if let slot {
                            VStack(spacing: 8) {
                                OneWayPhysicalIcon(
                                    role: slot.feature.physicalIconRole,
                                    size: 68,
                                    state: .selected,
                                    container: .toolbar,
                                    accessibilityLabel: slot.feature.accessibilityLabel,
                                    glowIntensity: 0.24
                                )
                                Text(slot.feature.displayName)
                                    .font(.title2.weight(.black))
                                    .foregroundStyle(.white)
                                Text("Position \((slotIndex ?? 0) + 1) of \(slots.count)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 8)
                        }

                        editorButton("Replace Shortcut", systemImage: "arrow.triangle.2.circlepath") {
                            pickerAddsShortcut = false
                            showsPicker = true
                        }

                        editorButton("Move Left", systemImage: "arrow.left") {
                            announceMove(offset: -1)
                        }
                        .disabled(slotIndex == 0)

                        editorButton("Move Right", systemImage: "arrow.right") {
                            announceMove(offset: 1)
                        }
                        .disabled(slotIndex == slots.indices.last)

                        editorButton(
                            "Remove from Toolbar",
                            systemImage: "minus.circle.fill",
                            destructive: true
                        ) {
                            guard slots.count > 1 else {
                                showsMinimumWarning = true
                                return
                            }
                            let removed = store.remove(slotID: slotID, in: context)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            UIAccessibility.post(
                                notification: .announcement,
                                argument: "\(removed?.displayName ?? "Shortcut") removed"
                            )
                            dismiss()
                        }

                        editorButton("Reset This Position", systemImage: "arrow.uturn.backward.circle") {
                            store.reset(slotID: slotID, in: context)
                            UIAccessibility.post(
                                notification: .announcement,
                                argument: "Toolbar position reset"
                            )
                            dismiss()
                        }

                        if canAdd {
                            Button {
                                pickerAddsShortcut = true
                                showsPicker = true
                            } label: {
                                HStack(spacing: 12) {
                                    OneWayPhysicalIcon(
                                        role: .create,
                                        size: 38,
                                        state: .selected,
                                        accessibilityLabel: "Add Shortcut"
                                    )
                                    Text("Add Shortcut")
                                        .font(.headline.weight(.black))
                                    Spacer()
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 56)
                                .background(
                                    OneWayDesignSystem.Colors.panelGlass,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(OneWayDesignSystem.Colors.purpleGlow.opacity(0.5), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Adds a shortcut to this toolbar only.")
                        }

                        editorButton(
                            context == .shops ? "Reset to Shops Default" : "Reset Entire Toolbar",
                            systemImage: "arrow.counterclockwise",
                            destructive: true
                        ) {
                            confirmsResetAll = true
                        }

                        Button("Cancel") { dismiss() }
                            .font(.headline.weight(.bold))
                            .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Customize Toolbar")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsPicker) {
                OneWayShortcutPickerSheet(
                    store: store,
                    context: context,
                    slotID: pickerAddsShortcut ? nil : slotID
                )
                .presentationDetents([.large])
            }
            .confirmationDialog(
                "Reset \(context.displayName)?",
                isPresented: $confirmsResetAll,
                titleVisibility: .visible
            ) {
                Button("Reset to Default", role: .destructive) {
                    store.reset(context: context)
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: "Toolbar reset to default"
                    )
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This restores the intended default shortcuts for this toolbar.")
            }
            .alert("At least one toolbar shortcut is required.", isPresented: $showsMinimumWarning) {
                Button("OK", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }

    private func editorButton(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            OneWayResolvedLabel(title, systemImage: systemImage)
                .font(.headline.weight(.black))
                .foregroundStyle(destructive ? Color.red : Color.white)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .padding(.horizontal, 16)
                .background(
                    OneWayDesignSystem.Colors.panelGlass,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OneWayDesignSystem.Colors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func announceMove(offset: Int) {
        guard let feature = slot?.feature,
              let destination = store.move(slotID: slotID, by: offset, in: context)
        else {
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(feature.displayName) moved to position \(destination + 1)"
        )
    }
}
