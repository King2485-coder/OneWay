import Foundation

enum ContactPermissionState {
    case notDetermined
    case authorized
    case denied
    case restricted
}

protocol ContactImportService {
    func permissionState() -> ContactPermissionState
    func requestAccessIfNeeded() async -> ContactPermissionState
    func importContacts(limit: Int?) async throws -> [ContactEntry]
}
