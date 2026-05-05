import Foundation
import Combine

@MainActor
final class BackupRestoreViewModel: ObservableObject {
    @Published var optedIn = false
    @Published var statusMessage: String?

    private let service: BackupService

    init(service: BackupService) {
        self.service = service
    }

    func load() async {
        optedIn = (try? await service.isOptedIn()) ?? false
    }

    func setOptIn(_ enabled: Bool) async {
        try? await service.setOptIn(enabled)
        optedIn = enabled
    }

    func createBackup() async {
        if let id = try? await service.createEncryptedBackup() {
            statusMessage = "Created encrypted backup: \(id)"
        }
    }

    func restoreBackup() async {
        try? await service.restoreLatestBackup()
        statusMessage = "Restore completed from latest backup."
    }
}
