import Foundation
import Combine
import SwiftUI

@MainActor
final class BusinessViewModel: ObservableObject {
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
    @Published private(set) var storefront: Storefront?
    @Published private(set) var publishedStorefront: Storefront?
    @Published private(set) var draft: StorefrontDraft?
    @Published var selectedStorefrontID: UUID?
    @Published private(set) var mode: Mode = .idle
    @Published var prompt: String = ""
    @Published var currentHandleText: String = ""
    @Published var errorMessage: String?
    @Published var aiHistory: [AIStoreEditSuggestion] = []
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

    init(businessService: BusinessService, aiStorefrontService: AIStorefrontService, searchService: BusinessSearchService) {
        self.businessService = businessService
        self.aiStorefrontService = aiStorefrontService
        self.searchService = searchService
    }

    func load() async {
        do {
            storefronts = try await businessService.listStorefronts()
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
            #if DEBUG
            errorMessage = "Failed to load storefronts: \(error.localizedDescription)"
            #else
            errorMessage = "Server unreachable. Check API host and ensure backend is running."
            #endif
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
            print("[AI Generate Error] \(error)")
            let ns = error as NSError
            lastAIError = "\(ns.domain)(\(ns.code)): \(ns.localizedDescription)"
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
        await saveDraft(currentHandleText: nil)
    }

    func saveDraft(currentHandleText: String?) async {
        guard let draft else { return }
        do {
            var storefrontToSave = draft.storefront
            let rawCurrentHandleText = currentHandleText ?? self.currentHandleText
            let currentHandle = normalizedHandle(rawCurrentHandleText)
            let draftHandle = normalizedHandle(draft.storefront.slug)
            let backendHandle = normalizedHandle(storefront?.slug ?? "")
            let payloadHandle: String
            let sourceOfTruth: String

            if !currentHandle.isEmpty && currentHandle != draftHandle {
                payloadHandle = currentHandle
                sourceOfTruth = "currentHandleText"
            } else if !currentHandle.isEmpty {
                payloadHandle = currentHandle
                sourceOfTruth = "currentHandleText"
            } else if !draftHandle.isEmpty {
                payloadHandle = draftHandle
                sourceOfTruth = "draftHandle"
            } else {
                payloadHandle = backendHandle
                sourceOfTruth = "backendHandle"
            }

            if !payloadHandle.isEmpty {
                storefrontToSave.slug = payloadHandle
            }

#if DEBUG
            print("[StorefrontSetupSave] currentHandleText=\(rawCurrentHandleText.isEmpty ? "nil" : rawCurrentHandleText) draftHandle=\(draftHandle) payloadHandle=\(payloadHandle) backendHandle=\(backendHandle) selectedStoreName=\(storefrontToSave.business.name) sourceOfTruth=\(sourceOfTruth)")
#endif

            storefront = storefrontToSave
            self.draft = StorefrontDraft(id: storefrontToSave.id, storefront: storefrontToSave, lastEditedAt: Date())
            let saved = try await businessService.save(storefront: storefrontToSave)
            applySelection(saved)
            try await reloadStorefrontsMaintainingSelection()
            markLatestSuggestionApplied()
            mode = .editing
#if DEBUG
            print("[StorefrontSetupSave] resultHandle=\(saved.slug) preview=https://oneway.is/shop/\(saved.slug)")
#endif
        } catch {
            errorMessage = "Failed to apply draft."
        }
    }

    func togglePublish() async {
        guard let storefront else { return }
        do {
            try await businessService.publish(storefrontID: storefront.id, isPublished: !storefront.isPublished)
            var updated = storefront
            updated.isPublished.toggle()
            self.storefront = updated
            if updated.isPublished {
                publishedStorefront = updated
            } else {
                publishedStorefront = nil
            }
            try await reloadStorefrontsMaintainingSelection()
        } catch {
            errorMessage = "Failed to update publish state."
        }
    }

    func togglePublish(store: Storefront) async {
        do {
            try await businessService.publish(storefrontID: store.id, isPublished: !store.isPublished)
            try await reloadStorefrontsMaintainingSelection()
        } catch {
            errorMessage = "Failed to update publish state."
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
        let saved = try await businessService.save(storefront: draft.storefront)
        applySelection(saved)
        try await reloadStorefrontsMaintainingSelection()
    }

    private func persistStorefront() async throws {
        guard let storefront else { return }
        let saved = try await businessService.save(storefront: storefront)
        applySelection(saved)
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

    func updateDraftHandleFromCurrentText(_ currentHandleText: String) {
        let currentHandle = normalizedHandle(currentHandleText)
        self.currentHandleText = currentHandle
        guard !currentHandle.isEmpty else { return }
        if var draft {
            draft.storefront.slug = currentHandle
            draft.lastEditedAt = Date()
            self.draft = draft
        }
        if var storefront {
            storefront.slug = currentHandle
            self.storefront = storefront
        }
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
        } catch {
            errorMessage = "Unable to delete storefront."
        }
    }

    func createStorefront(name: String, category: String, tagline: String?) async {
        do {
            _ = try await businessService.createStorefront(name: name, category: category, tagline: tagline)
            try await reloadStorefrontsMaintainingSelection()
        } catch {
            errorMessage = "Unable to create storefront."
        }
    }

    private func normalizedHandle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private func applySelection(_ store: Storefront) {
        storefront = store
        selectedStorefrontID = store.id
        publishedStorefront = store.isPublished ? store : nil
        draft = StorefrontDraft(id: store.id, storefront: store, lastEditedAt: Date())
        currentHandleText = normalizedHandle(store.slug)
        mode = .editing
    }

    private func reloadStorefrontsMaintainingSelection() async throws {
        storefronts = try await businessService.listStorefronts()
        if let selectedID = selectedStorefrontID, let match = storefronts.first(where: { $0.id == selectedID }) {
            applySelection(match)
        }
    }
}
