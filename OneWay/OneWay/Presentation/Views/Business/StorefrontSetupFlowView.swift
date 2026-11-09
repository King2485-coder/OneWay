import SwiftUI
import PhotosUI
import UIKit

private let maxProductImageUploadBytes = 10 * 1024 * 1024

private func jpegUploadData(from item: PhotosPickerItem) async throws -> Data? {
    guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
    guard let image = UIImage(data: data) else { return nil }

    for quality in stride(from: 0.88, through: 0.48, by: -0.10) {
        if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= maxProductImageUploadBytes {
            return jpeg
        }
    }
    return image.jpegData(compressionQuality: 0.38)
}

struct StorefrontSetupFlowView: View {
    private enum Step: Int, CaseIterable {
        case shopName = 0
        case products = 1
        case buyerContact = 2
        case payments = 4
        case preview = 3

        var title: String {
            switch self {
            case .shopName: return "Shop name and link"
            case .products: return "First product"
            case .buyerContact: return "Policies & contact"
            case .payments: return "Payments"
            case .preview: return "Preview and launch"
            }
        }
    }

    private enum SetupSaveSource: String {
        case localDraft
        case backendStore
        case userEdit
    }

    private struct LocalSetupDraftSnapshot: Codable {
        var storefront: Storefront
        var policy: StorePolicyDraft
        var productTitle: String
        var productDescription: String
        var productPrice: String
        var productInventory: String
        var productImageURL: String?
        var productPaymentLink: String?
        var productTrackInventory: Bool?
        var productAvailable: Bool?
        var stepRawValue: Int
        var savedAt: Date
    }

    @Environment(\.openURL) private var openURL
    @ObservedObject var viewModel: BusinessViewModel
    let onPreviewDraft: () -> Void
    let onPublished: () -> Void

    @State private var step: Step = .shopName
    @State private var draftStorefront: Storefront?
    @State private var draftPolicy: StorePolicyDraft = .default
    @State private var productTitle = ""
    @State private var productDescription = ""
    @State private var productPrice = ""
    @State private var productInventory = "1"
    @State private var productImageURL = ""
    @State private var productPaymentLink = ""
    @State private var productTrackInventory = true
    @State private var productAvailable = true
    @State private var productImagePickerItem: PhotosPickerItem?
    @State private var isUploadingProductImage = false
    @State private var publishedStorefront: Storefront?
    @State private var logoPickerItem: PhotosPickerItem?
    @State private var bannerPickerItem: PhotosPickerItem?
    @State private var isUploadingLogo = false
    @State private var isUploadingBanner = false
    @State private var isSaving = false
    @State private var isPublishing = false
    @State private var handleCheckTask: Task<Void, Never>?
    @State private var didBootstrapSetupState = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                progressHeader
                if let errorMessage = viewModel.errorMessage {
                    inlineMessage(errorMessage)
                }
                currentStepView
            }
            .padding(16)
            .safeAreaPadding(.bottom, 96)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Shop Setup")
        .task {
            guard !didBootstrapSetupState else { return }
            didBootstrapSetupState = true
            await initializeSetupState()
        }
        .onChange(of: logoPickerItem) { _, item in
            guard let item else { return }
            Task { await uploadImage(from: item, kind: .logo) }
        }
        .onChange(of: bannerPickerItem) { _, item in
            guard let item else { return }
            Task { await uploadImage(from: item, kind: .banner) }
        }
        .onChange(of: productImagePickerItem) { _, item in
            guard let item else { return }
            Task { await uploadProductImage(from: item) }
        }
        .onChange(of: step) { _, _ in persistLocalDraft() }
        .onChange(of: draftStorefront) { _, store in
            persistLocalDraft()
            if let handle = store?.business.handle {
                scheduleHandleCheck(handle)
            }
        }
        .onChange(of: draftPolicy) { _, _ in persistLocalDraft() }
        .onChange(of: productTitle) { _, _ in persistLocalDraft() }
        .onChange(of: productDescription) { _, _ in persistLocalDraft() }
        .onChange(of: productPrice) { _, _ in persistLocalDraft() }
        .onChange(of: productInventory) { _, _ in persistLocalDraft() }
        .onChange(of: productImageURL) { _, _ in persistLocalDraft() }
        .onChange(of: productPaymentLink) { _, _ in persistLocalDraft() }
        .onChange(of: productTrackInventory) { _, _ in persistLocalDraft() }
        .onChange(of: productAvailable) { _, _ in persistLocalDraft() }
        .onDisappear {
            handleCheckTask?.cancel()
            persistLocalDraft()
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About 3 minutes")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.accentGold)
            Text("Edit your storefront")
                .font(.system(size: 34, weight: .heavy))
            Text("Name your shop, add a product, set policies, choose payments, then review and launch.")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(Step.allCases.firstIndex(of: item)! <= Step.allCases.firstIndex(of: step)! ? Theme.primaryBlue : Color.white.opacity(0.12))
                        .frame(height: 6)
                }
            }

            Text("Step \(Step.allCases.firstIndex(of: step)! + 1) of \(Step.allCases.count) · \(step.title)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if !viewModel.storefrontSaveState.title.isEmpty {
                HStack(spacing: 8) {
                    Circle()
                        .fill(saveStateColor)
                        .frame(width: 8, height: 8)
                    Text(viewModel.storefrontSaveState.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }

#if DEBUG
            Button("Reset setup draft (dev)") {
                Task { await resetSetupDraftFromBackend() }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
#endif
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.glassSurface))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    private var saveStateColor: Color {
        switch viewModel.storefrontSaveState {
        case .saved:
            return .green
        case .saving:
            return Theme.primaryBlue
        case .offlineDraft:
            return Theme.accentGold
        case .syncFailedRetry:
            return .orange
        case .idle:
            return .secondary
        }
    }

    @ViewBuilder
    private var currentStepView: some View {
        switch step {
        case .shopName:
            ShopNameStepView(
                storefront: bindingStorefront,
                availability: viewModel.handleAvailability,
                isLoadingAI: viewModel.isAIHelping,
                onSuggestName: { Task { await suggestShopName() } },
                onHandleChanged: scheduleHandleCheck,
                isSaving: isSaving,
                onNext: { Task { await persistAndAdvance() } }
            )
        case .products:
            ProductListingStepView(
                storefront: bindingStorefront,
                productTitle: $productTitle,
                productDescription: $productDescription,
                productPrice: $productPrice,
                productInventory: $productInventory,
                productImageURL: $productImageURL,
                productPaymentLink: $productPaymentLink,
                productTrackInventory: $productTrackInventory,
                productAvailable: $productAvailable,
                productImagePickerItem: $productImagePickerItem,
                isUploadingProductImage: isUploadingProductImage,
                onBack: moveBack,
                onAddProduct: { Task { await addProduct() } },
                isLoadingAI: viewModel.isAIHelping,
                onImproveProductCopy: { Task { await improveProductCopy() } },
                onGenerateSampleProduct: generateSampleProduct,
                isSaving: isSaving,
                onNext: { Task { await persistAndAdvance() } }
            )
        case .buyerContact:
            LaunchDetailsStepView(
                storefront: bindingStorefront,
                policy: $draftPolicy,
                showsPayments: false,
                onBack: moveBack,
                isLoadingAI: viewModel.isAIHelping,
                onSuggestPolicies: { Task { await suggestPolicies() } },
                isSaving: isSaving,
                onNext: { Task { await persistPoliciesAndAdvance() } }
            )
        case .payments:
            LaunchDetailsStepView(
                storefront: bindingStorefront,
                policy: $draftPolicy,
                showsContact: false,
                onBack: moveBack,
                isLoadingAI: viewModel.isAIHelping,
                onSuggestPolicies: { Task { await suggestPolicies() } },
                isSaving: isSaving,
                onNext: { Task { await persistPoliciesAndAdvance() } }
            )
        case .preview:
            StorePreviewStepView(
                storefront: draftStorefront,
                policy: draftPolicy,
                checklist: draftStorefront.map { localChecklist(for: $0, policy: draftPolicy) } ?? [],
                publishedStorefront: publishedStorefront,
                isPublishing: isPublishing,
                onBack: moveBack,
                onEditSetup: { step = .shopName },
                onPreviewDraft: onPreviewDraft,
                onOpenLive: openLiveStore,
                onPublish: { Task { await publishStore() } },
                onGoToStudio: onPublished
            )
        }
    }

    private var uploadInFlight: Bool {
        isUploadingLogo || isUploadingBanner
    }

    private var bindingStorefront: Binding<Storefront> {
        Binding(
            get: { draftStorefront ?? emptyStorefront },
            set: { draftStorefront = $0 }
        )
    }

    private var emptyStorefront: Storefront {
        Storefront(
            id: UUID(),
            business: BusinessProfile(
                id: UUID(),
                ownerID: UUID(),
                name: "",
                handle: "",
                category: "",
                tagline: "",
                description: "",
                logoURL: nil,
                coverImageURL: nil,
                announcement: nil,
                sellerStory: nil,
                contactEmail: nil,
                phone: nil,
                website: nil,
                socialLinks: [:],
                address: nil,
                hours: nil,
                products: [],
                theme: StorefrontTheme(primaryColorHex: "#111827", accentColorHex: "#2563EB", backgroundStyle: "light", fontName: "SFPro"),
                layout: StorefrontLayout(heroStyle: "split", gridStyle: "card", spacing: 12),
                sections: [],
                isPublished: false
            ),
            sections: [],
            theme: StorefrontTheme(primaryColorHex: "#111827", accentColorHex: "#2563EB", backgroundStyle: "light", fontName: "SFPro"),
            layout: StorefrontLayout(heroStyle: "split", gridStyle: "card", spacing: 12),
            slug: "",
            shopURL: nil,
            paymentStatus: "pending",
            paymentsReady: false,
            paymentsEnabled: false,
            stripeConnectStatus: "not_started",
            defaultPaymentMode: "contact",
            defaultPaymentLinkURL: nil,
            policiesReady: false,
            setupComplete: false,
            publishChecklist: [],
            policy: .default,
            isPublished: false,
            publishedState: .draft
        )
    }

    private func moveBack() {
        if let index = Step.allCases.firstIndex(of: step), index > 0 {
            step = Step.allCases[index - 1]
        }
    }

    private func persistAndAdvance() async {
        guard !isSaving else { return }
        guard var store = draftStorefront else { return }
        // Users can move through steps without completing everything; the launch step uses a checklist.
        // with a checklist instead of blocking step navigation.
        if let index = Step.allCases.firstIndex(of: step), index + 1 < Step.allCases.count {
            let next = Step.allCases[index + 1]
            step = next
            persistLocalDraft()
        }
        isSaving = true
        defer { isSaving = false }
        store.policy = draftPolicy
        store.publishChecklist = localChecklist(for: store, policy: draftPolicy)
        store.setupComplete = store.publishChecklist.isEmpty
        logSetupState(event: "save-requested", source: .userEdit, payloadHandle: store.business.handle ?? store.slug)
        await viewModel.saveCurrentStorefront(store)
        applyCanonicalStorefrontAfterSave(fallback: store, source: .userEdit)
    }

    private func persistPoliciesAndAdvance() async {
        guard !isSaving else { return }
        guard var store = draftStorefront else { return }
        store.policy = draftPolicy
        store.policiesReady = true
        store.publishChecklist = localChecklist(for: store, policy: draftPolicy)
        store.setupComplete = store.publishChecklist.isEmpty
        draftStorefront = store
        viewModel.errorMessage = nil
        if let index = Step.allCases.firstIndex(of: step), index + 1 < Step.allCases.count {
            let next = Step.allCases[index + 1]
            step = next
            persistLocalDraft()
        }
        isSaving = true
        defer { isSaving = false }
        await viewModel.savePolicies(draftPolicy)
        logSetupState(event: "save-requested", source: .userEdit, payloadHandle: store.business.handle ?? store.slug)
        await viewModel.saveCurrentStorefront(store)
        applyCanonicalStorefrontAfterSave(fallback: store, source: .userEdit)
    }

    private func addProduct() async {
        guard !isSaving else { return }
        guard var store = draftStorefront else { return }
        let trimmedTitle = productTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            viewModel.errorMessage = "Add a product name first."
            return
        }
        let normalizedPrice = normalizedPriceDisplay(productPrice)
        guard priceValue(productPrice) > 0 else {
            viewModel.errorMessage = "Add a price greater than $0 before adding this product."
            return
        }
        let trimmedImage = productImageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageURL: URL?
        if trimmedImage.isEmpty {
            imageURL = nil
        } else if let url = URL(string: trimmedImage), url.scheme?.hasPrefix("http") == true {
            imageURL = url
        } else {
            viewModel.errorMessage = "Use a full image link that starts with http or https."
            return
        }
        let trimmedPaymentLink = productPaymentLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let paymentLinkURL: URL?
        if trimmedPaymentLink.isEmpty {
            paymentLinkURL = nil
        } else if let url = URL(string: trimmedPaymentLink), url.scheme == "http" || url.scheme == "https" {
            paymentLinkURL = url
        } else {
            viewModel.errorMessage = "Use a full payment link that starts with http or https."
            return
        }
        viewModel.errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        let product = ProductOrService(
            name: trimmedTitle,
            description: productDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            price: normalizedPrice,
            isSubscription: false,
            mediaURL: imageURL,
            inventory: productTrackInventory ? (productAvailable ? max(1, Int(productInventory) ?? 1) : 0) : nil,
            trackInventory: productTrackInventory,
            lowStockThreshold: 3,
            paymentLinkURL: paymentLinkURL,
            category: store.business.category,
            tags: [],
            variants: [],
            shippingInfo: store.business.hours,
            returnEligible: true
        )
        store.business.products.append(product)
        if let productsIndex = store.sections.firstIndex(where: { $0.type == .products }) {
            store.sections[productsIndex].items = store.business.products
        } else {
            store.sections.append(StorefrontSection(type: .products, title: "Listings", items: store.business.products))
        }
        draftStorefront = store
        persistLocalDraft()
        await viewModel.createListing(product)
        if viewModel.errorMessage == nil {
            draftStorefront = viewModel.storefront ?? store
        }
        productTitle = ""
        productDescription = ""
        productPrice = ""
        productInventory = "1"
        productImageURL = ""
        productPaymentLink = ""
        productTrackInventory = true
        productAvailable = true
        persistLocalDraft()
    }

    private func publishStore() async {
        guard !isPublishing else { return }
        guard let store = draftStorefront else { return }
        isPublishing = true
        defer { isPublishing = false }
        logSetupState(event: "launch-requested", source: .userEdit, payloadHandle: store.business.handle ?? store.slug)
        await viewModel.publishCurrentStorefront()
        if viewModel.errorMessage == nil, viewModel.publishedStorefront != nil {
            publishedStorefront = viewModel.publishedStorefront
            draftStorefront = viewModel.publishedStorefront
            clearLocalDraft()
        }
    }

    private func openLiveStore() {
        guard let store = draftStorefront,
              let url = storefrontURL(for: store) else { return }
        openURL(url)
    }

    private func localChecklist(for store: Storefront, policy: StorePolicyDraft) -> [String] {
        // Authentication and ownership are enforced by the API. All setup
        // fields are optional at publication time.
        _ = store
        _ = policy
        return []
    }

    private func validationMessage(for step: Step, store: Storefront) -> String? {
        // Deprecated: do not gate step navigation. Publish step uses a checklist.
        return nil
    }

    private func retrySync(_ store: Storefront) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        logSetupState(event: "save-requested", source: .localDraft, payloadHandle: store.business.handle ?? store.slug)
        await viewModel.saveCurrentStorefront(store)
        if viewModel.errorMessage == nil {
            applyCanonicalStorefrontAfterSave(fallback: store, source: .localDraft)
        }
    }

    private func persistLocalDraft() {
        guard let draftStorefront else { return }
        let snapshot = LocalSetupDraftSnapshot(
            storefront: draftStorefront,
            policy: draftPolicy,
            productTitle: productTitle,
            productDescription: productDescription,
            productPrice: productPrice,
            productInventory: productInventory,
            productImageURL: productImageURL,
            productPaymentLink: productPaymentLink,
            productTrackInventory: productTrackInventory,
            productAvailable: productAvailable,
            stepRawValue: step.rawValue,
            savedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: localDraftKey)
    }

    @discardableResult
    private func restoreLocalDraftIfAvailable(backendStorefront: Storefront?) -> SetupSaveSource {
        guard let data = UserDefaults.standard.data(forKey: localDraftKey),
              let snapshot = try? JSONDecoder().decode(LocalSetupDraftSnapshot.self, from: data) else {
            return .backendStore
        }

        // Keep transient setup state from local draft (current step and in-progress
        // product form fields), but prefer backend canonical storefront values unless
        // we are intentionally preserving an offline/failed-sync draft.
        draftPolicy = snapshot.policy
        productTitle = snapshot.productTitle
        productDescription = snapshot.productDescription
        productPrice = snapshot.productPrice
        productInventory = snapshot.productInventory
        productImageURL = snapshot.productImageURL ?? ""
        productPaymentLink = snapshot.productPaymentLink ?? ""
        productTrackInventory = snapshot.productTrackInventory ?? true
        productAvailable = snapshot.productAvailable ?? true
        if let restoredStep = Step(rawValue: snapshot.stepRawValue) {
            step = restoredStep
        }

        guard let backendStorefront else {
            draftStorefront = snapshot.storefront
            return .localDraft
        }

        let preserveOfflineDraft = (viewModel.storefrontSaveState == .offlineDraft || viewModel.storefrontSaveState == .syncFailedRetry)
            && snapshot.storefront.id == backendStorefront.id
        if preserveOfflineDraft {
            draftStorefront = snapshot.storefront
            return .localDraft
        }

        draftStorefront = backendStorefront
        return .backendStore
    }

    private func clearLocalDraft() {
        UserDefaults.standard.removeObject(forKey: localDraftKey)
    }

    private var localDraftKey: String {
        if let id = draftStorefront?.id ?? viewModel.storefront?.id {
            return "oneway.storefrontSetup.localDraft.\(id.uuidString)"
        }
        return "oneway.storefrontSetup.localDraft.pending"
    }

    private func scheduleHandleCheck(_ rawHandle: String) {
        let handle = normalizedHandle(rawHandle)
        handleCheckTask?.cancel()
        logSetupState(event: "handle-check-scheduled", source: .userEdit, payloadHandle: handle)
        guard !handle.isEmpty else {
            Task { @MainActor in await viewModel.checkHandleAvailability("", excluding: draftStorefront?.id) }
            return
        }
        let storefrontID = draftStorefront?.id
        handleCheckTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let currentHandle = normalizedHandle(draftStorefront?.business.handle ?? draftStorefront?.slug ?? "")
            guard currentHandle == handle else {
                logSetupState(event: "handle-check-discarded", source: .userEdit, payloadHandle: handle)
                return
            }
            await viewModel.checkHandleAvailability(handle, excluding: storefrontID)
        }
    }

    private func normalizedHandle(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return value
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { allowed.contains($0) }
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    private func isValidHandle(_ value: String) -> Bool {
        normalizedHandle(value).range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    private func storefrontURL(for store: Storefront) -> URL? {
        if let shopURL = store.shopURL, let url = URL(string: shopURL.hasPrefix("http") ? shopURL : "https://\(shopURL)") {
            return url
        }
        guard !store.slug.isEmpty else { return nil }
        return APIConfig.storefrontPublicURL(for: store.slug)
    }

    private func inlineMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            if viewModel.storefrontSaveState == .offlineDraft || viewModel.storefrontSaveState == .syncFailedRetry,
               let draftStorefront {
                Button("Retry sync") {
                    Task { await retrySync(draftStorefront) }
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.25), lineWidth: 1))
    }

    private func suggestShopName() async {
        guard var store = draftStorefront else { return }
        store.business.name = await viewModel.requestStorefrontHelp(type: .shopName, storefront: store)
        let handle = normalizedHandle(store.business.name)
        store.business.handle = handle
        store.slug = handle
        store.shopURL = APIConfig.storefrontPublicURLString(for: handle)
        draftStorefront = store
        scheduleHandleCheck(handle)
    }

    private func initializeSetupState() async {
        if viewModel.storefront == nil {
            await viewModel.load()
        }
        if viewModel.storefront == nil {
            await viewModel.startShopSetup()
        }

        let backendStorefront = viewModel.storefront
        draftStorefront = backendStorefront
        draftPolicy = await viewModel.loadPolicies()
        let source = restoreLocalDraftIfAvailable(backendStorefront: backendStorefront)
        logSetupState(event: "setup-loaded", source: source)
        if let handle = draftStorefront?.business.handle {
            scheduleHandleCheck(handle)
        }
    }

    private func applyCanonicalStorefrontAfterSave(fallback: Storefront, source: SetupSaveSource) {
        if let canonical = viewModel.storefront {
            draftStorefront = canonical
            logSetupState(event: "save-applied", source: .backendStore, payloadHandle: canonical.business.handle ?? canonical.slug)
        } else {
            draftStorefront = fallback
            logSetupState(event: "save-applied", source: source, payloadHandle: fallback.business.handle ?? fallback.slug)
        }
        persistLocalDraft()
    }

    private func resetSetupDraftFromBackend() async {
        clearAllLocalDrafts()
        await viewModel.load()
        if viewModel.storefront == nil {
            await viewModel.startShopSetup()
        }
        draftStorefront = viewModel.storefront
        draftPolicy = await viewModel.loadPolicies()
        productTitle = ""
        productDescription = ""
        productPrice = ""
        productInventory = "1"
        productImageURL = ""
        productPaymentLink = ""
        productTrackInventory = true
        productAvailable = true
        step = .shopName
        persistLocalDraft()
        logSetupState(event: "setup-reset", source: .backendStore)
        if let handle = draftStorefront?.business.handle {
            scheduleHandleCheck(handle)
        }
    }

    private func clearAllLocalDrafts() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "oneway.storefrontSetup.localDraft.pending")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("oneway.storefrontSetup.localDraft.") {
            defaults.removeObject(forKey: key)
        }
    }

    private func logSetupState(
        event: String,
        source: SetupSaveSource,
        payloadHandle: String? = nil
    ) {
#if DEBUG
        let currentStorefrontId = PrivacyLog.shortID(viewModel.storefront?.id.uuidString)
        let currentHandle = normalizedHandle(viewModel.storefront?.business.handle ?? viewModel.storefront?.slug ?? "")
        let draftHandle = normalizedHandle(draftStorefront?.business.handle ?? draftStorefront?.slug ?? "")
        let selectedStoreName = draftStorefront?.business.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload = normalizedHandle(payloadHandle ?? draftHandle)
        print(
            "[storefront setup] event=\(event) " +
            "saveSource=\(source.rawValue) " +
            "currentStorefrontId=\(PrivacyLog.redact(currentStorefrontId)) " +
            "currentHandle=\(PrivacyLog.redact(currentHandle)) " +
            "draftHandle=\(PrivacyLog.redact(draftHandle)) " +
            "payloadHandle=\(PrivacyLog.redact(payload)) " +
            "selectedStoreName=\(PrivacyLog.redact(selectedStoreName))"
        )
#endif
    }

    private func suggestCategory() async {
        guard var store = draftStorefront else { return }
        store.business.category = await viewModel.requestStorefrontHelp(type: .category, storefront: store)
        draftStorefront = store
    }

    private func suggestSellerStory() async {
        guard var store = draftStorefront else { return }
        store.business.sellerStory = await viewModel.requestStorefrontHelp(type: .sellerStory, storefront: store)
        draftStorefront = store
    }

    private func suggestDescription() async {
        guard var store = draftStorefront else { return }
        store.business.description = await viewModel.requestStorefrontHelp(type: .shopDescription, storefront: store)
        draftStorefront = store
    }

    private func improveProductCopy() async {
        productDescription = await viewModel.requestStorefrontHelp(
            type: .productCopy,
            storefront: draftStorefront,
            productName: productTitle,
            productDescription: productDescription
        )
    }

    private func generateSampleProduct() {
        let category = draftStorefront?.business.category.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shopName = draftStorefront?.business.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seed = category.isEmpty ? (shopName.isEmpty ? "OneWay" : shopName) : category
        productTitle = "\(seed) Starter Pack"
        productPrice = "$29.00"
        productDescription = "A simple, ready-to-share item from \(shopName.isEmpty ? "your new shop" : shopName). Perfect for first-time buyers."
        productInventory = "10"
        productImageURL = ""
        productPaymentLink = ""
        productTrackInventory = true
        productAvailable = true
        viewModel.errorMessage = nil
    }

    private func suggestPolicies() async {
        let text = await viewModel.requestStorefrontHelp(type: .storePolicies, storefront: draftStorefront)
        if draftPolicy.returns == StorePolicyDraft.default.returns { draftPolicy.returns = text }
        if draftPolicy.refunds == StorePolicyDraft.default.refunds { draftPolicy.refunds = text }
        if draftPolicy.processingTime == StorePolicyDraft.default.processingTime { draftPolicy.processingTime = text }
        if draftPolicy.shipping == StorePolicyDraft.default.shipping { draftPolicy.shipping = text }
        if draftPolicy.support == StorePolicyDraft.default.support { draftPolicy.support = text }
    }

    private func priceValue(_ value: String) -> Double {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned) ?? 0
    }

    private func normalizedPriceDisplay(_ value: String) -> String {
        String(format: "$%.2f", priceValue(value))
    }

    private enum UploadKind {
        case logo
        case banner
    }

    private func uploadImage(from item: PhotosPickerItem, kind: UploadKind) async {
        guard let data = try? await jpegUploadData(from: item) else {
            viewModel.errorMessage = "We could not read that image. Try another photo."
            return
        }

        let fileName = item.itemIdentifier.map { "\($0).jpg" } ?? "\(UUID().uuidString).jpg"
        switch kind {
        case .logo:
            isUploadingLogo = true
        case .banner:
            isUploadingBanner = true
        }

        defer {
            switch kind {
            case .logo:
                isUploadingLogo = false
                logoPickerItem = nil
            case .banner:
                isUploadingBanner = false
                bannerPickerItem = nil
            }
        }

        do {
            let url = try await viewModel.uploadStorefrontImage(data: data, fileName: fileName, mimeType: "image/jpeg")
            guard var store = draftStorefront else { return }
            switch kind {
            case .logo:
                store.business.logoURL = url
            case .banner:
                store.business.coverImageURL = url
            }
            draftStorefront = store
        } catch {
            // The view model already sets a specific inline error for image upload failures.
        }
    }

    private func uploadProductImage(from item: PhotosPickerItem) async {
        isUploadingProductImage = true
        defer {
            isUploadingProductImage = false
            productImagePickerItem = nil
        }

        do {
            guard let data = try await jpegUploadData(from: item) else {
                viewModel.errorMessage = "We could not read that image. Try another photo."
                return
            }
            let fileName = "product-\(UUID().uuidString).jpg"
            let url = try await viewModel.uploadStorefrontImage(data: data, fileName: fileName, mimeType: "image/jpeg")
            productImageURL = url.absoluteString
            viewModel.errorMessage = nil
        } catch {
            viewModel.errorMessage = "We could not upload that product photo yet. Your draft is still here."
        }
    }
}

private struct SetupCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oneWayCardStyle(cornerRadius: 22)
    }
}

struct ShopNameStepView: View {
    @Binding var storefront: Storefront
    let availability: StorefrontHandleAvailability
    let isLoadingAI: Bool
    let onSuggestName: () -> Void
    let onHandleChanged: (String) -> Void
    let isSaving: Bool
    let onNext: () -> Void

    var body: some View {
        SetupCard(title: "Step 1: name and link", subtitle: "Choose the public shop name, handle, and a simple description buyers will see first.") {
            TextField("Shop name", text: $storefront.business.name)
                .textInputAutocapitalization(.words)
                .textFieldStyle(OneWayFormFieldStyle())
                .onChange(of: storefront.business.name) { _, newValue in
                    let handle = normalizedHandle(newValue)
                    storefront.business.handle = handle
                    storefront.slug = handle
                    storefront.shopURL = APIConfig.storefrontPublicURLString(for: handle)
                    onHandleChanged(handle)
                }

            TextField("Shop handle", text: Binding(
                get: { storefront.business.handle ?? "" },
                set: {
                    let handle = normalizedHandle($0)
                    storefront.business.handle = handle
                    storefront.slug = handle
                    storefront.shopURL = APIConfig.storefrontPublicURLString(for: handle)
                    onHandleChanged(handle)
                }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(OneWayFormFieldStyle())

            TextField("Category", text: $storefront.business.category)
                .textFieldStyle(OneWayFormFieldStyle())

            TextField("Tagline (optional)", text: $storefront.business.tagline)
                .textFieldStyle(OneWayFormFieldStyle())

            TextField("Shop description", text: $storefront.business.description, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(OneWayFormFieldStyle())

            if let shopURL = storefront.shopURL, !shopURL.isEmpty {
                Text(shopURL)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !availability.message.isEmpty {
                HStack(spacing: 8) {
                    OneWayResolvedIcon(systemName: availabilityIcon)
                    Text(availability.message)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(availabilityColor)
            }

            HStack {
                Button(isLoadingAI ? "AI working..." : "Suggest with AI", action: onSuggestName)
                    .buttonStyle(.bordered)
                    .disabled(isLoadingAI)
                Spacer()
                Button(isSaving ? "Saving..." : "Next", action: onNext)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
    }

    private var availabilityIcon: String {
        switch availability.status {
        case .available:
            return "checkmark.circle.fill"
        case .taken, .invalid:
            return "exclamationmark.triangle.fill"
        case .checking:
            return "clock.fill"
        case .unknown:
            return "wifi.exclamationmark"
        case .idle:
            return "link"
        }
    }

    private var availabilityColor: Color {
        switch availability.status {
        case .available:
            return .green
        case .taken, .invalid:
            return .orange
        case .checking, .unknown, .idle:
            return .secondary
        }
    }

    private func normalizedHandle(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return value
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { allowed.contains($0) }
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}

struct ShopIdentityStepView: View {
    @Binding var storefront: Storefront
    @Binding var logoPickerItem: PhotosPickerItem?
    @Binding var bannerPickerItem: PhotosPickerItem?
    let isUploadingLogo: Bool
    let isUploadingBanner: Bool
    let onBack: () -> Void
    let isLoadingAI: Bool
    let onSuggestCategory: () -> Void
    let onSuggestSellerStory: () -> Void
    let onSuggestDescription: () -> Void
    let isSaving: Bool
    let onNext: () -> Void

    var body: some View {
        SetupCard(title: "Build your shop identity", subtitle: "Upload your images, choose a category, and add the story buyers need to trust your shop.") {
            imagePickerRow(
                title: "Logo image",
                imageURL: storefront.business.logoURL,
                pickerItem: $logoPickerItem,
                isUploading: isUploadingLogo
            )
            imagePickerRow(
                title: "Banner image",
                imageURL: storefront.business.coverImageURL,
                pickerItem: $bannerPickerItem,
                isUploading: isUploadingBanner
            )
            TextField("Shop announcement", text: Binding(get: { storefront.business.announcement ?? "" }, set: { storefront.business.announcement = $0 }))
                .textFieldStyle(OneWayFormFieldStyle())
            VStack(alignment: .leading, spacing: 8) {
                TextField("Category", text: $storefront.business.category)
                    .textFieldStyle(OneWayFormFieldStyle())
                Button(isLoadingAI ? "AI working…" : "Suggest category", action: onSuggestCategory)
                    .buttonStyle(.bordered)
                    .disabled(isLoadingAI)
            }
            TextField("Seller story", text: Binding(get: { storefront.business.sellerStory ?? "" }, set: { storefront.business.sellerStory = $0 }), axis: .vertical)
                .lineLimit(4...6)
                .textFieldStyle(OneWayFormFieldStyle())
            Button(isLoadingAI ? "AI working…" : "Write seller story", action: onSuggestSellerStory)
                .buttonStyle(.bordered)
                .disabled(isLoadingAI)
            TextField("Shop description", text: $storefront.business.description, axis: .vertical)
                .lineLimit(4...6)
                .textFieldStyle(OneWayFormFieldStyle())
            Button(isLoadingAI ? "AI working…" : "Improve shop description", action: onSuggestDescription)
                .buttonStyle(.bordered)
                .disabled(isLoadingAI)

            HStack {
                Button("Back", action: onBack).buttonStyle(.bordered)
                Spacer()
                Button(isSaving ? "Saving..." : "Next", action: onNext)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
    }

    private func imagePickerRow(title: String, imageURL: URL?, pickerItem: Binding<PhotosPickerItem?>, isUploading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06))
                    }
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            PhotosPicker(selection: pickerItem, matching: .images) {
                OneWayResolvedLabel(isUploading ? "Uploading…" : "Upload from Photos", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isUploading)
        }
    }
}

struct ProductListingStepView: View {
    @Binding var storefront: Storefront
    @Binding var productTitle: String
    @Binding var productDescription: String
    @Binding var productPrice: String
    @Binding var productInventory: String
    @Binding var productImageURL: String
    @Binding var productPaymentLink: String
    @Binding var productTrackInventory: Bool
    @Binding var productAvailable: Bool
    @Binding var productImagePickerItem: PhotosPickerItem?
    let isUploadingProductImage: Bool
    let onBack: () -> Void
    let onAddProduct: () -> Void
    let isLoadingAI: Bool
    let onImproveProductCopy: () -> Void
    let onGenerateSampleProduct: () -> Void
    let isSaving: Bool
    let onNext: () -> Void

    var body: some View {
        SetupCard(title: "Step 2: first product", subtitle: "One strong product is enough to launch. You can add and tune more in Shop Management.") {
            ProductPreviewCard(
                name: productTitle,
                price: productPrice,
                description: productDescription,
                imageURLString: productImageURL,
                available: productAvailable,
                inventoryCount: Int(productInventory),
                tracksInventory: productTrackInventory,
                paymentLink: productPaymentLink
            )

            PhotosPicker(selection: $productImagePickerItem, matching: .images) {
                OneWayResolvedLabel(isUploadingProductImage ? "Uploading photo..." : "Upload product photo", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isUploadingProductImage)

            TextField("Product name", text: $productTitle)
                .textInputAutocapitalization(.words)
                .textFieldStyle(OneWayFormFieldStyle())

            TextField("$24.00", text: $productPrice)
                .keyboardType(.decimalPad)
                .textFieldStyle(OneWayFormFieldStyle())

            TextField("Short description", text: $productDescription, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(OneWayFormFieldStyle())

            TextField("Image URL (optional)", text: $productImageURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(OneWayFormFieldStyle())

            DisclosureGroup("More options") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Track inventory", isOn: $productTrackInventory)
                        .toggleStyle(.switch)
                    Toggle(productAvailable ? "Available now" : "Mark as available", isOn: $productAvailable)
                        .toggleStyle(.switch)
                    if productAvailable && productTrackInventory {
                        TextField("Quantity available", text: $productInventory)
                            .keyboardType(.numberPad)
                            .textFieldStyle(OneWayFormFieldStyle())
                    }
                    TextField("Payment link for this product", text: $productPaymentLink)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(OneWayFormFieldStyle())
                    Text("Add a payment link to show Buy now. Leave blank to use Request to buy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            HStack(spacing: 10) {
                Button(isLoadingAI ? "AI working..." : "Generate sample product", action: onGenerateSampleProduct)
                    .buttonStyle(.bordered)
                    .disabled(isLoadingAI)
                Button(isLoadingAI ? "AI working..." : "Improve copy", action: onImproveProductCopy)
                    .buttonStyle(.bordered)
                    .disabled(isLoadingAI || productTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button(isSaving ? "Adding..." : "Add product", action: onAddProduct)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || productTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || priceValue <= 0)

            if storefront.business.products.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your first product will appear here.")
                        .font(.headline)
                    Text("Add one item now. Extra products, photos, and categories can wait until after launch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
            } else {
                ForEach(storefront.business.products) { product in
                    ProductMiniRow(product: product)
                }
            }

            HStack {
                Button("Back", action: onBack).buttonStyle(.bordered)
                Spacer()
                Button(isSaving ? "Saving..." : "Next", action: onNext)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
    }

    private var priceValue: Double {
        Double(productPrice.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

private struct ProductPreviewCard: View {
    let name: String
    let price: String
    let description: String
    let imageURLString: String
    let available: Bool
    let inventoryCount: Int?
    let tracksInventory: Bool
    let paymentLink: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                if let url = URL(string: imageURLString), !imageURLString.isEmpty {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Your first product" : name)
                        .font(.headline)
                    Text(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "A short description helps buyers know why they want it." : description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                Text(price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "$0.00" : price)
                    .font(.headline.weight(.heavy))
            }

            HStack(spacing: 8) {
                Text(stockText)
                if hasPaymentLink {
                    Text("Buy now ready")
                }
            }
                .font(.caption.weight(.bold))
                .foregroundStyle(available ? .green : .orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Theme.primaryBlue.opacity(0.5), Theme.accentGold.opacity(0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            OneWayResolvedIcon(systemName: "sparkles")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
        }
    }

    private var hasPaymentLink: Bool {
        paymentLink.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("http")
    }

    private var stockText: String {
        guard available else { return "Sold out" }
        guard tracksInventory else { return "Ready to sell" }
        guard let inventoryCount else { return "Stock tracked" }
        if inventoryCount <= 3 { return "Low stock: \(inventoryCount)" }
        return "\(inventoryCount) available"
    }
}

private struct ProductMiniRow: View {
    let product: ProductOrService

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let mediaURL = product.mediaURL {
                    AsyncImage(url: mediaURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color.white.opacity(0.08)
                        }
                    }
                } else {
                    Color.white.opacity(0.08)
                    OneWayResolvedIcon(systemName: "shippingbox.fill")
                        .foregroundStyle(Theme.accentGold)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(product.name).font(.headline)
                Text(product.description.isEmpty ? "No description yet" : product.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(product.price)
                .font(.subheadline.weight(.bold))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
    }
}

struct ShippingStepView: View {
    @Binding var storefront: Storefront
    let onBack: () -> Void
    let onNext: () -> Void

    var body: some View {
        SetupCard(title: "Choose shipping or delivery", subtitle: "For now, add your seller-defined shipping rules. You can offer digital, pickup, standard, free, or flat-rate shipping.") {
            TextField("Shipping and delivery details", text: Binding(
                get: { storefront.business.hours ?? "" },
                set: { storefront.business.hours = $0 }
            ), axis: .vertical)
            .lineLimit(4...6)
            .textFieldStyle(OneWayFormFieldStyle())

            HStack {
                Button("Back", action: onBack).buttonStyle(.bordered)
                Spacer()
                Button("Next", action: onNext).buttonStyle(.borderedProminent)
            }
        }
    }
}

struct LaunchDetailsStepView: View {
    @Binding var storefront: Storefront
    @Binding var policy: StorePolicyDraft
    var showsPayments = true
    var showsContact = true
    let onBack: () -> Void
    let isLoadingAI: Bool
    let onSuggestPolicies: () -> Void
    let isSaving: Bool
    let onNext: () -> Void

    var body: some View {
        SetupCard(title: showsContact ? "Policies and buyer contact" : "How buyers pay", subtitle: showsContact ? "Set contact details, fulfillment and policies before launch." : "Use a secure payment link or accept order requests. Provider verification remains separate.") {
            if showsContact {
            ContactChoiceCard(
                icon: "bubble.left.and.bubble.right.fill",
                title: "Message inside OneWay",
                status: "Ready",
                statusColor: .green,
                detail: "Buyers can request an order and keep the conversation in OneWay."
            )

            VStack(alignment: .leading, spacing: 8) {
                TextField("Email for buyer questions", text: Binding(
                    get: { storefront.business.contactEmail ?? "" },
                    set: { storefront.business.contactEmail = $0 }
                ))
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(OneWayFormFieldStyle())
                StatusPill(
                    text: emailReady ? "Email ready" : "Email not configured yet",
                    color: emailReady ? .green : .orange
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Phone or text number", text: Binding(
                    get: { storefront.business.phone ?? "" },
                    set: { storefront.business.phone = $0 }
                ))
                .keyboardType(.phonePad)
                .textFieldStyle(OneWayFormFieldStyle())
                HStack(spacing: 8) {
                    StatusPill(text: phoneReady ? "Phone ready" : "Phone not ready", color: phoneReady ? .green : .orange)
                    StatusPill(text: phoneReady ? "Texting waiting for approval" : "Add a number for text", color: .orange)
                }
            }

            }
            if showsPayments {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use a payment link", isOn: Binding(
                    get: { storefront.paymentsEnabled },
                    set: {
                        storefront.paymentsEnabled = $0
                        storefront.defaultPaymentMode = $0 ? "payment_link" : "contact"
                    }
                ))
                .toggleStyle(.switch)

                if storefront.paymentsEnabled {
                    TextField("Payment link", text: Binding(
                        get: { storefront.defaultPaymentLinkURL?.absoluteString ?? storefront.business.website ?? "" },
                        set: {
                            storefront.defaultPaymentLinkURL = URL(string: $0)
                        }
                    ))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(OneWayFormFieldStyle())
                    StatusPill(text: hasPaymentLink ? "Payment link added" : "Add a link before sharing buy buttons", color: hasPaymentLink ? .green : .orange)
                    Text("Paste a checkout or payment page link. If a product has its own link, that product link wins.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Buyers can still request an order and you can coordinate payment manually.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            }
            if showsContact {
            TextField("Pickup, delivery, shipping, or digital details", text: Binding(
                get: { storefront.business.hours ?? "" },
                set: { storefront.business.hours = $0 }
            ), axis: .vertical)
            .lineLimit(3...5)
            .textFieldStyle(OneWayFormFieldStyle())

            VStack(alignment: .leading, spacing: 10) {
                Text("Fulfillment options")
                    .font(.headline)
                Toggle("Local pickup", isOn: optionalBoolBinding(\.pickupEnabled))
                if storefront.business.pickupEnabled == true {
                    TextField("Pickup instructions", text: optionalStringBinding(\.pickupInstructions))
                        .textFieldStyle(OneWayFormFieldStyle())
                }
                Toggle("Local delivery", isOn: optionalBoolBinding(\.localDeliveryEnabled))
                if storefront.business.localDeliveryEnabled == true {
                    TextField("Delivery area note", text: optionalStringBinding(\.deliveryAreaNote))
                        .textFieldStyle(OneWayFormFieldStyle())
                }
                Toggle("Shipping", isOn: optionalBoolBinding(\.shippingEnabled))
                if storefront.business.shippingEnabled == true {
                    TextField("Shipping note", text: optionalStringBinding(\.shippingNote))
                        .textFieldStyle(OneWayFormFieldStyle())
                }
                Toggle("Digital delivery", isOn: optionalBoolBinding(\.digitalDeliveryEnabled))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))

            DisclosureGroup("Optional shop policies") {
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        TextField("Returns", text: $policy.returns, axis: .vertical).lineLimit(2...4)
                        TextField("Refunds", text: $policy.refunds, axis: .vertical).lineLimit(2...4)
                        TextField("Processing time", text: $policy.processingTime, axis: .vertical).lineLimit(2...3)
                        TextField("Shipping policy", text: $policy.shipping, axis: .vertical).lineLimit(2...4)
                        TextField("Support message", text: $policy.support, axis: .vertical).lineLimit(2...4)
                    }
                    .textFieldStyle(OneWayFormFieldStyle())

                    Button(isLoadingAI ? "AI working..." : "Write simple policies", action: onSuggestPolicies)
                        .buttonStyle(.bordered)
                        .disabled(isLoadingAI)
                }
                .padding(.top, 8)
            }

            }
            HStack {
                Button("Back", action: onBack).buttonStyle(.bordered)
                Spacer()
                Button(isSaving ? "Saving..." : "Next", action: onNext)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
    }

    private var emailReady: Bool {
        (storefront.business.contactEmail ?? "").contains("@")
    }

    private var phoneReady: Bool {
        (storefront.business.phone ?? "").filter(\.isNumber).count >= 7
    }

    private var hasPaymentLink: Bool {
        guard storefront.paymentsEnabled else { return false }
        let value = storefront.defaultPaymentLinkURL?.absoluteString ?? storefront.business.website ?? ""
        return value.hasPrefix("http://") || value.hasPrefix("https://")
    }

    private func optionalBoolBinding(_ keyPath: WritableKeyPath<BusinessProfile, Bool?>) -> Binding<Bool> {
        Binding(
            get: { storefront.business[keyPath: keyPath] ?? false },
            set: { storefront.business[keyPath: keyPath] = $0 }
        )
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<BusinessProfile, String?>) -> Binding<String> {
        Binding(
            get: { storefront.business[keyPath: keyPath] ?? "" },
            set: { storefront.business[keyPath: keyPath] = $0 }
        )
    }
}

private struct ContactChoiceCard: View {
    let icon: String
    let title: String
    let status: String
    let statusColor: Color
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OneWayResolvedIcon(systemName: icon)
                .font(.headline)
                .foregroundStyle(Theme.accentGold)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    StatusPill(text: status, color: statusColor)
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct PoliciesStepView: View {
    @Binding var policy: StorePolicyDraft
    let onBack: () -> Void
    let isLoadingAI: Bool
    let onSuggestPolicies: () -> Void
    let onNext: () -> Void

    var body: some View {
        SetupCard(title: "Add your shop policies", subtitle: "Set buyer expectations before launch. You can start from the default policy text and refine it.") {
            Group {
                TextField("Returns", text: $policy.returns, axis: .vertical).lineLimit(2...4)
                TextField("Refunds", text: $policy.refunds, axis: .vertical).lineLimit(2...4)
                TextField("Processing time", text: $policy.processingTime, axis: .vertical).lineLimit(2...3)
                TextField("Shipping policy", text: $policy.shipping, axis: .vertical).lineLimit(2...4)
                TextField("Support message", text: $policy.support, axis: .vertical).lineLimit(2...4)
            }
            .textFieldStyle(OneWayFormFieldStyle())
            Button(isLoadingAI ? "AI working…" : "Write store policies", action: onSuggestPolicies)
                .buttonStyle(.bordered)
                .disabled(isLoadingAI)

            HStack {
                Button("Back", action: onBack).buttonStyle(.bordered)
                Spacer()
                Button("Next", action: onNext).buttonStyle(.borderedProminent)
            }
        }
    }
}

struct StorePreviewStepView: View {
    let storefront: Storefront?
    let policy: StorePolicyDraft
    let checklist: [String]
    let publishedStorefront: Storefront?
    let isPublishing: Bool
    let onBack: () -> Void
    let onEditSetup: () -> Void
    let onPreviewDraft: () -> Void
    let onOpenLive: () -> Void
    let onPublish: () -> Void
    let onGoToStudio: () -> Void

    var body: some View {
        SetupCard(title: publishedStorefront == nil ? "Ready to Launch" : "Your shop is live", subtitle: publishedStorefront == nil ? "Check your storefront and launch when everything looks right." : "You made it. Share the link and start taking requests.") {
            if let live = publishedStorefront ?? storefront {
                if publishedStorefront != nil {
                    PublishedSuccessCard(storefront: live, onOpenLive: onOpenLive, onGoToStudio: onGoToStudio)
                } else {
                    StorefrontLaunchPreview(storefront: live, policy: policy)

                    if !checklist.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Finish these before launch")
                                .font(.headline)
                            ForEach(checklist, id: \.self) { item in
                                OneWayResolvedLabel(item, systemImage: "circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                        Button("Back", action: onBack).buttonStyle(.bordered)
                        Button("Edit store", action: onEditSetup).buttonStyle(.bordered)
                        Button("Preview draft", action: onPreviewDraft).buttonStyle(.bordered)
                        if let shareURL = shareURL(for: live) {
                            ShareLink(item: shareURL) {
                                Text("Share")
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(isPublishing ? "Launching..." : "Launch Shop", action: onPublish)
                            .buttonStyle(.borderedProminent)
                            .disabled(isPublishing || !checklist.isEmpty)
                    }
                }
            }
        }
    }

    private func shareURL(for storefront: Storefront) -> URL? {
        if let shopURL = storefront.shopURL {
            return URL(string: shopURL.hasPrefix("http") ? shopURL : "https://\(shopURL)")
        }
        guard !storefront.slug.isEmpty else { return nil }
        return APIConfig.storefrontPublicURL(for: storefront.slug)
    }
}

private struct StorefrontLaunchPreview: View {
    let storefront: Storefront
    let policy: StorePolicyDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(storefront.business.name)
                    .font(.system(size: 30, weight: .heavy))
                Text(storefront.business.description)
                    .foregroundStyle(.secondary)
                Text(publicLink)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentGold)
            }

            if let product = storefront.business.products.first(where: { $0.isVisible ?? true }) {
                ProductMiniRow(product: product)
            }

            Button(ctaTitle, action: {})
                .buttonStyle(.borderedProminent)
                .disabled(true)

            Text(policy.shipping)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.09), Theme.primaryBlue.opacity(0.14), Color.white.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    private var publicLink: String {
        storefront.shopURL ?? APIConfig.storefrontPublicURLString(for: storefront.slug)
    }

    private var ctaTitle: String {
        if storefront.paymentsEnabled,
           let link = storefront.defaultPaymentLinkURL?.absoluteString ?? storefront.business.website,
           !link.isEmpty {
            return "Buy now"
        }
        if let phone = storefront.business.phone, !phone.isEmpty {
            return "Text to buy"
        }
        if let email = storefront.business.contactEmail, !email.isEmpty {
            return "Email seller"
        }
        return "Message seller"
    }
}

private struct PublishedSuccessCard: View {
    let storefront: Storefront
    let onOpenLive: () -> Void
    let onGoToStudio: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OneWayResolvedIcon(systemName: "party.popper.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.accentGold)
            Text("Your shop is live")
                .font(.system(size: 32, weight: .heavy))
            Text("Share your link anywhere. Orders, messages, and product updates now live in Shop Management.")
                .foregroundStyle(.secondary)
            Text(publicLink)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accentGold)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
                Button("Open storefront", action: onOpenLive)
                    .buttonStyle(.borderedProminent)
                if let url = shareURL {
                    ShareLink(item: url) {
                        Text("Share shop")
                    }
                    .buttonStyle(.bordered)
                }
                Button("Go to Shop Management", action: onGoToStudio)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.glassSurface))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.accentGold.opacity(0.35), lineWidth: 1))
    }

    private var publicLink: String {
        storefront.shopURL ?? APIConfig.storefrontPublicURLString(for: storefront.slug)
    }

    private var shareURL: URL? {
        URL(string: publicLink.hasPrefix("http") ? publicLink : "https://\(publicLink)")
    }
}

struct SellerDashboardView: View {
    let storefront: Storefront
    let onViewLive: () -> Void
    let onManageListings: () -> Void
    let onOpenShopSettings: () -> Void
    let onOpenOrders: () -> Void
    let onOpenAnalytics: () -> Void
    let onOpenSecurityPrivacy: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SetupCard(title: storefront.business.name, subtitle: storefront.business.announcement ?? "Your shop is live. Your core tools are right here.") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                        sellerAction("Products", icon: "shippingbox.fill", subtitle: "\(storefront.business.products.count) live", action: onManageListings)
                        sellerAction("Shop settings", icon: "slider.horizontal.3", subtitle: "Contact and payout", action: onOpenShopSettings)
                        sellerAction("Orders", icon: "list.clipboard.fill", subtitle: "Ready to fulfill", action: onOpenOrders)
                        sellerAction("Messages", icon: "bubble.left.and.bubble.right.fill", subtitle: "Customer replies", action: onOpenOrders)
                        sellerAction("Store activity", icon: "bell.badge.fill", subtitle: "No new updates", action: {})
                        sellerAction("View live", icon: "safari.fill", subtitle: "Open public shop", action: onViewLive)
                        sellerAction("Analytics", icon: "chart.line.uptrend.xyaxis", subtitle: "Coming soon", action: onOpenAnalytics)
#if DEBUG
                        sellerAction("Security", icon: "lock.shield.fill", subtitle: "Admin privacy status", action: onOpenSecurityPrivacy)
#endif
                    }
                }

                HStack(spacing: 12) {
                    dashboardMetric(title: "Orders", value: "0")
                    dashboardMetric(title: "Revenue", value: "$0")
                    dashboardMetric(title: "Visits", value: "0")
                    dashboardMetric(title: "Conversion", value: "0%")
                }

                SetupCard(title: "AI assistant", subtitle: "Later, OneWay can help write product copy, reply to buyers, and suggest next steps. For now, your core shop is live and ready.") {
                    Text("Coming next: better product photos, automatic replies, and launch checklist coaching.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .safeAreaPadding(.bottom, 96)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Seller Dashboard")
    }

    private func sellerAction(_ title: String, icon: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                OneWayResolvedIcon(systemName: icon)
                    .foregroundStyle(Theme.accentGold)
                Text(title)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func dashboardMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.glassSurface))
    }
}

struct ProductListingEditorView: View {
    @ObservedObject var viewModel: BusinessViewModel
    @State private var editingProduct: ProductOrService?
    @State private var creatingProduct = false
    @State private var newProductDraft = ProductOrService(name: "", description: "", price: "$0.00", isSubscription: false, isVisible: true)
    @State private var pendingVisibilityToggle: ProductOrService?
    @State private var pendingArchive: ProductOrService?

    private var products: [ProductOrService] {
        (viewModel.storefront?.business.products ?? [])
            .sorted { lhs, rhs in
                let lhsVisible = lhs.isVisible ?? true
                let rhsVisible = rhs.isVisible ?? true
                if lhsVisible == rhsVisible { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
                return lhsVisible && !rhsVisible
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SetupCard(title: "Products", subtitle: "Add photos, stock, fulfillment hints, and payment links so buyers know exactly what to do.") {
                    Button {
                        newProductDraft = makeNewProductDraft()
                        creatingProduct = true
                    } label: {
                        OneWayResolvedLabel("Add product", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if products.isEmpty {
                        ContentUnavailableView("No products yet", systemImage: "shippingbox", description: Text("Add your first product here, then edit visibility, inventory, and payment settings."))
                            .frame(minHeight: 180)
                    } else {
                        ForEach(products) { product in
                            productManagementRow(product)
                        }
                    }
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(16)
            .safeAreaPadding(.bottom, 96)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Products")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newProductDraft = makeNewProductDraft()
                    creatingProduct = true
                } label: {
                    OneWayResolvedLabel("Add", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingProduct) { product in
            ProductCommerceEditorSheet(
                product: product,
                saveProduct: { updated in
                    var toSave = updated
                    if toSave.isVisible == nil { toSave.isVisible = true }
                    return await viewModel.updateListing(toSave)
                },
                uploadImage: { savedProduct, data, fileName, mimeType in
                    try await viewModel.uploadProductImage(productID: savedProduct.id, data: data, fileName: fileName, mimeType: mimeType)
                },
                onSaved: {
                    editingProduct = nil
                }
            )
        }
        .sheet(isPresented: $creatingProduct) {
            ProductCommerceEditorSheet(
                product: newProductDraft,
                saveProduct: { created in
                    var toCreate = created
                    toCreate.isVisible = true
                    if viewModel.storefront?.business.products.contains(where: { $0.id == toCreate.id }) == true {
                        return await viewModel.updateListing(toCreate)
                    }
                    return await viewModel.createListing(toCreate)
                },
                uploadImage: { savedProduct, data, fileName, mimeType in
                    try await viewModel.uploadProductImage(productID: savedProduct.id, data: data, fileName: fileName, mimeType: mimeType)
                },
                onSaved: {
                    creatingProduct = false
                }
            )
        }
        .alert("Update product visibility?", isPresented: Binding(
            get: { pendingVisibilityToggle != nil },
            set: { if !$0 { pendingVisibilityToggle = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                pendingVisibilityToggle = nil
            }
            Button("Confirm") {
                guard var product = pendingVisibilityToggle else { return }
                product.isVisible = !(product.isVisible ?? true)
                pendingVisibilityToggle = nil
                Task { await viewModel.updateListing(product) }
            }
        } message: {
            if let product = pendingVisibilityToggle {
                Text((product.isVisible ?? true)
                     ? "This will hide \(product.name) from the public storefront."
                     : "This will show \(product.name) on your public storefront.")
            } else {
                Text("Update visibility.")
            }
        }
        .alert("Archive this product?", isPresented: Binding(
            get: { pendingArchive != nil },
            set: { if !$0 { pendingArchive = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                pendingArchive = nil
            }
            Button("Archive", role: .destructive) {
                guard let product = pendingArchive else { return }
                pendingArchive = nil
                Task { await viewModel.deleteListing(product) }
            }
        } message: {
            if pendingArchive != nil {
                Text("Archived products are removed from your live catalog. This cannot be undone.")
            } else {
                Text("Archive product")
            }
        }
    }

    private func productManagementRow(_ product: ProductOrService) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if let mediaURL = product.mediaURL {
                    AsyncImage(url: mediaURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            productPlaceholder
                        }
                    }
                } else {
                    productPlaceholder
                }
            }
            .frame(width: 74, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(product.name)
                    .font(.headline)
                Text(product.price)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.accentGold)
                HStack(spacing: 6) {
                    if !(product.isVisible ?? true) {
                        commerceChip("Hidden", color: .secondary)
                    }
                    if product.isSoldOut {
                        commerceChip("Sold out", color: .orange)
                    } else if product.isLowStock {
                        commerceChip("Low stock", color: Theme.accentGold)
                    } else if product.tracksStock, let inventory = product.inventory {
                        commerceChip("\(inventory) in stock", color: .green)
                    }
                    if product.paymentLinkURL != nil {
                        commerceChip("Buy now", color: Theme.primaryBlue)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button("Edit") { editingProduct = product }
                    .buttonStyle(.bordered)
                Button((product.isVisible ?? true) ? "Hide" : "Show") {
                    pendingVisibilityToggle = product
                }
                .buttonStyle(.bordered)
                Button("Archive") {
                    pendingArchive = product
                }
                .buttonStyle(.bordered)
                .tint(.red.opacity(0.85))
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.05)))
    }

    private var productPlaceholder: some View {
        LinearGradient(colors: [Theme.primaryBlue.opacity(0.45), Theme.accentGold.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(OneWayResolvedIcon(systemName: "photo").foregroundStyle(.white.opacity(0.75)))
    }

    private func commerceChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func makeNewProductDraft() -> ProductOrService {
        ProductOrService(
            name: "",
            description: "",
            price: "$0.00",
            isSubscription: false,
            inventory: 1,
            trackInventory: true,
            lowStockThreshold: 3,
            paymentMode: "contact",
            paymentLinkURL: nil,
            isVisible: true,
            category: viewModel.storefront?.business.category,
            tags: [],
            variants: [],
            shippingInfo: viewModel.storefront?.business.hours,
            returnEligible: true
        )
    }
}

struct StorefrontShopSettingsView: View {
    @ObservedObject var viewModel: BusinessViewModel
    @State private var draftStorefront: Storefront?
    @State private var infoMessage: String?
    @State private var isSaving = false
    @State private var isPublishing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if draftStorefront != nil {
                    SetupCard(title: "Shop settings", subtitle: "Update name, handle, contact methods, fulfillment, and payment defaults.") {
                        TextField("Shop name", text: Binding(
                            get: { draftStorefront?.business.name ?? "" },
                            set: { value in
                                guard var store = draftStorefront else { return }
                                store.business.name = value
                                draftStorefront = store
                            }
                        ))
                        .textFieldStyle(OneWayFormFieldStyle())

                        TextField("Shop handle", text: Binding(
                            get: { draftStorefront?.business.handle ?? "" },
                            set: { updateHandle($0) }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(OneWayFormFieldStyle())

                        if let currentStore = draftStorefront, let url = shareURL(for: currentStore) {
                            HStack {
                                Text(url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                ShareLink(item: url) {
                                    Text("Share shop")
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if !viewModel.handleAvailability.message.isEmpty {
                            Text(viewModel.handleAvailability.message)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(handleAvailabilityColor)
                        }

                        TextField("Category", text: Binding(
                            get: { draftStorefront?.business.category ?? "" },
                            set: { value in
                                guard var store = draftStorefront else { return }
                                store.business.category = value
                                draftStorefront = store
                            }
                        ))
                        .textFieldStyle(OneWayFormFieldStyle())

                        TextField("Description", text: Binding(
                            get: { draftStorefront?.business.description ?? "" },
                            set: { value in
                                guard var store = draftStorefront else { return }
                                store.business.description = value
                                draftStorefront = store
                            }
                        ), axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(OneWayFormFieldStyle())

                        TextField("Contact email", text: Binding(
                            get: { draftStorefront?.business.contactEmail ?? "" },
                            set: { value in
                                guard var store = draftStorefront else { return }
                                store.business.contactEmail = value
                                draftStorefront = store
                            }
                        ))
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(OneWayFormFieldStyle())

                        TextField("Contact phone", text: Binding(
                            get: { draftStorefront?.business.phone ?? "" },
                            set: { value in
                                guard var store = draftStorefront else { return }
                                store.business.phone = value
                                draftStorefront = store
                            }
                        ))
                        .keyboardType(.phonePad)
                        .textFieldStyle(OneWayFormFieldStyle())

                        Picker("Default payment mode", selection: Binding(
                            get: { draftStorefront?.defaultPaymentMode ?? "contact" },
                            set: { value in
                                guard var store = draftStorefront else { return }
                                store.defaultPaymentMode = value
                                draftStorefront = store
                            }
                        )) {
                            Text("Request to buy").tag("contact")
                            Text("Payment link").tag("payment_link")
                        }
                        .pickerStyle(.segmented)

                        if (draftStorefront?.defaultPaymentMode ?? "contact") == "payment_link" {
                            TextField("Default payment link", text: Binding(
                                get: { draftStorefront?.defaultPaymentLinkURL?.absoluteString ?? draftStorefront?.business.website ?? "" },
                                set: { value in
                                    guard var store = draftStorefront else { return }
                                    store.business.website = value
                                    store.defaultPaymentLinkURL = URL(string: value)
                                    draftStorefront = store
                                }
                            ))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(OneWayFormFieldStyle())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Fulfillment options")
                                .font(.headline)
                            Toggle("Local pickup", isOn: optionalBoolBinding(\.pickupEnabled))
                            Toggle("Local delivery", isOn: optionalBoolBinding(\.localDeliveryEnabled))
                            Toggle("Shipping", isOn: optionalBoolBinding(\.shippingEnabled))
                            Toggle("Digital delivery", isOn: optionalBoolBinding(\.digitalDeliveryEnabled))
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))

                        if !publishChecklist.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Before launch:")
                                    .font(.caption.weight(.bold))
                                ForEach(publishChecklist, id: \.self) { item in
                                    Text("• \(item)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
                        }

                        HStack {
                            Button(isSaving ? "Saving..." : "Save settings") {
                                Task { await saveSettings() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving || isPublishing)

                            Button(isPublishing ? "Working..." : ((draftStorefront?.isPublished ?? false) ? "Move to Draft" : "Launch Shop")) {
                                Task { await togglePublish() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSaving || isPublishing || (!(draftStorefront?.isPublished ?? false) && !publishChecklist.isEmpty))
                        }
                    }

                    if let infoMessage {
                        Text(infoMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accentGold)
                    }
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                } else {
                    ProgressView("Loading shop settings...")
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding(16)
            .safeAreaPadding(.bottom, 90)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Shop settings")
        .task {
            if draftStorefront == nil {
                if viewModel.storefront == nil {
                    await viewModel.load()
                }
                draftStorefront = viewModel.storefront
            }
        }
        .onChange(of: draftStorefront?.business.handle ?? "") { _, value in
            let normalized = normalizeHandle(value)
            guard !normalized.isEmpty, normalized != value else { return }
            updateHandle(normalized)
        }
    }

    private var publishChecklist: [String] {
        []
    }

    private var handleAvailabilityColor: Color {
        switch viewModel.handleAvailability.status {
        case .available:
            return .green
        case .taken, .invalid:
            return .orange
        default:
            return .secondary
        }
    }

    private func saveSettings() async {
        guard var draftStorefront else { return }
        isSaving = true
        defer { isSaving = false }
        draftStorefront.business.handle = normalizeHandle(draftStorefront.business.handle ?? draftStorefront.slug)
        draftStorefront.slug = draftStorefront.business.handle ?? draftStorefront.slug
        draftStorefront.shopURL = APIConfig.storefrontPublicURLString(for: draftStorefront.slug)
        await viewModel.saveCurrentStorefront(draftStorefront)
        if let latest = viewModel.storefront {
            self.draftStorefront = latest
        }
        if viewModel.errorMessage == nil {
            infoMessage = "Shop settings saved."
        }
    }

    private func togglePublish() async {
        guard draftStorefront != nil else { return }
        isPublishing = true
        defer { isPublishing = false }
        await viewModel.publishCurrentStorefront()
        if let latest = viewModel.storefront {
            draftStorefront = latest
        }
        if viewModel.errorMessage == nil {
            infoMessage = draftStorefront?.isPublished == true ? "Shop launched." : "Shop moved to draft."
        }
    }

    private func optionalBoolBinding(_ keyPath: WritableKeyPath<BusinessProfile, Bool?>) -> Binding<Bool> {
        Binding(
            get: { draftStorefront?.business[keyPath: keyPath] ?? false },
            set: { newValue in
                guard var store = draftStorefront else { return }
                store.business[keyPath: keyPath] = newValue
                draftStorefront = store
            }
        )
    }

    private func normalizeHandle(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return value
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { allowed.contains($0) }
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    private func isValidHandle(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    private func updateHandle(_ value: String) {
        guard var draftStorefront else { return }
        let normalized = normalizeHandle(value)
        draftStorefront.business.handle = normalized
        draftStorefront.slug = normalized
        draftStorefront.shopURL = normalized.isEmpty ? nil : APIConfig.storefrontPublicURLString(for: normalized)
        self.draftStorefront = draftStorefront
        Task { await viewModel.checkHandleAvailability(normalized, excluding: draftStorefront.id) }
    }

    private func shareURL(for storefront: Storefront) -> URL? {
        let urlValue = storefront.shopURL ?? APIConfig.storefrontPublicURLString(for: storefront.slug)
        return URL(string: urlValue.hasPrefix("http") ? urlValue : "https://\(urlValue)")
    }
}

private struct ProductCommerceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var product: ProductOrService
    @State private var priceText: String
    @State private var inventoryText: String
    @State private var paymentMode: String
    @State private var paymentLinkText: String
    @State private var selectedImage: PhotosPickerItem?
    @State private var isUploading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    let saveProduct: (ProductOrService) async -> ProductOrService?
    let uploadImage: (ProductOrService, Data, String, String) async throws -> ProductOrService
    let onSaved: () -> Void

    init(
        product: ProductOrService,
        saveProduct: @escaping (ProductOrService) async -> ProductOrService?,
        uploadImage: @escaping (ProductOrService, Data, String, String) async throws -> ProductOrService,
        onSaved: @escaping () -> Void
    ) {
        _product = State(initialValue: product)
        _priceText = State(initialValue: product.price)
        _inventoryText = State(initialValue: product.inventory.map(String.init) ?? "")
        let initialPaymentMode = product.paymentMode == "oneway_wallet"
            ? "contact"
            : product.paymentMode ?? (product.paymentLinkURL == nil ? "contact" : "payment_link")
        _paymentMode = State(initialValue: initialPaymentMode)
        _paymentLinkText = State(initialValue: product.paymentLinkURL?.absoluteString ?? "")
        self.saveProduct = saveProduct
        self.uploadImage = uploadImage
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ProductPreviewCard(
                        name: product.name,
                        price: priceText,
                        description: product.description,
                        imageURLString: product.mediaURL?.absoluteString ?? "",
                        available: !product.isSoldOut,
                        inventoryCount: Int(inventoryText),
                        tracksInventory: product.trackInventory ?? false,
                        paymentLink: paymentLinkText
                    )

                    PhotosPicker(selection: $selectedImage, matching: .images) {
                        OneWayResolvedLabel(isUploading ? "Uploading photo..." : "Upload product photo", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isUploading)

                    TextField("Product name", text: $product.name)
                        .textFieldStyle(OneWayFormFieldStyle())
                    TextField("Price", text: $priceText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(OneWayFormFieldStyle())
                    TextField("Short description", text: $product.description, axis: .vertical)
                        .lineLimit(3...5)
                        .textFieldStyle(OneWayFormFieldStyle())
                    Toggle("Track inventory", isOn: Binding(
                        get: { product.trackInventory ?? false },
                        set: { product.trackInventory = $0 }
                    ))
                    if product.trackInventory == true {
                        TextField("Inventory count", text: $inventoryText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(OneWayFormFieldStyle())
                    }
                    Picker("How buyers pay", selection: $paymentMode) {
                        Text("Request").tag("contact")
                        Text("Payment link").tag("payment_link")
                    }
                    .pickerStyle(.segmented)

                    if paymentMode == "payment_link" {
                        TextField("Payment link", text: $paymentLinkText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(OneWayFormFieldStyle())
                        Text("Payment links show Buy now. Leave blank to keep Request to buy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Buyers send a request and you reply with next steps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .safeAreaPadding(.bottom, 60)
            }
            .background { SideMenuBackground() }
            .navigationTitle("Edit product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await saveAndClose() }
                    }
                    .disabled(isSaving || isUploading || product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || priceCents(priceText) <= 0)
                }
            }
            .onChange(of: selectedImage) { _, item in
                Task { await uploadSelectedImage(item) }
            }
        }
    }

    private func preparedProduct() -> ProductOrService? {
        let trimmedLink = paymentLinkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if paymentMode == "payment_link",
           !trimmedLink.isEmpty,
           !(trimmedLink.hasPrefix("http://") || trimmedLink.hasPrefix("https://")) {
            errorMessage = "Use a payment link that starts with http or https."
            return nil
        }
        var prepared = product
        prepared.price = String(format: "$%.2f", Double(priceCents(priceText)) / 100)
        prepared.priceCents = priceCents(priceText)
        prepared.inventory = prepared.trackInventory == true ? max(0, Int(inventoryText) ?? 0) : nil
        prepared.lowStockThreshold = prepared.lowStockThreshold ?? 3
        prepared.paymentMode = paymentMode
        prepared.paymentLinkURL = paymentMode == "payment_link" && !trimmedLink.isEmpty ? URL(string: trimmedLink) : nil
        prepared.isVisible = prepared.isVisible ?? true
        return prepared
    }

    private func saveAndClose() async {
        guard let prepared = preparedProduct() else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        guard let saved = await saveProduct(prepared) else {
            errorMessage = "Product save failed. Check the backend connection and try again."
            return
        }
        product = saved
        onSaved()
    }

    private func uploadSelectedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isUploading = true
        errorMessage = nil
        defer {
            isUploading = false
            selectedImage = nil
        }
        do {
            guard let data = try await jpegUploadData(from: item) else {
                errorMessage = "We could not read that image. Try another photo."
                return
            }
            guard let prepared = preparedProduct() else { return }
            guard let saved = await saveProduct(prepared) else {
                errorMessage = "Product save failed, so the photo was not uploaded."
                return
            }
            let updated = try await uploadImage(saved, data, "product-\(UUID().uuidString).jpg", "image/jpeg")
            product = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func priceCents(_ value: String) -> Int {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return max(0, Int(((Double(cleaned) ?? 0) * 100).rounded()))
    }
}

struct OrdersView: View {
    var body: some View {
        ContentUnavailableView("No orders yet", systemImage: "shippingbox", description: Text("Orders will appear here after your shop launches and buyers start checking out."))
            .navigationTitle("Orders")
    }
}

struct StorefrontOrdersView: View {
    private enum OrderFilter: String, CaseIterable, Identifiable {
        case newest = "New"
        case accepted = "Accepted"
        case completed = "Completed"
        case cancelled = "Cancelled"

        var id: String { rawValue }

        var statuses: [SiteStoreOrderRequestStatus] {
            switch self {
            case .newest: return [.requested]
            case .accepted: return [.accepted]
            case .completed: return [.completed]
            case .cancelled: return [.canceled]
            }
        }
    }

    let storefront: Storefront
    let service: SiteStoreService

    @State private var orders: [SiteStoreOrderRequest] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedOrder: SiteStoreOrderRequest?
    @State private var selectedFilter: OrderFilter = .newest

    init(storefront: Storefront, service: SiteStoreService = NetworkSiteStoreService()) {
        self.storefront = storefront
        self.service = service
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SetupCard(title: "Orders", subtitle: "Customer requests from your public shop appear here. Accept, reply, and mark complete when fulfilled.") {
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(OrderFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    if isLoading {
                        ProgressView().tint(Theme.accentGold)
                            .frame(maxWidth: .infinity)
                    } else if orders.isEmpty {
                        VStack(spacing: 8) {
                            OneWayResolvedIcon(systemName: "tray")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(Theme.accentGold)
                            Text("No order requests yet")
                                .font(.headline)
                            Text("When someone taps Request to buy, their request lands here.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(orders) { order in
                            StorefrontOrderRow(order: order) {
                                selectedOrder = order
                            } onAccept: {
                                Task { await update(order, status: .accepted) }
                            } onComplete: {
                                Task { await update(order, status: .completed) }
                            } onCancel: {
                                Task { await update(order, status: .canceled) }
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    Button {
                        Task { await load() }
                    } label: {
                        OneWayResolvedLabel("Refresh orders", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .safeAreaPadding(.bottom, 96)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Orders")
        .task { await load() }
        .onChange(of: selectedFilter) { _, _ in
            Task { await load() }
        }
        .sheet(item: $selectedOrder) { order in
            StorefrontOrderDetailView(
                storefront: storefront,
                initialOrder: order,
                service: service
            ) { updated in
                replace(updated)
            }
        }
    }

    private var domainSlug: String {
        storefront.slug.isEmpty ? (storefront.business.handle ?? storefront.business.name) : storefront.slug
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            orders = try await service.orderRequests(domainSlug: domainSlug, statuses: selectedFilter.statuses)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load order requests right now. Please try again."
        }
    }

    private func update(_ order: SiteStoreOrderRequest, status: SiteStoreOrderRequestStatus) async {
        do {
            let updated = try await service.updateOrderRequestStatus(domainSlug: domainSlug, orderRequestId: order.id, status: status)
            replace(updated)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update that order right now."
        }
    }

    private func replace(_ updated: SiteStoreOrderRequest) {
        if let index = orders.firstIndex(where: { $0.id == updated.id }) {
            orders[index] = updated
        } else {
            orders.insert(updated, at: 0)
        }
        selectedOrder = updated
    }
}

private struct StorefrontOrderRow: View {
    let order: SiteStoreOrderRequest
    let onDetails: () -> Void
    let onAccept: () -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(order.displayName)
                        .font(.headline)
                    Text(order.productName.isEmpty ? "Shop request" : order.productName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accentGold)
                }
                Spacer()
                Text(order.status.label.uppercased())
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(order.status == .requested ? Theme.accentGold.opacity(0.18) : Color.white.opacity(0.08)))
                    .foregroundStyle(order.status == .requested ? Theme.accentGold : .secondary)
            }

            Text(order.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack(spacing: 8) {
                OneWayResolvedLabel("Qty \(order.quantity)", systemImage: "number")
                OneWayResolvedLabel(order.fulfillmentLabel, systemImage: "shippingbox.fill")
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                Button("Details", action: onDetails).buttonStyle(.bordered)
                if order.status == .requested {
                    Button("Accept", action: onAccept).buttonStyle(.bordered).tint(Theme.primaryBlue)
                }
                if order.status == .accepted {
                    Button("Mark complete", action: onComplete).buttonStyle(.bordered).tint(.green)
                }
                if order.status != .completed && order.status != .canceled {
                    Button("Cancel", action: onCancel).buttonStyle(.bordered).tint(.red.opacity(0.85))
                }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }
}

private struct StorefrontOrderDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let storefront: Storefront
    let service: SiteStoreService
    let onUpdated: (SiteStoreOrderRequest) -> Void

    @State private var order: SiteStoreOrderRequest
    @State private var emailDeliveryConfigured = false
    @State private var replyText = ""
    @State private var isLoading = false
    @State private var infoMessage: String?
    @State private var errorMessage: String?

    init(
        storefront: Storefront,
        initialOrder: SiteStoreOrderRequest,
        service: SiteStoreService,
        onUpdated: @escaping (SiteStoreOrderRequest) -> Void
    ) {
        self.storefront = storefront
        self.service = service
        self.onUpdated = onUpdated
        _order = State(initialValue: initialOrder)
        _replyText = State(initialValue: StorefrontOrderDetailView.defaultReply(for: initialOrder))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCard
                    paymentCard
                    buyerCard
                    timelineCard
                    threadCard
                    replyCard
                    if let infoMessage {
                        Text(infoMessage).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accentGold)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .safeAreaPadding(.bottom, 60)
            }
            .background { SideMenuBackground() }
            .navigationTitle("Order request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
            }
            .task { await loadDetail() }
        }
    }

    private var summaryCard: some View {
        SetupCard(title: order.productName.isEmpty ? "Customer request" : order.productName, subtitle: "Ready to fulfill") {
            Text(order.message)
                .foregroundStyle(.secondary)
            HStack {
                OneWayResolvedLabel("Qty \(order.quantity)", systemImage: "number")
                OneWayResolvedLabel(order.fulfillmentLabel, systemImage: "shippingbox.fill")
                Spacer()
                Text(order.status.label)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.accentGold)
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                if order.inventoryApplied {
                    OneWayResolvedLabel("Inventory updated", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    OneWayResolvedLabel(order.status == .completed ? "Inventory pending" : "Inventory updates on completion", systemImage: "shippingbox")
                        .foregroundStyle(Theme.textSecondary)
                }
                if order.paymentLinkUrl?.isEmpty == false {
                    OneWayResolvedLabel("Payment link ready", systemImage: "link")
                        .foregroundStyle(Theme.primaryBlue)
                }
                if order.paymentMode == .oneWayWallet {
                    OneWayResolvedLabel(order.walletPaymentStatus == .paid ? "Payment received" : "OneWay Wallet", systemImage: "wallet.pass.fill")
                        .foregroundStyle(walletStatusColor)
                }
                OneWayResolvedLabel(order.paymentStatus.label, systemImage: "creditcard.fill")
                    .foregroundStyle(paymentStatusColor)
            }
            .font(.caption.weight(.semibold))
            HStack {
                statusButton("Accept", .accepted, tint: Theme.primaryBlue)
                statusButton("Mark complete", .completed, tint: .green)
                statusButton("Cancel", .canceled, tint: .red.opacity(0.8))
            }
        }
    }

    private var paymentCard: some View {
        SetupCard(title: "Payment", subtitle: "Keep the buyer status clear.") {
            HStack {
                OneWayResolvedLabel(order.paymentMode == .oneWayWallet ? "OneWay Wallet" : order.paymentStatus.label, systemImage: order.paymentMode == .oneWayWallet ? "wallet.pass.fill" : "creditcard.fill")
                    .foregroundStyle(paymentStatusColor)
                Spacer()
                if order.paymentMode == .oneWayWallet {
                    Text(order.walletPaymentStatus.label)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(walletStatusColor)
                } else if let paidAt = order.paidAt, !paidAt.isEmpty {
                    Text("Paid \(shortDate(paidAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if order.paymentMode == .oneWayWallet {
                if order.walletPaymentStatus == .paid {
                    OneWayResolvedLabel("Payment received", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                if let walletPaymentId = order.walletPaymentId, !walletPaymentId.isEmpty {
                    Text(walletPaymentId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("OneWay Wallet is in test mode. Do not use for real money movement.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if let link = order.paymentLinkUrl, !link.isEmpty {
                Text(link)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text("Add a payment link to the product or order before sending a Buy now link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if order.paymentMode == .oneWayWallet {
                    Button("Refund wallet payment") {
                        Task { await refundWalletPayment() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(order.walletPaymentStatus != .paid || isLoading)
                } else {
                    Button("Send payment link") {
                        Task { await sendPaymentLink() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(order.paymentLinkUrl?.isEmpty != false || order.customerEmail.isEmpty || isLoading)
                }

                Button("Mark paid") {
                    Task { await updatePaymentStatus(.paidManual) }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)

                Button("Mark refunded") {
                    Task { await updatePaymentStatus(.refunded) }
                }
                .buttonStyle(.bordered)
            .disabled(isLoading)
        }
    }
    }

    private var buyerCard: some View {
        SetupCard(title: "Buyer info", subtitle: order.displayName) {
            if !order.customerEmail.isEmpty {
                OneWayResolvedLabel(order.customerEmail, systemImage: "envelope.fill")
            }
            if !order.customerPhone.isEmpty {
                OneWayResolvedLabel(order.customerPhone, systemImage: "message.fill")
            }
            Text("Created \(shortDate(order.createdAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timelineCard: some View {
        SetupCard(title: "Status timeline", subtitle: "A quick history of what happened.") {
            let events = order.statusTimeline.isEmpty
                ? [SiteStoreStatusEvent(status: order.status.rawValue, at: order.updatedAt)]
                : order.statusTimeline
            ForEach(events) { event in
                HStack {
                    Circle().fill(Theme.accentGold).frame(width: 7, height: 7)
                    Text(statusLabel(event.status)).font(.caption.weight(.bold))
                    Spacer()
                    Text(shortDate(event.at)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var threadCard: some View {
        SetupCard(title: "Message thread", subtitle: "Customer message and seller replies stay together.") {
            if order.emailMessages.isEmpty {
                threadBubble(title: order.displayName, body: order.message, status: "received", outbound: false)
            } else {
                ForEach(order.emailMessages) { message in
                    threadBubble(
                        title: message.isOutbound ? "You" : order.displayName,
                        body: message.bodyText,
                        status: message.status,
                        outbound: message.isOutbound
                    )
                }
            }
        }
    }

    private var replyCard: some View {
        SetupCard(title: "Reply", subtitle: emailStatusText) {
            TextEditor(text: $replyText)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))

            Button {
                Task { await sendReply() }
            } label: {
                HStack {
                    if isLoading { ProgressView() }
                    Text("Send reply").fontWeight(.heavy)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(order.customerEmail.isEmpty || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)

            if order.paymentLinkUrl?.isEmpty == false {
                Button {
                    replyText = paymentLinkReply
                    Task { await sendReply() }
                } label: {
                    OneWayResolvedLabel("Send payment link", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(order.customerEmail.isEmpty || isLoading)
            }

            if order.customerEmail.isEmpty {
                Text("Buyer email missing. Ask for an email before sending an email reply.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var domainSlug: String {
        storefront.slug.isEmpty ? (storefront.business.handle ?? storefront.business.name) : storefront.slug
    }

    private var emailStatusText: String {
        if order.customerEmail.isEmpty { return "Email reply disabled until the buyer adds an email." }
        if emailDeliveryConfigured { return "Email ready" }
        if order.replyStatus == "failed" { return "Email delivery is not configured yet" }
        return "Email replies are in test mode"
    }

    private func threadBubble(title: String, body: String, status: String, outbound: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.heavy))
                Spacer()
                Text(messageStatusLabel(status)).font(.caption2.weight(.bold)).foregroundStyle(status == "failed" ? .orange : .secondary)
            }
            Text(body)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(outbound ? Theme.accentGold.opacity(0.14) : Color.white.opacity(0.06)))
    }

    private func statusButton(_ title: String, _ status: SiteStoreOrderRequestStatus, tint: Color) -> some View {
        Button(title) {
            Task { await updateStatus(status) }
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(order.status == status || isLoading)
    }

    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await service.order(domainSlug: domainSlug, orderId: order.id)
            order = detail.order
            emailDeliveryConfigured = detail.emailDeliveryConfigured
            onUpdated(detail.order)
        } catch {
            errorMessage = "Couldn't load this order request right now."
        }
    }

    private func updateStatus(_ status: SiteStoreOrderRequestStatus) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let updated = try await service.updateOrderRequestStatus(domainSlug: domainSlug, orderRequestId: order.id, status: status)
            order = updated
            onUpdated(updated)
            infoMessage = "Order request marked \(status.label.lowercased())."
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update this order request right now."
        }
    }

    private func sendReply() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.replyToOrder(domainSlug: domainSlug, orderId: order.id, message: replyText.trimmingCharacters(in: .whitespacesAndNewlines))
            order = result.order
            emailDeliveryConfigured = result.emailDeliveryConfigured
            onUpdated(result.order)
            infoMessage = result.message ?? "Reply saved."
            replyText = ""
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't send your reply right now."
        }
    }

    private func sendPaymentLink() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.sendPaymentLink(domainSlug: domainSlug, orderId: order.id)
            order = result.order
            emailDeliveryConfigured = result.emailDeliveryConfigured
            onUpdated(result.order)
            infoMessage = result.message ?? "Payment link sent."
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't send the payment link right now."
        }
    }

    private func updatePaymentStatus(_ status: SiteStoreOrderPaymentStatus) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let updated = try await service.updateOrderPaymentStatus(
                domainSlug: domainSlug,
                orderId: order.id,
                paymentStatus: status,
                paymentLinkUrl: order.paymentLinkUrl
            )
            order = updated
            onUpdated(updated)
            infoMessage = "Payment marked \(status.label.lowercased())."
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update payment status right now."
        }
    }

    private func refundWalletPayment() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.refundWalletPayment(domainSlug: domainSlug, orderId: order.id)
            order = result.order
            onUpdated(result.order)
            infoMessage = result.message ?? "Wallet refund complete."
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't process the wallet refund right now."
        }
    }

    private static func defaultReply(for order: SiteStoreOrderRequest) -> String {
        let greeting = order.displayName == "Customer" ? "Hi," : "Hi \(order.displayName),"
        let product = order.productName.isEmpty ? "your request" : order.productName
        return "\(greeting)\n\nThanks for your request for \(product). "
    }

    private var paymentLinkReply: String {
        let greeting = order.displayName == "Customer" ? "Hi," : "Hi \(order.displayName),"
        return "\(greeting)\n\nThanks for your request. You can use this payment link when you're ready:\n\(order.paymentLinkUrl ?? "")"
    }

    private var paymentStatusColor: Color {
        if order.paymentMode == .oneWayWallet {
            return walletStatusColor
        }
        switch order.paymentStatus {
        case .paidManual: return .green
        case .paymentLinkSent: return Theme.primaryBlue
        case .refunded: return Theme.accentGold
        case .failed: return .orange
        case .notRequested: return Theme.textSecondary
        }
    }

    private var walletStatusColor: Color {
        switch order.walletPaymentStatus {
        case .paid: return .green
        case .authorized, .pending: return Theme.primaryBlue
        case .refunded: return Theme.accentGold
        case .failed: return .orange
        case .notStarted: return Theme.textSecondary
        }
    }

    private func statusLabel(_ value: String) -> String {
        SiteStoreOrderRequestStatus(rawValue: value)?.label ?? value
    }

    private func messageStatusLabel(_ value: String) -> String {
        switch value {
        case "sent": return "Sent"
        case "stubbed": return "Stubbed"
        case "failed": return "Failed"
        case "received": return "Received"
        default: return value.isEmpty ? "Saved" : value.capitalized
        }
    }

    private func shortDate(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? (value.isEmpty ? "Just now" : value)
    }
}

struct StoreAnalyticsView: View {
    let storefront: Storefront?
    let service: SiteStoreService

    @State private var range: SiteStoreAnalyticsRange = .sevenDays
    @State private var summary: SiteStoreAnalyticsSummary?
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(storefront: Storefront? = nil, service: SiteStoreService = NetworkSiteStoreService()) {
        self.storefront = storefront
        self.service = service
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(SiteStoreAnalyticsRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                if storefront == nil {
                    ContentUnavailableView("Launch a shop first", systemImage: "storefront", description: Text("Analytics begin after your shop is live."))
                } else if isLoading && summary == nil {
                    ProgressView("Loading analytics...")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else if let summary, !summary.empty {
                    analyticsCards(summary)
                    topProducts(summary)
                } else {
                    ContentUnavailableView("Share your shop to start seeing activity", systemImage: "chart.line.uptrend.xyaxis", description: Text("Views, requests, and buy clicks will appear here."))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)
            .safeAreaPadding(.bottom, 80)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Analytics")
        .task { await load() }
        .onChange(of: range) { _, _ in
            Task { await load() }
        }
    }

    private func analyticsCards(_ summary: SiteStoreAnalyticsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            analyticsCard("Views", "\(summary.cards.views)", icon: "eye.fill")
            analyticsCard("Product views", "\(summary.cards.productViews)", icon: "shippingbox.fill")
            analyticsCard("Requests", "\(summary.cards.requests)", icon: "bubble.left.and.bubble.right.fill")
            analyticsCard("Buy clicks", "\(summary.cards.buyClicks)", icon: "cart.fill")
            analyticsCard("Shares", "\(summary.cards.shares)", icon: "square.and.arrow.up.fill")
            analyticsCard("Conversion", "\(summary.cards.conversionRate)%", icon: "chart.line.uptrend.xyaxis")
        }
    }

    private func analyticsCard(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OneWayResolvedIcon(systemName: icon)
                .foregroundStyle(Theme.accentGold)
            Text(value)
                .font(.title2.weight(.heavy))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.glassSurface))
    }

    private func topProducts(_ summary: SiteStoreAnalyticsSummary) -> some View {
        SetupCard(title: "People interested", subtitle: "Top products by views, requests, and buy clicks.") {
            if summary.topProducts.isEmpty {
                Text("No product activity yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.topProducts) { product in
                    HStack {
                        Text(productName(for: product.productId))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(product.count)")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.accentGold)
                    }
                }
            }
        }
    }

    private func productName(for productId: String) -> String {
        storefront?.business.products.first(where: { $0.id.uuidString == productId })?.name ?? "Product"
    }

    private var domainSlug: String? {
        guard let storefront else { return nil }
        return storefront.slug.isEmpty ? (storefront.business.handle ?? storefront.business.name) : storefront.slug
    }

    private func load() async {
        guard let domainSlug else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            summary = try await service.analytics(domainSlug: domainSlug, range: range)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load analytics right now."
        }
    }
}
