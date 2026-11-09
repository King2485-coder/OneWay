import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct BrowserHomeView: View {
    @StateObject private var viewModel: BrowserViewModel
    @StateObject private var portalStore = PortalPreferenceStore()
    @StateObject private var hubPreferences = OneWayHubPreferencesStore()
    @State private var showHomeCustomization = false
    private let domainService: DomainService
    private let siteService: SiteService
    private let initialURL: URL?
    private let asksForStartupPortal: Bool
    private let onInitialURLConsumed: () -> Void
    @State private var selectedPanel: BrowserPanel?
    @State private var showMoreMenu = false
    @State private var showSiteInfo = false
    @State private var showFindOnPage = false
    @State private var addressFocused = false
    @State private var showPortalManager = false
    @State private var showStartupChooser: Bool
    @State private var didConsumeInitialURL = false
    @State private var nativeReloadCounter = 0
    @State private var currentIdentityHandle = "@oneway"
    @State private var currentIdentityVerified = false
    @FocusState private var isAddressFieldFocused: Bool

    init(
        domainService: DomainService,
        siteService: SiteService,
        initialURL: URL? = nil,
        asksForStartupPortal: Bool = false,
        onInitialURLConsumed: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: BrowserViewModel(domainService: domainService, initialURL: initialURL))
        self.domainService = domainService
        self.siteService = siteService
        self.initialURL = initialURL
        self.asksForStartupPortal = asksForStartupPortal
        self.onInitialURLConsumed = onInitialURLConsumed
        _showStartupChooser = State(initialValue: asksForStartupPortal)
    }

    var body: some View {
        ZStack {
            BrowserChrome.background.ignoresSafeArea()

            if let url = viewModel.activeTab.url ?? viewModel.currentURL {
                browserPage(url)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                homeScreen
                    .transition(.opacity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .alert(item: $viewModel.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .sheet(item: $selectedPanel) { panel in
            switch panel {
            case .tabs:
                BrowserTabsView(viewModel: viewModel)
            case .downloads:
                BrowserDownloadsView(viewModel: viewModel)
            case .settings:
                BrowserSettingsView(viewModel: viewModel)
            case .history:
                BrowserHistoryPanel(viewModel: viewModel)
            case .bookmarks:
                BrowserBookmarksPanel(viewModel: viewModel)
            case .directory:
                DirectoryView(domainService: domainService, siteService: siteService)
            }
        }
        .sheet(isPresented: $showSiteInfo) {
            SiteInformationSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFindOnPage) {
            FindOnPageSheet(viewModel: viewModel)
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OneWayQuantumHomeRequested"))) { _ in
            showStartupChooser = false
            viewModel.showQuantumHome()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OneWayQuantumURLRequested"))) { notification in
            guard let url = notification.object as? URL, OneWayBrowserPolicy.isAllowed(url) else { return }
            viewModel.newTab()
            viewModel.open(url)
        }
        .sheet(isPresented: $showHomeCustomization) {
            NavigationStack {
                Form {
                    Section("Quantum home") {
                        Picker("Background", selection: $hubPreferences.homeBackground) { ForEach(["Cosmic", "Aurora", "Midnight"], id: \.self) { Text($0) } }
                        Toggle("Show homepage toolbox", isOn: $hubPreferences.showToolbox)
                        Toggle("Show Quantum AI", isOn: $hubPreferences.showQuantumAI)
                    }
                    Section("Your portals") {
                        Button("Manage Portal Apps and startup") { showHomeCustomization = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showPortalManager = true } }
                    }
                }.navigationTitle("Customize Quantum").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showHomeCustomization = false } } }
            }.tint(BrowserChrome.purple)
        }
        .sheet(isPresented: $showPortalManager) {
            PortalManagerView(store: portalStore) { portal in
                openPortal(portal)
            }
        }
        .sheet(isPresented: $showStartupChooser) {
            PortalLaunchChooser(store: portalStore) { portal, remember in
                if remember {
                    portalStore.setStartup(mode: .specificPortal, portalID: portal.id)
                }
                openPortal(portal)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.activeTab.url)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.currentURL)
        .task {
            await refreshCurrentIdentityHandle()
        }
        .onAppear {
            guard initialURL != nil, !didConsumeInitialURL else { return }
            didConsumeInitialURL = true
            DispatchQueue.main.async {
                onInitialURLConsumed()
            }
        }
    }

    private var homeScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 15) {
                quantumIdentityHeader
                quantumHero
                quantumSearchField
                quantumToolbox
                if portalStore.configuration.showPortalApps {
                    PortalAppsSection(
                        store: portalStore,
                        onOpen: { portal in
                            openPortal(portal)
                        },
                        onManage: {
                            showPortalManager = true
                        }
                    )
                }
                if hubPreferences.showQuantumAI { quantumAICard }
                quantumRecentCard
                quantumProtectionCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
        .background(quantumStarfieldBackground)
    }

    private func openPortal(_ portal: PortalDefinition) {
        guard portal.opensInstalledApp == true, let url = portal.launchURL, url.scheme?.lowercased() == "https" else {
            viewModel.openPortal(portal, preferences: portalStore)
            return
        }
        #if canImport(UIKit)
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            if !opened { Task { @MainActor in viewModel.openPortal(portal, preferences: portalStore) } }
        }
        #else
        viewModel.openPortal(portal, preferences: portalStore)
        #endif
    }

    private var quantumToolbox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    NotificationCenter.default.post(name: OneWayHubPreferencesStore.openRequested, object: nil)
                } label: { OneWayResolvedLabel("All OneWay features", systemImage: "square.grid.2x2.fill").font(.subheadline.weight(.bold)) }
                Spacer()
                Button { showHomeCustomization = true } label: { OneWayResolvedIcon(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.accessibilityLabel("Customize Quantum home")
            }
            .padding(.horizontal, 14)
            .background(OneWayDesignSystem.Colors.purple.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
            if hubPreferences.showToolbox {
              VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Toolbox").font(.headline.weight(.black)); Spacer(); Button("Edit") { NotificationCenter.default.post(name: OneWayHubPreferencesStore.openRequested, object: nil) }.font(.caption.weight(.bold)) }
                if hubPreferences.pinnedDestinations.isEmpty { Text("Pin tools in All Features to add them here.").font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 12) {
                    ForEach(hubPreferences.pinnedDestinations) { destination in
                        Button {
                            hubPreferences.recordOpen(destination)
                            NotificationCenter.default.post(name: OneWayHubPreferencesStore.routeRequested, object: destination.route)
                        } label: {
                            VStack(spacing: 6) {
                                OneWayPhysicalIcon(role: destination.iconRole, size: 44, container: .none, accessibilityLabel: destination.title)
                                Text(destination.title).font(.system(size: 11, weight: .semibold, design: .rounded)).multilineTextAlignment(.center).lineLimit(3)
                            }.frame(maxWidth: .infinity, minHeight: 78)
                        }.buttonStyle(.plain).accessibilityIdentifier("quantum.toolbox." + destination.id)
                    }
                }
              }.padding(16).quantumGlass(cornerRadius: 22)
            }
        }
    }

    private var quantumIdentityHeader: some View {
        HStack(spacing: 12) {
            Button { selectedPanel = .settings } label: {
                HStack(spacing: 10) {
                    OneWayLogoView(size: 32, containerStyle: .roundedSquare, fillMode: .fullBleed,
                                   showsGlow: false, showsBorder: false)
                    Text("OneWay").font(.system(size: 21, weight: .black, design: .rounded)).italic()
                    Text("I.D.").font(.caption.weight(.bold)).foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
                    Circle().fill(identityStatusColor).frame(width: 6, height: 6)
                }.foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("OneWay identity and settings")
            .accessibilityValue("\(currentIdentityHandle), \(identityStatusText)")
            Spacer(minLength: 0)
            Menu {
                Button("Tabs") { selectedPanel = .tabs }
                Button("Recent history") { selectedPanel = .history }
                Button("Browser settings") { selectedPanel = .settings }
                Button("Customize home") { showHomeCustomization = true }
            } label: {
                OneWayResolvedIcon(systemName: "slider.horizontal.3")
                    .frame(width: 44, height: 44)
                    .background(OneWayDesignSystem.Colors.panel, in: Circle())
                    .overlay(Circle().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
            }.accessibilityLabel("Quantum options")
        }
    }

    private var quantumIdentityBanner: some View {
        Button {
            selectedPanel = .settings
        } label: {
            HStack(spacing: 12) {
                OneWayLogoView(
                    size: 42,
                    containerStyle: .roundedSquare,
                    fillMode: .fullBleed,
                    showsGlow: true,
                    showsBorder: false
                )
                .accessibilityHidden(true)

                Text("OneWay")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .italic()
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                    .layoutPriority(2)

                Rectangle()
                    .fill(BrowserChrome.purple.opacity(0.58))
                    .frame(width: 1, height: 24)

                Text("I.D.")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(Color(hex: 0xEDE7FF))
                    .lineLimit(1)

                Circle()
                    .fill(identityStatusColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: identityStatusColor.opacity(0.65), radius: 8)

                Text(identityStatusText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(identityStatusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                OneWayResolvedIcon(systemName: "chevron.right")
                    .font(.caption.weight(.black))
                    .foregroundStyle(Color(hex: 0xAAA1BD))
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 58)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0x07040F).opacity(0.84), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                BrowserChrome.purple.opacity(0.72),
                                Color.white.opacity(0.12),
                                BrowserChrome.purple.opacity(0.36)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: BrowserChrome.purple.opacity(0.26), radius: 24, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OneWay Identity")
        .accessibilityValue("\(currentIdentityHandle), \(identityStatusText.lowercased())")
        .accessibilityHint("Opens OneWay identity settings.")
    }

    private var quantumUtilityActions: some View {
        HStack(alignment: .top, spacing: 10) {
            quantumHeaderButton(title: "Tabs", icon: "rectangle.on.rectangle", action: { selectedPanel = .tabs })
            quantumHeaderButton(title: "Recent", icon: "clock.arrow.circlepath", action: { selectedPanel = .history })
            quantumHeaderButton(title: "Settings", icon: "slider.horizontal.3", highlighted: true, action: { selectedPanel = .settings })
        }
    }

    private var identityStatusText: String {
        currentIdentityVerified ? "Verified" : "Unverified"
    }

    private var identityStatusColor: Color {
        currentIdentityVerified ? Color(hex: 0x00E99A) : Color(hex: 0xF59E0B)
    }

    private func quantumHeaderButton(title: String, icon: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(highlighted ? .white : Color(hex: 0xF5F0FF))
                    .frame(width: 46, height: 46)
                    .background(
                        highlighted
                        ? AnyShapeStyle(BrowserChrome.purpleGradient)
                        : AnyShapeStyle(Color.white.opacity(0.08))
                    )
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: BrowserChrome.purple.opacity(highlighted ? 0.42 : 0.2), radius: 18, x: 0, y: 8)

                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0xE8E0FF))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
    }

    private var quantumHero: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Quantum")
                    .font(.system(.largeTitle, design: .rounded, weight: .black))
                    .foregroundStyle(.white)
                Text("Your browser.\nYour home.")
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Text(currentIdentityHandle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image("OneWaySculptedQuantum")
                .resizable().scaledToFit()
                .frame(width: 138, height: 150)
                .accessibilityHidden(true)
        }
        .padding(18)
        .quantumGlass(cornerRadius: 22)
    }

    private var quantumSearchField: some View {
        HStack(spacing: 14) {
            OneWayResolvedIcon(systemName: "globe")
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: Circle())

            TextField("Search or enter website", text: $viewModel.query, prompt: Text("Search or enter website").foregroundColor(OneWayDesignSystem.Colors.textSecondary))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit(viewModel.submitQuery)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white)

            Button(action: viewModel.submitQuery) {
                OneWayResolvedIcon(systemName: "sparkles")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.38))
                            .overlay(Circle().stroke(BrowserChrome.purple.opacity(0.72), lineWidth: 1))
                    )
                    .shadow(color: BrowserChrome.purple.opacity(0.44), radius: 14, x: 0, y: 0)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 56)
        .background(Color.black.opacity(0.54), in: Capsule())
        .background(.ultraThinMaterial.opacity(0.38), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .overlay(Capsule().stroke(BrowserChrome.purple.opacity(0.28), lineWidth: 1.5))
        .shadow(color: BrowserChrome.purple.opacity(0.08), radius: 12, x: 0, y: 6)
    }

    private var quantumAICard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                OneWayResolvedIcon(systemName: "sparkles")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(BrowserChrome.purple.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        Text("Quantum AI")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Text("BETA")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(Color(hex: 0xD9C0FF))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(BrowserChrome.purple.opacity(0.32), in: Capsule())
                    }
                    Text("Ask anything.\nDiscover more.")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(hex: 0xCEC5F2))
                        .lineSpacing(2)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }
                .layoutPriority(1)

                Spacer()

                QuantumOrbView()
                    .frame(width: 96, height: 78)
                    .clipped()
                    .allowsHitTesting(false)
            }

            HStack(spacing: 12) {
                TextField("Ask Quantum AI...", text: $viewModel.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.send)
                    .onSubmit(viewModel.submitQuery)
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.white)
                Button(action: viewModel.submitQuery) {
                    OneWayResolvedIcon(systemName: "paperplane.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(BrowserChrome.purpleGradient, in: Circle())
                        .shadow(color: BrowserChrome.purple.opacity(0.52), radius: 16, x: 0, y: 7)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 48)
            .background(Color.black.opacity(0.36), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .padding(16)
        .frame(minHeight: 140)
        .quantumGlass(cornerRadius: 20)
    }

    private var quantumRecentCard: some View {
        HStack(alignment: .center, spacing: 14) {
            OneWayResolvedIcon(systemName: "eye.slash.fill")
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(BrowserChrome.purple)
                .frame(width: 48, height: 48)
                .background(BrowserChrome.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("Recent in Quantum")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("Browsing history is hidden.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0xD7CBFF))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can show or hide your recent browsing history anytime.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(hex: 0xAFA4C7))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Button {
                viewModel.settings.showRecentHistoryOnHome = true
                viewModel.saveSettings()
            } label: {
                OneWayResolvedLabel("Show History", systemImage: "eye.fill")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(Color(hex: 0xE374FF))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 12)
                    .frame(width: 126, height: 44)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .overlay(Capsule().stroke(BrowserChrome.purple.opacity(0.32), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(minHeight: 122)
        .quantumGlass(cornerRadius: 20)
    }

    private var quantumProtectionCard: some View {
        HStack(alignment: .center, spacing: 16) {
            OneWayCinematicAssetView(
                asset: .protectionShield,
                motion: .breathe,
                intensity: 0.75
            )
            .frame(width: 58, height: 58)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Quantum Protection")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(Color(hex: 0x29EF2F))
                        .frame(width: 11, height: 11)
                    Text("Protected")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(Color(hex: 0x29EF2F))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Text("HTTPS protects traffic between your device and each supported site.")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0xD0C8EA))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            OneWayResolvedIcon(systemName: "chevron.right")
                .font(.headline.weight(.black))
                .foregroundStyle(Color(hex: 0xAFA6C6))
        }
        .padding(18)
        .frame(minHeight: 100)
        .quantumGlass(cornerRadius: 20)
    }

    private var quantumStarfieldBackground: some View {
        ZStack {
            BrowserChrome.background
            if hubPreferences.homeBackground != "Midnight" {
                RadialGradient(colors: [(hubPreferences.homeBackground == "Aurora" ? Color.cyan : BrowserChrome.purple).opacity(0.28), Color.clear], center: .topTrailing, startRadius: 40, endRadius: 320)
                RadialGradient(colors: [Color(hex: 0x4322FF).opacity(0.18), Color.clear], center: .center, startRadius: 20, endRadius: 360)
            }
        }
        .ignoresSafeArea()
    }

    private static var statusTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter.string(from: Date())
    }

    @MainActor
    private func refreshCurrentIdentityHandle() async {
        do {
            let user = try await AuthAPIService.shared.currentAuthenticatedUser()
            if let handle = Self.normalizedHandle(user.handle ?? user.username) {
                currentIdentityHandle = handle
                currentIdentityVerified = true
                return
            }
            currentIdentityVerified = true
        } catch {
            #if DEBUG
            print("QUANTUM_IDENTITY_HANDLE_FALLBACK error=\(PrivacyLog.redact(error.localizedDescription))")
            #endif
            currentIdentityVerified = false
        }

        let stored = AuthTokenStore.shared.storedUserID() ?? AuthTokenStore.shared.currentUserID()
        currentIdentityHandle = "@\(PrivacyLog.shortID(stored))"
    }

    private static func normalizedHandle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
    }

    private func browserPage(_ url: URL) -> some View {
        VStack(spacing: 0) {
            webAddressBar

            ZStack(alignment: .top) {
                if let slug = OneWayBrowserPolicy.slug(from: url) {
                    QuantumOneWaySitePage(
                        url: url,
                        slug: slug,
                        siteService: siteService,
                        onStateChange: { isLoading, progress in
                            viewModel.applyNativeSiteLoadingState(isLoading: isLoading, progress: progress)
                        },
                        onTerminalURL: { finalURL in
                            viewModel.noteNativeSiteURL(finalURL)
                        }
                    )
                    .id("oneway-site-\(viewModel.activeTab.id.uuidString)-\(slug)-\(nativeReloadCounter)")
                } else {
                    BrowserWebView(
                        tabID: viewModel.activeTab.id,
                        url: url,
                        settings: viewModel.settings,
                        isPrivate: viewModel.activeTab.isPrivate,
                        viewModel: viewModel
                    )
                    .id("\(viewModel.activeTab.id.uuidString)-\(viewModel.activeTab.isPrivate)")

                    if viewModel.isLoading && viewModel.estimatedProgress < 0.18 {
                        BrowserSkeletonView()
                            .transition(.opacity)
                    }
                }

                if viewModel.showsSecurityCard {
                    secureConnectionCard
                        .padding(.top, 8)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topAddressBar: some View {
        HStack(spacing: 10) {
            BrowserLogo(size: 32)

            TextField("Search or enter address", text: $viewModel.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit(viewModel.submitQuery)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Button {
                viewModel.showsSecurityCard.toggle()
            } label: {
                OneWayResolvedIcon(systemName: "shield.lefthalf.filled")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(BrowserChrome.purple)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .browserGlass(cornerRadius: 22)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var webAddressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        viewModel.goHome()
                    }
                } label: {
                    BrowserLogo(size: 30)
                }
                .buttonStyle(.plain)

                Button {
                    showSiteInfo = true
                } label: {
                    OneWayResolvedIcon(systemName: viewModel.isSecureConnection ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(viewModel.isSecureConnection ? .green : .orange)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Site Information")

                TextField("Search or enter website", text: $viewModel.query)
                .focused($isAddressFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit(viewModel.submitQuery)
                .onChange(of: isAddressFieldFocused) { _, focused in
                    addressFocused = focused
                    if focused {
                        viewModel.query = viewModel.currentURL?.absoluteString ?? viewModel.query
                    }
                }
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .accessibilityLabel("Address and Search")
                .accessibilityHint("Enter a website, OneWay Site, or search query.")

                if !viewModel.query.isEmpty && addressFocused {
                    Button {
                        viewModel.query = ""
                    } label: {
                        OneWayResolvedIcon(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .accessibilityLabel("Clear Address")
                }

                Menu {
                    addressMenuActions
                } label: {
                    OneWayResolvedIcon(systemName: "chevron.down.circle.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Address Menu")

                Button {
                    selectedPanel = .tabs
                } label: {
                    ZStack(alignment: .topTrailing) {
                        OneWayResolvedIcon(systemName: "square.on.square")
                            .font(.headline.weight(.black))
                        Text("\(viewModel.tabCount)")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(BrowserChrome.purple, in: Circle())
                            .offset(x: 8, y: -8)
                    }
                    .frame(width: 34, height: 30)
                    .foregroundStyle(BrowserChrome.purple)
                }

                Button {
                    showMoreMenu = true
                } label: {
                    OneWayResolvedIcon(systemName: "ellipsis.circle.fill")
                        .font(.title3.weight(.black))
                        .foregroundStyle(BrowserChrome.purple)
                }
                .confirmationDialog("Quantum Options", isPresented: $showMoreMenu, titleVisibility: .visible) {
                    browserMenuActions
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .browserGlass(cornerRadius: 18)
            .padding(.horizontal, 14)
            .padding(.top, 6)

            ProgressView(value: viewModel.isLoading ? viewModel.estimatedProgress : 0)
                .progressViewStyle(.linear)
                .tint(BrowserChrome.purple)
                .opacity(viewModel.isLoading ? 1 : 0)
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isLoading)
        }
        .padding(.bottom, 6)
        .background(Color.black.opacity(0.32))
    }

    private var hero: some View {
        VStack(spacing: 12) {
            BrowserLogo(size: 92)
                .shadow(color: BrowserChrome.purple.opacity(0.55), radius: 28, x: 0, y: 16)

            Text("OneWay Quantum")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(.white)

            Text("Private. Secure. Limitless.")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.68))
        }
        .padding(.top, 16)
    }

    private var browserHeroHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                OneWayLogoView(
                    size: 46,
                    containerStyle: .roundedSquare,
                    fillMode: .fullBleed,
                    showsGlow: true,
                    showsBorder: false
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("OneWay Quantum")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("Private. Secure. Limitless.")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color(hex: 0xC8C1EA))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                Button {
                    viewModel.showsSecurityCard.toggle()
                } label: {
                    OneWayResolvedIcon(systemName: "shield")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .overlay(Circle().stroke(BrowserChrome.purple.opacity(0.36), lineWidth: 1))
                        .shadow(color: BrowserChrome.purple.opacity(0.18), radius: 16, x: 0, y: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Quantum privacy")

                Button {
                    selectedPanel = .settings
                } label: {
                    OneWayResolvedIcon(systemName: "hexagon")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(BrowserChrome.purple.opacity(0.22), in: Circle())
                        .overlay(Circle().stroke(BrowserChrome.purple.opacity(0.62), lineWidth: 1))
                        .shadow(color: BrowserChrome.purple.opacity(0.42), radius: 18, x: 0, y: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Quantum settings")
            }
            .frame(maxWidth: .infinity)

            cosmicHorizon
        }
    }

    private var cosmicHorizon: some View {
        ZStack {
            Capsule()
                .fill(BrowserChrome.purple.opacity(0.28))
                .frame(height: 4)
                .blur(radius: 5)
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x7B3FF2).opacity(0.02),
                            BrowserChrome.purple.opacity(0.42),
                            Color(hex: 0x4BA3FF).opacity(0.20),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 54)
                .offset(y: 18)
                .blur(radius: 1.6)
        }
        .frame(height: 36)
        .padding(.top, -8)
        .allowsHitTesting(false)
    }

    private var futuristicSearchField: some View {
        HStack(spacing: 14) {
            OneWayResolvedIcon(systemName: "globe")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white.opacity(0.88))
            TextField("Search or enter website", text: $viewModel.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit(viewModel.submitQuery)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Button(action: viewModel.submitQuery) {
                OneWayResolvedIcon(systemName: "sparkles")
                    .font(.title2.weight(.black))
                    .foregroundStyle(BrowserChrome.purple)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search Quantum")
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
        .background(Color.black.opacity(0.50), in: Capsule())
        .background(.ultraThinMaterial.opacity(0.24), in: Capsule())
        .overlay(Capsule().stroke(BrowserChrome.purple.opacity(0.82), lineWidth: 1.4))
        .shadow(color: BrowserChrome.purple.opacity(0.56), radius: 20, x: 0, y: 0)
    }

    private var quickSiteStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                quickSite("Apple", "apple.logo", .white, "https://apple.com")
                quickSite("Google", "g.circle.fill", Color(hex: 0x52A7FF), "https://google.com")
                quickSite("YouTube", "play.rectangle.fill", .red, "https://youtube.com")
                quickSite("X", "xmark", .white, "https://x.com")
                quickSite("Wikipedia", "w.circle", .white, "https://wikipedia.org")
                Button { selectedPanel = .directory } label: {
                    quickSiteContent("Add", "plus", BrowserChrome.purple)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 12
            ) {
                quickSite("Apple", "apple.logo", .white, "https://apple.com")
                quickSite("Google", "g.circle.fill", Color(hex: 0x52A7FF), "https://google.com")
                quickSite("YouTube", "play.rectangle.fill", .red, "https://youtube.com")
                quickSite("X", "xmark", .white, "https://x.com")
                quickSite("Wiki", "w.circle", .white, "https://wikipedia.org")
                Button { selectedPanel = .directory } label: {
                    quickSiteContent("Add", "plus", BrowserChrome.purple)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func quickSite(_ title: String, _ icon: String, _ color: Color, _ urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) {
                viewModel.open(url)
            }
        } label: {
            quickSiteContent(title, icon, color)
        }
        .buttonStyle(.plain)
    }

    private func quickSiteContent(_ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(color)
                .frame(width: 58, height: 58)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(BrowserChrome.purple.opacity(0.38), lineWidth: 1))
                .shadow(color: BrowserChrome.purple.opacity(0.18), radius: 12, x: 0, y: 6)
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(hex: 0xDED8FF))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 60)
    }

    private var oneWayAICard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                OneWayResolvedIcon(systemName: "sparkles")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(BrowserChrome.purple.opacity(0.20), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text("Quantum AI")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text("BETA")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(Color(hex: 0xD4B8FF))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(BrowserChrome.purple.opacity(0.36), in: Capsule())
                    }
                    Text("Ask anything.\nDiscover more.")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color(hex: 0xC8C1EA))
                }
                .layoutPriority(1)

                Spacer()

                dimensionalOrb
            }

            HStack(spacing: 12) {
                TextField("Ask Quantum AI...", text: $viewModel.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .foregroundStyle(.white)
                    .font(.headline.weight(.semibold))
                    .submitLabel(.send)
                    .onSubmit(viewModel.submitQuery)
                Button(action: viewModel.submitQuery) {
                    OneWayResolvedIcon(systemName: "paperplane.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(BrowserChrome.purpleGradient, in: Circle())
                        .shadow(color: BrowserChrome.purple.opacity(0.46), radius: 16, x: 0, y: 7)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 66)
            .background(Color.black.opacity(0.34), in: Capsule())
            .overlay(Capsule().stroke(BrowserChrome.purple.opacity(0.36), lineWidth: 1))
        }
        .padding(20)
        .browserGlass(cornerRadius: 28)
    }

    private var dimensionalOrb: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.42), BrowserChrome.purple.opacity(0.72), Color.clear], center: .topLeading, startRadius: 4, endRadius: 48))
                .frame(width: 62, height: 62)
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(BrowserChrome.purple.opacity(0.78), lineWidth: 2)
                .frame(width: 80, height: 26)
                .rotationEffect(.degrees(-8))
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .frame(width: 58, height: 58)
        }
        .frame(width: 84, height: 66)
    }

    @ViewBuilder
    private var recentHistorySection: some View {
        if viewModel.settings.saveBrowsingHistory && viewModel.settings.showRecentHistoryOnHome {
            recentActivityCard
        } else {
            recentHistoryHiddenCard
        }
    }

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                OneWayResolvedLabel("Recent in Quantum", systemImage: "clock")
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                Spacer()
                Menu {
                    OneWayResolvedButton("Hide Recent History", systemImage: "eye.slash") {
                        viewModel.settings.showRecentHistoryOnHome = false
                        viewModel.saveSettings()
                        announce("Recent browsing history hidden.")
                    }
                    OneWayResolvedButton("Clear History", systemImage: "trash", role: .destructive) {
                        BrowserHistoryStore.clear()
                        viewModel.history = []
                        viewModel.notice = BrowserNotice(title: "Quantum History Cleared", message: "Quantum browsing history was cleared.")
                    }
                    OneWayResolvedButton("Manage History", systemImage: "slider.horizontal.3") {
                        selectedPanel = .history
                    }
                } label: {
                    OneWayResolvedIcon(systemName: "ellipsis")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(BrowserChrome.purple)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }

            let rows = recentRows
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                recentRow(row.title, row.domain, row.time, row.icon, row.color)
                if index != rows.count - 1 {
                    Divider().overlay(Color.white.opacity(0.12))
                }
            }
        }
        .padding(20)
        .browserGlass(cornerRadius: 28)
    }

    private var recentHistoryHiddenCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                OneWayResolvedIcon(systemName: viewModel.settings.saveBrowsingHistory ? "eye.slash.fill" : "clock.badge.xmark.fill")
                    .font(.title3.weight(.black))
                    .foregroundStyle(BrowserChrome.purple)
                    .frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent in Quantum")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                    Text(viewModel.settings.saveBrowsingHistory ? "Browsing history is hidden." : "Browsing history is not being saved.")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color(hex: 0xC4B9EA))
                }
            }
            Text("You can show or hide your recent browsing history anytime.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: 0xAFA7D8))
            if viewModel.settings.saveBrowsingHistory {
                Button {
                    viewModel.settings.showRecentHistoryOnHome = true
                    viewModel.saveSettings()
                    announce("Recent browsing history shown.")
                } label: {
                    OneWayResolvedLabel("Show Recent History", systemImage: "eye.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(BrowserChrome.purpleGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .browserGlass(cornerRadius: 28)
    }

    private var recentRows: [(title: String, domain: String, time: String, icon: String, color: Color)] {
        let stored = viewModel.history.prefix(3).map {
            (
                title: $0.title,
                domain: $0.url?.host?.replacingOccurrences(of: "www.", with: "") ?? $0.urlString,
                time: "Recent",
                icon: "globe",
                color: BrowserChrome.purple
            )
        }
        if !stored.isEmpty { return stored }
        return [
            ("OneWay - Your world. Connected.", "oneway.is", "2m ago", "circle", BrowserChrome.purple),
            ("OneWay Docs", "docs.oneway.is", "1h ago", "shield.fill", BrowserChrome.purple),
            ("OneWay GitHub", "github.com/oneway", "3h ago", "chevron.left.forwardslash.chevron.right", .white)
        ]
    }

    private func recentRow(_ title: String, _ domain: String, _ time: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 14) {
            OneWayResolvedIcon(systemName: icon)
                .font(.title3.weight(.black))
                .foregroundStyle(color)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(BrowserChrome.purple.opacity(0.30), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(domain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(hex: 0xAFA7D8))
                    .lineLimit(1)
            }
            Spacer()
            Text(time)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: 0xAFA7D8))
            OneWayResolvedIcon(systemName: "ellipsis")
                .foregroundStyle(.white.opacity(0.72))
        }
        .contentShape(Rectangle())
    }

    private func announce(_ message: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }

    private var privacyProtectionCard: some View {
        HStack(spacing: 16) {
            OneWayResolvedIcon(systemName: "lock.fill")
                .font(.title3.weight(.black))
                .foregroundStyle(BrowserChrome.purple)
                .frame(width: 52, height: 52)
                .background(BrowserChrome.purple.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Quantum Privacy")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                    Spacer()
                    OneWayResolvedLabel("Protection On", systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(Color(hex: 0x38EF5E))
                }
                Text("Enhanced privacy protection is active.")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Text("Quantum limits supported trackers and keeps local private browsing data separate.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(hex: 0xC8C1EA))
            }
            OneWayResolvedIcon(systemName: "chevron.right")
                .font(.headline.weight(.black))
                .foregroundStyle(.white.opacity(0.54))
        }
        .padding(20)
        .browserGlass(cornerRadius: 28)
    }

    private var privateSearchField: some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: "magnifyingglass")
                .foregroundStyle(BrowserChrome.purple)
            TextField("Search Quantum privately", text: $viewModel.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.webSearch)
                .submitLabel(.search)
                .onSubmit(viewModel.submitQuery)
                .foregroundStyle(.white)
            Button(action: viewModel.submitQuery) {
                OneWayResolvedIcon(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(BrowserChrome.purple)
            }
        }
        .padding(15)
        .browserGlass(cornerRadius: 20)
    }

    private var quickAccessGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Access")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                quickAccess("OneWay", "paperplane.fill", .purple, "https://oneway.is")
                quickAccess("YouTube", "play.rectangle.fill", .red, "https://youtube.com")
                quickAccess("X", "xmark", .white, "https://x.com")
                quickAccess("Wikipedia", "book.closed.fill", .cyan, "https://wikipedia.org")
                quickAccess("Reddit", "bubble.left.and.bubble.right.fill", .orange, "https://reddit.com")
                quickAccess("GitHub", "chevron.left.forwardslash.chevron.right", .gray, "https://github.com")
                quickAccess("News", "newspaper.fill", .yellow, "https://news.google.com")
                Button {
                    selectedPanel = .directory
                } label: {
                    quickAccessContent("Add", "plus", .green)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .browserGlass(cornerRadius: 26)
    }

    private func quickAccess(_ title: String, _ icon: String, _ color: Color, _ urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) {
                viewModel.open(url)
            }
        } label: {
            quickAccessContent(title, icon, color)
        }
        .buttonStyle(.plain)
    }

    private func quickAccessContent(_ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            OneWayResolvedIcon(systemName: icon)
                .font(.headline.weight(.black))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }

    private var privacyDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            OneWayResolvedLabel("Quantum Privacy", systemImage: "shield.lefthalf.filled")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                privacyMetric("\(viewModel.privacyStats.trackersBlocked)", "Trackers\nBlocked", .purple)
                privacyMetric("\(viewModel.privacyStats.adsBlocked)", "Ads\nBlocked", .pink)
                privacyMetric("\(viewModel.privacyStats.dataSavedKilobytes)KB", "Data\nSaved", .green)
            }
        }
        .padding(18)
        .browserGlass(cornerRadius: 26)
    }

    private func privacyMetric(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.title3.weight(.black))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var privateModeCard: some View {
        HStack(spacing: 14) {
            OneWayResolvedIcon(systemName: "flame.fill")
                .font(.title2.weight(.black))
                .foregroundStyle(BrowserChrome.purple)
                .frame(width: 44, height: 44)
                .background(BrowserChrome.purple.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("Quantum Private Mode")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                Text("Local history is not saved for this tab.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { viewModel.activeTab.isPrivate },
                set: { viewModel.setPrivateMode($0) }
            ))
            .labelsHidden()
            .tint(BrowserChrome.purple)
        }
        .padding(18)
        .browserGlass(cornerRadius: 26)
    }

    private var secureConnectionCard: some View {
        HStack(alignment: .center, spacing: 10) {
            OneWayResolvedIcon(systemName: viewModel.isSecureConnection ? "lock.shield.fill" : "exclamationmark.triangle.fill")
                .font(.headline.weight(.black))
                .foregroundStyle(viewModel.isSecureConnection ? .green : .orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.isSecureConnection ? "Secure Connection" : "Connection Warning")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(.white)
                Text(viewModel.isSecureConnection ? "This page is using an HTTPS connection." : "This page is not using a verified HTTPS connection.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(2)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    viewModel.showsSecurityCard = false
                }
            } label: {
                OneWayResolvedIcon(systemName: "chevron.up.circle.fill")
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask Quantum AI")
        }
        .padding(12)
        .browserGlass(cornerRadius: 18)
    }

    private var bottomTabBar: some View {
        HStack(spacing: 0) {
            bottomItem("Quantum", "atom") { viewModel.goHome() }
            bottomItem("Tabs", "square.on.square") { selectedPanel = .tabs }
            Button {
                viewModel.newTab()
            } label: {
                OneWayResolvedIcon(systemName: "plus")
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 46)
                    .background(BrowserChrome.purpleGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: BrowserChrome.purple.opacity(0.45), radius: 16, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            bottomItem("Downloads", "arrow.down.circle.fill") { selectedPanel = .downloads }
            bottomItem("Settings", "gearshape.fill") { selectedPanel = .settings }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.82))
    }

    private func bottomItem(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                OneWayResolvedIcon(systemName: icon)
                Text(title)
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white.opacity(0.76))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func performRefreshOrStop() {
        if viewModel.isLoading {
            viewModel.stopLoading()
            return
        }
        if viewModel.currentURL.flatMap(OneWayBrowserPolicy.slug(from:)) != nil {
            nativeReloadCounter += 1
            viewModel.applyNativeSiteLoadingState(isLoading: true, progress: 0.08)
        } else {
            viewModel.reload()
        }
    }

    private func focusAddressBar() {
        viewModel.query = viewModel.currentURL?.absoluteString ?? viewModel.query
        isAddressFieldFocused = true
        addressFocused = true
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    @ViewBuilder
    private var addressMenuActions: some View {
        OneWayResolvedButton("Copy Address", systemImage: "doc.on.doc") { copyCurrentLink() }
        OneWayResolvedButton("Paste and Go", systemImage: "doc.on.clipboard") { viewModel.pasteAndGo() }
        OneWayResolvedButton(viewModel.isCurrentPageBookmarked ? "Remove Bookmark" : "Add Bookmark", systemImage: viewModel.isCurrentPageBookmarked ? "bookmark.slash.fill" : "bookmark.fill") { viewModel.bookmarkCurrentPage() }
        OneWayResolvedButton("Add to Favorites", systemImage: "star.fill") {
            viewModel.notice = BrowserNotice(title: "Favorite Added", message: viewModel.displayAddress)
        }
        OneWayResolvedButton(viewModel.isDesktopSiteRequested ? "Request Mobile Site" : "Request Desktop Site", systemImage: "desktopcomputer") {
            viewModel.requestDesktopSite(!viewModel.isDesktopSiteRequested)
        }
        OneWayResolvedButton("Find on Page", systemImage: "magnifyingglass") { showFindOnPage = true }
        OneWayResolvedButton("Site Information", systemImage: "lock.shield") { showSiteInfo = true }
        OneWayResolvedButton("Open in New Tab", systemImage: "plus.square.on.square") {
            if let url = viewModel.shareURL {
                viewModel.newTab()
                viewModel.open(url)
            }
        }
    }

    @ViewBuilder
    private var browserMenuActions: some View {
        OneWayResolvedButton("Back", systemImage: "chevron.left") { viewModel.goBack() }
            .disabled(!viewModel.canGoBack)
        OneWayResolvedButton("Forward", systemImage: "chevron.right") { viewModel.goForward() }
            .disabled(!viewModel.canGoForward)
        OneWayResolvedButton(viewModel.isLoading ? "Stop Loading" : "Refresh", systemImage: viewModel.isLoading ? "xmark" : "arrow.clockwise") {
            performRefreshOrStop()
        }
        OneWayResolvedButton("Quantum Home", systemImage: "house.fill") { viewModel.goHome() }
        OneWayResolvedButton("Show Tabs", systemImage: "square.on.square") { selectedPanel = .tabs }
        if let url = viewModel.shareURL {
            ShareLink(item: url, subject: Text(viewModel.pageTitle), message: Text(viewModel.pageTitle)) {
                OneWayResolvedLabel("Share", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        OneWayResolvedButton("New Quantum Tab", systemImage: "plus.square") { viewModel.newTab() }
        OneWayResolvedButton("New Private Tab", systemImage: "flame.fill") { viewModel.newTab(privateMode: true) }
        OneWayResolvedButton("Close Quantum Tab", systemImage: "xmark.square") { viewModel.closeCurrentTab() }
        OneWayResolvedButton(viewModel.isCurrentPageBookmarked ? "Remove Bookmark" : "Add Bookmark", systemImage: viewModel.isCurrentPageBookmarked ? "bookmark.slash.fill" : "bookmark.fill") { viewModel.bookmarkCurrentPage() }
        OneWayResolvedButton("Bookmarks", systemImage: "book") { selectedPanel = .bookmarks }
        OneWayResolvedButton("History", systemImage: "clock") { selectedPanel = .history }
        OneWayResolvedButton("Downloads", systemImage: "arrow.down.circle") { selectedPanel = .downloads }
        OneWayResolvedButton("Focus Address Bar", systemImage: "magnifyingglass.circle") { focusAddressBar() }
        OneWayResolvedButton("Find on Page", systemImage: "magnifyingglass") { showFindOnPage = true }
        OneWayResolvedButton(viewModel.isDesktopSiteRequested ? "Request Mobile Site" : "Request Desktop Site", systemImage: "desktopcomputer") {
            viewModel.requestDesktopSite(!viewModel.isDesktopSiteRequested)
        }
        OneWayResolvedButton("Copy Link", systemImage: "doc.on.doc") { copyCurrentLink() }
        OneWayResolvedButton("Open in Safari", systemImage: "safari") { openCurrentPageInSafari() }
        OneWayResolvedButton("Page Settings", systemImage: "slider.horizontal.3") { selectedPanel = .settings }
        OneWayResolvedButton("Privacy Report", systemImage: "shield.lefthalf.filled") { showSiteInfo = true }
        OneWayResolvedButton("Diagnostics", systemImage: "stethoscope") {
            viewModel.notice = BrowserNotice(
                title: "Quantum Build",
                message: """
                \(OneWayBuildInfo.appVersion) (\(OneWayBuildInfo.buildNumber))
                Commit: \(OneWayBuildInfo.commitSuffix)
                Built: \(OneWayBuildInfo.buildTimestamp)
                Site Router: \(OneWayBuildInfo.siteRouterVersion)
                Site Resolver: \(APIConfig.publicSiteResolverAPIBaseURL)
                Environment: \(OneWayBuildInfo.environment)
                """
            )
        }
        OneWayResolvedButton("Clear Site Data", systemImage: "trash") { viewModel.clearBrowsingData() }
        OneWayResolvedButton("Quantum Home", systemImage: "house.fill") { viewModel.goHome() }
    }

    private func copyCurrentLink() {
        #if canImport(UIKit)
        UIPasteboard.general.string = viewModel.currentURL?.absoluteString
        #endif
    }

    private func openCurrentPageInSafari() {
        #if canImport(UIKit)
        guard let url = viewModel.currentURL else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

private struct SiteInformationSheet: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Site") {
                    OneWayResolvedLabel(viewModel.currentDomain, systemImage: "globe")
                    OneWayResolvedLabel(viewModel.currentURL?.absoluteString ?? "Quantum Home", systemImage: "link")
                        .font(.caption)
                }
                Section("Security") {
                    OneWayResolvedLabel(viewModel.isSecureConnection ? "HTTPS encrypted" : "Not fully secure", systemImage: viewModel.isSecureConnection ? "lock.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(viewModel.isSecureConnection ? .green : .orange)
                    Text(viewModel.isSecureConnection ? "The page loaded over HTTPS. Quantum still cannot verify site identity beyond the browser security state." : "This page may not be using HTTPS or navigation reported a security warning.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    OneWayResolvedLabel("Tracking protection \(viewModel.settings.blockTrackers ? "on" : "off")", systemImage: "shield.lefthalf.filled")
                }
                Section("Permissions") {
                    OneWayResolvedLabel("Camera: Ask", systemImage: "camera.fill")
                    OneWayResolvedLabel("Microphone: Ask", systemImage: "mic.fill")
                    OneWayResolvedLabel("Location: Ask", systemImage: "location.fill")
                }
                Section("Site Data") {
                    OneWayResolvedLabel("Cookies and cache managed by Quantum privacy settings", systemImage: "internaldrive")
                    Button(role: .destructive) {
                        viewModel.clearBrowsingData()
                        dismiss()
                    } label: {
                        OneWayResolvedLabel("Clear Site Data", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Site Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct FindOnPageSheet: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Find on Page")
                    .font(.headline.weight(.black))
                Spacer()
                Button("Done") { dismiss() }
            }

            HStack(spacing: 10) {
                OneWayResolvedIcon(systemName: "magnifyingglass")
                    .foregroundStyle(BrowserChrome.purple)
                TextField("Find text", text: $viewModel.findQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .onSubmit { viewModel.findOnPage(viewModel.findQuery) }
                if let count = viewModel.findMatchCount {
                    Text("\(count)")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemBackground), in: Capsule())

            HStack(spacing: 12) {
                Button {
                    viewModel.findPrevious()
                } label: {
                    OneWayResolvedLabel("Previous", systemImage: "chevron.up")
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.findNext()
                } label: {
                    OneWayResolvedLabel("Next", systemImage: "chevron.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(BrowserChrome.purple)
            }
        }
        .padding(18)
    }
}

private enum BrowserPanel: Identifiable {
    case tabs, downloads, settings, history, bookmarks, directory
    var id: String { "\(self)" }
}

enum BrowserChrome {
    static let black = Color(hex: 0x0A0A0F)
    static let purple = Color(hex: 0x9B5CFF)
    static let hotPurple = Color(hex: 0xC38BFF)
    static let deepPurple = Color(hex: 0x27104F)
    static let purpleGradient = LinearGradient(colors: [Color(hex: 0x785CFF), Color(hex: 0xC38BFF)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let background = LinearGradient(colors: [Color(hex: 0x020207), Color(hex: 0x07040F), Color(hex: 0x10071D), Color(hex: 0x05020B)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

private struct BrowserLogo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(BrowserChrome.purpleGradient)
            OneWayResolvedIcon(systemName: "paperplane.fill")
                .font(.system(size: size * 0.42, weight: .black))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-8))
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
    }
}

private struct QuantumWaveform: View {
    private let bars: [CGFloat] = [0.28, 0.46, 0.34, 0.66, 0.92, 0.54, 0.38, 0.72, 0.58, 0.4, 0.34, 0.52, 0.7, 0.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(Color(hex: 0x77FF18))
                    .frame(width: 2, height: 18 * height)
                    .shadow(color: Color(hex: 0x77FF18).opacity(0.54), radius: 4)
            }
        }
    }
}

private struct QuantumOrbView: View {
    var body: some View {
        OneWayCinematicAssetView(
            asset: .quantumSphere,
            motion: .orbital,
            intensity: 1
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuantumQuickTileContent: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            OneWayResolvedIcon(systemName: symbol)
                .font(.system(size: 25, weight: .black))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
                .shadow(color: BrowserChrome.purple.opacity(0.17), radius: 12, x: 0, y: 8)

            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color(hex: 0xF0ECFF))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct BrowserSkeletonView: View {
    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(index == 0 ? 0.12 : 0.07))
                    .frame(height: index == 0 ? 120 : 64)
                    .padding(.horizontal, 18)
            }
            Spacer()
        }
        .padding(.top, 22)
        .background(Color.black.opacity(0.62))
    }
}

private enum QuantumSiteLoadState: String {
    case idle = "IDLE"
    case normalizing = "NORMALIZING"
    case resolving = "RESOLVING"
    case decoding = "DECODING"
    case rendering = "RENDERING"
    case loaded = "LOADED"
    case failed = "FAILED"
    case canceled = "CANCELED"
}

private struct QuantumSiteLoadTransaction: Identifiable, Equatable {
    let id = UUID()
    let requestedAddress: String
    let normalizedAddress: String
    let canonicalSlug: String
    var siteId: UUID?
    var publicationId: String?
    var publicationVersion: String?
    var state: QuantumSiteLoadState = .idle
    var startedAt = Date()
    var completedAt: Date?
    var requestCount = 0
    var redirectCount = 0
    var retryCount = 0
    var rendererGeneration = 0
    var cancellationReason: String?
    var failureCode: String?
}

@MainActor
private final class QuantumOneWaySiteLoader: ObservableObject {
    @Published var transaction: QuantumSiteLoadTransaction?
    @Published var html: String?
    @Published var site: OneWaySite?
    @Published var errorMessage: String?
    @Published var progress: Double = 0

    private var activeTask: Task<Void, Never>?
    private var completedAddresses: Set<String> = []

    var isLoading: Bool {
        guard let state = transaction?.state else { return false }
        return [.normalizing, .resolving, .decoding, .rendering].contains(state)
    }

    func load(url: URL, slug: String, siteService: SiteService, retry: Bool = false) {
        let normalizedAddress = "https://sites.oneway.app/\(slug)"
        print("QUANTUM_ONEWAY_HOST_DETECTED host=sites.oneway.app mode=ONEWAY_SITE")
        print("QUANTUM_ONEWAY_SLUG_PARSED slug=\(slug)")
        if let active = transaction,
           active.normalizedAddress == normalizedAddress,
           [.normalizing, .resolving, .decoding, .rendering, .loaded].contains(active.state),
           !retry {
            print("QUANTUM_SITE_DUPLICATE_LOAD_SUPPRESSED navigationId=\(active.id.uuidString) slug=\(slug) normalizedURL=\(normalizedAddress) requestCount=\(active.requestCount)")
            return
        }

        if let activeTask, !activeTask.isCancelled {
            activeTask.cancel()
            if var active = transaction {
                active.state = .canceled
                active.completedAt = Date()
                active.cancellationReason = "new_navigation"
                transaction = active
                print("QUANTUM_SITE_LOAD_CANCELED navigationId=\(active.id.uuidString) slug=\(active.canonicalSlug) failureCode=new_navigation")
            }
        }

        var next = QuantumSiteLoadTransaction(
            requestedAddress: url.absoluteString,
            normalizedAddress: normalizedAddress,
            canonicalSlug: slug
        )
        next.retryCount = retry ? (transaction?.retryCount ?? 0) + 1 : 0
        next.state = .normalizing
        transaction = next
        html = nil
        site = nil
        errorMessage = nil
        progress = 0.08
        URLCache.shared.removeAllCachedResponses()
        log("QUANTUM_SITE_LOAD_TRANSACTION_CREATED", next, status: nil, failureStage: nil, failureCode: nil)
        log("QUANTUM_NAVIGATION_NORMALIZED", next, status: nil, failureStage: nil, failureCode: nil)

        activeTask = Task { [weak self] in
            await self?.resolve(slug: slug, siteService: siteService)
        }
    }

    private func resolve(slug: String, siteService: SiteService) async {
        guard var tx = transaction else { return }
        tx.state = .resolving
        tx.requestCount += 1
        transaction = tx
        progress = 0.28
        log("QUANTUM_SITE_RESOLVER_REQUEST_STARTED", tx, status: nil, failureStage: "resolving", failureCode: nil)
        log("QUANTUM_SITE_API_RESOLVE_STARTED", tx, status: nil, failureStage: "resolving", failureCode: nil)

        do {
            guard let site = try await siteService.publishedSite(forSlug: slug) else {
                fail("unpublished", message: "This OneWay Site is not published yet.", stage: "resolver", status: 404)
                return
            }
            guard site.published else {
                fail("unpublished", message: "This OneWay Site is not published yet.", stage: "resolver", status: 404)
                return
            }
            guard !Task.isCancelled else {
                cancel("task_cancelled")
                return
            }

            tx = transaction ?? tx
            tx.siteId = site.id
            tx.state = .decoding
            transaction = tx
            progress = 0.56
            log("QUANTUM_SITE_RESOLVER_RESPONSE", tx, status: 200, failureStage: nil, failureCode: nil)
            log("QUANTUM_SITE_API_RESOLVE_SUCCEEDED", tx, status: 200, failureStage: nil, failureCode: nil)
            log("QUANTUM_SITE_MANIFEST_DECODE_STARTED", tx, status: 200, failureStage: nil, failureCode: nil)

            let renderedHTML = render(site)
            guard !renderedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail("empty_manifest", message: "This OneWay Site returned an empty publication.", stage: "decode", status: 200)
                return
            }

            tx.state = .rendering
            tx.rendererGeneration += 1
            transaction = tx
            progress = 0.78
            log("QUANTUM_SITE_MANIFEST_DECODE_SUCCEEDED", tx, status: 200, failureStage: nil, failureCode: nil)
            let publicHostAvailable = await checkPublicHost(slug: slug, transaction: tx)
            log("QUANTUM_SITE_RENDER_STARTED", tx, status: nil, failureStage: nil, failureCode: nil)
            log("QUANTUM_SITE_NATIVE_RENDER_STARTED", tx, status: nil, failureStage: nil, failureCode: nil)
            if !publicHostAvailable {
                log("QUANTUM_SITE_NATIVE_FALLBACK_STARTED", tx, status: nil, failureStage: "public_host", failureCode: "MANIFEST_AVAILABLE_PUBLIC_HOST_FAILED")
                log("QUANTUM_LOADED_STATE_PROTECTED", tx, status: nil, failureStage: "public_host", failureCode: "DNS_FAILURE_NONBLOCKING")
            }

            self.site = site
            html = renderedHTML
            tx.state = .loaded
            tx.completedAt = Date()
            transaction = tx
            progress = 1
            completedAddresses.insert(tx.normalizedAddress)
            log("QUANTUM_SITE_RENDER_SUCCEEDED", tx, status: nil, failureStage: nil, failureCode: nil)
            log("QUANTUM_SITE_NATIVE_RENDER_SUCCEEDED", tx, status: nil, failureStage: nil, failureCode: nil)
            log("QUANTUM_SITE_LOAD_COMPLETED", tx, status: nil, failureStage: nil, failureCode: nil)
        } catch {
            fail(
                "api_resolver_error",
                message: "This Site may be published, but OneWay could not verify the publication right now. \(error.localizedDescription)",
                stage: "resolver",
                status: nil
            )
        }
    }

    private func checkPublicHost(slug: String, transaction tx: QuantumSiteLoadTransaction) async -> Bool {
        guard let url = URL(string: "https://sites.oneway.app/\(slug)") else { return false }
        log("QUANTUM_SITE_PUBLIC_HOST_CHECK_STARTED", tx, status: nil, failureStage: "public_host", failureCode: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 4

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            if let status, (200..<400).contains(status) {
                log("QUANTUM_SITE_PUBLIC_HOST_CHECK_SUCCEEDED", tx, status: status, failureStage: nil, failureCode: nil)
                return true
            } else {
                log("QUANTUM_SITE_PUBLIC_ROUTE_FAILURE", tx, status: status, failureStage: "public_host", failureCode: "PUBLIC_ROUTE_FAILURE")
                return false
            }
        } catch {
            let nsError = error as NSError
            let code = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotFindHost
                ? "DNS_UNAVAILABLE"
                : "PUBLIC_HOST_UNREACHABLE"
            let event = code == "DNS_UNAVAILABLE"
                ? "QUANTUM_SITE_PUBLIC_HOST_DNS_FAILED"
                : "QUANTUM_SITE_PUBLIC_HOST_CHECK_FAILED"
            log(event, tx, status: nil, failureStage: "public_host", failureCode: code)
            return false
        }
    }

    private func render(_ site: OneWaySite) -> String {
        site.publishedHtml
    }

    private func fail(_ code: String, message: String, stage: String, status: Int?) {
        guard var tx = transaction else { return }
        tx.state = .failed
        tx.completedAt = Date()
        tx.failureCode = code
        transaction = tx
        errorMessage = message
        progress = 1
        log("QUANTUM_SITE_LOAD_FAILED", tx, status: status, failureStage: stage, failureCode: code)
    }

    private func cancel(_ reason: String) {
        guard var tx = transaction else { return }
        tx.state = .canceled
        tx.completedAt = Date()
        tx.cancellationReason = reason
        transaction = tx
        progress = 1
        log("QUANTUM_SITE_LOAD_CANCELED", tx, status: nil, failureStage: nil, failureCode: reason)
    }

    private func log(_ event: String, _ tx: QuantumSiteLoadTransaction, status: Int?, failureStage: String?, failureCode: String?) {
        let duration = Date().timeIntervalSince(tx.startedAt)
        print("\(event) navigationId=\(tx.id.uuidString) canonicalSiteId=\(tx.siteId?.uuidString ?? "nil") slug=\(tx.canonicalSlug) publicationId=\(tx.publicationId ?? "nil") publicationVersion=\(tx.publicationVersion ?? "nil") normalizedURL=\(tx.normalizedAddress) requestCount=\(tx.requestCount) redirectCount=\(tx.redirectCount) rendererGeneration=\(tx.rendererGeneration) responseStatus=\(status.map(String.init) ?? "nil") duration=\(duration) failureStage=\(failureStage ?? "nil") failureCode=\(failureCode ?? "nil")")
    }
}

private struct QuantumOneWaySitePage: View {
    let url: URL
    let slug: String
    let siteService: SiteService
    let onStateChange: (Bool, Double) -> Void
    let onTerminalURL: (URL) -> Void

    @StateObject private var loader = QuantumOneWaySiteLoader()
    @StateObject private var browserState = BrowserPageState()
    #if DEBUG
    @AppStorage("oneway.quantumDiagnostics.visible") private var showsDiagnostics = false
    #endif

    var body: some View {
        ZStack {
            if let site = loader.site {
                NativeOneWaySiteView(site: site)
                .overlay(alignment: .topLeading) {
                    #if DEBUG
                    if showsDiagnostics {
                        QuantumNativeDebugBadge(
                            slug: slug,
                            state: loader.transaction?.state.rawValue ?? "UNKNOWN",
                            siteId: loader.transaction?.siteId?.uuidString ?? "nil"
                        )
                        .padding(.top, 10)
                        .padding(.leading, 12)
                    }
                    #endif
                }
            } else if let message = loader.errorMessage {
                QuantumSiteErrorView(slug: slug, message: message) {
                    loader.load(url: url, slug: slug, siteService: siteService, retry: true)
                }
            } else {
                BrowserSkeletonView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: slug) {
            loader.load(url: url, slug: slug, siteService: siteService)
        }
        .onChange(of: loader.isLoading) { _, value in
            onStateChange(value, loader.progress)
            if !value { onTerminalURL(url) }
        }
        .onChange(of: loader.progress) { _, value in
            onStateChange(loader.isLoading, value)
        }
    }
}

private struct NativeOneWaySiteView: View {
    let site: OneWaySite

    private var pageText: [String] {
        let html = site.publishedHtml
        let body = html
            .replacingOccurrences(of: "(?is)<style.*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<script.*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</(h1|h2|h3|p|div|section|article|li)>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return body
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, item in
                if result.last != item { result.append(item) }
            }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(site.title)
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                    if !site.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(site.description)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.82))
                    }
                    Text("Publication active")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(BrowserChrome.purpleGradient, in: Capsule())
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [Color(hex: 0x140725), Color(hex: 0x5B23C9), Color(hex: 0xF59E0B)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 30, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(pageText.prefix(12).enumerated()), id: \.offset) { index, line in
                        if index == 0 || line.count < 48 {
                            Text(line)
                                .font(.title3.weight(.black))
                                .foregroundStyle(OneWayLightTheme.textPrimary)
                        } else {
                            Text(line)
                                .font(.body.weight(.medium))
                                .foregroundStyle(OneWayLightTheme.textSecondary)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(hex: 0xE4D9FA), lineWidth: 1)
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .background(
            LinearGradient(colors: [Color(hex: 0xFAFAFC), Color(hex: 0xF7F3FF)], startPoint: .top, endPoint: .bottom)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuantumSiteErrorView: View {
    let slug: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            OneWayResolvedIcon(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .black))
                .foregroundStyle(BrowserChrome.purple)
            Text("Site Unavailable")
                .font(.title2.weight(.black))
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
            Text("sites.oneway.app/\(slug)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.58))
            Button(action: onRetry) {
                OneWayResolvedLabel("Retry", systemImage: "arrow.clockwise")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(BrowserChrome.purpleGradient, in: Capsule())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrowserChrome.background)
    }
}

#if DEBUG
private struct QuantumNativeDebugBadge: View {
    let slug: String
    let state: String
    let siteId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Mode: OneWay Site")
            Text("State: \(state)")
            Text("Slug: \(slug)")
            Text("Router: \(OneWayBuildInfo.siteRouterVersion)")
            Text("Site: \(siteId.suffix(8))")
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BrowserChrome.purple.opacity(0.75), lineWidth: 1)
        )
    }
}
#endif

extension View {
    func quantumGlass(cornerRadius: CGFloat) -> some View {
        self
            .background(Color.black.opacity(0.46), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(.ultraThinMaterial.opacity(0.34), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                BrowserChrome.purple.opacity(0.34),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 22, x: 0, y: 14)
            .shadow(color: BrowserChrome.purple.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    func browserGlass(cornerRadius: CGFloat) -> some View {
        self
            .background(.ultraThinMaterial.opacity(0.45), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [Color.white.opacity(0.24), BrowserChrome.purple.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
            .shadow(color: BrowserChrome.purple.opacity(0.14), radius: 20, x: 0, y: 12)
    }
}
