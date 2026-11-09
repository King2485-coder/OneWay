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
        do {
            try await service.setOptIn(enabled)
            optedIn = enabled
        } catch {
            optedIn = false
            statusMessage = error.localizedDescription
        }
    }

    func createBackup() async {
        do {
            let id = try await service.createBackup()
            statusMessage = "Created backup: \(id)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restoreBackup() async {
        do {
            try await service.restoreLatestBackup()
            statusMessage = "Restore completed from latest backup."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
