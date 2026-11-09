import Foundation
import Combine
import SwiftUI

@MainActor
final class BusinessViewModel: ObservableObject {
    enum ShopManagementState {
        case noStorefront
        case draft
        case published
    }

    enum SearchState {
        case idle
        case typing
        case loading
        case results
        case empty
        case error(String)
    }

    enum Mode {
        case idle
        case generating
        case editing
    }

    enum StorefrontSaveState: Equatable {
        case idle
        case saving
        case saved
        case offlineDraft
        case syncFailedRetry

        var title: String {
            switch self {
            case .idle:
                return ""
            case .saving:
                return "Saving..."
            case .saved:
                return "Saved"
            case .offlineDraft:
                return "Offline draft"
            case .syncFailedRetry:
                return "Sync failed - retry"
            }
        }
    }

    enum LayoutOption: String, CaseIterable {
        case grid, list, hero
    }

    struct BuilderProductInput: Identifiable, Equatable {
        let id: UUID
        var name: String
        var price: String
        var description: String
        var imageData: Data?
        var imageName: String?
    }

    struct BuilderState {
        var storeName: String = ""
        var tagline: String = ""
        var category: String = ""
        var preferredColors: String = ""
        var layout: LayoutOption = .grid
        var products: [BuilderProductInput] = []
        var extraPages: [String] = []
        var wantsCheckout: Bool = true
    }

    @Published private(set) var storefronts: [Storefront] = []
    @Published private(set) var marketplaceStorefronts: [Storefront] = []
    @Published private(set) var storefront: Storefront?
    @Published private(set) var publishedStorefront: Storefront?
    @Published private(set) var draft: StorefrontDraft?
    @Published var selectedStorefrontID: UUID?
    @Published private(set) var mode: Mode = .idle
    @Published var prompt: String = ""
    @Published var errorMessage: String?
    @Published var lastBackendError: String = ""
    @Published var aiHistory: [AIStoreEditSuggestion] = []
    @Published var isAIHelping = false
    @Published private(set) var storefrontSaveState: StorefrontSaveState = .idle
    @Published private(set) var handleAvailability = StorefrontHandleAvailability(handle: "", status: .idle, message: "")
    // Debug telemetry
    @Published var lastAIEndpoint: String = ""
    @Published var lastAIMethod: String = ""
    @Published var lastAIBody: String = ""
    @Published var lastAIError: String = ""

    // Search
    @Published var searchQuery: String = ""
    @Published private(set) var searchResults: [SearchResult] = []
    @Published var searchState: SearchState = .idle

    // Builder state
    @Published var builder: BuilderState = BuilderState()

    private let businessService: BusinessService
    private let aiStorefrontService: AIStorefrontService
    private let searchService: BusinessSearchService
    private var latestHandleAvailabilityToken = 0

    init(businessService: BusinessService, aiStorefrontService: AIStorefrontService, searchService: BusinessSearchService) {
        self.businessService = businessService
        self.aiStorefrontService = aiStorefrontService
        self.searchService = searchService
    }

    var shopManagementState: ShopManagementState {
        if let store = storefront {
            return store.isPublished ? .published : .draft
        }
        return .noStorefront
    }

    var publishChecklist: [String] {
        guard let storefront else { return [] }
        return WebsiteQualityStandard.validateStorefront(storefront).missingItems
    }

    var canPreviewDraft: Bool {
        storefront != nil
    }

    func load() async {
        do {
            storefronts = try await businessService.listStorefronts()
            marketplaceStorefronts = (try? await businessService.listMarketplaceStorefronts()) ?? []
            if let selectedID = selectedStorefrontID, let match = storefronts.first(where: { $0.id == selectedID }) {
                applySelection(match)
            } else if let first = storefronts.first {
                applySelection(first)
            } else {
                storefront = nil
                draft = nil
                publishedStorefront = nil
                mode = .idle
            }
            errorMessage = nil
        } catch {
            lastBackendError = error.localizedDescription
            errorMessage = storefrontFriendlyError(error)
        }
    }

    func generate() async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        mode = .generating
        do {
            // If the user already has a storefront selected, treat most prompts as
            // targeted improvements instead of creating a brand new storefront.
            if let current = storefront, !wantsNewStore(from: trimmedPrompt) {
#if DEBUG
                lastAIEndpoint = "/api/ai/storefronts/\(current.id.uuidString)/improve"
                lastAIMethod = "POST"
                lastAIBody = "{\"prompt\":\(String(reflecting: trimmedPrompt))}"
#endif
                let result = try await aiStorefrontService.improve(storefrontID: current.id, prompt: trimmedPrompt)
                applySelection(result.storefront)
                try await reloadStorefrontsMaintainingSelection()
                aiHistory.insert(
                    AIStoreEditSuggestion(
                        id: UUID(),
                        title: "Updated storefront",
                        description: "Based on prompt: \(trimmedPrompt)",
                        suggestedAt: Date(),
                        affectedSectionIDs: [],
                        action: .rewriteCopy,
                        applied: false
                    ),
                    at: 0
                )
                errorMessage = nil
                mode = .editing
                return
            }

            let request = AIStorefrontRequest(
                prompt: trimmedPrompt,
                businessName: inferredName(from: trimmedPrompt),
                category: inferredCategory(from: trimmedPrompt),
                tone: "Friendly",
                goals: ["Launch quickly", "Showcase products"],
                preferredColors: ["#4F46E5", "#22D3EE"],
                includeSections: StorefrontSectionType.allCases
            )
#if DEBUG
            lastAIEndpoint = "/api/ai/storefronts/generate"
            lastAIMethod = "POST"
            if let data = try? JSONEncoder().encode(request),
               let json = String(data: data, encoding: .utf8) {
                lastAIBody = json
            }
#endif
            let result = try await aiStorefrontService.generate(from: request)
            let generated = result.storefront
            applySelection(generated)
            try await reloadStorefrontsMaintainingSelection()
            aiHistory.insert(
                AIStoreEditSuggestion(
                    id: UUID(),
                    title: "Generated storefront",
                    description: "Based on prompt: \(trimmedPrompt)",
                    suggestedAt: Date(),
                    affectedSectionIDs: [],
                    action: .generateStorefront,
                    applied: false
                ),
                at: 0
            )
            try await persistDraft()
            errorMessage = nil
            mode = .editing
        } catch {
            mode = .idle
            errorMessage = error.localizedDescription
#if DEBUG
            print("[AI Generate Error] \(PrivacyLog.redact(error.localizedDescription))")
            let ns = error as NSError
            lastAIError = "\(PrivacyLog.redact(ns.domain))(\(ns.code)): \(PrivacyLog.redact(ns.localizedDescription))"
#endif
        }
    }

    func generateFromBuilder() async {
        mode = .generating
        let name = builder.storeName.isEmpty ? "My Store" : builder.storeName
        let category = builder.category.isEmpty ? "General" : builder.category
        let colors = builder.preferredColors.isEmpty ? ["#111827", "#2563EB"] : builder.preferredColors
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        do {
            let prompt = [
                "Build a storefront for \(name).",
                builder.tagline.isEmpty ? nil : "Tagline: \(builder.tagline).",
                builder.category.isEmpty ? nil : "Category: \(category)."
            ].compactMap { $0 }.joined(separator: " ")
            let request = AIStorefrontRequest(
                prompt: prompt,
                businessName: name,
                category: category,
                tone: "Friendly",
                goals: ["Launch quickly", "Showcase products", builder.wantsCheckout ? "Enable checkout" : "Catalog only"],
                preferredColors: colors,
                includeSections: StorefrontSectionType.allCases
            )
            let result = try await aiStorefrontService.generate(from: request)

            // Apply builder specifics onto generated record
            var tailored = result.storefront
            tailored.business.name = name
            tailored.business.tagline = builder.tagline.isEmpty ? tailored.business.tagline : builder.tagline
            tailored.business.category = category
            tailored.theme.primaryColorHex = colors.first ?? tailored.theme.primaryColorHex
            tailored.theme.accentColorHex = colors.count > 1 ? colors[1] : tailored.theme.accentColorHex

            if !builder.products.isEmpty {
                let converted = builder.products.map {
                    ProductOrService(
                        name: $0.name,
                        description: $0.description,
                        price: $0.price,
                        isSubscription: false,
                        mediaURL: nil
                    )
                }
                if let idx = tailored.sections.firstIndex(where: { $0.type == .products }) {
                    tailored.sections[idx].items = converted
                } else {
                    tailored.sections.append(StorefrontSection(type: .products, title: "Products", body: nil, items: converted, mediaURLs: []))
                }
                tailored.business.products = converted
            }

            draft = StorefrontDraft(id: tailored.id, storefront: tailored, lastEditedAt: Date())
            storefront = tailored
            applySelection(tailored)
            try await reloadStorefrontsMaintainingSelection()
            aiHistory.insert(
                AIStoreEditSuggestion(
                    id: UUID(),
                    title: "AI-built storefront",
                    description: "Configured from your inputs.",
                    suggestedAt: Date(),
                    affectedSectionIDs: [],
                    action: .generateStorefront,
                    applied: false
                ),
                at: 0
            )
            try await persistDraft()
            errorMessage = nil
            mode = .editing
        } catch {
            mode = .idle
            errorMessage = error.localizedDescription
        }
    }

    func applyDraft() async {
        guard let draft else { return }
        do {
            storefront = try await businessService.save(storefront: draft.storefront)
            try await reloadStorefrontsMaintainingSelection()
            markLatestSuggestionApplied()
            mode = .editing
        } catch {
            errorMessage = "Failed to apply draft."
        }
    }

    func togglePublish() async {
        guard let storefront else { return }
        do {
            storefrontSaveState = .saving
            let updated = try await businessService.publish(storefrontID: storefront.id, isPublished: !storefront.isPublished)
            self.storefront = updated
            publishedStorefront = updated.isPublished ? updated : nil
            try await reloadStorefrontsMaintainingSelection()
            try? await refreshMarketplace()
            storefrontSaveState = .saved
            errorMessage = nil
        } catch {
            lastBackendError = error.localizedDescription
            storefrontSaveState = .syncFailedRetry
            errorMessage = storefront.isPublished
                ? storefrontFriendlyError(error)
                : publishErrorMessage(error)
        }
    }

    func togglePublish(store: Storefront) async {
        do {
            storefrontSaveState = .saving
            _ = try await businessService.publish(storefrontID: store.id, isPublished: !store.isPublished)
            try await reloadStorefrontsMaintainingSelection()
            try? await refreshMarketplace()
            storefrontSaveState = .saved
            errorMessage = nil
        } catch {
            lastBackendError = error.localizedDescription
            storefrontSaveState = .syncFailedRetry
            errorMessage = publishErrorMessage(error)
        }
    }

    func regenerate(section: StorefrontSectionType) async {
        guard var storefront else { return }
        do {
            let updated = try await aiStorefrontService.regenerateSection(storefront: storefront, section: section)
            if let idx = storefront.sections.firstIndex(where: { $0.type == section }) {
                storefront.sections[idx] = updated
            } else {
                storefront.sections.append(updated)
            }
            self.storefront = storefront
            try await persistStorefront()
        } catch {
            errorMessage = "Unable to regenerate section."
        }
    }

    func updateTheme(primary: String, accent: String) {
        guard var storefront else { return }
        storefront.theme.primaryColorHex = primary
        storefront.theme.accentColorHex = accent
        self.storefront = storefront
    }

    func moveSection(from offsets: IndexSet, to index: Int) {
        guard var storefront else { return }
        storefront.sections.move(fromOffsets: offsets, toOffset: index)
        self.storefront = storefront
    }

    func search(mode: BusinessSearchMode) async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            searchState = .idle
            return
        }
        searchState = .loading
        do {
            let results = try await searchService.search(query: trimmed, mode: mode)
            searchResults = results
            searchState = results.isEmpty ? .empty : .results
        } catch {
            searchState = .error("Search failed")
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        searchState = .idle
    }

    func regenerateSection(section: StorefrontSectionType) async {
        guard var draft else { return }
        do {
            let regenerated = try await aiStorefrontService.regenerateSection(storefront: draft.storefront, section: section)
            if let idx = draft.storefront.sections.firstIndex(where: { $0.type == section }) {
                draft.storefront.sections[idx] = regenerated
            } else {
                draft.storefront.sections.append(regenerated)
            }
            draft.lastEditedAt = Date()
            self.draft = draft
            aiHistory.insert(
                AIStoreEditSuggestion(
                    id: UUID(),
                    title: "Regenerated \(section.rawValue)",
                    description: "Applied AI changes to \(section.rawValue)",
                    suggestedAt: Date(),
                    affectedSectionIDs: [],
                    action: .regenerateSection,
                    applied: false
                ),
                at: 0
            )
        } catch {
            errorMessage = "Unable to regenerate section."
        }
    }

    private func persistDraft() async throws {
        guard let draft else { return }
        _ = try await businessService.save(storefront: draft.storefront)
        try await reloadStorefrontsMaintainingSelection()
    }

    private func persistStorefront() async throws {
        guard let storefront else { return }
        _ = try await businessService.save(storefront: storefront)
        try await reloadStorefrontsMaintainingSelection()
    }

    private func markLatestSuggestionApplied() {
        guard !aiHistory.isEmpty else { return }
        let first = aiHistory[0]
        aiHistory.remove(at: 0)
        aiHistory.insert(
            AIStoreEditSuggestion(
                id: first.id,
                title: first.title,
                description: first.description,
                suggestedAt: first.suggestedAt,
                affectedSectionIDs: first.affectedSectionIDs,
                action: first.action,
                applied: true
            ),
            at: 0
        )
    }

    private func inferredCategory(from prompt: String) -> String {
        let lowered = prompt.lowercased()
        if lowered.contains("pet") || lowered.contains("dog") { return "Pets" }
        if lowered.contains("coffee") { return "Food & Drink" }
        if lowered.contains("beauty") { return "Beauty" }
        if lowered.contains("tech") || lowered.contains("gadget") { return "Electronics" }
        if lowered.contains("fashion") || lowered.contains("apparel") { return "Apparel" }
        return "General"
    }

    private func inferredName(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "My Business" }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private func wantsNewStore(from prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        if lowered.contains("create") && lowered.contains("store") { return true }
        if lowered.contains("build") && lowered.contains("store") { return true }
        if lowered.contains("new storefront") { return true }
        return false
    }

    // MARK: - Builder helpers

    func addProductInput() {
        builder.products.append(
            BuilderProductInput(id: UUID(), name: "New product", price: "$0.00", description: "Description", imageData: nil, imageName: nil)
        )
    }

    func removeProductInput(_ id: UUID) {
        builder.products.removeAll { $0.id == id }
    }

    func selectStorefront(_ store: Storefront) {
        applySelection(store)
    }

    func deleteStorefront(_ id: UUID) async {
        do {
            try await businessService.delete(storefrontID: id)
            storefronts.removeAll { $0.id == id }
            if let first = storefronts.first {
                applySelection(first)
            } else {
                storefront = nil
                draft = nil
                publishedStorefront = nil
                selectedStorefrontID = nil
                mode = .idle
            }
            try? await refreshMarketplace()
        } catch {
            errorMessage = "Unable to delete storefront."
        }
    }

    func createStorefront(name: String, category: String, tagline: String?) async {
        do {
            let created = try await businessService.createStorefront(name: name, category: category, tagline: tagline)
            applySelection(created)
            try await reloadStorefrontsMaintainingSelection()
            try? await refreshMarketplace()
        } catch {
            lastBackendError = error.localizedDescription
            errorMessage = storefrontFriendlyError(error)
        }
    }

    func startShopSetup() async {
        if storefront != nil { return }
        do {
            var setupDraft = try await businessService.createStorefront(name: "My Shop", category: "General", tagline: "")
            setupDraft.business.name = ""
            setupDraft.business.handle = ""
            setupDraft.business.category = ""
            setupDraft.business.tagline = ""
            setupDraft.business.description = ""
            setupDraft.business.logoURL = nil
            setupDraft.business.coverImageURL = nil
            setupDraft.business.announcement = nil
            setupDraft.business.sellerStory = nil
            setupDraft.business.contactEmail = nil
            setupDraft.business.phone = nil
            setupDraft.business.website = nil
            setupDraft.business.address = nil
            setupDraft.business.hours = nil
            setupDraft.business.pickupEnabled = true
            setupDraft.business.localDeliveryEnabled = false
            setupDraft.business.shippingEnabled = true
            setupDraft.business.digitalDeliveryEnabled = false
            setupDraft.business.pickupInstructions = nil
            setupDraft.business.shippingNote = nil
            setupDraft.business.deliveryAreaNote = nil
            setupDraft.business.products = []
            setupDraft.sections = []
            setupDraft.slug = ""
            setupDraft.shopURL = nil
            setupDraft.paymentStatus = "pending"
            setupDraft.paymentsReady = false
            setupDraft.paymentsEnabled = false
            setupDraft.stripeConnectStatus = "not_started"
            setupDraft.defaultPaymentMode = "contact"
            setupDraft.defaultPaymentLinkURL = nil
            setupDraft.policiesReady = false
            setupDraft.setupComplete = false
            setupDraft.publishChecklist = [
                "Add a shop name",
                "Add a product",
                "Add a contact method",
                "Choose fulfillment details"
            ]
            setupDraft.policy = .default
            setupDraft.isPublished = false
            setupDraft.publishedState = .draft
            applySelection(setupDraft)
            if let index = storefronts.firstIndex(where: { $0.id == setupDraft.id }) {
                storefronts[index] = setupDraft
            } else {
                storefronts.insert(setupDraft, at: 0)
            }
            storefrontSaveState = .idle
            errorMessage = nil
        } catch {
            lastBackendError = error.localizedDescription
            errorMessage = storefrontFriendlyError(error)
        }
    }

    func saveCurrentStorefront(_ updated: Storefront) async {
        do {
            storefrontSaveState = .saving
            let saved = try await businessService.save(storefront: updated)
            storefront = saved
            draft = StorefrontDraft(id: saved.id, storefront: saved, lastEditedAt: Date())
            try await reloadStorefrontsMaintainingSelection()
            storefrontSaveState = .saved
            errorMessage = nil
        } catch {
            lastBackendError = error.localizedDescription
            storefrontSaveState = isNetworkUnavailable(error) ? .offlineDraft : .syncFailedRetry
            errorMessage = saveErrorMessage(for: updated, error: error)
        }
    }

    @discardableResult
    func createListing(_ product: ProductOrService) async -> ProductOrService? {
        guard let storefront else { return nil }
        do {
            storefrontSaveState = .saving
            let saved = try await businessService.createListing(storefrontID: storefront.id, product: product)
            try await reloadStorefrontsMaintainingSelection()
            storefrontSaveState = .saved
            errorMessage = nil
            return saved
        } catch {
            lastBackendError = error.localizedDescription
            storefrontSaveState = isNetworkUnavailable(error) ? .offlineDraft : .syncFailedRetry
            errorMessage = storefrontFriendlyError(error)
            return nil
        }
    }

    @discardableResult
    func updateListing(_ product: ProductOrService) async -> ProductOrService? {
        guard let storefront else { return nil }
        do {
            storefrontSaveState = .saving
            let saved = try await businessService.updateListing(storefrontID: storefront.id, product: product)
            try await reloadStorefrontsMaintainingSelection()
            storefrontSaveState = .saved
            errorMessage = nil
            return saved
        } catch {
            lastBackendError = error.localizedDescription
            storefrontSaveState = isNetworkUnavailable(error) ? .offlineDraft : .syncFailedRetry
            errorMessage = storefrontFriendlyError(error)
            return nil
        }
    }

    func deleteListing(_ product: ProductOrService) async {
        guard let storefront else { return }
        do {
            storefrontSaveState = .saving
            try await businessService.deleteListing(storefrontID: storefront.id, productID: product.id)
            try await reloadStorefrontsMaintainingSelection()
            storefrontSaveState = .saved
            errorMessage = nil
        } catch {
            lastBackendError = error.localizedDescription
            storefrontSaveState = isNetworkUnavailable(error) ? .offlineDraft : .syncFailedRetry
            errorMessage = storefrontFriendlyError(error)
        }
    }

    func loadPolicies() async -> StorePolicyDraft {
        guard let storefront else { return .default }
        do {
            return try await businessService.fetchPolicies(storefrontID: storefront.id)
        } catch {
            errorMessage = "Unable to load store policies."
            return .default
        }
    }

    func savePolicies(_ policy: StorePolicyDraft) async {
        guard let storefront else { return }
        do {
            storefrontSaveState = .saving
            _ = try await businessService.savePolicies(storefrontID: storefront.id, policy: policy)
            var updated = storefront
            updated.policy = policy
            updated.policiesReady = true
            await saveCurrentStorefront(updated)
        } catch {
            lastBackendError = error.localizedDescription
            storefrontSaveState = isNetworkUnavailable(error) ? .offlineDraft : .syncFailedRetry
            errorMessage = storefrontFriendlyError(error)
        }
    }

    func publishCurrentStorefront() async {
        await togglePublish()
    }

    func uploadStorefrontImage(data: Data, fileName: String, mimeType: String) async throws -> URL {
        do {
            return try await businessService.uploadStorefrontImage(data: data, fileName: fileName, mimeType: mimeType)
        } catch {
            lastBackendError = error.localizedDescription
            storefrontSaveState = isNetworkUnavailable(error) ? .offlineDraft : .syncFailedRetry
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func uploadProductImage(productID: UUID, data: Data, fileName: String, mimeType: String) async throws -> ProductOrService {
        do {
            storefrontSaveState = .saving
            let saved = try await businessService.uploadProductImage(productID: productID, data: data, fileName: fileName, mimeType: mimeType)
            try await reloadStorefrontsMaintainingSelection()
            storefrontSaveState = .saved
            errorMessage = nil
            return saved
        } catch {
            lastBackendError = error.localizedDescription
            storefrontSaveState = isNetworkUnavailable(error) ? .offlineDraft : .syncFailedRetry
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func checkHandleAvailability(_ handle: String, excluding storefrontID: UUID?) async {
        let sanitized = normalizeHandle(handle)
        latestHandleAvailabilityToken += 1
        let requestToken = latestHandleAvailabilityToken
        guard !sanitized.isEmpty else {
            handleAvailability = StorefrontHandleAvailability(handle: "", status: .idle, message: "")
            return
        }
        guard isValidHandle(sanitized) else {
            handleAvailability = StorefrontHandleAvailability(
                handle: sanitized,
                status: .invalid,
                message: "Use lowercase letters, numbers, and hyphens."
            )
            return
        }

        handleAvailability = StorefrontHandleAvailability(handle: sanitized, status: .checking, message: "Checking...")
        do {
            let availability = try await businessService.checkStorefrontHandleAvailability(
                handle: sanitized,
                excluding: storefrontID
            )
            guard requestToken == latestHandleAvailabilityToken else {
#if DEBUG
                print("[storefront setup] handle-check-discarded reason=stale-token requested=\(PrivacyLog.redact(sanitized))")
#endif
                return
            }
            let resultHandle = normalizeHandle(availability.handle)
            guard resultHandle == sanitized else {
#if DEBUG
                print("[storefront setup] handle-check-discarded reason=stale-response requested=\(PrivacyLog.redact(sanitized)) returned=\(PrivacyLog.redact(resultHandle))")
#endif
                return
            }
            handleAvailability = StorefrontHandleAvailability(
                handle: resultHandle,
                status: availability.status,
                message: availability.message
            )
        } catch {
            guard requestToken == latestHandleAvailabilityToken else {
#if DEBUG
                print("[storefront setup] handle-check-discarded reason=stale-error requested=\(PrivacyLog.redact(sanitized))")
#endif
                return
            }
            lastBackendError = error.localizedDescription
            handleAvailability = StorefrontHandleAvailability(
                handle: sanitized,
                status: .unknown,
                message: "We will check this again when OneWay is reachable."
            )
        }
    }

    func requestStorefrontHelp(
        type: StorefrontAIHelpType,
        storefront: Storefront?,
        productName: String = "",
        productDescription: String = ""
    ) async -> String {
        isAIHelping = true
        defer { isAIHelping = false }

        let context = StorefrontAIHelpContext(
            shopName: storefront?.business.name ?? "",
            category: storefront?.business.category ?? "",
            sellerStory: storefront?.business.sellerStory ?? "",
            shopDescription: storefront?.business.description ?? "",
            productName: productName,
            productDescription: productDescription
        )

        do {
            let text = try await aiStorefrontService.storefrontHelp(type: type, context: context)
            errorMessage = nil
            return text
        } catch {
            lastBackendError = error.localizedDescription
            return StorefrontAIFallback.text(for: type, context: context)
        }
    }

    private func applySelection(_ store: Storefront) {
        storefront = store
        selectedStorefrontID = store.id
        publishedStorefront = store.isPublished ? store : nil
        draft = StorefrontDraft(id: store.id, storefront: store, lastEditedAt: Date())
        mode = .editing
    }

    private func reloadStorefrontsMaintainingSelection() async throws {
        storefronts = try await businessService.listStorefronts()
        if let selectedID = selectedStorefrontID, let match = storefronts.first(where: { $0.id == selectedID }) {
            applySelection(match)
        } else if let first = storefronts.first {
            applySelection(first)
        }
    }

    private func refreshMarketplace() async throws {
        marketplaceStorefronts = try await businessService.listMarketplaceStorefronts()
    }

    private func saveValidationMessage(for store: Storefront) -> String? {
        if store.business.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Please add a shop name to keep going."
        }
        if store.business.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Please choose a category for your shop."
        }
        return nil
    }

    private func saveErrorMessage(for store: Storefront, error: Error) -> String {
        if saveValidationMessage(for: store) != nil {
            return saveValidationMessage(for: store) ?? "Please complete all required fields."
        }
        return storefrontFriendlyError(error)
    }

    private func publishErrorMessage(_ error: Error) -> String {
        storefrontFriendlyError(error)
    }

    private func storefrontFriendlyError(_ error: Error) -> String {
        let code = errorCode(from: error)
        switch code {
        case "duplicate_handle", "handle_taken":
            return "That shop link is already taken."
        case "validation_failed", "bad_request", "invalid_handle":
            return "Please complete all required fields."
        case "unauthorized", "unauthenticated", "profile_required":
            return "Please sign in again."
        case "backend_unavailable":
            return "We couldn't reach OneWay right now."
        default:
            if isNetworkUnavailable(error) {
                return "We couldn't reach OneWay right now."
            }
            return "Your draft was saved locally. Try again in a moment."
        }
    }

    private func errorCode(from error: Error) -> String {
        let ns = error as NSError
        if let code = ns.userInfo["code"] as? String {
            return code
        }
        if ns.code == 401 || ns.code == 403 {
            return "unauthorized"
        }
        if ns.code == 409 {
            return "duplicate_handle"
        }
        if ns.code == 400 || ns.code == 422 {
            return "validation_failed"
        }
        if (500...599).contains(ns.code) {
            return "backend_unavailable"
        }
        return "unknown"
    }

    private func isNetworkUnavailable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return true
            default:
                break
            }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("offline")
            || message.contains("timed out")
            || message.contains("could not connect")
            || message.contains("cannot find host")
            || message.contains("network connection")
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
}
