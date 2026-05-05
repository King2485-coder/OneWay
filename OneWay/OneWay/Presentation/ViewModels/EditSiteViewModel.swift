import Foundation
import Combine

@MainActor
final class EditSiteViewModel: ObservableObject {
    @Published var title: String = "My OneWay Site"
    @Published var siteDescription: String = ""
    @Published var mode: SiteMode = .nocode
    @Published var html: String = ""
    @Published var aiPrompt: String = ""
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var isPublishing = false
    @Published private(set) var isGenerating = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    let domainSlug: String
    private var loadedSite: OneWaySite?

    private let siteService: SiteService

    init(siteService: SiteService, domainSlug: String) {
        self.siteService = siteService
        self.domainSlug = domainSlug
    }

    var fullDomain: String { "\(domainSlug).oneway.app" }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let site = try await siteService.site(forSlug: domainSlug) {
                loadedSite = site
                title = site.title
                siteDescription = site.description
                mode = site.mode
                html = site.htmlContent
            }
        } catch {
            errorMessage = "Couldn't load this site."
        }
    }

    func save(thenPublish: Bool = false) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let draft = SiteDraft(
                domainSlug: domainSlug,
                title: title,
                description: siteDescription,
                mode: mode,
                htmlContent: html,
                blocks: loadedSite?.blocks ?? []
            )
            let site = try await siteService.upsert(site: draft)
            loadedSite = site
            errorMessage = nil
            infoMessage = thenPublish ? nil : "Draft saved."

            if thenPublish {
                isPublishing = true
                defer { isPublishing = false }
                try await siteService.publish(site: site)
                infoMessage = "\(fullDomain) is live."
            }
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func generateWithAI() async {
        guard !aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Describe the site first."
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        do {
            html = try await siteService.generateAISite(
                prompt: aiPrompt,
                domainSlug: domainSlug,
                title: title
            )
            mode = .ai
            errorMessage = nil
            infoMessage = "Generated. Review the HTML and publish."
        } catch {
            errorMessage = "AI generation failed: \(error.localizedDescription)"
        }
    }
}
