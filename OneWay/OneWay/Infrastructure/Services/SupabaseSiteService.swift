import Foundation

#if canImport(Supabase)
import Supabase

struct SupabaseSiteService: SiteService {
    private let client: SupabaseClient

    init?(client: SupabaseClient? = SupabaseClientProvider.shared.client) {
        guard let client else { return nil }
        self.client = client
    }

    // MARK: - SiteService

    func site(forSlug slug: String) async throws -> OneWaySite? {
        let rows: [SiteRow] = try await client
            .from("ow_sites")
            .select()
            .eq("domain_slug", value: slug)
            .limit(1)
            .execute()
            .value
        return rows.first?.toSite()
    }

    func upsert(site draft: SiteDraft) async throws -> OneWaySite {
        let user = try await client.auth.user()

        struct Upsert: Encodable {
            let user_id: UUID
            let domain_slug: String
            let title: String
            let description: String
            let mode: String
            let html_content: String
            let blocks: [SiteBlock]
        }

        let payload = Upsert(
            user_id: user.id,
            domain_slug: draft.domainSlug,
            title: draft.title,
            description: draft.description,
            mode: draft.mode.rawValue,
            html_content: draft.htmlContent,
            blocks: draft.blocks
        )

        let row: SiteRow = try await client
            .from("ow_sites")
            .upsert(payload, onConflict: "domain_slug")
            .select()
            .single()
            .execute()
            .value
        return row.toSite()
    }

    func publish(site: OneWaySite) async throws {
        // 1) Mark row published
        struct PublishPatch: Encodable { let published: Bool }
        _ = try await client
            .from("ow_sites")
            .update(PublishPatch(published: true))
            .eq("id", value: site.id)
            .execute()

        // 2) Push HTML to Storage so the edge function can serve it
        let html: String
        switch site.mode {
        case .nocode:
            html = SiteRenderer.render(blocks: site.blocks, title: site.title, description: site.description)
        case .code, .ai:
            html = site.htmlContent
        }

        let path = "sites/\(site.domainSlug)/index.html"
        try await client.storage
            .from("oneway-sites")
            .upload(
                path: path,
                file: Data(html.utf8),
                options: FileOptions(contentType: "text/html", upsert: true)
            )
    }

    func generateAISite(prompt: String, domainSlug: String, title: String) async throws -> String {
        struct Body: Encodable {
            let prompt: String
            let domain: String
            let title: String
        }
        struct Reply: Decodable { let html: String }

        let reply: Reply = try await client.functions
            .invoke(
                "generate-site",
                options: FunctionInvokeOptions(
                    body: Body(prompt: prompt, domain: domainSlug, title: title)
                )
            )
        return reply.html
    }
}

// MARK: - Row mapping

private struct SiteRow: Decodable {
    let id: UUID
    let user_id: UUID
    let domain_slug: String
    let title: String
    let description: String
    let mode: String
    let html_content: String
    let blocks: [SiteBlock]
    let published: Bool
    let created_at: Date
    let updated_at: Date

    func toSite() -> OneWaySite {
        OneWaySite(
            id: id,
            userId: user_id,
            domainSlug: domain_slug,
            title: title,
            description: description,
            mode: SiteMode(rawValue: mode) ?? .nocode,
            htmlContent: html_content,
            blocks: blocks,
            published: published,
            createdAt: created_at,
            updatedAt: updated_at
        )
    }
}
#endif

// MARK: - Block → HTML renderer (used both by stub and real services)

enum SiteRenderer {
    static func render(blocks: [SiteBlock], title: String, description: String) -> String {
        let body = blocks.map(renderBlock).joined(separator: "\n")
        return """
        <!DOCTYPE html><html><head>
        <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        *{box-sizing:border-box;margin:0;padding:0}
        body{font-family:-apple-system,sans-serif;background:#06030f;color:#f0ebff;
          padding:48px 20px;max-width:680px;margin:0 auto;line-height:1.6}
        h1,h2,h3{font-weight:900;margin:24px 0 8px}
        p{color:#9d8fc4;margin:8px 0}
        a{color:#a855f7}
        img{max-width:100%;border-radius:12px;margin:12px 0}
        hr{border:0;border-top:1px solid rgba(124,58,237,0.18);margin:24px 0}
        footer{margin-top:48px;padding-top:24px;border-top:1px solid rgba(124,58,237,0.18);
          color:#6b5d8c;font-size:.8rem;text-align:center}
        </style></head><body>
        \(body)
        <footer>Hosted on <a href="https://home.oneway.app">OneWay</a></footer>
        </body></html>
        """
    }

    private static func renderBlock(_ block: SiteBlock) -> String {
        switch block {
        case .heading(let level, let text):
            let l = max(1, min(3, level))
            return "<h\(l)>\(escape(text))</h\(l)>"
        case .paragraph(let text):
            return "<p>\(escape(text))</p>"
        case .image(let url, let alt):
            return "<img src=\"\(escape(url.absoluteString))\" alt=\"\(escape(alt ?? ""))\" />"
        case .link(let href, let label):
            return "<a href=\"\(escape(href.absoluteString))\">\(escape(label))</a>"
        case .divider:
            return "<hr/>"
        case .html(let raw):
            return raw // trusted: author's own site
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }
}
