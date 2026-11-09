import SwiftUI
import Combine
import PhotosUI
import UIKit

struct DomainDetailView: View {
    let domain: OneWayDomain
    private let siteService: SiteService

    @State private var site: OneWaySite?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var visitURL: URL?

    init(domain: OneWayDomain, siteService: SiteService) {
        self.domain = domain
        self.siteService = siteService
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero

                    if let error = errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.85))
                    }

                    if isLoading {
                        ProgressView().tint(Theme.accentGold).padding(.top, 32)
                    } else if let site {
                        siteCard(site)
                    } else {
                        emptyCard
                    }

                    actionButtons
                }
                .padding(20)
            }
        }
        .navigationTitle(domain.slug)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSite() }
        .refreshable { await loadSite() }
        .navigationDestination(item: $visitURL) { url in
            BrowserPageView(url: url, siteService: siteService)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(domain.fullDomain)
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(Theme.accentGold)

            HStack(spacing: 8) {
                statusBadge
                Text("Expires \(domain.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var statusBadge: some View {
        let (bg, fg, label) = badgeStyle(for: domain.status)
        return Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
    }

    private func siteCard(_ site: OneWaySite) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(site.title.isEmpty ? "Untitled site" : site.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if site.published {
                    Text("PUBLISHED")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.green)
                } else {
                    Text("DRAFT")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.glassSurface, in: Capsule())
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if !site.description.isEmpty {
                Text(site.description)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 8) {
                OneWayResolvedLabel(site.mode.label, systemImage: modeIcon(site.mode))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.glassSurface, in: Capsule())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            OneWayResolvedIcon(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textMuted)
            Text("No site yet.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Build your page in code, blocks, or with AI.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            NavigationLink {
                EditSiteView(siteService: siteService, domainSlug: domain.slug)
            } label: {
                OneWayResolvedLabel(
                    site == nil ? "Create site" : "Edit site",
                    systemImage: "pencil"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())

            NavigationLink {
                SiteStorefrontSetupView(domainSlug: domain.slug)
            } label: {
                OneWayResolvedLabel("Storefront", systemImage: "bag.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.glassSurface, in: Capsule())
                    .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                    .foregroundStyle(Theme.accentGold)
            }
            .buttonStyle(.plain)

            if let site, site.published, let url = URL(string: "https://\(domain.fullDomain)") {
                Button {
                    BrowserRecentSiteStore.record(url)
                    visitURL = url
                } label: {
                    OneWayResolvedLabel("Visit live site", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.glassSurface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func loadSite() async {
        isLoading = true
        defer { isLoading = false }
        do {
            site = try await siteService.site(forSlug: domain.slug)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load this site."
        }
    }

    private func badgeStyle(for status: DomainStatus) -> (Color, Color, String) {
        switch status {
        case .active:    return (Color.green.opacity(0.18), Color.green, "Active")
        case .expired:   return (Color.red.opacity(0.18), Color.red, "Expired")
        case .suspended: return (Color.orange.opacity(0.18), Color.orange, "Suspended")
        case .pending:   return (Theme.glassSurface, Theme.textSecondary, "Pending")
        }
    }

    private func modeIcon(_ mode: SiteMode) -> String {
        switch mode {
        case .nocode: return "square.grid.2x2"
        case .code:   return "chevron.left.forwardslash.chevron.right"
        case .ai:     return "sparkles"
        }
    }
}

@MainActor
private final class SiteStorefrontSetupViewModel: ObservableObject {
    @Published var store: SiteStore?
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var isPublishing = false
    @Published var inquiries: [SiteStoreInquiry] = []
    @Published var notifications: [SiteStoreNotification] = []
    @Published var orderRequests: [SiteStoreOrderRequest] = []
    @Published var isLoadingInquiries = false
    @Published var isLoadingOperations = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var autoSaveMessage = "Draft ready"

    let domainSlug: String
    private let service: SiteStoreService
    private var lastSavedSignature = ""

    init(domainSlug: String, service: SiteStoreService = NetworkSiteStoreService()) {
        self.domainSlug = domainSlug
        self.service = service
    }

    var fullDomain: String { "\(domainSlug).oneway.app" }
    var visibleProducts: [SiteStoreProduct] {
        (store?.products ?? [])
            .filter { $0.inventoryStatus != .hidden }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var canPublish: Bool {
        guard let store else { return false }
        if store.storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if visibleProducts.isEmpty { return false }
        if store.checkoutMode == .paymentLink {
            return URL(string: store.paymentLinkUrl)?.scheme?.hasPrefix("http") == true
        }
        return true
    }

    var setupStep: StorefrontSetupStep {
        guard let store else { return .shopName }
        if store.storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .shopName }
        if store.storeDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .description }
        if visibleProducts.isEmpty { return .firstProduct }
        if needsContactMethod(store) { return .contact }
        return .publish
    }

    var setupProgress: Double {
        guard let store else { return 0.05 }
        var completed = 0
        if !store.storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { completed += 1 }
        if !store.storeDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { completed += 1 }
        if !visibleProducts.isEmpty { completed += 1 }
        if !needsContactMethod(store) { completed += 1 }
        if store.published { completed += 1 }
        return max(0.08, min(1, Double(completed) / 5.0))
    }

    var setupComplete: Bool {
        store?.published == true
    }

    var autoSaveSignature: String {
        guard let store else { return "empty" }
        let productSignature = store.products
            .map { "\($0.id)|\($0.name)|\($0.description)|\($0.priceCents)|\($0.imageUrl)|\($0.inventoryStatus.rawValue)" }
            .joined(separator: "~")
        return [
            store.storeName,
            store.storeDescription,
            store.checkoutMode.rawValue,
            store.paymentLinkUrl,
            store.contactEmail,
            store.contactPhone,
            String(store.pickupEnabled),
            String(store.shippingEnabled),
            String(store.marketplaceListed),
            productSignature
        ].joined(separator: "|")
    }

    var activeInquiries: [SiteStoreInquiry] {
        inquiries
            .filter { $0.status != .archived && $0.status != .orderRequested }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var newInquiryCount: Int {
        inquiries.filter { $0.status == .new }.count
    }

    var unreadNotificationCount: Int {
        notifications.filter(\.isUnread).count
    }

    var activeOrderRequests: [SiteStoreOrderRequest] {
        orderRequests
            .filter { $0.status != .completed && $0.status != .canceled }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            store = try await service.store(forSlug: domainSlug)
            if store?.storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                store?.storeName = titleFromSlug(domainSlug)
            }
            lastSavedSignature = autoSaveSignature
            errorMessage = nil
            await loadInquiries()
            await loadStoreOperations()
        } catch {
            errorMessage = "Couldn't load this storefront: \(error.localizedDescription)"
        }
    }

    func loadInquiries() async {
        isLoadingInquiries = true
        defer { isLoadingInquiries = false }
        do {
            inquiries = try await service.inquiries(domainSlug: domainSlug)
        } catch {
            errorMessage = "Couldn't load store inquiries: \(error.localizedDescription)"
        }
    }

    func loadStoreOperations() async {
        isLoadingOperations = true
        defer { isLoadingOperations = false }
        do {
            async let latestNotifications = service.notifications(domainSlug: domainSlug)
            async let latestOrderRequests = service.orderRequests(domainSlug: domainSlug)
            notifications = try await latestNotifications
            orderRequests = try await latestOrderRequests
        } catch {
            errorMessage = "Couldn't load seller activity: \(error.localizedDescription)"
        }
    }

    func updateInquiry(_ inquiry: SiteStoreInquiry, status: SiteStoreInquiryStatus) async {
        do {
            let updated = try await service.updateInquiryStatus(
                domainSlug: domainSlug,
                inquiryId: inquiry.id,
                status: status
            )
            if let index = inquiries.firstIndex(where: { $0.id == inquiry.id }) {
                inquiries[index] = updated
            }
            infoMessage = status == .archived ? "Inquiry archived." : "Inquiry marked \(status.label.lowercased())."
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update inquiry: \(error.localizedDescription)"
        }
    }

    func replyToInquiry(_ inquiry: SiteStoreInquiry, message: String) async {
        do {
            let updated = try await service.replyToInquiry(
                domainSlug: domainSlug,
                inquiryId: inquiry.id,
                message: message
            )
            replaceInquiry(updated)
            await loadStoreOperations()
            if updated.replyStatus == "stubbed" {
                infoMessage = "Stubbed in dev. Reply saved in OneWay."
            } else if updated.replyStatus == "failed" {
                infoMessage = "Reply saved, but external email failed."
            } else {
                infoMessage = "Reply sent and saved."
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't send reply: \(error.localizedDescription)"
        }
    }

    func convertInquiryToOrderRequest(_ inquiry: SiteStoreInquiry) async {
        do {
            let note = inquiry.productName.isEmpty
                ? "Customer asked about this store."
                : "Customer asked about \(inquiry.productName)."
            let updated = try await service.convertInquiryToOrderRequest(
                domainSlug: domainSlug,
                inquiryId: inquiry.id,
                note: note
            )
            replaceInquiry(updated)
            await loadStoreOperations()
            infoMessage = "Inquiry moved to order requests."
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't create order request: \(error.localizedDescription)"
        }
    }

    func updateNotification(_ notification: SiteStoreNotification, status: SiteStoreNotificationStatus) async {
        do {
            let updated = try await service.updateNotificationStatus(
                domainSlug: domainSlug,
                notificationId: notification.id,
                status: status
            )
            if status == .dismissed {
                notifications.removeAll { $0.id == notification.id }
            } else if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                notifications[index] = updated
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update notification: \(error.localizedDescription)"
        }
    }

    func markAllNotificationsRead() async {
        do {
            try await service.markAllNotificationsRead(domainSlug: domainSlug)
            notifications = notifications.map { notification in
                var updated = notification
                if updated.status == .unread {
                    updated.status = .read
                }
                return updated
            }
            infoMessage = "Store activity marked read."
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't mark activity read: \(error.localizedDescription)"
        }
    }

    func updateOrderRequest(_ orderRequest: SiteStoreOrderRequest, status: SiteStoreOrderRequestStatus) async {
        do {
            let updated = try await service.updateOrderRequestStatus(
                domainSlug: domainSlug,
                orderRequestId: orderRequest.id,
                status: status
            )
            if let index = orderRequests.firstIndex(where: { $0.id == orderRequest.id }) {
                orderRequests[index] = updated
            }
            infoMessage = "Order request marked \(status.label.lowercased())."
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update order request: \(error.localizedDescription)"
        }
    }

    private func replaceInquiry(_ updated: SiteStoreInquiry) {
        if let index = inquiries.firstIndex(where: { $0.id == updated.id }) {
            inquiries[index] = updated
        } else {
            inquiries.insert(updated, at: 0)
        }
    }

    func save() async {
        guard var store else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            store.storeEnabled = true
            self.store = try await service.save(store: store, domainSlug: domainSlug)
            lastSavedSignature = autoSaveSignature
            autoSaveMessage = "Draft saved"
            errorMessage = nil
            infoMessage = "Storefront saved."
        } catch {
            errorMessage = "Couldn't save storefront: \(error.localizedDescription)"
        }
    }

    func saveProduct(_ product: SiteStoreProduct) async {
        guard store != nil else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let existing = store?.products.contains(where: { $0.id == product.id }) == true
            store = existing
                ? try await service.updateProduct(product, domainSlug: domainSlug)
                : try await service.addProduct(product, domainSlug: domainSlug)
            lastSavedSignature = autoSaveSignature
            autoSaveMessage = "Draft saved"
            errorMessage = nil
            infoMessage = existing ? "Product updated." : "Product added."
        } catch {
            errorMessage = "Couldn't save product: \(error.localizedDescription)"
        }
    }

    func deleteProduct(_ product: SiteStoreProduct) async {
        isSaving = true
        defer { isSaving = false }
        do {
            store = try await service.deleteProduct(productId: product.id, domainSlug: domainSlug)
            lastSavedSignature = autoSaveSignature
            autoSaveMessage = "Draft saved"
            errorMessage = nil
            infoMessage = "Product removed."
        } catch {
            errorMessage = "Couldn't remove product: \(error.localizedDescription)"
        }
    }

    func generateSampleStore() async {
        guard var store else { return }
        let base = store.storeDescription.isEmpty ? "OneWay storefront" : store.storeDescription
        store.storeEnabled = true
        if store.storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.storeName = titleFromSlug(domainSlug)
        }
        if store.storeDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.storeDescription = "A simple shop for \(titleFromSlug(domainSlug))."
        }
        store.products = [
            SiteStoreProduct(id: UUID().uuidString, name: "Starter Pack", description: "A beginner-friendly bundle inspired by \(base).", priceCents: 2900, imageUrl: "", inventoryStatus: .inStock, sortOrder: 0),
            SiteStoreProduct(id: UUID().uuidString, name: "Signature Item", description: "Your featured product or service offer.", priceCents: 4900, imageUrl: "", inventoryStatus: .inStock, sortOrder: 1),
            SiteStoreProduct(id: UUID().uuidString, name: "Gift Card", description: "A flexible option for customers who want to support you.", priceCents: 2500, imageUrl: "", inventoryStatus: .inStock, sortOrder: 2)
        ]
        self.store = store
        await save()
    }

    func generateSampleProduct() async {
        guard var store else { return }
        let name = store.storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? titleFromSlug(domainSlug)
            : store.storeName
        let product = SiteStoreProduct(
            id: UUID().uuidString,
            name: "\(name) Signature Item",
            description: "A customer-ready listing you can customize with your own details.",
            priceCents: 2400,
            imageUrl: "",
            inventoryStatus: .inStock,
            sortOrder: store.products.count
        )
        store.products.append(product)
        self.store = store
        await save()
    }

    func autosaveDraftAfterDelay() async {
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard !Task.isCancelled else { return }
        await autosaveDraft()
    }

    func autosaveDraft() async {
        guard var store, !isLoading, !isSaving, !isPublishing else { return }
        let signature = autoSaveSignature
        guard signature != lastSavedSignature else { return }
        autoSaveMessage = "Saving draft..."
        do {
            store.storeEnabled = true
            self.store = try await service.save(store: store, domainSlug: domainSlug)
            lastSavedSignature = autoSaveSignature
            autoSaveMessage = "Draft saved"
            errorMessage = nil
        } catch {
            autoSaveMessage = "Draft not saved"
            errorMessage = "Autosave failed: \(error.localizedDescription)"
        }
    }

    func publish() async {
        guard canPublish else {
            errorMessage = "Add a store name, at least one product, and a valid payment link if needed."
            return
        }
        await save()
        isPublishing = true
        defer { isPublishing = false }
        do {
            store = try await service.publish(domainSlug: domainSlug)
            lastSavedSignature = autoSaveSignature
            autoSaveMessage = "Published"
            errorMessage = nil
            infoMessage = "\(fullDomain) storefront is live."
        } catch {
            errorMessage = "Couldn't publish storefront: \(error.localizedDescription)"
        }
    }

    private func titleFromSlug(_ slug: String) -> String {
        slug
            .replacingOccurrences(of: ".oneway.app", with: "")
            .split(separator: "-")
            .map { part in part.prefix(1).uppercased() + part.dropFirst() }
            .joined(separator: " ")
    }

    private func needsContactMethod(_ store: SiteStore) -> Bool {
        if store.checkoutMode == .paymentLink {
            return URL(string: store.paymentLinkUrl)?.scheme?.hasPrefix("http") != true
        }
        return store.contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.contactPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum StorefrontSetupStep: String, CaseIterable, Identifiable {
    case shopName
    case description
    case firstProduct
    case contact
    case publish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shopName: return "Name shop"
        case .description: return "Describe it"
        case .firstProduct: return "Add product"
        case .contact: return "How to buy"
        case .publish: return "Publish"
        }
    }

    var icon: String {
        switch self {
        case .shopName: return "sparkles"
        case .description: return "text.quote"
        case .firstProduct: return "shippingbox.fill"
        case .contact: return "hand.tap.fill"
        case .publish: return "paperplane.fill"
        }
    }
}

private enum StoreActivityFilter: String, CaseIterable, Identifiable {
    case unread
    case orders
    case inquiries
    case completed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unread: return "Unread"
        case .orders: return "Orders"
        case .inquiries: return "Inquiries"
        case .completed: return "Completed"
        }
    }
}

private enum StorefrontStudioSection: String, CaseIterable, Identifiable {
    case setup
    case orders
    case messages
    case products
    case analytics
    case ai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .setup: return "Setup"
        case .orders: return "Orders"
        case .messages: return "Messages"
        case .products: return "Products"
        case .analytics: return "Analytics"
        case .ai: return "AI"
        }
    }

    var icon: String {
        switch self {
        case .setup: return "wand.and.stars"
        case .orders: return "list.clipboard.fill"
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .products: return "shippingbox.fill"
        case .analytics: return "chart.line.uptrend.xyaxis"
        case .ai: return "sparkles"
        }
    }
}

private struct SiteStorefrontSetupView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel: SiteStorefrontSetupViewModel
    @State private var editingProduct: SiteStoreProduct?
    @State private var replyingInquiry: SiteStoreInquiry?
    @State private var selectedOrderRequest: SiteStoreOrderRequest?
    @State private var activityFilter: StoreActivityFilter = .unread
    @State private var showingPreview = false
    @State private var showingPublishSuccess = false
    @State private var selectedStudioSection: StorefrontStudioSection = .setup

    init(domainSlug: String) {
        _viewModel = StateObject(wrappedValue: SiteStorefrontSetupViewModel(domainSlug: domainSlug))
    }

    private var liveURL: URL {
        URL(string: "https://\(viewModel.fullDomain)") ?? URL(string: "https://oneway.app")!
    }

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            if viewModel.isLoading {
                VStack(spacing: 14) {
                    ProgressView().tint(Theme.accentGold)
                    Text("Preparing your shop builder...")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        setupHero
                        guidedSetupCard
                        storefrontPreviewMoment
                        studioSwitcher
                        studioSectionContent
                        messages
                    }
                    .padding(20)
                    .padding(.bottom, 120)
                }
            }
        }
        .navigationTitle("Create your shop")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .task(id: viewModel.autoSaveSignature) { await viewModel.autosaveDraftAfterDelay() }
        .sheet(item: $editingProduct) { product in
            SiteStoreProductEditorView(product: product, domainSlug: viewModel.domainSlug) { saved in
                editingProduct = nil
                Task { await viewModel.saveProduct(saved) }
            }
        }
        .sheet(item: $replyingInquiry) { inquiry in
            SiteStoreInquiryReplyView(inquiry: inquiry) { message in
                replyingInquiry = nil
                Task { await viewModel.replyToInquiry(inquiry, message: message) }
            }
        }
        .sheet(item: $selectedOrderRequest) { orderRequest in
            SiteStoreOrderRequestDetailView(domainSlug: viewModel.domainSlug, initialOrder: orderRequest) { updated in
                if let index = viewModel.orderRequests.firstIndex(where: { $0.id == updated.id }) {
                    viewModel.orderRequests[index] = updated
                }
            }
        }
        .sheet(isPresented: $showingPreview) {
            NavigationStack {
                SiteStorePreviewView(store: viewModel.store)
                    .navigationTitle("Store preview")
                    .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                            Button("Back") { showingPreview = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showingPublishSuccess) {
            StorefrontPublishSuccessView(url: liveURL) {
                openURL(liveURL)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var setupHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create your shop")
                        .font(.system(size: 36, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text("A tiny storefront for products, custom work, drops, appointments, or digital goods. About 3 minutes.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(spacing: 4) {
                    Text("\(Int(viewModel.setupProgress * 100))%")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Theme.accentGold)
                        .monospacedDigit()
                    Text(viewModel.autoSaveMessage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            ProgressView(value: viewModel.setupProgress)
                .tint(Theme.accentGold)
                .scaleEffect(x: 1, y: 1.8, anchor: .center)
                .clipShape(Capsule())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StorefrontSetupStep.allCases) { step in
                        stepChip(step)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.11), Theme.primaryBlue.opacity(0.18), Theme.accentGold.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.divider, lineWidth: 1))
        .shadow(color: Theme.primaryBlue.opacity(0.24), radius: 24, x: 0, y: 18)
    }

    private func stepChip(_ step: StorefrontSetupStep) -> some View {
        let current = viewModel.setupStep == step
        let complete = isStepComplete(step)
        return HStack(spacing: 6) {
            OneWayResolvedIcon(systemName: complete ? "checkmark.circle.fill" : step.icon)
            Text(step.title)
        }
        .font(.caption.weight(.bold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(current ? Theme.accentGold.opacity(0.2) : Color.white.opacity(0.07), in: Capsule())
        .foregroundStyle(current ? Theme.accentGold : Theme.textSecondary)
    }

    private var guidedSetupCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                OneWayResolvedLabel("Setup path", systemImage: "map.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("Momentum over configuration")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textMuted)
            }

            shopNameStep
            descriptionStep
            firstProductStep
            contactStep
            publishStep
        }
        .storeCard()
    }

    private var shopNameStep: some View {
        setupStepBlock(.shopName, title: "Name your shop", subtitle: "Make it searchable, memorable, and easy to say.") {
            smallField("Shop name", text: binding(\.storeName, default: ""))
            Text("Examples: King’s Vintage Finds, TwinBlixx Customs, Desert Glow Studio")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var descriptionStep: some View {
        setupStepBlock(.description, title: "Tell people what you sell", subtitle: "One sentence is enough. You can polish it later.") {
            smallField("Short shop description", text: binding(\.storeDescription, default: ""), lineLimit: 3...5)
            Button {
                if var store = viewModel.store {
                    let name = store.storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "this shop" : store.storeName
                    store.storeDescription = "Handpicked products and services from \(name), ready to request through OneWay."
                    viewModel.store = store
                }
            } label: {
                OneWayResolvedLabel("Suggest description", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .tint(Theme.accentGold)
        }
    }

    private var firstProductStep: some View {
        setupStepBlock(.firstProduct, title: "Add your first product", subtitle: "Start with one item. Your shop feels real the moment a product card appears.") {
            if let first = viewModel.visibleProducts.first {
                miniProductPreview(first)
            } else {
                HStack(spacing: 10) {
                    Button {
                        editingProduct = SiteStoreProduct(
                            id: UUID().uuidString,
                            name: "",
                            description: "",
                            priceCents: 0,
                            imageUrl: "",
                            inventoryStatus: .inStock,
                            sortOrder: viewModel.store?.products.count ?? 0
                        )
                    } label: {
                        OneWayResolvedLabel("Add first product", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryPillButtonStyle())

                    Button {
                        Task { await viewModel.generateSampleProduct() }
                    } label: {
                        OneWayResolvedIcon(systemName: "wand.and.stars")
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentGold)
                }
            }
        }
    }

    private var contactStep: some View {
        setupStepBlock(.contact, title: "Choose how customers buy", subtitle: "Start simple: customer requests the order, then you reply.") {
            Picker("Buy method", selection: binding(\.checkoutMode, default: .contact)) {
                ForEach(SiteStoreCheckoutMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.store?.checkoutMode == .paymentLink {
                smallField("Payment link", text: binding(\.paymentLinkUrl, default: "https://"))
            } else {
                smallField("Email for customer requests", text: binding(\.contactEmail, default: ""))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                smallField("Phone or text number", text: binding(\.contactPhone, default: ""))
                    .keyboardType(.phonePad)
            }

            HStack(spacing: 10) {
                Toggle("Pickup", isOn: binding(\.pickupEnabled, default: false))
                    .toggleStyle(.button)
                Toggle("Shipping", isOn: binding(\.shippingEnabled, default: false))
                    .toggleStyle(.button)
            }
            .foregroundStyle(Theme.textPrimary)
        }
    }

    private var publishStep: some View {
        setupStepBlock(.publish, title: "Publish and share", subtitle: "When the basics are ready, put your shop live on OneWay.") {
            HStack(spacing: 10) {
                Button {
                    showingPreview = true
                } label: {
                    OneWayResolvedLabel("Preview", systemImage: "eye.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.primaryBlue)

                Button {
                    Task {
                        await viewModel.publish()
                        if viewModel.store?.published == true {
                            showingPublishSuccess = true
                        }
                    }
                } label: {
                    OneWayResolvedLabel(viewModel.store?.published == true ? "Published" : "Publish", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(!viewModel.canPublish || viewModel.isPublishing)
            }

            if viewModel.store?.published == true {
                ShareLink(item: liveURL) {
                    OneWayResolvedLabel("Share your shop", systemImage: "square.and.arrow.up.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accentGold)
            }
        }
    }

    private func setupStepBlock<Content: View>(_ step: StorefrontSetupStep, title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        let current = viewModel.setupStep == step
        let complete = isStepComplete(step)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                OneWayResolvedIcon(systemName: complete ? "checkmark.circle.fill" : step.icon)
                    .font(.headline)
                    .foregroundStyle(complete ? Color.green : current ? Theme.accentGold : Theme.textMuted)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }

            content()
                .padding(.leading, 40)
        }
        .padding(14)
        .background(current ? Theme.accentGold.opacity(0.08) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(current ? Theme.accentGold.opacity(0.28) : Theme.divider, lineWidth: 1))
    }

    private var storefrontPreviewMoment: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OneWayResolvedLabel("Your shop preview", systemImage: "sparkles.rectangle.stack.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if viewModel.visibleProducts.isEmpty {
                    Text("Waiting for first product")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    Text("It exists now")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accentGold)
                }
            }

            SiteStorePreviewSnapshot(store: viewModel.store, url: viewModel.fullDomain)

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = liveURL.absoluteString
                    viewModel.infoMessage = "Shop link copied."
                } label: {
                    OneWayResolvedLabel("Copy link", systemImage: "doc.on.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.primaryBlue)

                Button {
                    showingPreview = true
                } label: {
                    OneWayResolvedLabel("Full preview", systemImage: "eye.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accentGold)
            }
            .font(.caption.weight(.bold))
        }
        .storeCard()
    }

    private var studioSwitcher: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shop Management")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text(viewModel.setupComplete ? "Run the shop from here." : "The studio unlocks as your shop comes together.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StorefrontStudioSection.allCases) { section in
                        Button {
                            selectedStudioSection = section
                        } label: {
                            OneWayResolvedLabel(section.label, systemImage: section.icon)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(selectedStudioSection == section ? Theme.primaryBlue.opacity(0.22) : Color.white.opacity(0.07), in: Capsule())
                                .foregroundStyle(selectedStudioSection == section ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var studioSectionContent: some View {
        if !viewModel.setupComplete && selectedStudioSection != .setup {
            notReadyStudioCard
        } else {
            switch selectedStudioSection {
            case .setup:
                quickSetupSummary
            case .orders:
                orderRequestsCard
            case .messages:
                VStack(alignment: .leading, spacing: 14) {
                    sellerActivityCard
                    inquiriesCard
                }
            case .products:
                productsCard
            case .analytics:
                analyticsPlaceholder
            case .ai:
                aiAssistantCard
            }
        }
    }

    private var quickSetupSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            OneWayResolvedLabel("Quick checklist", systemImage: "checklist")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            ForEach(StorefrontSetupStep.allCases) { step in
                HStack {
                    OneWayResolvedIcon(systemName: isStepComplete(step) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isStepComplete(step) ? Color.green : Theme.textMuted)
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
            }
        }
        .storeCard()
    }

    private var notReadyStudioCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            OneWayResolvedLabel("Finish setup first", systemImage: "lock.open.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Orders, messages, analytics, and AI tools stay out of the way until your first shop is live.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Button("Back to setup") { selectedStudioSection = .setup }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primaryBlue)
        }
        .storeCard()
    }

    private var analyticsPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            OneWayResolvedLabel("Analytics", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Views, product taps, order requests, and share performance will appear here as your shop gets traffic.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                metricTile("Products", "\(viewModel.visibleProducts.count)")
                metricTile("New", "\(viewModel.newInquiryCount)")
                metricTile("Orders", "\(viewModel.activeOrderRequests.count)")
            }
        }
        .storeCard()
    }

    private var aiAssistantCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            OneWayResolvedLabel("AI Assistant", systemImage: "sparkles")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Use AI after the basics are done: improve your product copy, write a pickup policy, or create a launch caption.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Button {
                Task { await viewModel.generateSampleStore() }
            } label: {
                OneWayResolvedLabel("Generate sample store", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accentGold)
        }
        .storeCard()
    }

    private func metricTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.weight(.heavy))
                .foregroundStyle(Theme.accentGold)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func miniProductPreview(_ product: SiteStoreProduct) -> some View {
        HStack(spacing: 12) {
            productThumb(product)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 5) {
                Text(product.name.isEmpty ? "Untitled product" : product.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(product.description.isEmpty ? "Add a short description so buyers know what they’re getting." : product.description)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                Text(product.formattedPrice)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.accentGold)
            }
            Spacer()
            Button("Edit") { editingProduct = product }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
                .tint(Theme.primaryBlue)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func productThumb(_ product: SiteStoreProduct) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay {
                if let url = URL(string: product.imageUrl), !product.imageUrl.isEmpty {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        OneWayResolvedIcon(systemName: "photo")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    OneWayResolvedIcon(systemName: "camera.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sellerActivityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OneWayResolvedLabel("Store activity", systemImage: "bell.badge.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if viewModel.unreadNotificationCount > 0 {
                    Text("\(viewModel.unreadNotificationCount) new")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.green)
                }
            }

            Picker("Activity filter", selection: $activityFilter) {
                ForEach(StoreActivityFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.isLoadingOperations {
                ProgressView().tint(Theme.accentGold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else if filteredNotifications.isEmpty {
                Text("New buyer messages and order updates will show up here.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(filteredNotifications.prefix(6)) { notification in
                    notificationRow(notification)
                }
            }

            HStack {
                Button {
                    Task { await viewModel.markAllNotificationsRead() }
                } label: {
                    OneWayResolvedLabel("Mark all read", systemImage: "checkmark.circle")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .disabled(viewModel.unreadNotificationCount == 0)

                Button {
                    Task { await viewModel.loadStoreOperations() }
                } label: {
                    OneWayResolvedLabel("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .storeCard()
    }

    private var filteredNotifications: [SiteStoreNotification] {
        switch activityFilter {
        case .unread:
            return viewModel.notifications.filter { $0.status == .unread }
        case .orders:
            return viewModel.notifications.filter { $0.type.contains("order") || $0.relatedOrderRequestId != nil }
        case .inquiries:
            return viewModel.notifications.filter { $0.type.contains("inquiry") || $0.relatedInquiryId != nil }
        case .completed:
            return viewModel.notifications.filter { $0.type.contains("completed") || $0.body.localizedCaseInsensitiveContains("completed") }
        }
    }

    private var orderRequestsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OneWayResolvedLabel("Order requests", systemImage: "list.clipboard.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !viewModel.activeOrderRequests.isEmpty {
                    Text("\(viewModel.activeOrderRequests.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accentGold.opacity(0.18), in: Capsule())
                        .foregroundStyle(Theme.accentGold)
                }
            }

            if viewModel.activeOrderRequests.isEmpty {
                Text("When a customer is ready, request orders land here with quantity, fulfillment, and status.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(viewModel.activeOrderRequests) { orderRequest in
                    orderRequestRow(orderRequest)
                }
            }
        }
        .storeCard()
    }

    private var productsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OneWayResolvedLabel("Products", systemImage: "shippingbox.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    editingProduct = SiteStoreProduct(
                        id: UUID().uuidString,
                        name: "",
                        description: "",
                        priceCents: 0,
                        imageUrl: "",
                        inventoryStatus: .inStock,
                        sortOrder: viewModel.store?.products.count ?? 0
                    )
                } label: {
                    OneWayResolvedLabel("Add", systemImage: "plus")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primaryBlue)
            }

            if viewModel.store?.products.isEmpty != false {
                VStack(spacing: 8) {
                    OneWayResolvedIcon(systemName: "bag.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.accentGold)
                    Text("Add your first product.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Start with one item. You can add more after publishing.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Generate sample product") {
                        Task { await viewModel.generateSampleProduct() }
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accentGold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ForEach((viewModel.store?.products ?? []).sorted { $0.sortOrder < $1.sortOrder }) { product in
                    productRow(product)
                }
            }
        }
        .storeCard()
    }

    private var inquiriesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OneWayResolvedLabel("Customer messages", systemImage: "tray.full.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if viewModel.newInquiryCount > 0 {
                    Text("\(viewModel.newInquiryCount) new")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.green)
                }
            }

            if viewModel.isLoadingInquiries {
                ProgressView().tint(Theme.accentGold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if viewModel.activeInquiries.isEmpty {
                VStack(spacing: 8) {
                    OneWayResolvedIcon(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.accentGold)
                    Text("No customer messages yet.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("When someone taps Request order, their message appears here.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ForEach(viewModel.activeInquiries) { inquiry in
                    inquiryRow(inquiry)
                }
            }

            Button {
                Task { await viewModel.loadInquiries() }
            } label: {
                OneWayResolvedLabel("Refresh messages", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
        }
        .storeCard()
    }

    private func notificationRow(_ notification: SiteStoreNotification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                OneWayResolvedIcon(systemName: notification.isUnread ? "bell.badge.fill" : "bell.fill")
                    .foregroundStyle(notification.isUnread ? Theme.accentGold : Theme.textMuted)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(notification.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(notification.body)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if notification.isUnread {
                    Button("Mark read") {
                        Task { await viewModel.updateNotification(notification, status: .read) }
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.primaryBlue)
                }

                Button("Dismiss") {
                    Task { await viewModel.updateNotification(notification, status: .dismissed) }
                }
                .buttonStyle(.bordered)
                .tint(.red.opacity(0.8))
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Color.white.opacity(notification.isUnread ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func orderRequestRow(_ orderRequest: SiteStoreOrderRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(orderRequest.displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    if !orderRequest.productName.isEmpty {
                        Text(orderRequest.productName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accentGold)
                    }
                }
                Spacer()
                Text(orderRequest.status.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(orderRequest.status == .requested ? Theme.accentGold.opacity(0.18) : Color.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(orderRequest.status == .requested ? Theme.accentGold : Theme.textSecondary)
            }

            Text(orderRequest.note.isEmpty ? orderRequest.message : orderRequest.note)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                OneWayResolvedLabel("Qty \(orderRequest.quantity)", systemImage: "number")
                OneWayResolvedLabel(orderRequest.fulfillmentLabel, systemImage: "shippingbox.fill")
            }
            .font(.caption)
            .foregroundStyle(Theme.textMuted)

            HStack(spacing: 8) {
                Button("Details") {
                    selectedOrderRequest = orderRequest
                }
                .buttonStyle(.bordered)
                .tint(Theme.accentGold)

                Button("Accept") {
                    Task { await viewModel.updateOrderRequest(orderRequest, status: .accepted) }
                }
                .buttonStyle(.bordered)
                .tint(Theme.primaryBlue)

                Button("Complete") {
                    Task { await viewModel.updateOrderRequest(orderRequest, status: .completed) }
                }
                .buttonStyle(.bordered)
                .tint(.green)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func inquiryRow(_ inquiry: SiteStoreInquiry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(inquiry.displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    if !inquiry.productName.isEmpty {
                        Text(inquiry.productName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accentGold)
                    }
                }
                Spacer()
                Text(inquiry.status.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(inquiry.status == .new ? Color.green.opacity(0.18) : Color.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(inquiry.status == .new ? Color.green : Theme.textSecondary)
            }

            Text(inquiry.message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                OneWayResolvedLabel("Qty \(inquiry.quantity)", systemImage: "number")
                if !inquiry.fulfillmentPreference.isEmpty {
                    OneWayResolvedLabel(fulfillmentLabel(inquiry.fulfillmentPreference), systemImage: "shippingbox.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textMuted)

            HStack(spacing: 8) {
                Button("Reply") { replyingInquiry = inquiry }
                    .buttonStyle(.bordered)
                    .tint(Theme.primaryBlue)
                Button("Request order") {
                    Task { await viewModel.convertInquiryToOrderRequest(inquiry) }
                }
                .buttonStyle(.bordered)
                .tint(Theme.accentGold)
                Button("Archive") {
                    Task { await viewModel.updateInquiry(inquiry, status: .archived) }
                }
                .buttonStyle(.bordered)
                .tint(.red.opacity(0.8))
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func productRow(_ product: SiteStoreProduct) -> some View {
        HStack(spacing: 12) {
            productThumb(product)
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(product.name.isEmpty ? "Untitled product" : product.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(product.formattedPrice) • \(product.inventoryStatus.label)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Menu {
                Button("Edit") { editingProduct = product }
                Button("Delete", role: .destructive) {
                    Task { await viewModel.deleteProduct(product) }
                }
            } label: {
                OneWayResolvedIcon(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let info = viewModel.infoMessage {
                Text(info).font(.footnote).foregroundStyle(Theme.accentGold)
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red.opacity(0.9))
            }
        }
    }

    private func smallField(_ placeholder: String, text: Binding<String>, lineLimit: ClosedRange<Int> = 1...1) -> some View {
        TextField(placeholder, text: text, axis: lineLimit.upperBound > 1 ? .vertical : .horizontal)
            .lineLimit(lineLimit)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SiteStore, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding {
            viewModel.store?[keyPath: keyPath] ?? defaultValue
        } set: { value in
            viewModel.store?[keyPath: keyPath] = value
        }
    }

    private func isStepComplete(_ step: StorefrontSetupStep) -> Bool {
        guard let store = viewModel.store else { return false }
        switch step {
        case .shopName:
            return !store.storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .description:
            return !store.storeDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .firstProduct:
            return !viewModel.visibleProducts.isEmpty
        case .contact:
            if store.checkoutMode == .paymentLink {
                return URL(string: store.paymentLinkUrl)?.scheme?.hasPrefix("http") == true
            }
            return !store.contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !store.contactPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .publish:
            return store.published
        }
    }

    private func fulfillmentLabel(_ value: String) -> String {
        switch value {
        case "pickup": return "Pickup"
        case "local_delivery": return "Local delivery"
        case "shipping": return "Shipping"
        case "digital": return "Digital"
        default: return value
        }
    }
}

private struct SiteStorePreviewSnapshot: View {
    let store: SiteStore?
    let url: String

    private var firstProduct: SiteStoreProduct? {
        store?.products
            .filter { $0.inventoryStatus != .hidden }
            .sorted { $0.sortOrder < $1.sortOrder }
            .first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store?.storeName.isEmpty == false ? store?.storeName ?? "" : "Your shop name")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text(store?.storeDescription.isEmpty == false ? store?.storeDescription ?? "" : "A short, friendly promise about what customers can buy from you.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(url)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accentGold)
            }

            if let product = firstProduct {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 90, height: 90)
                        .overlay {
                            if let imageURL = URL(string: product.imageUrl), !product.imageUrl.isEmpty {
                                AsyncImage(url: imageURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    OneWayResolvedIcon(systemName: "photo")
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            } else {
                                OneWayResolvedIcon(systemName: "bag.fill")
                                    .font(.title2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(product.name)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(product.description.isEmpty ? "Product description appears here." : product.description)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                        Text(product.formattedPrice)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.accentGold)
                    }
                    Spacer()
                }
            } else {
                VStack(spacing: 8) {
                    OneWayResolvedIcon(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(Theme.textMuted)
                    Text("Your first product card will appear here.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack {
                OneWayResolvedLabel(store?.checkoutMode.label ?? "Contact to buy", systemImage: "hand.tap.fill")
                Spacer()
                Text("Request order")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.accentGold.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.accentGold)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.1), Theme.primaryBlue.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }
}

private struct StorefrontPublishSuccessView: View {
    let url: URL
    let onOpen: () -> Void
    @State private var copied = false

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your shop is live")
                            .font(.system(size: 36, weight: .heavy))
                            .foregroundStyle(Theme.textPrimary)
                        Text("That first-store moment is real now. Share it with customers and start taking requests.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(url.absoluteString)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.accentGold)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        copied = true
                    } label: {
                        OneWayResolvedLabel(copied ? "Copied" : "Copy link", systemImage: "doc.on.doc.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryPillButtonStyle())

                    Button {
                        onOpen()
                    } label: {
                        OneWayResolvedLabel("Open storefront", systemImage: "safari.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.primaryBlue)

                    ShareLink(item: url) {
                        OneWayResolvedLabel("Share via Messages", systemImage: "message.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accentGold)

                    VStack(alignment: .leading, spacing: 8) {
                        OneWayResolvedLabel("Instagram and TikTok sharing", systemImage: "sparkles.tv")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Coming next: one-tap social launch posts for creators.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(20)
            }
        }
    }
}

private struct SiteStoreOrderRequestDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let domainSlug: String
    let service: SiteStoreService
    let onUpdated: (SiteStoreOrderRequest) -> Void

    @State private var order: SiteStoreOrderRequest
    @State private var emailDeliveryConfigured = false
    @State private var replyText = ""
    @State private var infoMessage: String?
    @State private var errorMessage: String?
    @State private var isLoading = false

    init(
        domainSlug: String,
        initialOrder: SiteStoreOrderRequest,
        service: SiteStoreService = NetworkSiteStoreService(),
        onUpdated: @escaping (SiteStoreOrderRequest) -> Void
    ) {
        self.domainSlug = domainSlug
        self.service = service
        self.onUpdated = onUpdated
        _order = State(initialValue: initialOrder)
        _replyText = State(initialValue: Self.defaultReply(for: initialOrder))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryCard
                        buyerCard
                        timelineCard
                        threadCard
                        replyCard
                        messages
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Order request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Back") { dismiss() }
                }
            }
            .task { await loadDetail() }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(order.productName.isEmpty ? "Store order request" : order.productName)
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Ready to fulfill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accentGold)
                }
                Spacer()
                Text(order.status.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentGold.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.accentGold)
            }

            Text(order.message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                OneWayResolvedLabel("Qty \(order.quantity)", systemImage: "number")
                OneWayResolvedLabel(order.fulfillmentLabel, systemImage: "shippingbox.fill")
            }
            .font(.caption)
            .foregroundStyle(Theme.textMuted)

            HStack(spacing: 8) {
                statusButton("Accept", .accepted, tint: Theme.primaryBlue)
                statusButton("Complete", .completed, tint: .green)
                statusButton("Cancel", .canceled, tint: .red.opacity(0.8))
            }
            .font(.caption.weight(.semibold))
        }
        .storeCard()
    }

    private var buyerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            OneWayResolvedLabel("Buyer info", systemImage: "person.crop.circle.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(order.displayName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            if !order.customerEmail.isEmpty {
                OneWayResolvedLabel(order.customerEmail, systemImage: "envelope.fill")
            }
            if !order.customerPhone.isEmpty {
                OneWayResolvedLabel(order.customerPhone, systemImage: "message.fill")
            }
            if !order.note.isEmpty {
                Text(order.note)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)
            }
            Text("Created \(shortDate(order.createdAt)) • Updated \(shortDate(order.updatedAt))")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .storeCard()
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            OneWayResolvedLabel("Status timeline", systemImage: "clock.arrow.circlepath")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            let timeline = order.statusTimeline.isEmpty
                ? [SiteStoreStatusEvent(status: order.status.rawValue, at: order.updatedAt)]
                : order.statusTimeline
            ForEach(timeline) { event in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.accentGold)
                        .frame(width: 7, height: 7)
                    Text(statusLabel(event.status))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(shortDate(event.at))
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .storeCard()
    }

    private var replyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            OneWayResolvedLabel("Reply to customer", systemImage: "arrowshape.turn.up.left.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            if !emailDeliveryConfigured {
                Text(emailStatusText)
                    .font(.caption)
                    .foregroundStyle(Theme.accentGold)
            } else {
                Text(order.customerEmail.isEmpty ? "Add a buyer email before replying." : "Email ready")
                    .font(.caption)
                    .foregroundStyle(order.customerEmail.isEmpty ? .red.opacity(0.9) : .green)
            }

            TextEditor(text: $replyText)
                .frame(minHeight: 130)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.textPrimary)
                .padding(10)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.divider, lineWidth: 1))

            Button {
                Task { await sendReply() }
            } label: {
                OneWayResolvedLabel("Send reply", systemImage: "paperplane.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || order.customerEmail.isEmpty)

            if !order.sellerReply.isEmpty {
                Text("Last reply: \(order.sellerReply)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .storeCard()
    }

    private var threadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            OneWayResolvedLabel("Message thread", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                if order.emailMessages.isEmpty {
                    threadBubble(
                        title: order.displayName,
                        subtitle: "Original request • \(shortDate(order.createdAt))",
                        body: order.message,
                        outbound: false,
                        status: "received"
                    )
                    Text("Replies will appear here once the conversation starts.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(order.emailMessages) { message in
                        threadBubble(
                            title: message.isOutbound ? "You" : order.displayName,
                            subtitle: "\(messageStatusLabel(message.status)) • \(shortDate(message.createdAt))",
                            body: message.bodyText,
                            outbound: message.isOutbound,
                            status: message.status
                        )
                    }
                }
            }
        }
        .storeCard()
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLoading {
                ProgressView().tint(Theme.accentGold)
            }
            if let infoMessage {
                Text(infoMessage).font(.footnote).foregroundStyle(Theme.accentGold)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red.opacity(0.9))
            }
        }
    }

    private func threadBubble(title: String, subtitle: String, body: String, outbound: Bool, status: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(messageStatusLabel(status))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(status == "failed" ? .red.opacity(0.9) : Theme.textMuted)
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
            Text(body)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(outbound ? Theme.accentGold.opacity(0.14) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    private func statusButton(_ title: String, _ status: SiteStoreOrderRequestStatus, tint: Color) -> some View {
        Button(title) {
            Task { await updateStatus(status) }
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(order.status == status)
    }

    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await service.order(domainSlug: domainSlug, orderId: order.id)
            order = detail.order
            emailDeliveryConfigured = detail.emailDeliveryConfigured
            onUpdated(detail.order)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load order request: \(error.localizedDescription)"
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
            errorMessage = "Couldn't update order request: \(error.localizedDescription)"
        }
    }

    private func sendReply() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.replyToOrder(
                domainSlug: domainSlug,
                orderId: order.id,
                message: replyText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            order = result.order
            emailDeliveryConfigured = result.emailDeliveryConfigured
            onUpdated(result.order)
            infoMessage = result.message ?? "Reply saved and sent."
            replyText = ""
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't send reply: \(error.localizedDescription)"
        }
    }

    private static func defaultReply(for order: SiteStoreOrderRequest) -> String {
        let greeting = order.displayName == "Customer" ? "Hi," : "Hi \(order.displayName),"
        let product = order.productName.isEmpty ? "your request" : order.productName
        return "\(greeting)\n\nThanks for your order request for \(product). "
    }

    private func statusLabel(_ value: String) -> String {
        SiteStoreOrderRequestStatus(rawValue: value)?.label ?? value
    }

    private var emailStatusText: String {
        if order.customerEmail.isEmpty { return "Buyer email missing. Ask for an email before replying." }
        if order.replyStatus == "stubbed" { return "Stubbed in dev" }
        if order.replyStatus == "failed" { return "Email not configured" }
        return "Email not configured yet. OneWay will save a failed delivery record until SendGrid is ready."
    }

    private func messageStatusLabel(_ value: String) -> String {
        switch value {
        case "queued": return "Queued"
        case "sent": return "Sent"
        case "failed": return "Failed"
        case "stubbed": return "Stubbed"
        case "received": return "Received"
        default: return value.isEmpty ? "Saved" : value.capitalized
        }
    }

    private func shortDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            return value.isEmpty ? "Just now" : value
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct SiteStoreInquiryReplyView: View {
    @Environment(\.dismiss) private var dismiss
    let inquiry: SiteStoreInquiry
    let onSend: (String) -> Void
    @State private var message: String

    init(inquiry: SiteStoreInquiry, onSend: @escaping (String) -> Void) {
        self.inquiry = inquiry
        self.onSend = onSend
        let greeting = inquiry.displayName == "Store visitor" ? "Hi," : "Hi \(inquiry.displayName),"
        let productLine = inquiry.productName.isEmpty ? "" : "\n\nThanks for asking about \(inquiry.productName)."
        _message = State(initialValue: "\(greeting)\(productLine)\n\n")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Reply to \(inquiry.displayName)")
                                .font(.title2.weight(.heavy))
                                .foregroundStyle(Theme.textPrimary)
                            Text(inquiry.message)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .storeCard()

                        VStack(alignment: .leading, spacing: 10) {
                            OneWayResolvedLabel("Your reply", systemImage: "arrowshape.turn.up.left.fill")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            TextEditor(text: $message)
                                .frame(minHeight: 180)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(Theme.textPrimary)
                                .padding(10)
                                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.divider, lineWidth: 1))
                            Text(replyDestinationText)
                                .font(.caption)
                                .foregroundStyle(inquiry.customerEmail.isEmpty ? .red.opacity(0.9) : Theme.textSecondary)
                        }
                        .storeCard()
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Seller reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSend(message.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inquiry.customerEmail.isEmpty)
                }
            }
        }
    }

    private var replyDestinationText: String {
        if !inquiry.customerEmail.isEmpty {
            return "OneWay will send this to \(inquiry.customerEmail) and keep a copy here."
        }
        if !inquiry.customerPhone.isEmpty {
            return "No email was provided. Add a buyer email before replying from OneWay."
        }
        return "Add a buyer email before replying from OneWay."
    }
}

private struct SiteStoreProductEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var product: SiteStoreProduct
    @State private var priceText: String
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var isUploadingImage = false
    @State private var imageUploadError: String?
    @State private var showMoreOptions = false

    let domainSlug: String
    let imageUploader: SiteStoreService
    let onSave: (SiteStoreProduct) -> Void

    init(
        product: SiteStoreProduct,
        domainSlug: String,
        imageUploader: SiteStoreService = NetworkSiteStoreService(),
        onSave: @escaping (SiteStoreProduct) -> Void
    ) {
        _product = State(initialValue: product)
        _priceText = State(initialValue: product.priceCents == 0 ? "" : String(format: "%.2f", Double(product.priceCents) / 100))
        self.domainSlug = domainSlug
        self.imageUploader = imageUploader
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Add your first product")
                                .font(.system(size: 30, weight: .heavy))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Keep it light. A photo, name, price, and one sentence is enough to launch.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        productLivePreview

                        PhotosPicker(selection: $selectedImageItem, matching: .images) {
                            OneWayResolvedLabel(isUploadingImage ? "Uploading photo..." : "Product photo", systemImage: "photo.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .disabled(isUploadingImage)

                        field("Product name, like Ceramic Mug", text: $product.name)
                        field("Price, like 24", text: $priceText)
                            .keyboardType(.decimalPad)
                        field("Short description", text: $product.description, lineLimit: 3...5)

                        Button {
                            generateSampleProduct()
                        } label: {
                            OneWayResolvedLabel("Generate sample product", systemImage: "wand.and.stars")
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.08), in: Capsule())
                                .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accentGold)

                        DisclosureGroup(isExpanded: $showMoreOptions) {
                            VStack(alignment: .leading, spacing: 12) {
                                field("Image URL", text: $product.imageUrl)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                Toggle("Available to buy", isOn: Binding {
                                    product.inventoryStatus == .inStock
                                } set: { isAvailable in
                                    product.inventoryStatus = isAvailable ? .inStock : .soldOut
                                })
                                .foregroundStyle(Theme.textPrimary)

                                Text("OneWay converts uploads to web-friendly JPEGs. Image URLs are optional.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.top, 10)
                        } label: {
                            Text("More options")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        if let imageUploadError {
                            Text(imageUploadError)
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.9))
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(product.name.isEmpty ? "Add product" : "Edit product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        product.priceCents = parsePriceCents(priceText)
                        onSave(product)
                    }
                    .disabled(product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: selectedImageItem) { _, item in
                Task { await uploadSelectedImage(item) }
            }
        }
    }

    private var productLivePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live preview")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accentGold)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 96, height: 96)
                    .overlay {
                        if let url = URL(string: product.imageUrl), !product.imageUrl.isEmpty {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                OneWayResolvedIcon(systemName: "photo")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        } else {
                            OneWayResolvedIcon(systemName: "bag.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(product.name.isEmpty ? "Product name" : product.name)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text(product.description.isEmpty ? "A short description helps buyers say yes." : product.description)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Text(previewPrice)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.accentGold)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    private var previewPrice: String {
        let cents = parsePriceCents(priceText)
        guard cents > 0 else { return "$0.00" }
        let amount = Decimal(cents) / Decimal(100)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$\(cents / 100)"
    }

    private func generateSampleProduct() {
        product.name = product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Signature Item"
            : product.name
        product.description = "A customer-ready favorite with simple details, clear value, and easy ordering."
        priceText = priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "24" : priceText
        product.inventoryStatus = .inStock
    }

    private func field(_ placeholder: String, text: Binding<String>, lineLimit: ClosedRange<Int> = 1...1) -> some View {
        TextField(placeholder, text: text, axis: lineLimit.upperBound > 1 ? .vertical : .horizontal)
            .lineLimit(lineLimit)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    private func parsePriceCents(_ value: String) -> Int {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = Decimal(string: cleaned) ?? 0
        return max(0, NSDecimalNumber(decimal: amount * Decimal(100)).intValue)
    }

    private func uploadSelectedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isUploadingImage = true
        imageUploadError = nil
        defer {
            isUploadingImage = false
            selectedImageItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.82) else {
                imageUploadError = "That image could not be prepared for upload."
                return
            }
            let asset = try await imageUploader.uploadProductImage(
                domainSlug: domainSlug,
                fileName: "product-\(UUID().uuidString).jpg",
                mimeType: "image/jpeg",
                data: jpeg
            )
            product.imageUrl = asset.url
        } catch {
            imageUploadError = "Image upload failed: \(error.localizedDescription)"
        }
    }
}

private struct SiteStorePreviewView: View {
    let store: SiteStore?

    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store?.storeName.isEmpty == false ? store?.storeName ?? "" : "My Store")
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(Theme.textPrimary)
                        Text(store?.storeDescription.isEmpty == false ? store?.storeDescription ?? "" : "Your simple OneWay storefront preview.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)

                        fulfillmentChips
                    }

                    let products = store?.products.filter { $0.inventoryStatus != .hidden } ?? []
                    if products.isEmpty {
                        Text("Add products to preview the public store.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                            .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(products) { product in
                                productPreview(product)
                            }
                        }
                    }

                    contactPreview
                }
                .padding(20)
            }
        }
    }

    private var fulfillmentChips: some View {
        let chips = [
            store?.pickupEnabled == true ? "Local pickup" : nil,
            store?.shippingEnabled == true ? "Shipping available" : nil,
            store?.marketplaceListed == true ? "Listed in OneWay" : nil
        ].compactMap { $0 }

        return HStack {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var contactPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How customers buy")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            if let email = store?.contactEmail, !email.isEmpty {
                OneWayResolvedLabel(email, systemImage: "envelope.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let phone = store?.contactPhone, !phone.isEmpty {
                OneWayResolvedLabel(phone, systemImage: "message.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let note = store?.fulfillmentNote, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }

    private func productPreview(_ product: SiteStoreProduct) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    if let url = URL(string: product.imageUrl), !product.imageUrl.isEmpty {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            OneWayResolvedIcon(systemName: "photo")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        OneWayResolvedIcon(systemName: "photo")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(product.name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Text(product.formattedPrice)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accentGold)
            Text(product.inventoryStatus == .soldOut ? "Sold out" : (store?.checkoutMode.label ?? "Contact to buy"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }
}

private extension View {
    func storeCard() -> some View {
        self
            .padding(16)
            .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }
}
