import Foundation
import Combine

@MainActor
final class SellerStudioViewModel: ObservableObject {
    @Published var draft: StorefrontDraft?
    @Published var published: Storefront?
    @Published var suggestions: [AIStoreEditSuggestion] = []
    @Published var errorMessage: String?

    private let businessService: BusinessService
    private let aiStorefrontService: AIStorefrontService

    init(businessService: BusinessService, aiStorefrontService: AIStorefrontService) {
        self.businessService = businessService
        self.aiStorefrontService = aiStorefrontService
    }

    func load() async {
        do {
            let stores = try await businessService.listStorefronts()
            published = stores.first(where: { $0.isPublished })
            if let current = stores.first {
                draft = StorefrontDraft(id: current.id, storefront: current, lastEditedAt: Date())
            }
            errorMessage = nil
        } catch {
            errorMessage = "Unable to load storefront."
        }
    }

    func addSuggestion(title: String, action: AIStoreAction, description: String = "Suggested by AI") {
        let suggestion = AIStoreEditSuggestion(
            id: UUID(),
            title: title,
            description: description,
            suggestedAt: Date(),
            affectedSectionIDs: [],
            action: action,
            applied: false
        )
        suggestions.insert(suggestion, at: 0)
    }
}
