import Foundation

final class UserDefaultsImportedContactsStore: ImportedContactsStore {
    private struct StoredContact: Codable {
        let id: String
        let displayName: String
        let phoneNumber: String
    }

    private let defaults: UserDefaults
    private let contactsKey = "imported_contacts.v1"
    private let addedIDsKey = "imported_contacts_added_ids.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadContacts() -> [ContactEntry] {
        guard let data = defaults.data(forKey: contactsKey),
              let decoded = try? JSONDecoder().decode([StoredContact].self, from: data) else {
            return []
        }

        return decoded.map { ContactEntry(id: $0.id, displayName: $0.displayName, phoneNumber: $0.phoneNumber) }
    }

    func saveContacts(_ contacts: [ContactEntry]) {
        let encoded = contacts.map { StoredContact(id: $0.id, displayName: $0.displayName, phoneNumber: $0.phoneNumber) }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: contactsKey)
    }

    func loadAddedContactIDs() -> Set<String> {
        let values = defaults.stringArray(forKey: addedIDsKey) ?? []
        return Set(values)
    }

    func saveAddedContactIDs(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: addedIDsKey)
    }

    func clear() {
        defaults.removeObject(forKey: contactsKey)
        defaults.removeObject(forKey: addedIDsKey)
    }
}
