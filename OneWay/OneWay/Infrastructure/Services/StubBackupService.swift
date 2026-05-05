import Foundation

actor StubBackupService: BackupService {
    private var optedIn = false
    private var latestBackupID: String?

    func isOptedIn() async throws -> Bool {
        optedIn
    }

    func setOptIn(_ value: Bool) async throws {
        optedIn = value
    }

    func createEncryptedBackup() async throws -> String {
        let backupID = "backup-\(UUID().uuidString.prefix(8))"
        latestBackupID = String(backupID)
        return String(backupID)
    }

    func restoreLatestBackup() async throws {
        _ = latestBackupID
    }
}
