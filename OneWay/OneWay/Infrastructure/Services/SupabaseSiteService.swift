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

    func sites() async throws -> [OneWaySite] {
        let rows: [SiteRow] = try await client
            .from("ow_sites")
            .select()
            .order("updated_at", ascending: false)
            .execute()
            .value
        return rows.map { $0.toSite() }
    }

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

    func publishedSite(forSlug slug: String) async throws -> OneWaySite? {
        let rows: [SiteRow] = try await client
            .from("ow_sites")
            .select()
            .eq("domain_slug", value: slug)
            .not("published_at", operator: .is, value: "null")
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
            let ai_prompt: String
        }

        let payload = Upsert(
            user_id: user.id,
            domain_slug: draft.domainSlug,
            title: draft.title,
            description: draft.description,
            mode: draft.mode.rawValue,
            html_content: draft.htmlContent,
            blocks: draft.blocks,
            ai_prompt: draft.aiPrompt
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

    func publish(site: OneWaySite) async throws -> OneWaySite {
        // 1) Mark row published
        struct PublishPatch: Encodable {
            let published: Bool
            let published_html: String
            let published_at: String
        }
        let html = renderHTML(for: site)
        let publishedAt = ISO8601DateFormatter().string(from: Date())
        _ = try await client
            .from("ow_sites")
            .update(PublishPatch(published: true, published_html: html, published_at: publishedAt))
            .eq("id", value: site.id)
            .execute()

        // 2) Push HTML to Storage so the edge function can serve it
        let path = "sites/\(site.domainSlug)/index.html"
        try await client.storage
            .from("oneway-sites")
            .upload(
                path: path,
                file: Data(html.utf8),
                options: FileOptions(contentType: "text/html", upsert: true)
            )
        var copy = site
        copy.publishedHtml = html
        copy.publishedAt = publishedAt
        return copy
    }

    func uploadSiteImage(domainSlug: String, fileName: String, mimeType: String, data: Data) async throws -> SiteAsset {
        let safeName = fileName
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
        let path = "sites/\(domainSlug)/assets/\(UUID().uuidString)-\(safeName)"
        try await client.storage
            .from("oneway-sites")
            .upload(
                path: path,
                file: data,
                options: FileOptions(contentType: mimeType, upsert: true)
            )
        let encodedPath = path
            .split(separator: "/")
            .dropFirst(2)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let publishedURL = "https://\(domainSlug).oneway.app/assets/\(encodedPath.replacingOccurrences(of: "assets/", with: ""))"
        return SiteAsset(url: publishedURL, path: path, mimeType: mimeType, byteCount: data.count)
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
    let ai_prompt: String?
    let published_html: String?
    let published_at: String?
    let published: Bool?
    let created_at: Date
    let updated_at: Date

    func toSite() -> OneWaySite {
        OneWaySite(
            id: id,
            userId: user_id.uuidString,
            domainSlug: domain_slug,
            title: title,
            description: description,
            mode: SiteMode(rawValue: mode) ?? .nocode,
            htmlContent: html_content,
            blocks: blocks,
            aiPrompt: ai_prompt ?? "",
            publishedHtml: published_html ?? "",
            publishedAt: published_at,
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
        .gallery-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin:12px 0}
        .gallery-grid figure{background:rgba(255,255,255,.06);border-radius:14px;overflow:hidden}
        .gallery-grid img{width:100%;aspect-ratio:4/3;object-fit:cover;margin:0;border-radius:0}
        figcaption{color:#9d8fc4;font-size:.9rem;padding:8px 10px}
        blockquote{background:rgba(168,85,247,.12);border:1px solid rgba(168,85,247,.22);border-radius:18px;padding:20px;margin:18px 0}
        blockquote p{color:#f0ebff;font-size:1.25rem;font-weight:800}
        blockquote footer{margin:10px 0 0;padding:0;border:0;text-align:left;color:#ffcc33}
        .services-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin:12px 0}
        .service-item,.faq-item{background:rgba(255,255,255,.06);border:1px solid rgba(168,85,247,.2);border-radius:16px;padding:14px;margin:10px 0}
        .service-item h3,.faq-item h3{margin:0 0 6px;font-size:1rem}
        .service-item p,.faq-item p{margin:0}
        hr{border:0;border-top:1px solid rgba(124,58,237,0.18);margin:24px 0}
        footer{margin-top:48px;padding-top:24px;border-top:1px solid rgba(124,58,237,0.18);
          color:#6b5d8c;font-size:.8rem;text-align:center}
        footer nav{display:flex;gap:14px;justify-content:center;flex-wrap:wrap;margin-bottom:10px}
        </style></head><body>
        \(body)
        <footer>
          <nav aria-label="Site links">
            <a href="https://oneway.is/privacy">Privacy</a>
            <a href="https://oneway.is/terms">Terms</a>
            <a href="https://oneway.is/support">Support</a>
          </nav>
          Hosted on <a href="https://home.oneway.app">OneWay</a>
        </footer>
        </body></html>
        """
    }

    private static func renderBlock(_ block: SiteBlock) -> String {
        switch block {
        case .hero(let eyebrow, let title, let subtitle):
            return "<section class=\"hero\"><p>\(escape(eyebrow))</p><h1>\(escape(title))</h1><p>\(escape(subtitle))</p></section>"
        case .text(let text):
            return "<p>\(escape(text))</p>"
        case .button(let label, let url):
            return "<a class=\"button\" href=\"\(escape(url))\">\(escape(label))</a>"
        case .contact(let name, let email, let phone):
            return "<section><h2>Contact</h2><p>\(escape(name))</p><p>\(escape(email))</p><p>\(escape(phone))</p></section>"
        case .hours(let hours):
            return "<section><h2>Business hours</h2><p>\(escape(hours))</p></section>"
        case .callText(let label, let phoneNumber):
            return "<section><h2>\(escape(label))</h2><p>\(escape(phoneNumber))</p></section>"
        case .photo(let url, let alt, let caption):
            let figcaption = caption.isEmpty ? "" : "<figcaption>\(escape(caption))</figcaption>"
            return "<figure><img src=\"\(escape(url))\" alt=\"\(escape(alt))\" />\(figcaption)</figure>"
        case .gallery(let title, let images):
            let imageHTML = images
                .filter { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { image in
                    let figcaption = image.caption.isEmpty ? "" : "<figcaption>\(escape(image.caption))</figcaption>"
                    return "<figure><img src=\"\(escape(image.url))\" alt=\"\(escape(image.alt))\" />\(figcaption)</figure>"
                }
                .joined()
            return "<section><h2>\(escape(title))</h2><div class=\"gallery-grid\">\(imageHTML)</div></section>"
        case .testimonial(let quote, let name, let role):
            let roleHTML = role.isEmpty ? "" : " <span>\(escape(role))</span>"
            return "<blockquote><p>“\(escape(quote))”</p><footer>\(escape(name))\(roleHTML)</footer></blockquote>"
        case .services(let title, let items):
            let itemHTML = items
                .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { item in
                    "<article class=\"service-item\"><h3>\(escape(item.title.isEmpty ? "Service" : item.title))</h3><p>\(escape(item.detail))</p></article>"
                }
                .joined()
            return "<section><h2>\(escape(title))</h2><div class=\"services-grid\">\(itemHTML)</div></section>"
        case .faq(let title, let items):
            let itemHTML = items
                .filter { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { item in
                    "<article class=\"faq-item\"><h3>\(escape(item.question.isEmpty ? "Question" : item.question))</h3><p>\(escape(item.answer))</p></article>"
                }
                .joined()
            return "<section><h2>\(escape(title))</h2>\(itemHTML)</section>"
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
