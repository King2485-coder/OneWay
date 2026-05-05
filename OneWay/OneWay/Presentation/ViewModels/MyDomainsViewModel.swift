import Foundation
import Combine

@MainActor
final class MyDomainsViewModel: ObservableObject {
    @Published private(set) var domains: [OneWayDomain] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let domainService: DomainService

    init(domainService: DomainService) {
        self.domainService = domainService
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            domains = try await domainService.listMyDomains()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load your domains."
        }
    }
}
