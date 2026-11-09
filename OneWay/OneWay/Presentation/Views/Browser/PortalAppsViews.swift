import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PortalAppsSection: View {
    @ObservedObject var store: PortalPreferenceStore
    let onOpen: (PortalDefinition) -> Void
    let onManage: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 64, maximum: 92), spacing: 8, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Portal Apps")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text("Trusted destinations inside Quantum")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                Spacer()
                Button("Edit", action: onManage)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(Color(hex: 0xD24CFF))
                    .accessibilityHint("Opens Portal Manager.")
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(store.visiblePortals) { portal in
                    PortalTile(
                        portal: portal,
                        isStartup: store.startupPortalID == portal.id,
                        onOpen: { open(portal) },
                        onSetStartup: { store.setStartup(mode: .specificPortal, portalID: portal.id) },
                        onToggleFavorite: { store.toggleFavorite(portal.id) },
                        onManage: onManage
                    )
                }

                Button(action: onManage) {
                    VStack(spacing: 7) {
                        OneWayResolvedIcon(systemName: "plus")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(BrowserChrome.purple)
                            .frame(width: 52, height: 52)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(BrowserChrome.purple.opacity(0.42), lineWidth: 1))
                        Text("Add")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PortalPressButtonStyle())
                .accessibilityLabel("Add a Portal App")
            }
        }
        .padding(12)
        .quantumGlass(cornerRadius: 20)
    }

    private func open(_ portal: PortalDefinition) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        onOpen(portal)
    }
}

struct PortalTile: View {
    let portal: PortalDefinition
    let isStartup: Bool
    let onOpen: () -> Void
    let onSetStartup: () -> Void
    let onToggleFavorite: () -> Void
    let onManage: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    PortalBrandIcon(portal: portal)
                        .frame(width: 52, height: 52)

                    if isStartup {
                        OneWayResolvedIcon(systemName: "house.fill")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(BrowserChrome.purpleGradient, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 1))
                            .offset(x: 5, y: -5)
                    } else if portal.isFavorite {
                        OneWayResolvedIcon(systemName: "star.fill")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color(hex: 0xFFD45C))
                            .offset(x: 3, y: -3)
                    }
                }

                Text(portal.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(portal.isEnabled ? .white : Color.white.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if isStartup {
                    Text("Startup")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Color(hex: 0xD9C0FF))
                        .textCase(.uppercase)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PortalPressButtonStyle())
        .disabled(!portal.isEnabled)
        .contextMenu {
            OneWayResolvedButton("Open", systemImage: "arrow.up.forward.app", action: onOpen)
            OneWayResolvedButton("Set as Startup", systemImage: "house.fill", action: onSetStartup)
            OneWayResolvedButton(
                portal.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: portal.isFavorite ? "star.slash" : "star",
                action: onToggleFavorite
            )
            OneWayResolvedButton("App or website preferences", systemImage: "slider.horizontal.3", action: onManage)
            OneWayResolvedButton("Move or Edit", systemImage: "slider.horizontal.3", action: onManage)
            if let url = portal.launchURL {
                OneWayResolvedButton("Open Externally", systemImage: "safari") {
                    openURL(url)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(portal.name) portal\(isStartup ? ". Set as startup portal." : ".")")
        .accessibilityHint("Opens inside OneWay Quantum. Long press for portal options.")
        .accessibilityAddTraits(isStartup ? [.isSelected] : [])
    }
}

struct PortalBrandIcon: View {
    let portal: PortalDefinition

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.96))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1)

            if let asset = portal.iconAssetName {
                Image(asset)
                    .resizable()
                    .aspectRatio(contentMode: asset == OneWayBrandAsset.appLogoFullBleed.imageName ? .fill : .fit)
                    .padding(asset == OneWayBrandAsset.appLogoFullBleed.imageName ? 0 : 10)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Text(portal.iconMonogram)
                    .font(.system(size: portal.iconMonogram.count > 1 ? 17 : 23, weight: .black, design: .rounded))
                    .foregroundStyle(Color.black)
            }
        }
        .shadow(color: BrowserChrome.purple.opacity(0.28), radius: 12, x: 0, y: 6)
    }
}

private struct PortalPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct PortalManagerView: View {
    @ObservedObject var store: PortalPreferenceStore
    let onOpen: (PortalDefinition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var editingPortal: PortalDefinition?
    @State private var showingResetConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.configuration.portals) { portal in
                        portalRow(portal)
                    }
                    .onMove(perform: store.move)
                } header: {
                    Text("Portal Apps")
                } footer: {
                    Text("Built-in portals can be hidden but not deleted. Drag while editing to change their order.")
                }

                Section("Startup Experience") {
                    NavigationLink {
                        PortalStartupPicker(store: store)
                    } label: {
                        LabeledContent(
                            "Startup",
                            value: startupDescription
                        )
                    }
                }

                Section {
                    OneWayResolvedButton("Add App or Website Shortcut", systemImage: "plus.app.fill") {
                        editingPortal = nil
                        showingEditor = true
                    }
                    OneWayResolvedButton("Reset Portal Configuration", systemImage: "arrow.counterclockwise") {
                        showingResetConfirmation = true
                    }
                    .foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(BrowserChrome.background.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle("Portal Manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingPortal = nil
                        showingEditor = true
                    } label: {
                        OneWayResolvedLabel("Add Custom Portal", systemImage: "plus")
                    }
                    .accessibilityLabel("Add App or Website Shortcut")
                }
            }
            .sheet(isPresented: $showingEditor) {
                PortalEditorView(store: store, portal: editingPortal)
            }
            .confirmationDialog(
                "Reset all Portal Apps?",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset to Defaults", role: .destructive) { store.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Custom portals and portal startup preferences will be removed. Quantum tabs and browsing data are not changed.")
            }
        }
    }

    private func portalRow(_ portal: PortalDefinition) -> some View {
        HStack(spacing: 12) {
            PortalBrandIcon(portal: portal)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(portal.name)
                        .font(.headline)
                    if store.startupPortalID == portal.id {
                        OneWayResolvedLabel("Startup", systemImage: "house.fill")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(Color(hex: 0xC9A5FF))
                    }
                }
                Text(portal.id == PortalRegistry.quantumHomeID ? "OneWay start page" : portal.homeURL?.host ?? "Invalid address")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                store.toggleFavorite(portal.id)
            } label: {
                OneWayResolvedIcon(systemName: portal.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(portal.isFavorite ? Color(hex: 0xFFD45C) : Color.white.opacity(0.58))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(portal.isFavorite ? "Unfavorite \(portal.name)" : "Favorite \(portal.name)")

            Toggle(
                "",
                isOn: Binding(
                    get: { portal.isEnabled },
                    set: { store.setEnabled(portal.id, enabled: $0) }
                )
            )
            .labelsHidden()
            .tint(BrowserChrome.purple)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onOpen(portal)
                dismiss()
            } label: {
                OneWayResolvedLabel("Open", systemImage: "arrow.up.forward.app")
            }
            .tint(BrowserChrome.purple)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                store.setStartup(mode: .specificPortal, portalID: portal.id)
            } label: {
                OneWayResolvedLabel("Startup", systemImage: "house.fill")
            }
            .tint(.blue)

            if !portal.isBuiltIn {
                Button(role: .destructive) {
                    store.removeCustom(portal.id)
                } label: {
                    OneWayResolvedLabel("Remove", systemImage: "trash")
                }
                Button {
                    editingPortal = portal
                    showingEditor = true
                } label: {
                    OneWayResolvedLabel("Edit", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            if portal.id != PortalRegistry.quantumHomeID {
                Toggle("Open installed app when available", isOn: Binding(get: { portal.opensInstalledApp == true }, set: { store.setAppOpening(portal.id, enabled: $0) }))
            }
            OneWayResolvedButton("Open", systemImage: "arrow.up.forward.app") {
                onOpen(portal)
                dismiss()
            }
            OneWayResolvedButton("Set as Startup", systemImage: "house.fill") {
                store.setStartup(mode: .specificPortal, portalID: portal.id)
            }
            if !portal.isBuiltIn {
                OneWayResolvedButton("Edit", systemImage: "pencil") {
                    editingPortal = portal
                    showingEditor = true
                }
                OneWayResolvedButton("Remove", systemImage: "trash", role: .destructive) {
                    store.removeCustom(portal.id)
                }
            }
        }
    }

    private var startupDescription: String {
        switch store.configuration.startup.mode {
        case .quantumHome: return "Quantum Home"
        case .resumeLastPortal: return "Resume Last Portal"
        case .askEveryLaunch: return "Ask Every Launch"
        case .specificPortal:
            return store.configuration.startup.selectedPortalID
                .flatMap(store.portal(id:))?.name ?? "Quantum Home"
        }
    }
}

struct PortalStartupPicker: View {
    @ObservedObject var store: PortalPreferenceStore

    var body: some View {
        List {
            Section {
                ForEach(PortalStartupMode.allCases) { mode in
                    Button {
                        if mode == .specificPortal {
                            let selected = store.configuration.startup.selectedPortalID
                                ?? store.enabledStartupPortals.first(where: { $0.id != PortalRegistry.quantumHomeID })?.id
                            store.setStartup(mode: mode, portalID: selected)
                        } else {
                            store.setStartup(mode: mode)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.title)
                                    .foregroundStyle(.white)
                                Text(modeDescription(mode))
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.58))
                            }
                            Spacer()
                            if store.configuration.startup.mode == mode {
                                OneWayResolvedIcon(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(BrowserChrome.purple)
                            }
                        }
                    }
                }
            }

            if store.configuration.startup.mode == .specificPortal {
                Section("Choose Portal") {
                    ForEach(store.enabledStartupPortals) { portal in
                        Button {
                            store.setStartup(mode: .specificPortal, portalID: portal.id)
                        } label: {
                            HStack(spacing: 12) {
                                PortalBrandIcon(portal: portal)
                                    .frame(width: 36, height: 36)
                                Text(portal.name)
                                    .foregroundStyle(.white)
                                Spacer()
                                if store.startupPortalID == portal.id {
                                    OneWayResolvedIcon(systemName: "house.fill")
                                        .foregroundStyle(BrowserChrome.purple)
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BrowserChrome.background.ignoresSafeArea())
        .navigationTitle("Startup Experience")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func modeDescription(_ mode: PortalStartupMode) -> String {
        switch mode {
        case .quantumHome: return "Always show the Quantum start page."
        case .resumeLastPortal: return "Restore the last enabled portal when safe."
        case .specificPortal: return "Open one selected portal immediately."
        case .askEveryLaunch: return "Choose after OneWay authentication completes."
        }
    }
}

struct PortalLaunchChooser: View {
    @ObservedObject var store: PortalPreferenceStore
    let onChoose: (PortalDefinition, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rememberChoice = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose how OneWay opens")
                        .font(.title2.weight(.black))
                    Text("Your selection opens inside the existing Quantum browser after authentication and privacy setup.")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.66))

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        ForEach(store.enabledStartupPortals) { portal in
                            Button {
                                onChoose(portal, rememberChoice)
                                dismiss()
                            } label: {
                                VStack(spacing: 10) {
                                    PortalBrandIcon(portal: portal)
                                        .frame(width: 58, height: 58)
                                    Text(portal.name)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .browserPanelCard()
                            }
                            .buttonStyle(PortalPressButtonStyle())
                        }
                    }

                    Toggle("Remember this choice", isOn: $rememberChoice)
                        .tint(BrowserChrome.purple)
                        .font(.headline)
                        .padding(16)
                        .browserPanelCard()
                }
                .padding(18)
            }
            .background(BrowserChrome.background.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle("Startup Portal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .interactiveDismissDisabled()
        }
    }
}

struct PortalEditorView: View {
    @ObservedObject var store: PortalPreferenceStore
    let portal: PortalDefinition?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var errorMessage: String?

    init(store: PortalPreferenceStore, portal: PortalDefinition?) {
        self.store = store
        self.portal = portal
        _name = State(initialValue: portal?.name ?? "")
        _address = State(initialValue: portal?.homeURLString ?? "https://")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Portal Details") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("https://example.com", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section {
                    OneWayResolvedLabel("Custom portals require HTTPS.", systemImage: "lock.shield.fill")
                    Text("Scripts, data URLs, files, and local app schemes are blocked. Website cookies remain managed by Quantum.")
                }
                .font(.caption)

                if let errorMessage {
                    Section {
                        OneWayResolvedLabel(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BrowserChrome.background.ignoresSafeArea())
            .foregroundStyle(.white)
            .navigationTitle(portal == nil ? "Add Portal" : "Edit Portal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.bold)
                }
            }
        }
    }

    private func save() {
        do {
            if let portal {
                try store.updateCustom(id: portal.id, name: name, address: address)
            } else {
                try store.addCustom(name: name, address: address)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
