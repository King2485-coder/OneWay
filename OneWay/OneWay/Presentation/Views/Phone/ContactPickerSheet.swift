import SwiftUI
@preconcurrency import Contacts
@preconcurrency import ContactsUI

struct ContactPickerSheet: UIViewControllerRepresentable {
    let onSelect: ([ContactEntry]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0 OR emailAddresses.@count > 0")
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onSelect: ([ContactEntry]) -> Void

        init(onSelect: @escaping ([ContactEntry]) -> Void) {
            self.onSelect = onSelect
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onSelect(contacts.flatMap(Self.entries(from:)))
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onSelect(Self.entries(from: contact))
        }

        private static func entries(from contact: CNContact) -> [ContactEntry] {
            // CNContactPicker may return CNContact objects missing properties unless
            // explicitly fetched. Refetch by identifier with the keys we use.
            let resolved: CNContact = {
                let store = CNContactStore()
                return (try? store.unifiedContact(withIdentifier: contact.identifier, keysToFetch: ContactKeys.fullProfile)) ?? contact
            }()

            let displayName = displayName(for: resolved)

            let phoneEntries = resolved.phoneNumbers.compactMap { labeledValue -> ContactEntry? in
                let raw = labeledValue.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = raw.filter(\.isNumber)
                guard !normalized.isEmpty else { return nil }
                return ContactEntry(
                    id: "\(resolved.identifier)-\(normalized)",
                    displayName: displayName,
                    phoneNumber: raw
                )
            }

            if !phoneEntries.isEmpty {
                return unique(phoneEntries)
            }

            let emailEntries = resolved.emailAddresses.compactMap { labeledValue -> ContactEntry? in
                let raw = String(labeledValue.value).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return nil }
                return ContactEntry(
                    id: "\(resolved.identifier)-\(raw.lowercased())",
                    displayName: displayName,
                    phoneNumber: raw
                )
            }

            return unique(emailEntries)
        }

        private static func unique(_ entries: [ContactEntry]) -> [ContactEntry] {
            var seen = Set<String>()
            return entries.filter { seen.insert($0.id).inserted }
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
}
