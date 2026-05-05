import Foundation

protocol AccountLifecycleService {
    func deleteAccountBestEffort() async throws
}
