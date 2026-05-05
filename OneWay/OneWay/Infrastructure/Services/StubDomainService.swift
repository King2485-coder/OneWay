import Foundation

/// In-memory stub used until the real Supabase package is wired in.
/// Mirrors the behavior of `SupabaseDomainService` so views work end-to-end.
actor StubDomainService: DomainService {
    private var domains: [OneWayDomain]
    private let userId = UUID()

    init(seedSlugs: [String] = ["mira", "sandbox"]) {
        let now = Date()
        let oneYear: TimeInterval = 60 * 60 * 24 * 365
        let userId = self.userId
        self.domains = seedSlugs.map { slug in
            OneWayDomain(
                id: UUID(),
                userId: userId,
                slug: slug,
                status: .active,
                expiresAt: now.addingTimeInterval(oneYear),
                renewalPriceUSD: 3.99,
                siteId: nil,
                paymentMethod: .appleIAP,
                paymentReference: nil,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    func listMyDomains() async throws -> [OneWayDomain] {
        domains.sorted { $0.createdAt > $1.createdAt }
    }

    func isSlugAvailable(_ slug: String) async throws -> Bool {
        try await Task.sleep(nanoseconds: 200_000_000) // simulate latency
        return !domains.contains(where: { $0.slug == slug })
    }

    func registerDomain(
        slug: String,
        paymentMethod: PaymentMethod,
        paymentReference: String?
    ) async throws -> OneWayDomain {
        guard !domains.contains(where: { $0.slug == slug }) else {
            throw DomainServiceError.slugTaken
        }
        let now = Date()
        let oneYear: TimeInterval = 60 * 60 * 24 * 365
        let new = OneWayDomain(
            id: UUID(),
            userId: userId,
            slug: slug,
            status: .active,
            expiresAt: now.addingTimeInterval(oneYear),
            renewalPriceUSD: 3.99,
            siteId: nil,
            paymentMethod: paymentMethod,
            paymentReference: paymentReference,
            createdAt: now,
            updatedAt: now
        )
        domains.append(new)
        return new
    }

    func directory(limit: Int) async throws -> [DirectoryEntry] {
        domains.prefix(limit).map { d in
            DirectoryEntry(slug: d.slug, title: nil, description: nil)
        }
    }
}

enum DomainServiceError: LocalizedError {
    case slugTaken
    case notSignedIn
    case network(String)

    var errorDescription: String? {
        switch self {
        case .slugTaken:        return "That name is already taken."
        case .notSignedIn:      return "You need to sign in first."
        case .network(let s):   return s
        }
    }
}
