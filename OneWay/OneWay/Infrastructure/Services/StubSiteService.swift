import Foundation

actor StubSiteService: SiteService {
    private var sites: [String: OneWaySite] = [:]
    private let userId = "local-user"

    func sites() async throws -> [OneWaySite] {
        sites.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func site(forSlug slug: String) async throws -> OneWaySite? {
        sites[slug]
    }

    func publishedSite(forSlug slug: String) async throws -> OneWaySite? {
        guard let site = sites[slug], site.published else { return nil }
        return site
    }

    func upsert(site draft: SiteDraft) async throws -> OneWaySite {
        let now = Date()
        let existing = sites[draft.domainSlug]
        let merged = OneWaySite(
            id: existing?.id ?? UUID(),
            userId: existing?.userId ?? userId,
            domainSlug: draft.domainSlug,
            title: draft.title,
            description: draft.description,
            mode: draft.mode,
            htmlContent: draft.htmlContent,
            blocks: draft.blocks,
            aiPrompt: draft.aiPrompt,
            publishedHtml: existing?.publishedHtml ?? "",
            publishedAt: existing?.publishedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        sites[draft.domainSlug] = merged
        return merged
    }

    func publish(site: OneWaySite) async throws -> OneWaySite {
        var copy = site
        copy.publishedHtml = renderHTML(for: site)
        copy.publishedAt = ISO8601DateFormatter().string(from: Date())
        sites[site.domainSlug] = copy
        return copy
    }

    func uploadSiteImage(domainSlug: String, fileName: String, mimeType: String, data: Data) async throws -> SiteAsset {
        let encoded = data.base64EncodedString()
        let url = "data:\(mimeType);base64,\(encoded)"
        return SiteAsset(url: url, path: nil, mimeType: mimeType, byteCount: data.count)
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

    private func renderHTML(for site: OneWaySite) -> String {
        switch site.mode {
        case .nocode:
            return SiteRenderer.render(blocks: site.blocks, title: site.title, description: site.description)
        case .ai:
            return site.blocks.isEmpty ? site.htmlContent : SiteRenderer.render(blocks: site.blocks, title: site.title, description: site.description)
        case .code:
            return site.htmlContent
        }
    }
}
