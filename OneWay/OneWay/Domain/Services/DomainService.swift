import Foundation
import Combine
protocol DomainService {
    func listMyDomains() async throws -> [OneWayDomain]
    func isSlugAvailable(_ slug: String) async throws -> Bool
    func registerDomain(slug: String, paymentMethod: PaymentMethod, paymentReference: String?) async throws -> OneWayDomain
    func directory(limit: Int) async throws -> [DirectoryEntry]
}

struct DirectoryEntry: Identifiable, Equatable {
    var id: String { slug }
    let slug: String
    let title: String?
    let description: String?
}
