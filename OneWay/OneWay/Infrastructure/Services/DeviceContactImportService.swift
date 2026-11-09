import Foundation
@preconcurrency import Contacts

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
        return try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let request = CNContactFetchRequest(keysToFetch: ContactKeys.fullProfile)
            request.unifyResults = true
            request.sortOrder = .userDefault
            var entries: [ContactEntry] = []
            var seenIDs = Set<String>()

            try store.enumerateContacts(with: request) { contact, stop in
                let display = Self.displayName(for: contact)

                let phoneNumbers = contact.phoneNumbers
                    .map(\.value.stringValue)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                let emailAddresses = contact.emailAddresses
                    .map { String($0.value) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                let reachableValues: [(raw: String, normalized: String)] = {
                    if !phoneNumbers.isEmpty {
                        return phoneNumbers.compactMap { phone in
                            let normalized = phone.filter(\.isNumber)
                            guard !normalized.isEmpty else { return nil }
                            return (raw: phone, normalized: normalized)
                        }
                    }

                    return emailAddresses.map { email in
                        (raw: email, normalized: email.lowercased())
                    }
                }()

                guard !reachableValues.isEmpty else {
                    return
                }

                for value in reachableValues {
                    let uniqueID = "\(contact.identifier)-\(value.normalized)"
                    guard seenIDs.insert(uniqueID).inserted else { continue }

                    entries.append(
                        ContactEntry(
                            id: uniqueID,
                            displayName: display,
                            phoneNumber: value.raw
                        )
                    )

                    if let limit, entries.count >= limit {
                        stop.pointee = true
                        break
                    }
                }

                if let limit, entries.count >= limit {
                    stop.pointee = true
                }
            }

            return entries.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }.value
    }

    private static func displayName(for contact: CNContact) -> String {
        let formatted = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let formatted, !formatted.isEmpty {
            return formatted
        }

        let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !organization.isEmpty {
            return organization
        }

        return "Unknown"
    }
}
    