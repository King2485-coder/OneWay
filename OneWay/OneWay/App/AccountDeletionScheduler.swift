import Foundation
import Combine

@MainActor
final class AccountDeletionScheduler: ObservableObject {
    @Published private(set) var scheduledDeletionDate: Date?
    @Published private(set) var lastError: String?

    private let storageKey = "account_deletion_timestamp"
    private let accountLifecycleService: AccountLifecycleService?
    private var isExecuting = false

    init(accountLifecycleService: AccountLifecycleService? = nil) {
        self.accountLifecycleService = accountLifecycleService

        let timestamp = UserDefaults.standard.double(forKey: storageKey)
        if timestamp > 0 {
            scheduledDeletionDate = Date(timeIntervalSince1970: timestamp)
        }
    }

    func schedule() {
        print("Account deletion scheduled")
    }

    func schedule(after interval: TimeInterval) {
        let date = Date().addingTimeInterval(interval)
        scheduledDeletionDate = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: storageKey)
        lastError = nil
    }

    func cancel() {
        scheduledDeletionDate = nil
        UserDefaults.standard.removeObject(forKey: storageKey)
        lastError = nil
    }

    func clearError() {
        lastError = nil
    }

    func processIfNeeded() async {
        guard !isExecuting, let scheduledDeletionDate else { return }
        guard Date() >= scheduledDeletionDate else { return }

        isExecuting = true
        defer { isExecuting = false }

        guard let accountLifecycleService else {
            cancel()
            return
        }

        do {
            try await accountLifecycleService.deleteAccountBestEffort()
            cancel()
        } catch {
            lastError = "Scheduled deletion failed. Please retry."
        }
    }
}
