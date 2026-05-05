import Foundation

protocol SiteService {
    func site(forSlug slug: String) async throws -> OneWaySite?
    func upsert(site: SiteDraft) async throws -> OneWaySite
    func publish(site: OneWaySite) async throws
    func generateAISite(prompt: String, domainSlug: String, title: String) async throws -> String
}

struct SiteDraft: Equatable {
    var domainSlug: String
    var title: String
    var description: String
    var mode: SiteMode
    var htmlContent: String
    var blocks: [SiteBlock]
}
