import Foundation
import Combine

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var directory: [DirectoryEntry] = []
    @Published private(set) var isLoadingDirectory = false
    @Published var errorMessage: String?

    private let domainService: DomainService

    init(domainService: DomainService) {
        self.domainService = domainService
    }

    var resolvedURL: URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let url = URL(string: q.contains("://") ? q : "https://\(q)\(q.contains(".") ? "" : ".oneway.app")"),
           url.host != nil {
            return url
        }
        return nil
    }

    func loadDirectory() async {
        isLoadingDirectory = true
        defer { isLoadingDirectory = false }
        do {
            directory = try await domainService.directory(limit: 100)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the directory."
        }
    }
}
