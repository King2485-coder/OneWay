import Foundation

enum OneWayBackupUnavailableError: LocalizedError, Equatable {
    case notSecureForE2EE

    var errorDescription: String? {
        "Encrypted backup is not implemented. No backup artifact was created."
    }
}

/// Fail-closed placeholder. Future schema hooks live in the security design;
/// this service cannot opt in, create an artifact, or claim secure recovery.
actor UnavailableBackupService: BackupService {
    func isOptedIn() async throws -> Bool {
        false
    }

    func setOptIn(_ value: Bool) async throws {
        if value { throw OneWayBackupUnavailableError.notSecureForE2EE }
    }

    func createBackup() async throws -> String {
        throw OneWayBackupUnavailableError.notSecureForE2EE
    }

    func restoreLatestBackup() async throws {
        throw OneWayBackupUnavailableError.notSecureForE2EE
    }
}
