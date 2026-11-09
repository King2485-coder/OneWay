import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct CreateShopView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onCreated: () -> Void
    let onBack: () -> Void
    @State private var draft = SellerShopDraft()
    @State private var bannerPickerItem: PhotosPickerItem?
    @State private var badgePickerItem: PhotosPickerItem?
    @State private var artworkMessage: String?

    var body: some View {
        sellerPage(title: "Create a Shop", back: onBack) {
            introCard
            shopForm
            validationMessage
            Button {
                Task {
                    if await viewModel.createSellerShop(from: draft) { onCreated() }
                }
            } label: {
                HStack(spacing: 10) {
                    if viewModel.sellerShopIsSaving { ProgressView().tint(.white) }
                    Text(viewModel.sellerShopIsSaving ? "Creating Shop…" : "Create My Shop")
                        .font(.headline.weight(.black))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(MarketplaceTheme.gradient, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.sellerShopIsSaving)
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start selling on OneWay")
                .font(.largeTitle.weight(.black))
                .foregroundStyle(.white)
            OneWayResolvedLabel("Private by default", systemImage: "eye.slash.fill")
            OneWayResolvedLabel("Secure payments", systemImage: "lock.fill")
            OneWayResolvedLabel("Creator-first marketplace", systemImage: "sparkles")
            OneWayResolvedLabel("No middlemen feel", systemImage: "person.2.slash.fill")
        }
        .foregroundStyle(MarketplaceTheme.muted)
        .padding(18)
        .marketplaceCard(cornerRadius: 24)
    }

    private var shopForm: some View {
        VStack(spacing: 12) {
            sellerTextField("Shop name", text: $draft.shopName)
            sellerTextField("Shop description", text: $draft.description, axis: .vertical)
            sellerTextField("Category", text: $draft.category)
            ShopArtworkPickerRow(
                title: "Banner artwork",
                subtitle: "Wide storefront image",
                systemImage: "photo.fill",
                fileName: draft.bannerImageFileName,
                aspectRatio: 2.8,
                pickerItem: $bannerPickerItem,
                onRemove: { draft.bannerImageFileName = nil }
            )
            ShopArtworkPickerRow(
                title: "Circular badge artwork",
                subtitle: "Shop avatar image",
                systemImage: "person.crop.circle.fill",
                fileName: draft.badgeImageFileName,
                aspectRatio: 1,
                pickerItem: $badgePickerItem,
                onRemove: { draft.badgeImageFileName = nil }
            )
            if let artworkMessage {
                Text(artworkMessage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            sellerTextField("Location optional", text: $draft.location)
            sellerTextField("Shipping policy", text: $draft.shippingPolicy, axis: .vertical)
            sellerTextField("Returns policy", text: $draft.returnsPolicy, axis: .vertical)
            sellerTextField("Processing time", text: $draft.processingTime)
            contactToggles
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
        .onChange(of: bannerPickerItem) { _, item in
            guard let item else { return }
            Task { await applyShopArtwork(item, kind: .banner) }
        }
        .onChange(of: badgePickerItem) { _, item in
            guard let item else { return }
            Task { await applyShopArtwork(item, kind: .badge) }
        }
    }

    private var contactToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Seller contact preference")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
            Toggle("Messages", isOn: $draft.contactMessages)
            Toggle("Calls", isOn: $draft.contactCalls)
            Toggle("Chirp", isOn: $draft.contactWalkie)
        }
        .tint(MarketplaceTheme.purple)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var validationMessage: some View {
        if let message = viewModel.sellerValidationMessage {
            Text(message)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .marketplaceCard(cornerRadius: 18)
        }
    }

    @MainActor
    private func applyShopArtwork(_ item: PhotosPickerItem, kind: ShopArtworkKind) async {
        do {
            let fileName = try await ShopArtworkLocalStore.save(item, kind: kind)
            switch kind {
            case .banner:
                draft.bannerImageFileName = fileName
                bannerPickerItem = nil
            case .badge:
                draft.badgeImageFileName = fileName
                badgePickerItem = nil
            }
            artworkMessage = nil
        } catch {
            artworkMessage = "Unable to use that image. Please choose another photo."
        }
    }
}

struct ManageMyShopView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onRoute: (MarketplaceRoute) -> Void
    let onBack: () -> Void
    @State private var launchFeedback: String?
    @State private var launchFeedbackTitle = "Shop Status"
    @State private var showPauseConfirmation = false
    @State private var showDeletePrompt = false
    @State private var showFinalDeleteConfirmation = false
    @State private var deleteConfirmationText = ""

    var body: some View {
        sellerPage(title: "Manage My Shop", back: onBack) {
            if viewModel.hasSellerShop {
                header
                dashboard
                actions
            } else {
                sellerOnboardingState
            }
        }
        .alert(
            launchFeedbackTitle,
            isPresented: Binding(
                get: { launchFeedback != nil },
                set: { if !$0 { launchFeedback = nil } }
            )
        ) {
            Button("OK", role: .cancel) { launchFeedback = nil }
        } message: {
            Text(launchFeedback ?? "")
        }
        .confirmationDialog(
            "Pause this shop?",
            isPresented: $showPauseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Pause Shop", role: .destructive) {
                Task {
                    await viewModel.pauseSellerShop()
                    launchFeedbackTitle = viewModel.sellerValidationMessage == nil ? "Shop Paused" : "Unable to Pause Shop"
                    launchFeedback = viewModel.sellerValidationMessage ?? "Your shop is hidden from public search and purchases. Its content remains in Shop Management."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The shop will disappear from public search and new purchases will stop. Products, settings, orders, and conversations will remain available.")
        }
        .alert("Permanently Delete Shop", isPresented: $showDeletePrompt) {
            TextField("Type shop name or DELETE", text: $deleteConfirmationText)
            Button("Continue", role: .destructive) {
                showFinalDeleteConfirmation = true
            }
            Button("Cancel", role: .cancel) { deleteConfirmationText = "" }
        } message: {
            Text("This permanently deletes the storefront, products, media, favorites, carts, and shop conversations. This cannot be undone.")
        }
        .alert("Final Confirmation", isPresented: $showFinalDeleteConfirmation) {
            Button("Delete Forever", role: .destructive) {
                Task {
                    let deleted = await viewModel.deleteSellerShop(confirmation: deleteConfirmationText)
                    launchFeedbackTitle = deleted ? "Shop Deleted" : "Unable to Delete Shop"
                    launchFeedback = deleted ? "The shop was permanently deleted." : viewModel.sellerValidationMessage
                    deleteConfirmationText = ""
                }
            }
            Button("Cancel", role: .cancel) { deleteConfirmationText = "" }
        } message: {
            Text("There is no restore option. Delete this shop permanently?")
        }
    }

    private var sellerOnboardingState: some View {
        VStack(alignment: .leading, spacing: 14) {
            MarketplaceLogo(size: 58)
            Text("Shop Management")
                .font(.title.weight(.black))
                .foregroundStyle(.white)
            Text("Create your shop from the central + menu first. Shop Management opens here after your storefront exists.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MarketplaceTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            OneWayResolvedLabel("+ → Create Shop", systemImage: "plus.circle.fill")
                .font(.headline.weight(.black))
                .foregroundStyle(MarketplaceTheme.purple)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(MarketplaceTheme.border, lineWidth: 1))
        }
        .padding(18)
        .marketplaceCard(cornerRadius: 24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                OneWayPhysicalIcon(role: .seller, size: 76, state: .selected, container: .showcase)
                VStack(alignment: .leading, spacing: 5) {
                    Text(viewModel.sellerShop?.name ?? "Your Shop")
                        .font(.title.weight(.black))
                        .foregroundStyle(.white)
                    MarketplaceBadge(title: viewModel.shopStatus(for: viewModel.sellerShop).rawValue, icon: statusIcon)
                }
                Spacer()
            }
            if !viewModel.canPublishSellerShop(viewModel.sellerShop) {
                HStack(spacing: 10) {
                    OneWayPhysicalIcon(role: .paymentSetup, size: 46, state: .warning, container: .toolbar)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Payment Setup Optional")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.orange)
                        Text("Launch now with Shop Messages, or connect payouts later")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(MarketplaceTheme.muted)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.34), lineWidth: 1))
            }
            HStack(spacing: 10) {
                Button {
                    if let shop = viewModel.sellerShop { onRoute(.shop(shop.id)) }
                } label: {
                    Text("Preview Store")
                        .font(.subheadline.weight(.black))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(MarketplaceTheme.purple)
                Button {
                    onRoute(.editStore)
                } label: {
                    Text("Edit Store")
                        .font(.subheadline.weight(.black))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }

    private var dashboard: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            stat("Sales", sellerRevenue.currency, .sales)
            stat("Orders", "\(sellerOrders.count)", .orders)
            stat("Visitors", "\(viewModel.sellerShop?.sales ?? 0)", .visitors)
            stat("Messages", "\(sellerMessageCount)", .messages)
            stat("Favorites", "\(viewModel.favorites.count)", .favorites)
            stat("Products", "\(viewModel.sellerProducts.count)", .product)
        }
    }

    private var sellerOrders: [MarketplaceOrder] { viewModel.sellerOrdersForCurrentShop() }
    private var sellerRevenue: Double { sellerOrders.reduce(0) { $0 + ($1.sellerEarnings ?? $1.total) } }
    private var sellerMessageCount: Int {
        guard let shopID = viewModel.sellerShop?.id else { return 0 }
        return viewModel.threads.filter { $0.shopID == shopID }.count
    }

    private func stat(_ title: String, _ value: String, _ role: OneWayIconRole) -> some View {
        HStack(spacing: 10) {
            OneWayPhysicalIcon(role: role, size: 42, container: .toolbar, accessibilityLabel: title)
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.title3.weight(.black)).foregroundStyle(.white)
                Text(title).font(.caption.weight(.bold)).foregroundStyle(MarketplaceTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .marketplaceCard(cornerRadius: 18)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            managementAction("Add Product", .quickAdd) { onRoute(.addProduct) }
            managementAction("Edit Store", .shopSettings) { onRoute(.editStore) }
            managementAction("Manage Products", .product) { onRoute(.manageProducts) }
            managementAction("Orders", .orders) { onRoute(.sellerOrders) }
            managementAction("Messages", .messages) { onRoute(.sellerMessages) }
            managementAction("Payments", .paymentPrivacy) { onRoute(.sellerPayments) }
            managementAction("Seller Plans & Capacity", .plans) { onRoute(.sellerPlans) }
            managementAction("Shop Policies", .privacy) { onRoute(.shopPolicies(viewModel.sellerShopID)) }
            Button {
                if viewModel.shopStatus(for: viewModel.sellerShop) == .active {
                    showPauseConfirmation = true
                } else {
                    let wasPaused = viewModel.shopStatus(for: viewModel.sellerShop) == .paused
                    Task {
                        let launched = await viewModel.launchSellerShop()
                        launchFeedbackTitle = launched ? (wasPaused ? "Shop Resumed" : "Shop Launched") : "Unable to Launch Shop"
                        launchFeedback = launched
                            ? "Your shop is live and searchable in OneWay Shops."
                            : (viewModel.sellerValidationMessage ?? "The shop could not be launched. Please try again.")
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    OneWayPhysicalIcon(role: .seller, size: 46, container: .toolbar, accessibilityLabel: "Shop launch status")
                    Text(viewModel.sellerShopIsSaving
                         ? "Updating Shop…"
                         : (viewModel.shopStatus(for: viewModel.sellerShop) == .active
                            ? "Pause Shop"
                            : (viewModel.shopStatus(for: viewModel.sellerShop) == .paused ? "Resume Shop" : "Launch Shop")))
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Spacer()
                    if viewModel.sellerShopIsSaving {
                        ProgressView().tint(.white)
                    } else {
                        OneWayResolvedIcon(systemName: "chevron.right")
                            .foregroundStyle(MarketplaceTheme.purple)
                    }
                }
                .padding(12)
                .marketplaceCard(cornerRadius: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.sellerShopIsSaving)
            Button(role: .destructive) {
                deleteConfirmationText = ""
                showDeletePrompt = true
            } label: {
                HStack(spacing: 12) {
                    OneWayResolvedIcon(systemName: "trash.fill")
                        .frame(width: 46, height: 46)
                    Text("Delete Shop")
                        .font(.headline.weight(.black))
                    Spacer()
                    OneWayResolvedIcon(systemName: "chevron.right")
                }
                .foregroundStyle(.red)
                .padding(12)
                .marketplaceCard(cornerRadius: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.sellerShopIsSaving)
        }
    }

    private func managementAction(_ title: String, _ role: OneWayIconRole, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                OneWayPhysicalIcon(role: role, size: 46, container: .toolbar, accessibilityLabel: title)
                Text(title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                Spacer()
                OneWayResolvedIcon(systemName: "chevron.right")
                    .foregroundStyle(MarketplaceTheme.purple)
            }
            .padding(12)
            .marketplaceCard(cornerRadius: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusIcon: String {
        switch viewModel.shopStatus(for: viewModel.sellerShop) {
        case .active: return "checkmark.seal.fill"
        case .paused: return "pause.circle.fill"
        case .verificationPending: return "hourglass"
        case .paymentSetupRequired: return "creditcard.trianglebadge.exclamationmark.fill"
        case .restricted: return "exclamationmark.triangle.fill"
        case .archived: return "archivebox.fill"
        case .draft: return "doc.badge.gearshape.fill"
        }
    }
}

struct MyShopsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onOpenAds: () -> Void
    let onRoute: (MarketplaceRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var cloudViewModel = CreationToolsViewModel()
    @State private var showsFileImporter = false
    @State private var pendingPauseShop: MarketplaceShop?

    init(
        viewModel: MarketplaceViewModel,
        onOpenAds: @escaping () -> Void = {},
        onRoute: @escaping (MarketplaceRoute) -> Void
    ) {
        self.viewModel = viewModel
        self.onOpenAds = onOpenAds
        self.onRoute = onRoute
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MyShopsBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(compact: proxy.size.width < 390)
                        capacityCard

                        if viewModel.sellerShops.isEmpty {
                            emptyState
                        } else {
                            section("Your Shops") {
                                LazyVStack(spacing: 14) {
                                    ForEach(viewModel.sellerShops) { shop in
                                        shopRow(shop)
                                    }
                                }
                            }
                        }

                        section("Tools") {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: min(330, proxy.size.width - 36)), spacing: 14)],
                                spacing: 14
                            ) {
                                toolCard(
                                    title: "OneWay Ads",
                                    subtitle: "Create sponsored placements, fund campaigns, review policy status, and track performance.",
                                    icon: "megaphone.fill",
                                    asset: "OneWayCinematicAds",
                                    color: MyShopsPalette.purple,
                                    buttonTitle: "Go to Ads Manager",
                                    action: onOpenAds
                                )
                                toolCard(
                                    title: "Upload File",
                                    subtitle: "Add a private cloud file for use across your OneWay projects.",
                                    icon: "icloud.and.arrow.up.fill",
                                    asset: "OneWayCinematicCloud",
                                    color: MyShopsPalette.green,
                                    buttonTitle: cloudViewModel.isUploading ? "Uploading…" : "Upload File",
                                    action: { showsFileImporter = true }
                                )
                            }
                            cloudStatus
                        }

                        section("Quick Actions") {
                            quickActions
                        }
                    }
                    .frame(maxWidth: 840)
                    .padding(.horizontal, proxy.size.width < 390 ? 14 : 18)
                    .padding(.top, max(12, proxy.safeAreaInsets.top + 4))
                    .padding(.bottom, max(42, proxy.safeAreaInsets.bottom + 28))
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationBarHidden(true)
        .preferredColorScheme(.dark)
        .task {
            await cloudViewModel.load()
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await cloudViewModel.upload(url: url) }
            case .failure(let error):
                cloudViewModel.reportImportFailure(error)
            }
        }
        .confirmationDialog("Pause this shop?", isPresented: Binding(
            get: { pendingPauseShop != nil },
            set: { if !$0 { pendingPauseShop = nil } }
        ), titleVisibility: .visible) {
            Button("Pause Shop", role: .destructive) {
                guard let shop = pendingPauseShop else { return }
                viewModel.selectSellerShop(shop)
                pendingPauseShop = nil
                Task { await viewModel.pauseSellerShop() }
            }
            Button("Cancel", role: .cancel) { pendingPauseShop = nil }
        } message: {
            Text("The shop will be removed from search and new purchases will stop. Its products, orders, settings, and conversations will remain.")
        }
    }

    private func header(compact: Bool) -> some View {
        ZStack(alignment: .top) {
            Image("OneWayMyShopsHero")
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 195 : 230, height: compact ? 195 : 230)
                .offset(x: compact ? 75 : 95, y: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        OneWayResolvedIcon(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(MyShopsPalette.border))
                    }
                    .accessibilityLabel("Back")

                    Spacer()
                    overflowMenu
                        .padding(.trailing, 58)
                }

                Spacer(minLength: compact ? 72 : 88)
                Text("My Shops")
                    .font(.system(size: compact ? 36 : 42, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("Manage your storefront,\nproducts, orders, and customers.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MyShopsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }
        }
        .frame(height: compact ? 225 : 245)
    }

    private var overflowMenu: some View {
        Menu {
            if !viewModel.sellerShops.isEmpty {
                Button {
                    prepareSellerRoute(.editStore)
                } label: {
                    OneWayResolvedLabel("Shop Settings", systemImage: "gearshape.fill")
                }
                Button {
                    prepareSellerRoute(.sellerPayments)
                } label: {
                    OneWayResolvedLabel("Payouts", systemImage: "banknote.fill")
                }
            }
            Button {
                onRoute(.sellerPlans)
            } label: {
                OneWayResolvedLabel("Billing & Plan", systemImage: "creditcard.fill")
            }
        } label: {
            OneWayResolvedIcon(systemName: "ellipsis")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(MyShopsPalette.border))
        }
        .accessibilityLabel("More shop options")
    }

    private var capacityCard: some View {
        let summary = viewModel.sellerCapacitySummary
        return VStack(spacing: 14) {
            HStack(spacing: 0) {
                planMetric(
                    icon: "bag.fill",
                    value: "\(summary.availableShopSlots)",
                    title: summary.availableShopSlots == 1 ? "Available shop slot" : "Available shop slots",
                    color: MyShopsPalette.purple
                )
                Divider()
                    .overlay(MyShopsPalette.border)
                    .padding(.vertical, 5)
                planMetric(
                    icon: "calendar",
                    value: viewModel.nextShopSlotStorePrice ?? "Unavailable",
                    title: "Next slot • App Store",
                    color: MyShopsPalette.green
                )
            }

            Button {
                if summary.availableShopSlots > 0 {
                    onRoute(.createShop)
                } else {
                    onRoute(.sellerPlans)
                }
            } label: {
                OneWayResolvedLabel(
                    summary.availableShopSlots > 0 ? "Create Shop" : "View Upgrade Options",
                    systemImage: summary.availableShopSlots > 0 ? "plus.circle.fill" : "arrow.up.circle.fill"
                )
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [MyShopsPalette.purple, MyShopsPalette.blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .buttonStyle(MyShopsPressStyle())
            .accessibilityHint(summary.availableShopSlots > 0 ? "Opens the shop creation flow." : "Opens seller plans.")

            if summary.availableShopSlots == 0 {
                OneWayResolvedLabel("You’ve reached your current shop limit.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .myShopsCard(color: MyShopsPalette.purple)
    }

    private func planMetric(icon: String, value: String, title: String, color: Color) -> some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 19, weight: .black))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(color.opacity(0.55)))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MyShopsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private var shopStatusSummary: some View {
        let active = viewModel.sellerShops.filter { viewModel.shopStatus(for: $0) == .active }.count
        let paused = viewModel.sellerShops.filter { viewModel.shopStatus(for: $0) == .paused }.count
        return HStack(spacing: 10) {
            shopStat("Owned", "\(viewModel.sellerShops.count)", MyShopsPalette.purple)
            shopStat("Active", "\(active)", MyShopsPalette.green)
            shopStat("Paused", "\(paused)", MyShopsPalette.orange)
        }
    }

    private func shopStat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title2.weight(.black))
                .foregroundStyle(.white)
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.22)))
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            OneWayResolvedIcon(systemName: "storefront.fill")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(MyShopsPalette.purple)
                .frame(width: 64, height: 64)
                .background(MyShopsPalette.purple.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(MyShopsPalette.purple.opacity(0.55)))
            Text("You haven’t created a shop yet.")
                .font(.title3.weight(.black))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Launch your storefront, add products, and start selling on OneWay.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MyShopsPalette.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                onRoute(.createShop)
            } label: {
                OneWayResolvedLabel("Create Shop", systemImage: "plus.circle.fill")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 13)
                    .background(MyShopsPalette.purple, in: Capsule())
            }
            .buttonStyle(MyShopsPressStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .myShopsCard(color: MyShopsPalette.purple)
    }

    private func shopRow(_ shop: MarketplaceShop) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MarketplaceLogo(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.name)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text("\(shop.category) • \(shop.slug).oneway.shop")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MyShopsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                MarketplaceBadge(title: viewModel.shopStatus(for: shop).rawValue, icon: statusIcon(for: shop))
            }
            Text(shop.description)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MyShopsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    viewModel.selectSellerShop(shop)
                    onRoute(.manageShop)
                } label: {
                    OneWayResolvedLabel("Manage", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(MarketplaceTheme.gradient, in: Capsule())
                }
                Button {
                    viewModel.selectSellerShop(shop)
                    onRoute(.shop(shop.id))
                } label: {
                    OneWayResolvedLabel("Preview", systemImage: "eye.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(MyShopsPalette.purple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(MyShopsPalette.border, lineWidth: 1))
                }
            }
            .buttonStyle(MyShopsPressStyle())
            Button {
                viewModel.selectSellerShop(shop)
                if viewModel.shopStatus(for: shop) == .active {
                    pendingPauseShop = shop
                } else {
                    Task { _ = await viewModel.launchSellerShop() }
                }
            } label: {
                OneWayResolvedLabel(lifecycleActionTitle(for: shop), systemImage: lifecycleActionIcon(for: shop))
                    .font(.caption.weight(.black))
                    .foregroundStyle(viewModel.shopStatus(for: shop) == .active ? .orange : MyShopsPalette.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(MyShopsPalette.border, lineWidth: 1))
            }
            .buttonStyle(MyShopsPressStyle())
        }
        .padding(16)
        .myShopsCard(color: statusColor(for: shop))
    }

    private func lifecycleActionTitle(for shop: MarketplaceShop) -> String {
        switch viewModel.shopStatus(for: shop) {
        case .active: return "Pause Shop"
        case .paused: return "Resume Shop"
        default: return "Launch Shop"
        }
    }

    private func lifecycleActionIcon(for shop: MarketplaceShop) -> String {
        viewModel.shopStatus(for: shop) == .active ? "pause.circle.fill" : "play.circle.fill"
    }

    private func statusIcon(for shop: MarketplaceShop) -> String {
        switch viewModel.shopStatus(for: shop) {
        case .active: return "checkmark.seal.fill"
        case .paused: return "pause.circle.fill"
        default: return "doc.fill"
        }
    }

    private func toolCard(
        title: String,
        subtitle: String,
        icon: String,
        asset: String,
        color: Color,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .trailing) {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .offset(x: 16, y: 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        OneWayResolvedIcon(systemName: icon)
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(color)
                            .frame(width: 40, height: 40)
                            .background(color.opacity(0.15), in: Circle())
                            .overlay(Circle().stroke(color.opacity(0.55)))
                        Text(title)
                            .font(.title3.weight(.black))
                            .foregroundStyle(.white)
                    }
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MyShopsPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 205, alignment: .leading)
                    HStack(spacing: 8) {
                        OneWayResolvedIcon(systemName: icon)
                        Text(buttonTitle)
                        Spacer()
                        OneWayResolvedIcon(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.black))
                    .foregroundStyle(color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.55)))
                    .frame(maxWidth: 210)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
            .myShopsCard(color: color)
        }
        .buttonStyle(MyShopsPressStyle())
        .disabled(cloudViewModel.isUploading && title == "Upload File")
        .accessibilityHint(subtitle)
    }

    @ViewBuilder
    private var cloudStatus: some View {
        if cloudViewModel.isOffline {
            statusBanner(
                icon: "wifi.slash",
                title: "Offline",
                detail: "Cloud files will refresh when your connection returns.",
                actionTitle: "Retry"
            ) {
                Task { await cloudViewModel.loadCloudFiles() }
            }
        } else if let message = cloudViewModel.cloudErrorMessage {
            statusBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Cloud unavailable",
                detail: message,
                actionTitle: "Retry"
            ) {
                Task { await cloudViewModel.loadCloudFiles() }
            }
        } else if cloudViewModel.isLoadingCloud || cloudViewModel.isUploading {
            HStack(spacing: 10) {
                ProgressView().tint(MyShopsPalette.purple)
                Text(cloudViewModel.isUploading ? "Uploading securely…" : "Loading private cloud files…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MyShopsPalette.secondaryText)
            }
            .accessibilityElement(children: .combine)
        } else if let message = cloudViewModel.uploadMessage {
            statusBanner(icon: "checkmark.circle.fill", title: "Upload complete", detail: message)
        }
    }

    private func statusBanner(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .foregroundStyle(MyShopsPalette.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MyShopsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.black))
                    .foregroundStyle(MyShopsPalette.purple)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MyShopsPalette.border))
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                quickAction("Create Shop", icon: "bag.fill", color: MyShopsPalette.purple) {
                    viewModel.sellerCapacitySummary.availableShopSlots > 0
                        ? onRoute(.createShop)
                        : onRoute(.sellerPlans)
                }
                if !viewModel.sellerShops.isEmpty {
                    quickAction("Products", icon: "shippingbox.fill", color: MyShopsPalette.blue) {
                        prepareSellerRoute(.manageProducts)
                    }
                    quickAction("Orders", icon: "doc.text.fill", color: MyShopsPalette.orange) {
                        prepareSellerRoute(.sellerOrders)
                    }
                    quickAction("Messages", icon: "bubble.left.and.bubble.right.fill", color: MyShopsPalette.green) {
                        prepareSellerRoute(.sellerMessages)
                    }
                    moreQuickAction
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func quickAction(
        _ title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 78, height: 78)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(color.opacity(0.55)))
        }
        .buttonStyle(MyShopsPressStyle())
    }

    private var moreQuickAction: some View {
        Menu {
            Button {
                prepareSellerRoute(.editStore)
            } label: {
                OneWayResolvedLabel("Shop Settings", systemImage: "gearshape.fill")
            }
            Button {
                prepareSellerRoute(.sellerPayments)
            } label: {
                OneWayResolvedLabel("Payments & Payouts", systemImage: "banknote.fill")
            }
            Button {
                onRoute(.sellerPlans)
            } label: {
                OneWayResolvedLabel("Billing & Plan", systemImage: "creditcard.fill")
            }
        } label: {
            VStack(spacing: 10) {
                OneWayResolvedIcon(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(MyShopsPalette.slateText)
                Text("More")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
            }
            .frame(width: 78, height: 78)
            .background(MyShopsPalette.slate.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(MyShopsPalette.slateText.opacity(0.55)))
        }
        .accessibilityLabel("More shop actions")
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.black))
                .tracking(1.6)
                .foregroundStyle(MyShopsPalette.purple)
            if title == "Your Shops" {
                shopStatusSummary
            }
            content()
        }
    }

    private func prepareSellerRoute(_ route: MarketplaceRoute) {
        if viewModel.sellerShop == nil, let shop = viewModel.sellerShops.first {
            viewModel.selectSellerShop(shop)
        }
        onRoute(route)
    }

    private func statusColor(for shop: MarketplaceShop) -> Color {
        switch viewModel.shopStatus(for: shop) {
        case .active: return MyShopsPalette.green
        case .paused: return MyShopsPalette.orange
        case .restricted, .archived: return MyShopsPalette.pink
        default: return MyShopsPalette.purple
        }
    }
}

private enum MyShopsPalette {
    static let purple = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let blue = Color(red: 0.231, green: 0.510, blue: 0.965)
    static let orange = Color(red: 0.976, green: 0.451, blue: 0.086)
    static let green = Color(red: 0.063, green: 0.725, blue: 0.506)
    static let pink = Color(red: 0.925, green: 0.282, blue: 0.600)
    static let slate = Color(red: 0.122, green: 0.161, blue: 0.216)
    static let slateText = Color(red: 0.58, green: 0.65, blue: 0.75)
    static let secondaryText = Color(red: 0.74, green: 0.74, blue: 0.84)
    static let border = Color.white.opacity(0.12)
}

private struct MyShopsBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.007, green: 0.009, blue: 0.028)
            RadialGradient(
                colors: [MyShopsPalette.purple.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 390
            )
            RadialGradient(
                colors: [MyShopsPalette.blue.opacity(0.10), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 430
            )
        }
        .ignoresSafeArea()
    }
}

private struct MyShopsCardModifier: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                    LinearGradient(
                        colors: [color.opacity(0.11), Color.white.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [color.opacity(0.68), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .shadow(color: color.opacity(0.14), radius: 20, y: 9)
    }
}

private extension View {
    func myShopsCard(color: Color) -> some View {
        modifier(MyShopsCardModifier(color: color))
    }
}

private struct MyShopsPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SellerCapacityBlockedView: View {
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        sellerPage(title: "Capacity Needed", back: { dismiss() }) {
            VStack(alignment: .leading, spacing: 14) {
                OneWayResolvedIcon(systemName: "lock.open.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 46, weight: .black))
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.title.weight(.black))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(MarketplaceTheme.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .marketplaceCard(cornerRadius: 24)
        }
    }
}

struct AddProductView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SellerProductDraft()

    var body: some View {
        sellerPage(title: "Add Product", back: { dismiss() }) {
            SellerProductForm(draft: $draft)

            if let message = viewModel.sellerValidationMessage {
                Text(message).font(.subheadline.weight(.bold)).foregroundStyle(.orange)
            }

            HStack {
                Button("Save Draft") {
                    if viewModel.saveSellerProduct(from: draft, publish: false) { dismiss() }
                }
                .buttonStyle(.bordered)
                Button("Publish Product") {
                    if viewModel.saveSellerProduct(from: draft, publish: true) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .tint(MarketplaceTheme.purple)
            }
        }
        .sheet(isPresented: $viewModel.showProductCapacitySheet) {
            ProductCapacitySheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct EditProductView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let product: MarketplaceProduct
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SellerProductDraft

    init(viewModel: MarketplaceViewModel, product: MarketplaceProduct) {
        self.viewModel = viewModel
        self.product = product
        _draft = State(initialValue: viewModel.draft(for: product))
    }

    var body: some View {
        sellerPage(title: "Edit Product", back: { dismiss() }) {
            SellerProductForm(draft: $draft)

            if let message = viewModel.sellerValidationMessage {
                Text(message).font(.subheadline.weight(.bold)).foregroundStyle(.orange)
            }

            HStack {
                Button("Save Draft") {
                    if viewModel.updateSellerProduct(product, from: draft, publish: false) { dismiss() }
                }
                .buttonStyle(.bordered)
                Button("Publish Product") {
                    if viewModel.updateSellerProduct(product, from: draft, publish: true) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .tint(MarketplaceTheme.purple)
            }
        }
    }
}

private struct SellerProductForm: View {
    @Binding var draft: SellerProductDraft

    var body: some View {
        VStack(spacing: 12) {
            sellerTextField("Product title", text: $draft.title)
            sellerTextField("Description", text: $draft.description, axis: .vertical)
            ProductPhotoEditor(images: $draft.images, productTitle: draft.title)
            sellerTextField("Price", text: $draft.priceText)
                .keyboardType(.decimalPad)
            sellerTextField("Category", text: $draft.category)
            sellerTextField("Inventory quantity", text: $draft.inventoryText)
                .keyboardType(.numberPad)
            sellerTextField("Shipping option", text: $draft.shippingOption)
            Toggle("Privacy verified", isOn: $draft.privacyVerified)
                .tint(MarketplaceTheme.purple)
                .foregroundStyle(MarketplaceTheme.text)
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }
}

struct ManageProductsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    var onRoute: ((MarketplaceRoute) -> Void)?
    let onBack: () -> Void
    @State private var deleteTarget: MarketplaceProduct?
    @State private var showDeleteConfirmation = false

    var body: some View {
        sellerPage(title: "Manage Products", back: onBack) {
            productCapacityPanel
            if viewModel.sellerProducts.isEmpty {
                Text("No products yet. Add your first product to start building your shop.")
                    .foregroundStyle(MarketplaceTheme.muted)
                    .padding(16)
                    .marketplaceCard()
            } else {
                ForEach(viewModel.sellerProducts) { product in
                    VStack(alignment: .leading, spacing: 10) {
                        MarketplaceProductRow(
                            product: product,
                            shop: viewModel.sellerShop,
                            isFavorite: false,
                            onFavorite: {},
                            onAdd: {}
                        )
                        HStack {
                            Button("Edit") {
                                MarketplaceHaptics.tap()
                                onRoute?(.editProduct(product.id))
                            }
                            Button("Duplicate") { viewModel.duplicateSellerProduct(product) }
                            Button("Pause") { MarketplaceHaptics.tap() }
                            Button("Delete", role: .destructive) {
                                deleteTarget = product
                                showDeleteConfirmation = true
                            }
                        }
                        .font(.caption.weight(.black))
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showProductCapacitySheet) {
            ProductCapacitySheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Delete product?", isPresented: $showDeleteConfirmation) {
            if let deleteTarget {
                Button("Delete \(deleteTarget.title)", role: .destructive) {
                    viewModel.deleteSellerProduct(deleteTarget)
                    self.deleteTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }

    private var productCapacityPanel: some View {
        let summary = viewModel.sellerCapacitySummary
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.hasUnlimitedProducts ? "\(summary.activeProductCount) active listings" : "\(summary.activeProductCount) of \(summary.totalProductCapacity ?? 10) Product slots used")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                    Text(summary.hasUnlimitedProducts ? "Unlimited product listings active" : "\(summary.availableProductSlots ?? 0) slots available")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle((summary.hasUnlimitedProducts || (summary.availableProductSlots ?? 0) > 0) ? .green : .orange)
                }
                Spacer()
                Button("Upgrade") { viewModel.showProductCapacitySheet = true }
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(MarketplaceTheme.gradient, in: Capsule())
            }
            if summary.isOverProductCapacity {
                Text("Your account is over capacity. You can still edit, fulfill orders, receive payouts, and support customers, but publishing more products is paused until capacity is restored.")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }
}

struct ProductCapacitySheet: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            MarketplaceTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Unlock more product listings")
                        .font(.title.weight(.black))
                        .foregroundStyle(.white)
                    Text("You've used your free product listings. Save as draft, buy capacity, or join Seller Pro.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MarketplaceTheme.muted)
                    ForEach(viewModel.sellerPackageCatalog.filter { [.productSlot, .productBundle, .unlimitedProducts, .sellerPro].contains($0.packageType) }) { package in
                        packageButton(package)
                    }
                    Button("Keep as Draft") { dismiss() }
                        .font(.headline.weight(.black))
                        .foregroundStyle(MarketplaceTheme.purple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                .padding(18)
                .padding(.bottom, 40)
            }
        }
        .task {
            await viewModel.loadSellerStoreProducts()
        }
    }

    private func packageButton(_ package: SellerPackage) -> some View {
        Button {
            Task {
                await viewModel.buySellerPackage(package)
                if viewModel.sellerValidationMessage?.lowercased().contains("complete") == true {
                    dismiss()
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.displayedSellerName(for: package))
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text(viewModel.displayedSellerDescription(for: package))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MarketplaceTheme.muted)
                }
                Spacer()
                Text(viewModel.displayedSellerPrice(for: package) ?? "Unavailable")
                    .font(.caption.weight(.black))
                    .foregroundStyle(MarketplaceTheme.purple)
            }
            .padding(14)
            .marketplaceCard(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.sellerPackageIsAvailable(package))
        .opacity(viewModel.sellerPackageIsAvailable(package) ? 1 : 0.65)
    }
}

struct SellerPaymentSetupView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss

    private var account: SellerPaymentAccount {
        viewModel.paymentAccount(for: viewModel.sellerShop)
    }

    var body: some View {
        sellerPage(title: "Payment Setup", back: { dismiss() }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect payments")
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(.white)
                Text("OneWay Shops uses a marketplace payment model. Sellers complete identity, bank, and tax onboarding through Stripe Connect before publishing or receiving orders.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Complete every required identity, bank, and tax step before accepting customer payments.")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MarketplaceTheme.faint)
            }
            .padding(18)
            .marketplaceCard(cornerRadius: 24)

            ForEach(SellerPaymentOnboardingStage.allCases.filter { $0 != .notStarted }, id: \.self) { stage in
                onboardingRow(stage)
            }

            Picker("Payout schedule", selection: Binding(
                get: { account.payoutSchedule },
                set: { viewModel.setPayoutSchedule($0, for: viewModel.sellerShop) }
            )) {
                ForEach(SellerPayoutSchedule.allCases, id: \.self) { schedule in
                    Text(schedule.rawValue).tag(schedule)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .marketplaceCard(cornerRadius: 18)

            Button {
                if account.onboardingStage == .notStarted {
                    viewModel.beginPaymentOnboarding(for: viewModel.sellerShop)
                } else {
                    viewModel.advancePaymentOnboarding(for: viewModel.sellerShop)
                }
            } label: {
                OneWayResolvedLabel(account.onboardingStage == .complete ? "Payment Setup Complete" : "Continue Payment Setup", systemImage: "creditcard.fill")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(MarketplaceTheme.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(account.onboardingStage == .complete)
            .opacity(account.onboardingStage == .complete ? 0.65 : 1)
        }
    }

    private func onboardingRow(_ stage: SellerPaymentOnboardingStage) -> some View {
        let completed = stageRank(account.onboardingStage) >= stageRank(stage)
        return HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: completed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(completed ? Color.green : MarketplaceTheme.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text(stage.rawValue)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                Text(stageDetail(stage))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MarketplaceTheme.muted)
            }
            Spacer()
        }
        .padding(14)
        .marketplaceCard(cornerRadius: 18)
    }

    private func stageRank(_ stage: SellerPaymentOnboardingStage) -> Int {
        switch stage {
        case .notStarted: return 0
        case .identity: return 1
        case .bankAccount: return 2
        case .tax: return 3
        case .review: return 4
        case .complete: return 5
        }
    }

    private func stageDetail(_ stage: SellerPaymentOnboardingStage) -> String {
        switch stage {
        case .notStarted: return "Start a Connected Account"
        case .identity: return "KYC and business information"
        case .bankAccount: return "Add payout destination"
        case .tax: return "Tax profile and required forms"
        case .review: return "Confirm all Stripe requirements"
        case .complete: return "Ready to launch and accept payments"
        }
    }
}

struct SellerPaymentsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onRoute: (MarketplaceRoute) -> Void
    @Environment(\.dismiss) private var dismiss

    private var account: SellerPaymentAccount {
        viewModel.paymentAccount(for: viewModel.sellerShop)
    }

    var body: some View {
        sellerPage(title: "Payments", back: { dismiss() }) {
            paymentStatusCard
            balances
            revenue
            operations
            Button {
                onRoute(.sellerPaymentSetup)
            } label: {
                OneWayResolvedLabel(account.onboardingStage == .complete ? "Review Connected Account" : "Resume Payment Setup", systemImage: "arrow.up.right.square.fill")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(MarketplaceTheme.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var paymentStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MarketplaceLogo(size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stripe Connect")
                        .font(.title2.weight(.black))
                        .foregroundStyle(.white)
                    Text(account.stripeConnectedAccountID ?? "Connected account not created")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MarketplaceTheme.muted)
                }
                Spacer()
            }
            OneWayResolvedLabel(account.verificationStatus.rawValue, systemImage: "person.text.rectangle.fill")
                .font(.caption.weight(.black))
                .foregroundStyle(account.verificationStatus == .complete ? .green : .orange)
            OneWayResolvedLabel("Bank account: \(account.bankAccountStatus)", systemImage: "building.columns.fill")
                .font(.caption.weight(.black))
                .foregroundStyle(MarketplaceTheme.muted)
            OneWayResolvedLabel("Payout schedule: \(account.payoutSchedule.rawValue)", systemImage: "calendar")
                .font(.caption.weight(.black))
                .foregroundStyle(MarketplaceTheme.muted)
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }

    private var balances: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            moneyStat("Current Balance", account.currentBalance)
            moneyStat("Pending", account.pendingBalance)
            moneyStat("Available", account.availableBalance)
            moneyStat("Pending Payouts", account.pendingPayouts)
        }
    }

    private var revenue: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            moneyStat("Today's Sales", account.todaySales)
            moneyStat("This Week", account.weekSales)
            moneyStat("This Month", account.monthSales)
            moneyStat("Lifetime", account.lifetimeSales)
        }
    }

    private var operations: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            moneyStat("Completed Payouts", account.completedPayouts)
            moneyStat("Refunds", account.refunds)
            moneyStat("OneWay Sale Fees", account.platformFeesPaid)
            textStat("Disputes", "\(account.disputes)")
            textStat("Tax Documents", account.taxDocumentsStatus)
            textStat("Fee Rule", "Fixed \(viewModel.platformFeeConfiguration.fixedFee.currency) per paid order")
        }
    }

    private func moneyStat(_ title: String, _ value: Double) -> some View {
        textStat(title, value.currency)
    }

    private func textStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(MarketplaceTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .marketplaceCard(cornerRadius: 18)
    }
}

struct SellerPlansCapacityView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingPackage: SellerPackage?
    @State private var purchasingPackageID: String?
    @State private var showsPlanManagement = false

    private var summary: SellerCapacitySummary {
        viewModel.sellerCapacitySummary
    }

    private var productPackages: [SellerPackage] {
        viewModel.sellerPackageCatalog
            .filter {
                $0.active &&
                [.productSlot, .productBundle, .unlimitedProducts].contains($0.packageType)
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var shopPackages: [SellerPackage] {
        viewModel.sellerPackageCatalog
            .filter { $0.active && [.shopSlot, .shopBundle].contains($0.packageType) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var sellerSubscriptions: [SellerPackage] {
        viewModel.sellerPackageCatalog
            .filter { $0.active && $0.packageType == .sellerPro }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ZStack {
            SellerPlansTheme.pageBackground
                .ignoresSafeArea()
            RadialGradient(
                colors: [SellerPlansTheme.purpleAccent.opacity(0.12), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 460
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        currentCapacity
                        packageSection(title: "Product Capacity", packages: productPackages)
                        packageSection(title: "Shop Capacity", packages: shopPackages)
                        packageSection(title: "Seller Subscriptions", packages: sellerSubscriptions)
                        SellerPlansFooter()
                        purchaseStatus
                    }
                    // A vertical ScrollView may accept an ideal width wider than its
                    // viewport. Constrain the plans column to the actual container so
                    // large cards and fixed-size price labels cannot push either edge
                    // off-screen on iPhone.
                    .frame(width: max(0, min(proxy.size.width - 36, 760)), alignment: .leading)
                    .padding(.top, 22)
                    .padding(.bottom, 170)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            await viewModel.loadSellerStoreProducts()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SellerPlansHeader(
                sellerID: maskedSellerID,
                onBack: { dismiss() },
                onManage: { showsPlanManagement = true }
            )
        }
        .sheet(isPresented: $showsPlanManagement) {
            planManagementSheet
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
        }
        .confirmationDialog(
            "Confirm capacity purchase",
            isPresented: Binding(
                get: { pendingPackage != nil },
                set: { if !$0 { pendingPackage = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let package = pendingPackage {
                Button("Buy \(viewModel.displayedSellerName(for: package)) for \(price(for: package))") {
                    purchase(package)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPackage = nil
            }
        } message: {
            if let package = pendingPackage {
                Text(package.billingType == .oneTime
                     ? "This permanently adds capacity to your seller account."
                     : "This starts the existing \(viewModel.storeClassification(for: package)) plan.")
            }
        }
    }

    private var maskedSellerID: String {
        let identifier = AuthTokenStore.shared.currentUserID()
        guard identifier.count > 15 else { return identifier }
        return "\(identifier.prefix(6))...\(identifier.suffix(6))"
    }

    private var currentCapacity: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Current Capacity")
                .font(.system(size: 27, weight: .black, design: .rounded))
                .foregroundStyle(SellerPlansTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            CapacitySummaryCard(
                metrics: [
                    .init(
                        value: "\(summary.usedShopSlots) / \(summary.totalShopCapacity)",
                        label: "Shops",
                        role: .shops
                    ),
                    .init(
                        value: "\(summary.availableShopSlots)",
                        label: "Shop Slots Left",
                        role: .capacity
                    ),
                    .init(
                        value: summary.hasUnlimitedProducts
                            ? "\(summary.activeProductCount) / ∞"
                            : "\(summary.activeProductCount) / \(summary.totalProductCapacity ?? 0)",
                        label: "Products",
                        role: .product
                    ),
                    .init(
                        value: summary.hasUnlimitedProducts
                            ? "Unlimited"
                            : "\(summary.availableProductSlots ?? 0)",
                        label: "Product Slots Left",
                        role: .capacity
                    )
                ],
                warning: summary.isOverShopCapacity || summary.isOverProductCapacity
                    ? "Your account is over capacity. Existing data remains intact while new capacity-consuming actions are paused."
                    : nil
            )
        }
    }

    @ViewBuilder
    private func packageSection(title: String, packages: [SellerPackage]) -> some View {
        if !packages.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                .font(.system(size: 27, weight: .black, design: .rounded))
                .foregroundStyle(SellerPlansTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(packages) { package in
                    ProductCapacityPlanCard(
                        package: package,
                        displayName: viewModel.displayedSellerName(for: package),
                        displayDescription: viewModel.displayedSellerDescription(for: package),
                        price: price(for: package),
                        billingLabel: viewModel.storeClassification(for: package),
                        isAvailable: viewModel.sellerPackageIsAvailable(package),
                        isPurchasing: purchasingPackageID == package.id,
                        wasPurchased: viewModel.sellerPlanTransactions.contains { $0.packageId == package.id },
                        action: { select(package) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var purchaseStatus: some View {
        if let message = viewModel.sellerValidationMessage {
            HStack(alignment: .top, spacing: 10) {
                OneWayStatusIcon(
                    role: successMessage(message) ? .success : .warning,
                    size: 28,
                    accessibilityLabel: successMessage(message) ? "Success" : "Warning"
                )
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SellerPlansTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(14)
            .background(SellerPlansTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(SellerPlansTheme.purpleBorder))
            .accessibilityElement(children: .combine)
        }
    }

    private var planManagementSheet: some View {
        NavigationStack {
            ZStack {
                SellerPlansTheme.pageBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Purchased Capacity")
                            .font(.title2.weight(.black))
                            .foregroundStyle(SellerPlansTheme.primaryText)

                        HStack(spacing: 10) {
                            managementMetric("Product Slots", "\(summary.purchasedProductSlots)")
                            managementMetric("Shop Slots", "\(summary.purchasedShopSlots)")
                            managementMetric(
                                "Subscriptions",
                                "\(viewModel.sellerEntitlements.filter { $0.sourceType == .subscription && $0.status == .active }.count)"
                            )
                        }

                        if viewModel.sellerPlanTransactions.isEmpty {
                            Text("No purchase history yet.")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(SellerPlansTheme.secondaryText)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(viewModel.sellerPlanTransactions.prefix(8)) { transaction in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(transaction.transactionType.replacingOccurrences(of: "_", with: " ").capitalized)
                                            .font(.footnote.weight(.bold))
                                            .foregroundStyle(SellerPlansTheme.primaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer()
                                        Text(transaction.amount.currency)
                                            .font(.footnote.weight(.black))
                                            .foregroundStyle(SellerPlansTheme.purpleAccent)
                                    }
                                    .padding(.vertical, 12)
                                    if transaction.id != viewModel.sellerPlanTransactions.prefix(8).last?.id {
                                        Divider().overlay(SellerPlansTheme.purpleBorder)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .background(SellerPlansTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(SellerPlansTheme.purpleBorder))
                        }

                        Button {
                            Task {
                                await viewModel.restoreSellerPurchases()
                            }
                        } label: {
                            OneWayResolvedLabel("Restore Purchases", systemImage: "arrow.clockwise.circle.fill")
                                .font(.headline.weight(.black))
                                .foregroundStyle(SellerPlansTheme.purpleAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(SellerPlansTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(SellerPlansTheme.purpleBorder))
                        }
                        .buttonStyle(SellerPlansPressStyle())
                    }
                    .padding(18)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Plan Management")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showsPlanManagement = false }
                        .foregroundStyle(SellerPlansTheme.purpleAccent)
                }
            }
        }
    }

    private func managementMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.black))
                .foregroundStyle(SellerPlansTheme.primaryText)
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(SellerPlansTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 82)
        .background(SellerPlansTheme.cardSurface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(SellerPlansTheme.purpleBorder))
        .accessibilityElement(children: .combine)
    }

    private func select(_ package: SellerPackage) {
        guard package.active,
              viewModel.sellerPackageIsAvailable(package),
              purchasingPackageID == nil else {
            if !viewModel.sellerPackageIsAvailable(package) {
                viewModel.sellerValidationMessage = "This package is currently unavailable from the App Store."
            }
            return
        }
        pendingPackage = package
    }

    private func purchase(_ package: SellerPackage) {
        guard package.active, purchasingPackageID == nil else { return }
        pendingPackage = nil
        purchasingPackageID = package.id
        Task {
            await viewModel.buySellerPackage(package)
            purchasingPackageID = nil
        }
    }

    private func price(for package: SellerPackage) -> String {
        if let price = viewModel.displayedSellerPrice(for: package) {
            return price
        }
        return viewModel.sellerStoreProductsAreLoading ? "Loading…" : "Unavailable"
    }

    private func successMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("complete") || normalized.contains("restored")
    }
}

private enum SellerPlansTheme {
    static let pageBackground = Color(red: 0.008, green: 0.012, blue: 0.040)
    static let elevatedSurface = Color(red: 0.045, green: 0.055, blue: 0.120)
    static let cardSurface = Color(red: 0.030, green: 0.038, blue: 0.092)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 0.72, green: 0.70, blue: 0.84)
    static let purpleAccent = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let purpleBorder = Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.34)
    static let successGreen = Color(red: 0.16, green: 0.82, blue: 0.54)
    static let inactiveNavigation = Color(red: 0.48, green: 0.49, blue: 0.62)
}

private struct SellerPlansHeader: View {
    let sellerID: String
    let onBack: () -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Text("Seller Plans")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .foregroundStyle(SellerPlansTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: 140)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .accessibilityAddTraits(.isHeader)

                HStack {
                    SellerPlansHeaderButton(
                        icon: "chevron.left",
                        accessibilityLabel: "Back",
                        action: onBack
                    )
                    Spacer()
                    SellerPlansHeaderButton(
                        icon: "receipt.fill",
                        accessibilityLabel: "Plan management and purchase history",
                        action: onManage
                    )
                }
            }

            SellerIDPill(sellerID: sellerID)
        }
        .padding(.horizontal, 18)
        .padding(.top, headerTopPadding)
        .padding(.bottom, 14)
        .background(SellerPlansTheme.pageBackground.opacity(0.96))
        .overlay(Rectangle().fill(SellerPlansTheme.purpleBorder).frame(height: 1), alignment: .bottom)
    }

    private var headerTopPadding: CGFloat {
#if DEBUG
        42
#else
        8
#endif
    }
}

private struct SellerPlansHeaderButton: View {
    let icon: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let role = OneWayIconRole.resolve(systemName: icon) {
                    OneWayPhysicalIcon(
                        role: role,
                        size: icon == "chevron.left" ? 20 : 34,
                        container: .none,
                        accessibilityLabel: accessibilityLabel,
                        glowIntensity: icon == "chevron.left" ? 0 : 0.14
                    )
                } else {
                    OneWayResolvedIcon(systemName: icon)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(icon == "chevron.left" ? Color.white : SellerPlansTheme.purpleAccent)
                }
            }
                .frame(width: 48, height: 48)
                .background(SellerPlansTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 15))
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(SellerPlansTheme.purpleBorder, lineWidth: 1)
                )
                .shadow(
                    color: icon == "chevron.left" ? .clear : SellerPlansTheme.purpleAccent.opacity(0.15),
                    radius: 12
                )
        }
        .buttonStyle(SellerPlansPressStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct SellerIDPill: View {
    let sellerID: String

    var body: some View {
        HStack(spacing: 7) {
            OneWayPhysicalIcon(
                role: .sellerID,
                size: 24,
                container: .none,
                accessibilityLabel: "Seller ID"
            )
            Text("ID \(sellerID)")
                .font(.caption.weight(.black))
                .foregroundStyle(SellerPlansTheme.secondaryText)
                .lineLimit(1)
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(SellerPlansTheme.elevatedSurface.opacity(0.86), in: Capsule())
            .overlay(Capsule().stroke(SellerPlansTheme.purpleBorder))
            .accessibilityLabel("Seller ID \(sellerID)")
    }
}

private struct CapacityMetric: Identifiable {
    let id = UUID()
    let value: String
    let label: String
    let role: OneWayIconRole
}

private struct CapacitySummaryCard: View {
    let metrics: [CapacityMetric]
    let warning: String?

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(metrics) { metric in
                    CapacityMetricTile(metric: metric)
                }
            }

            if let warning {
                HStack(alignment: .top, spacing: 8) {
                    OneWayStatusIcon(role: .warning, size: 26, accessibilityLabel: "Capacity warning")
                    Text(warning)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(SellerPlansTheme.elevatedSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(SellerPlansTheme.purpleBorder))
        .shadow(color: SellerPlansTheme.purpleAccent.opacity(0.10), radius: 18, y: 8)
    }
}

private struct CapacityMetricTile: View {
    let metric: CapacityMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            OneWayFeatureIcon(
                role: metric.role,
                size: 44,
                accessibilityLabel: metric.label
            )

            Text(metric.value)
                .font(.system(size: 23, weight: .black, design: .rounded))
                .foregroundStyle(SellerPlansTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(metric.label)
                .font(.caption.weight(.bold))
                .foregroundStyle(SellerPlansTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        .padding(13)
        .background(SellerPlansTheme.cardSurface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(SellerPlansTheme.purpleBorder.opacity(0.76)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.label), \(metric.value)")
    }
}

private struct ProductCapacityPlanCard: View {
    let package: SellerPackage
    let displayName: String
    let displayDescription: String
    let price: String
    let billingLabel: String
    let isAvailable: Bool
    let isPurchasing: Bool
    let wasPurchased: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize >= .xLarge {
                    verticalContent
                } else {
                    ViewThatFits(in: .horizontal) {
                        horizontalContent
                        verticalContent
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .background(SellerPlansTheme.cardSurface, in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).stroke(SellerPlansTheme.purpleBorder))
            .shadow(color: SellerPlansTheme.purpleAccent.opacity(0.09), radius: 14, y: 7)
        }
        .buttonStyle(SellerPlansPressStyle())
        .disabled(isPurchasing || !package.active || !isAvailable)
        .opacity(isAvailable || isPurchasing ? 1 : 0.68)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isAvailable ? "Double tap to review this purchase." : "This plan is currently unavailable from the App Store.")
        .accessibilityValue(isPurchasing ? "Purchasing" : (wasPurchased ? "Previously purchased" : (isAvailable ? "Available" : "Unavailable")))
    }

    private var horizontalContent: some View {
        HStack(alignment: .center, spacing: 14) {
            planIcon
            planDetails
                .layoutPriority(1)
            Spacer(minLength: 4)
            priceBlock
        }
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                planIcon
                planDetails
            }
            priceBlock
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var planIcon: some View {
        OneWayPhysicalIcon(
            role: iconRole,
            size: 58,
            container: .feature,
            accessibilityLabel: "\(displayName) plan",
            glowIntensity: 0.20
        )
    }

    private var planDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(displayName)
                    .font(.headline.weight(.black))
                    .foregroundStyle(SellerPlansTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if wasPurchased {
                    OneWayStatusIcon(role: .success, size: 22, accessibilityLabel: "Previously purchased")
                        .accessibilityHidden(true)
                }
            }
            Text(displayDescription)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SellerPlansTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            PermanentCapacityBadge(isPermanent: package.billingType == .oneTime)
        }
    }

    private var priceBlock: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if isPurchasing {
                ProgressView()
                    .tint(SellerPlansTheme.purpleAccent)
                    .accessibilityHidden(true)
            } else {
                Text(isAvailable ? price : "Unavailable")
                    .font(.system(size: isAvailable ? 21 : 14, weight: .black, design: .rounded))
                    .foregroundStyle(SellerPlansTheme.purpleAccent)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(billingLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(SellerPlansTheme.secondaryText)
        }
    }

    private var iconRole: OneWayIconRole {
        switch package.packageType {
        case .shopSlot, .shopBundle: return .shops
        case .sellerPro: return .storefront
        case .unlimitedProducts, .productSlot, .productBundle: return .product
        }
    }

    private var accessibilityLabel: String {
        "\(displayName). \(displayDescription). \(price), \(billingLabel). \(package.billingType == .oneTime ? "Permanent capacity after verified purchase." : "Capacity remains active with the subscription.")"
    }
}

private struct PermanentCapacityBadge: View {
    let isPermanent: Bool

    var body: some View {
        HStack(spacing: 5) {
            OneWayPhysicalIcon(
                role: isPermanent ? .permanentCapacity : .plans,
                size: 19,
                container: .none,
                accessibilityLabel: isPermanent ? "Permanent capacity" : "Subscription capacity",
                glowIntensity: 0.08
            )
            Text(isPermanent ? "Permanent capacity after purchase" : "Capacity while subscribed")
                .font(.caption2.weight(.black))
                .foregroundStyle(SellerPlansTheme.successGreen)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SellerPlansFooter: View {
    var body: some View {
        HStack(spacing: 12) {
            divider
            Text("Choose the plan that matches your current Shop capacity needs.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SellerPlansTheme.secondaryText)
                .fixedSize()
            divider
        }
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle()
            .fill(SellerPlansTheme.purpleBorder)
            .frame(height: 1)
    }
}

private struct SellerPlansPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SellerOrdersView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onRoute: (MarketplaceRoute) -> Void
    let onBack: () -> Void

    private var orders: [MarketplaceOrder] {
        viewModel.sellerOrdersForCurrentShop()
    }

    var body: some View {
        sellerPage(title: "Orders", back: onBack) {
            if orders.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    OneWayResolvedIcon(systemName: "list.clipboard.fill")
                        .font(.system(size: 40, weight: .black))
                        .foregroundStyle(MarketplaceTheme.purple)
                    Text("No paid orders yet")
                        .font(.title2.weight(.black))
                        .foregroundStyle(.white)
                    Text("Orders appear here after checkout succeeds and the payment split is recorded.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MarketplaceTheme.muted)
                }
                .padding(18)
                .marketplaceCard(cornerRadius: 24)
            } else {
                ForEach(orders) { order in
                    Button {
                        onRoute(.sellerOrderDetail(order.id))
                    } label: {
                        orderRow(order)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await viewModel.syncMarketplaceOrders() }
    }

    private func orderRow(_ order: MarketplaceOrder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(order.title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                Spacer()
                Text(order.total.currency)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
            }
            HStack {
                MarketplaceBadge(title: order.status, icon: "shippingbox.fill")
                Spacer()
                Text(order.paymentStatus?.rawValue ?? "Payment pending")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(MarketplaceTheme.muted)
            }
        }
        .padding(14)
        .marketplaceCard(cornerRadius: 18)
    }
}

struct SellerOrderDetailView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let order: MarketplaceOrder
    @Environment(\.dismiss) private var dismiss

    private var currentOrder: MarketplaceOrder {
        viewModel.orders.first(where: { $0.id == order.id }) ?? order
    }

    var body: some View {
        sellerPage(title: "Order Detail", back: { dismiss() }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(currentOrder.title)
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(.white)
                MarketplaceBadge(title: currentOrder.status, icon: "shippingbox.fill")
                paymentLine("Customer Paid", currentOrder.total)
                paymentLine("Tax", currentOrder.tax ?? 0)
                paymentLine("Shipping", currentOrder.shipping ?? 0)
                paymentLine("Discount", currentOrder.discount ?? 0)
                paymentLine("OneWay Sale Fee", currentOrder.platformFee ?? 0)
                paymentLine("Payment Processing", currentOrder.processingFee ?? 0)
                paymentLine("Refunds", currentOrder.refundedAmount ?? 0)
                paymentLine("Disputes", currentOrder.disputedAmount ?? 0)
                paymentLine("Seller Net Earnings", currentOrder.sellerEarnings ?? 0, bold: true)
                paymentLine("Payout Amount", currentOrder.payoutAmount ?? currentOrder.sellerEarnings ?? 0)
                detailLine("Payment", currentOrder.paymentStatus?.rawValue ?? "Unknown")
                detailLine("Payout", currentOrder.payoutStatus?.rawValue ?? "Unknown")
                detailLine("Refund", currentOrder.refundStatus?.rawValue ?? "None")
                detailLine("Dispute", currentOrder.disputeStatus?.rawValue ?? "None")
                detailLine("Transaction", currentOrder.transactionID ?? "Not available")
                detailLine("Connected Account", currentOrder.connectedAccountID ?? "Not available")
            }
            .padding(16)
            .marketplaceCard(cornerRadius: 24)

            HStack {
                Button("Accept") { viewModel.acceptOrder(currentOrder) }
                Button("Fulfill") { viewModel.fulfillOrder(currentOrder) }
                Button("Refund", role: .destructive) { viewModel.refundOrder(currentOrder) }
            }
            .buttonStyle(.borderedProminent)
            .tint(MarketplaceTheme.purple)
        }
    }

    private func paymentLine(_ title: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(amount.currency).fontWeight(bold ? .black : .semibold)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(MarketplaceTheme.muted)
    }
}

private struct ProductPhotoEditor: View {
    @Binding var images: [MarketplaceProductImage]
    let productTitle: String
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var previewImage: MarketplaceProductImage?
    @State private var errorMessage: String?

    private var sortedImages: [MarketplaceProductImage] {
        images.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var remainingSlots: Int {
        max(0, 10 - images.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Product Photos")
                        .font(.headline.weight(.black))
                        .foregroundStyle(MarketplaceTheme.text)
                    Text("\(images.count)/10 images • one primary required to publish")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MarketplaceTheme.muted)
                }
                Spacer()
                addPhotoMenu
            }

            primaryPreview
            thumbnailStrip

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(14)
        .background(MarketplaceTheme.lavenderCard.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(MarketplaceTheme.border, lineWidth: 1))
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { await addPickerItems(newItems) }
        }
        .sheet(isPresented: $showCamera) {
            CameraCaptureView { image in
                addCameraImage(image)
            }
        }
        .fullScreenCover(item: $previewImage) { image in
            ProductPhotoFullScreenViewer(image: image)
        }
    }

    private var addPhotoMenu: some View {
        Menu {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: remainingSlots, matching: .images) {
                OneWayResolvedLabel("Choose From Library", systemImage: "photo.on.rectangle")
            }
            PhotosPicker(selection: $pickerItems, maxSelectionCount: remainingSlots, matching: .images) {
                OneWayResolvedLabel("Select Multiple Photos", systemImage: "rectangle.stack.badge.plus")
            }
            Button {
                showCamera = true
            } label: {
                OneWayResolvedLabel("Take Photo", systemImage: "camera.fill")
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera) || remainingSlots == 0)
        } label: {
            OneWayResolvedLabel("Add Photos", systemImage: "plus")
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(remainingSlots == 0 ? Color.gray : MarketplaceTheme.purple, in: Capsule())
        }
        .disabled(remainingSlots == 0)
    }

    @ViewBuilder
    private var primaryPreview: some View {
        if let primary = sortedImages.first(where: \.isPrimary) ?? sortedImages.first,
           let uiImage = ProductPhotoLocalStore.image(named: primary.mediumFileName) ?? ProductPhotoLocalStore.image(named: primary.originalFileName) {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .clipped()
                HStack {
                    OneWayResolvedLabel("Primary", systemImage: "star.fill")
                    Spacer()
                    Text(primary.uploadState == .completed ? "Uploaded" : primary.uploadState.rawValue.capitalized)
                }
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(10)
            }
            .onTapGesture { previewImage = primary }
        } else {
            VStack(spacing: 10) {
                OneWayResolvedIcon(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(MarketplaceTheme.purple)
                Text("Add your first product photo")
                    .font(.headline.weight(.black))
                    .foregroundStyle(MarketplaceTheme.text)
                Text("Photos are compressed safely and stored locally until backend product media sync is enabled.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(MarketplaceTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(MarketplaceTheme.border, lineWidth: 1))
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(sortedImages) { image in
                    thumbnailTile(image)
                }
                addTile
            }
            .padding(.vertical, 2)
        }
    }

    private func thumbnailTile(_ image: MarketplaceProductImage) -> some View {
        VStack(spacing: 7) {
            Button {
                previewImage = image
            } label: {
                ZStack(alignment: .topTrailing) {
                    if let uiImage = ProductPhotoLocalStore.image(named: image.thumbnailFileName) ?? ProductPhotoLocalStore.image(named: image.originalFileName) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        MarketplaceProductArt(seed: productTitle, height: 76)
                    }

                    if image.isPrimary {
                        OneWayResolvedIcon(systemName: "star.fill")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(MarketplaceTheme.purple, in: Circle())
                            .padding(5)
                    }
                }
                .frame(width: 82, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(image.isPrimary ? MarketplaceTheme.purple : MarketplaceTheme.border, lineWidth: image.isPrimary ? 2 : 1))
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button { move(image, by: -1) } label: { OneWayResolvedIcon(systemName: "chevron.left") }
                    .disabled(image.sortOrder == 0)
                Button { makePrimary(image) } label: { OneWayResolvedIcon(systemName: "star") }
                    .disabled(image.isPrimary)
                Button { move(image, by: 1) } label: { OneWayResolvedIcon(systemName: "chevron.right") }
                    .disabled(image.sortOrder >= images.count - 1)
                Button(role: .destructive) { remove(image) } label: { OneWayResolvedIcon(systemName: "trash") }
            }
            .font(.caption2.weight(.black))
            .foregroundStyle(MarketplaceTheme.purple)
        }
        .frame(width: 92)
    }

    private var addTile: some View {
        PhotosPicker(selection: $pickerItems, maxSelectionCount: remainingSlots, matching: .images) {
            VStack(spacing: 6) {
                OneWayResolvedIcon(systemName: "plus")
                    .font(.headline.weight(.black))
                Text("Add")
                    .font(.caption2.weight(.black))
            }
            .foregroundStyle(remainingSlots == 0 ? MarketplaceTheme.faint : MarketplaceTheme.purple)
            .frame(width: 82, height: 76)
            .background(MarketplaceTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(MarketplaceTheme.border, lineWidth: 1))
        }
        .disabled(remainingSlots == 0)
    }

    private func addPickerItems(_ items: [PhotosPickerItem]) async {
        defer { pickerItems = [] }
        errorMessage = nil
        for item in items.prefix(remainingSlots) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let uiImage = UIImage(data: data) else {
                    throw ProductPhotoError.unreadable
                }
                try appendImage(uiImage)
            } catch {
                errorMessage = "One photo could not be processed. Try a JPEG, PNG, HEIC, or another image."
            }
        }
    }

    private func addCameraImage(_ image: UIImage) {
        do {
            try appendImage(image)
        } catch {
            errorMessage = "Camera photo could not be saved. Please try again."
        }
    }

    private func appendImage(_ uiImage: UIImage) throws {
        guard images.count < 10 else {
            errorMessage = "You can add up to 10 photos per product."
            return
        }
        var image = try ProductPhotoLocalStore.save(uiImage, altText: productTitle.isEmpty ? "Product photo" : productTitle)
        image.sortOrder = images.count
        image.isPrimary = images.isEmpty
        image.uploadState = .completed
        image.progress = 1
        images.append(image)
        normalizeImages()
        MarketplaceHaptics.success()
    }

    private func makePrimary(_ image: MarketplaceProductImage) {
        for index in images.indices {
            images[index].isPrimary = images[index].id == image.id
        }
        MarketplaceHaptics.tap()
    }

    private func move(_ image: MarketplaceProductImage, by offset: Int) {
        let ordered = sortedImages
        guard let from = ordered.firstIndex(where: { $0.id == image.id }) else { return }
        let to = max(0, min(ordered.count - 1, from + offset))
        guard from != to else { return }
        var next = ordered
        next.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        images = next
        normalizeImages()
        MarketplaceHaptics.tap()
    }

    private func remove(_ image: MarketplaceProductImage) {
        ProductPhotoLocalStore.delete(image)
        images.removeAll { $0.id == image.id }
        normalizeImages()
        MarketplaceHaptics.tap()
    }

    private func normalizeImages() {
        images = images.enumerated().map { index, image in
            var copy = image
            copy.sortOrder = index
            copy.updatedAt = Date()
            return copy
        }
        if !images.isEmpty && !images.contains(where: \.isPrimary) {
            images[0].isPrimary = true
        }
    }
}

struct ProductPhotoFullScreenViewer: View {
    let image: MarketplaceProductImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if image.mimeType == "image/remote",
               let remoteURL = URL(string: image.storageKey),
               remoteURL.scheme == "https" {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .success(let remoteImage):
                        remoteImage.resizable().scaledToFit()
                    case .failure:
                        ContentUnavailableView(
                            "Photo unavailable",
                            systemImage: "photo",
                            description: Text("The seller's photo could not be loaded.")
                        )
                        .foregroundStyle(.white)
                    default:
                        ProgressView().tint(.white)
                    }
                }
                .accessibilityLabel(image.altText)
                .padding()
            } else if let uiImage = ProductPhotoLocalStore.image(named: image.originalFileName) ?? ProductPhotoLocalStore.image(named: image.mediumFileName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(image.altText)
                    .padding()
            }
            Button {
                dismiss()
            } label: {
                OneWayResolvedIcon(systemName: "xmark")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.18), in: Circle())
            }
            .padding()
        }
    }
}

enum ProductPhotoLocalStore {
    static func image(named fileName: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: fileName).path)
    }

    static func save(_ image: UIImage, altText: String) throws -> MarketplaceProductImage {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let id = UUID()
        let normalized = image.normalizedForProductUpload(maxLongestEdge: 2400)
        let medium = image.normalizedForProductUpload(maxLongestEdge: 1200)
        let thumbnail = image.normalizedForProductUpload(maxLongestEdge: 300)
        guard let originalData = normalized.jpegData(compressionQuality: 0.86),
              let mediumData = medium.jpegData(compressionQuality: 0.82),
              let thumbnailData = thumbnail.jpegData(compressionQuality: 0.78) else {
            throw ProductPhotoError.unreadable
        }

        let originalName = "\(id.uuidString)-original.jpg"
        let mediumName = "\(id.uuidString)-medium.jpg"
        let thumbnailName = "\(id.uuidString)-thumbnail.jpg"
        try originalData.write(to: url(for: originalName), options: [.atomic])
        try mediumData.write(to: url(for: mediumName), options: [.atomic])
        try thumbnailData.write(to: url(for: thumbnailName), options: [.atomic])

        return MarketplaceProductImage(
            storageKey: "local-shops/products/\(id.uuidString)/original.jpg",
            originalFileName: originalName,
            thumbnailFileName: thumbnailName,
            mediumFileName: mediumName,
            width: normalized.size.width,
            height: normalized.size.height,
            fileSize: originalData.count,
            mimeType: "image/jpeg",
            sortOrder: 0,
            isPrimary: false,
            altText: altText,
            uploadState: .completed,
            progress: 1,
            errorMessage: nil
        )
    }

    static func delete(_ image: MarketplaceProductImage) {
        [image.originalFileName, image.mediumFileName, image.thumbnailFileName].forEach { fileName in
            try? FileManager.default.removeItem(at: url(for: fileName))
        }
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OneWayProductPhotos", isDirectory: true)
    }

    private static func url(for fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }
}

enum ShopArtworkLocalStore {
    static func image(named fileName: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: fileName).path)
    }

    static func fileName(fromSeed seed: String) -> String? {
        let prefix = "local-shop-art:"
        guard seed.hasPrefix(prefix) else { return nil }
        return String(seed.dropFirst(prefix.count))
    }

    static func image(fromSeed seed: String) -> UIImage? {
        guard let fileName = fileName(fromSeed: seed) else { return nil }
        return image(named: fileName)
    }

    static func save(_ item: PhotosPickerItem, kind: ShopArtworkKind) async throws -> String {
        guard let data = try await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            throw ProductPhotoError.unreadable
        }
        return try save(image, kind: kind)
    }

    static func save(_ image: UIImage, kind: ShopArtworkKind) throws -> String {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let maxEdge: CGFloat = kind == .banner ? 2400 : 1000
        let normalized = image.normalizedForProductUpload(maxLongestEdge: maxEdge)
        guard let data = normalized.jpegData(compressionQuality: kind == .banner ? 0.86 : 0.9) else {
            throw ProductPhotoError.unreadable
        }
        let fileName = "\(kind.rawValue)-\(id).jpg"
        try data.write(to: url(for: fileName), options: [.atomic])
        return fileName
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OneWayShopArtwork", isDirectory: true)
    }

    private static func url(for fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }
}

private enum ProductPhotoError: Error {
    case unreadable
}

private extension UIImage {
    func normalizedForProductUpload(maxLongestEdge: CGFloat) -> UIImage {
        let sourceSize = size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return self }
        let longest = max(sourceSize.width, sourceSize.height)
        let scale = min(1, maxLongestEdge / longest)
        let targetSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: targetSize)).fill()
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

struct EditStoreView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onBack: () -> Void
    @State private var draft: SellerShopDraft
    @State private var bannerPickerItem: PhotosPickerItem?
    @State private var badgePickerItem: PhotosPickerItem?
    @State private var artworkMessage: String?

    init(viewModel: MarketplaceViewModel, onBack: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onBack = onBack
        _draft = State(initialValue: viewModel.draftForSellerShop())
    }

    var body: some View {
        sellerPage(title: "Edit Store", back: onBack) {
            VStack(spacing: 12) {
                sellerTextField("Shop name", text: $draft.shopName)
                sellerTextField("Description", text: $draft.description, axis: .vertical)
                sellerTextField("Category", text: $draft.category)
                ShopArtworkPickerRow(
                    title: "Banner artwork",
                    subtitle: "Wide storefront image",
                    systemImage: "photo.fill",
                    fileName: draft.bannerImageFileName,
                    aspectRatio: 2.8,
                    pickerItem: $bannerPickerItem,
                    onRemove: { draft.bannerImageFileName = nil }
                )
                ShopArtworkPickerRow(
                    title: "Circular badge artwork",
                    subtitle: "Shop avatar image",
                    systemImage: "person.crop.circle.fill",
                    fileName: draft.badgeImageFileName,
                    aspectRatio: 1,
                    pickerItem: $badgePickerItem,
                    onRemove: { draft.badgeImageFileName = nil }
                )
                if let artworkMessage {
                    Text(artworkMessage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                sellerTextField("Shipping policy", text: $draft.shippingPolicy, axis: .vertical)
                sellerTextField("Returns policy", text: $draft.returnsPolicy, axis: .vertical)
                sellerTextField("Processing time", text: $draft.processingTime)
                Toggle("Messages", isOn: $draft.contactMessages)
                Toggle("Calls", isOn: $draft.contactCalls)
                Toggle("Chirp", isOn: $draft.contactWalkie)
            }
            .tint(MarketplaceTheme.purple)
            .padding(16)
            .marketplaceCard(cornerRadius: 24)
            .onChange(of: bannerPickerItem) { _, item in
                guard let item else { return }
                Task { await applyShopArtwork(item, kind: .banner) }
            }
            .onChange(of: badgePickerItem) { _, item in
                guard let item else { return }
                Task { await applyShopArtwork(item, kind: .badge) }
            }

            Button("Save Changes") {
                Task {
                    if await viewModel.updateSellerShop(from: draft) { onBack() }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(MarketplaceTheme.purple)
            .disabled(viewModel.sellerShopIsSaving)
        }
    }

    @MainActor
    private func applyShopArtwork(_ item: PhotosPickerItem, kind: ShopArtworkKind) async {
        do {
            let fileName = try await ShopArtworkLocalStore.save(item, kind: kind)
            switch kind {
            case .banner:
                draft.bannerImageFileName = fileName
                bannerPickerItem = nil
            case .badge:
                draft.badgeImageFileName = fileName
                badgePickerItem = nil
            }
            artworkMessage = nil
        } catch {
            artworkMessage = "Unable to use that image. Please choose another photo."
        }
    }
}

struct SellerPlaceholderListView: View {
    let title: String
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        sellerPage(title: title, back: { dismiss() }) {
            Text(message)
                .foregroundStyle(MarketplaceTheme.muted)
                .padding(16)
                .marketplaceCard()
        }
    }
}

private func sellerPage<Content: View>(title: String, back: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
    ZStack {
        MarketplaceTheme.background.ignoresSafeArea()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(18)
            .padding(.bottom, 110)
        }
    }
    .navigationBarBackButtonHidden(true)
    .safeAreaInset(edge: .top, spacing: 0) {
        MarketplaceBackBar(title: title, onBack: back)
    }
}

private func sellerTextField(_ title: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
    TextField(title, text: text, axis: axis)
        .textInputAutocapitalization(.words)
        .foregroundStyle(.white)
        .padding(13)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MarketplaceTheme.border, lineWidth: 1))
}

enum ShopArtworkKind: String {
    case banner
    case badge
}

private struct ShopArtworkPickerRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let fileName: String?
    let aspectRatio: CGFloat
    @Binding var pickerItem: PhotosPickerItem?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                preview
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text(fileName == nil ? subtitle : "Custom artwork selected")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(MarketplaceTheme.muted)
                }
                Spacer()
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text(fileName == nil ? "Upload" : "Replace")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(MarketplaceTheme.gradient, in: Capsule())
                }
            }

            if fileName != nil {
                Button(action: onRemove) {
                    OneWayResolvedLabel("Use styled default art", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.black))
                        .foregroundStyle(MarketplaceTheme.purple)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(13)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MarketplaceTheme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var preview: some View {
        let width: CGFloat = aspectRatio > 1 ? 82 : 54
        let height: CGFloat = aspectRatio > 1 ? 46 : 54
        if let fileName, let image = ShopArtworkLocalStore.image(named: fileName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: aspectRatio > 1 ? 12 : 27, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: aspectRatio > 1 ? 12 : 27, style: .continuous)
                        .stroke(MarketplaceTheme.purple.opacity(0.7), lineWidth: 1)
                )
        } else {
            OneWayResolvedIcon(systemName: systemImage)
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(MarketplaceTheme.purple)
                .frame(width: width, height: height)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: aspectRatio > 1 ? 12 : 27, style: .continuous))
        }
    }
}

private func placeholderRow(_ title: String, _ icon: String) -> some View {
    HStack {
        OneWayResolvedIcon(systemName: icon).foregroundStyle(MarketplaceTheme.purple)
        Text(title).foregroundStyle(.white)
        Spacer()
        Text("Placeholder").font(.caption.weight(.black)).foregroundStyle(MarketplaceTheme.faint)
    }
    .padding(13)
    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
}

private func sellerAction(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack {
            OneWayResolvedIcon(systemName: icon).foregroundStyle(MarketplaceTheme.purple)
            Text(title).foregroundStyle(.white)
            Spacer()
            OneWayResolvedIcon(systemName: "chevron.right").foregroundStyle(MarketplaceTheme.faint)
        }
        .font(.headline.weight(.black))
        .padding(15)
        .marketplaceCard(cornerRadius: 18)
    }
    .buttonStyle(.plain)
}
