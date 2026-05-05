import Foundation

actor StubSiteService: SiteService {
    private var sites: [String: OneWaySite] = [:]

    func site(forSlug slug: String) async throws -> OneWaySite? {
        sites[slug]
    }

    func upsert(site draft: SiteDraft) async throws -> OneWaySite {
        let now = Date()
        let existing = sites[draft.domainSlug]
        let merged = OneWaySite(
            id: existing?.id ?? UUID(),
            userId: existing?.userId ?? UUID(),
            domainSlug: draft.domainSlug,
            title: draft.title,
            description: draft.description,
            mode: draft.mode,
            htmlContent: draft.htmlContent,
            blocks: draft.blocks,
            published: existing?.published ?? false,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        sites[draft.domainSlug] = merged
        return merged
    }

    func publish(site: OneWaySite) async throws {
        var copy = site
        copy.published = true
        sites[site.domainSlug] = copy
    }

    func generateAISite(prompt: String, domainSlug: String, title: String) async throws -> String {
        // Minimal stub HTML so the AI flow works without the edge function.
        try await Task.sleep(nanoseconds: 400_000_000)
        return """
        <!DOCTYPE html><html><head><meta charset="UTF-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(title))</title>
        <style>body{background:#06030f;color:#f0ebff;font-family:-apple-system,sans-serif;
        padding:48px 20px;max-width:680px;margin:0 auto;line-height:1.6}
        a{color:#a855f7}</style></head><body>
        <h1>\(escape(title))</h1>
        <p>\(escape(prompt))</p>
        <footer><a href="https://home.oneway.app">Hosted on OneWay</a></footer>
        </body></html>
        """
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
