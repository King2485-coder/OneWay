import Foundation

protocol BackupService {
    func isOptedIn() async throws -> Bool
    func setOptIn(_ value: Bool) async throws
    func createEncryptedBackup() async throws -> String
    func restoreLatestBackup() async throws
}
