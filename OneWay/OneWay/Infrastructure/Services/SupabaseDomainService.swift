import Foundation

#if canImport(Supabase)
import Supabase

/// Real DomainService backed by `supabase-swift`. Activated automatically
/// when the Supabase SwiftPM package is added to the project; before that,
/// `AppEnvironment` falls back to `StubDomainService`.
struct SupabaseDomainService: DomainService {
    private let client: SupabaseClient

    init?(client: SupabaseClient? = SupabaseClientProvider.shared.client) {
        guard let client else { return nil }
        self.client = client
    }

    // MARK: - DomainService

    func listMyDomains() async throws -> [OneWayDomain] {
        let rows: [DomainRow] = try await client
            .from("ow_domains")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
        return rows.map { $0.toDomain() }
    }

    func isSlugAvailable(_ slug: String) async throws -> Bool {
        let rows: [DomainRow] = try await client
            .from("ow_domains")
            .select("id, slug")
            .eq("slug", value: slug)
            .limit(1)
            .execute()
            .value
        return rows.isEmpty
    }

    func registerDomain(
        slug: String,
        paymentMethod: PaymentMethod,
        paymentReference: String?
    ) async throws -> OneWayDomain {
        let user = try await client.auth.user()
        let expires = Calendar(identifier: .gregorian)
            .date(byAdding: .year, value: 1, to: Date()) ?? Date().addingTimeInterval(31_536_000)

        struct Insert: Encodable {
            let user_id: UUID
            let slug: String
            let status: String
            let expires_at: Date
            let payment_method: String
            let payment_reference: String?
        }

        let payload = Insert(
            user_id: user.id,
            slug: slug,
            status: DomainStatus.active.rawValue,
            expires_at: expires,
            payment_method: paymentMethod.rawValue,
            payment_reference: paymentReference
        )

        let row: DomainRow = try await client
            .from("ow_domains")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value
        return row.toDomain()
    }

    func directory(limit: Int) async throws -> [DirectoryEntry] {
        struct Joined: Decodable {
            let slug: String
            let ow_sites: SiteSummary?
        }
        struct SiteSummary: Decodable {
            let title: String?
            let description: String?
        }

        let rows: [Joined] = try await client
            .from("ow_domains")
            .select("slug, ow_sites(title, description)")
            .eq("status", value: "active")
            .not("site_id", operator: .is, value: "null")
            .limit(limit)
            .execute()
            .value
        return rows.map {
            DirectoryEntry(slug: $0.slug, title: $0.ow_sites?.title, description: $0.ow_sites?.description)
        }
    }
}

// MARK: - Row mapping

private struct DomainRow: Decodable {
    let id: UUID
    let user_id: UUID
    let slug: String
    let status: String
    let expires_at: Date
    let renewal_price_usd: Decimal
    let site_id: UUID?
    let payment_method: String?
    let payment_reference: String?
    let created_at: Date
    let updated_at: Date

    func toDomain() -> OneWayDomain {
        OneWayDomain(
            id: id,
            userId: user_id,
            slug: slug,
            status: DomainStatus(rawValue: status) ?? .pending,
            expiresAt: expires_at,
            renewalPriceUSD: renewal_price_usd,
            siteId: site_id,
            paymentMethod: payment_method.flatMap(PaymentMethod.init(rawValue:)),
            paymentReference: payment_reference,
            createdAt: created_at,
            updatedAt: updated_at
        )
    }
}
#endif
