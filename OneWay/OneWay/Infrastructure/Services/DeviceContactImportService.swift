import Foundation
import Contacts

final class DeviceContactImportService: ContactImportService {
    private let store = CNContactStore()

    func permissionState() -> ContactPermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .limited:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .restricted
        }
    }

    func requestAccessIfNeeded() async -> ContactPermissionState {
        let current = permissionState()
        guard current == .notDetermined else {
            return current
        }

        let granted = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }

        return granted ? .authorized : .denied
    }

    func importContacts(limit: Int? = 200) async throws -> [ContactEntry] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let keys: [CNKeyDescriptor] = [
                        CNContactGivenNameKey as CNKeyDescriptor,
                        CNContactFamilyNameKey as CNKeyDescriptor,
                        CNContactPhoneNumbersKey as CNKeyDescriptor
                    ]

                    let request = CNContactFetchRequest(keysToFetch: keys)
                    var entries: [ContactEntry] = []

                    try self.store.enumerateContacts(with: request) { contact, stop in
                        guard let phone = contact.phoneNumbers.first?.value.stringValue,
                              !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return
                        }

                        let name = "\(contact.givenName) \(contact.familyName)"
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let display = name.isEmpty ? "Unknown" : name
                        let normalized = self.normalizePhone(phone)
                        entries.append(
                            ContactEntry(
                                id: "\(display)-\(normalized)",
                                displayName: display,
                                phoneNumber: phone
                            )
                        )

                        if let limit, entries.count >= limit {
                            stop.pointee = true
                        }
                    }

                    let sorted = entries.sorted {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    }
                    continuation.resume(returning: sorted)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func normalizePhone(_ value: String) -> String {
        value.filter(\.isNumber)
    }
}
