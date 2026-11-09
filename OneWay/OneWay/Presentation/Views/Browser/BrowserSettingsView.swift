import SwiftUI

struct BrowserSettingsView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @StateObject private var portalStore = PortalPreferenceStore()
    @Environment(\.dismiss) private var dismiss
    @State private var showPortalManager = false

    var body: some View {
        NavigationStack {
            ZStack {
                BrowserPanelBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        settingsCard {
                            Picker("Quantum Search Engine", selection: $viewModel.settings.defaultSearchEngine) {
                                ForEach(BrowserSettings.SearchEngine.allCases) { engine in
                                    Text(engine.rawValue).tag(engine)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white)
                        }

                        settingsCard(title: "Portal Apps") {
                            NavigationLink {
                                PortalStartupPicker(store: portalStore)
                            } label: {
                                LabeledContent("Startup Experience", value: startupDescription)
                            }

                            Toggle(
                                "Show Portal Apps on Quantum Home",
                                isOn: Binding(
                                    get: { portalStore.configuration.showPortalApps },
                                    set: portalStore.setShowPortalApps
                                )
                            )
                            .tint(Color(hex: 0xA66BFF))

                            Picker(
                                "Portal Opening",
                                selection: Binding(
                                    get: { portalStore.configuration.openingBehavior },
                                    set: portalStore.setOpeningBehavior
                                )
                            ) {
                                ForEach(PortalOpeningBehavior.allCases) { behavior in
                                    Text(behavior.title).tag(behavior)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white)

                            Toggle(
                                "Remember Portal Restoration",
                                isOn: Binding(
                                    get: { portalStore.configuration.rememberSessions },
                                    set: portalStore.setRememberSessions
                                )
                            )
                            .tint(Color(hex: 0xA66BFF))

                            Button {
                                showPortalManager = true
                            } label: {
                                OneWayResolvedLabel("Open Portal Manager", systemImage: "square.grid.2x2.fill")
                            }

                            Button(role: .destructive) {
                                BrowserDataStore.clearWebsiteData {
                                    viewModel.notice = BrowserNotice(
                                        title: "Portal Session Data Cleared",
                                        message: "Quantum website cookies, cache, and local website storage were cleared."
                                    )
                                }
                            } label: {
                                OneWayResolvedLabel("Clear Portal Session Data", systemImage: "trash")
                            }

                            Button(role: .destructive) {
                                portalStore.reset()
                            } label: {
                                OneWayResolvedLabel("Reset Portal Configuration", systemImage: "arrow.counterclockwise")
                            }
                        }

                        settingsCard {
                            Toggle("Quantum Private Mode by Default", isOn: $viewModel.settings.privateModeDefault)
                                .tint(Color(hex: 0xA66BFF))
                            Toggle("HTTPS-only Mode", isOn: $viewModel.settings.httpsOnlyMode)
                                .tint(Color(hex: 0xA66BFF))
                            Toggle("Quantum Tracking Protection", isOn: $viewModel.settings.blockTrackers)
                                .tint(Color(hex: 0xA66BFF))
                        }

                        settingsCard(title: "History") {
                            Toggle("Show Recent History on Quantum Home", isOn: $viewModel.settings.showRecentHistoryOnHome)
                                .tint(Color(hex: 0xA66BFF))
                            Toggle("Save Browsing History", isOn: $viewModel.settings.saveBrowsingHistory)
                                .tint(Color(hex: 0xA66BFF))
                            Toggle("Clear on Exit", isOn: $viewModel.settings.clearHistoryOnExit)
                                .tint(Color(hex: 0xA66BFF))
                            Toggle("Hide Site Thumbnails", isOn: $viewModel.settings.hideSiteThumbnails)
                                .tint(Color(hex: 0xA66BFF))
                            Toggle("Require Face ID to View History", isOn: $viewModel.settings.requireFaceIDForHistory)
                                .tint(Color(hex: 0xA66BFF))

                            Button(role: .destructive) {
                                BrowserHistoryStore.clear()
                                viewModel.history = []
                                viewModel.notice = BrowserNotice(title: "Quantum History Cleared", message: "Quantum browsing history was cleared.")
                            } label: {
                                OneWayResolvedLabel("Clear Browsing History", systemImage: "trash")
                                    .font(.subheadline.weight(.black))
                            }
                        }

                        Button(role: .destructive) {
                            viewModel.clearBrowsingData()
                        } label: {
                            OneWayResolvedLabel("Clear Quantum Browsing Data", systemImage: "trash.fill")
                                .font(.headline.weight(.black))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red.opacity(0.84))
                    }
                    .padding(18)
                }
            }
            .foregroundStyle(.white)
            .navigationTitle("OneWay Quantum")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.saveSettings()
                        dismiss()
                    } label: {
                        OneWayResolvedLabel("Back", systemImage: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
            }
            .onDisappear { viewModel.saveSettings() }
            .sheet(isPresented: $showPortalManager) {
                PortalManagerView(store: portalStore) { portal in
                    viewModel.openPortal(portal, preferences: portalStore)
                }
            }
        }
    }

    private var startupDescription: String {
        switch portalStore.configuration.startup.mode {
        case .quantumHome: return "Quantum Home"
        case .resumeLastPortal: return "Resume Last Portal"
        case .askEveryLaunch: return "Ask Every Launch"
        case .specificPortal:
            return portalStore.configuration.startup.selectedPortalID
                .flatMap(portalStore.portal(id:))?.name ?? "Quantum Home"
        }
    }

    private func settingsCard<Content: View>(title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.headline.weight(.black))
            }
            content()
        }
        .font(.subheadline.weight(.semibold))
        .padding(16)
        .browserPanelCard()
    }
}
