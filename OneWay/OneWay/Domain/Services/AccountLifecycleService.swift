import Foundation

@MainActor
protocol AccountLifecycleService {
    func deleteAccountBestEffort() async throws
}
