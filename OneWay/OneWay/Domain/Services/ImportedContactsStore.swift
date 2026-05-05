import Foundation

protocol ImportedContactsStore {
    func loadContacts() -> [ContactEntry]
    func saveContacts(_ contacts: [ContactEntry])
    func loadAddedContactIDs() -> Set<String>
    func saveAddedContactIDs(_ ids: Set<String>)
    func clear()
}

final class InMemoryImportedContactsStore: ImportedContactsStore {
    private var contacts: [ContactEntry] = []
    private var addedIDs: Set<String> = []

    func loadContacts() -> [ContactEntry] {
        contacts
    }

    func saveContacts(_ contacts: [ContactEntry]) {
        self.contacts = contacts
    }

    func loadAddedContactIDs() -> Set<String> {
        addedIDs
    }

    func saveAddedContactIDs(_ ids: Set<String>) {
        addedIDs = ids
    }

    func clear() {
        contacts.removeAll()
        addedIDs.removeAll()
    }
}
