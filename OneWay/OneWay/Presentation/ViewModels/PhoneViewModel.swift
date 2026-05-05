import Foundation
import Combine

@MainActor
final class PhoneViewModel: ObservableObject {
    private enum StorageKeys {
        static let favoriteContactIDs = "phone.favoriteContactIDs"
    }

    enum PermissionHelpAction {
        case openSettings
    }

    struct RecentCall: Identifiable {
        let id = UUID()
        let name: String
        let type: CallType
        let duration: String
        let timeLabel: String
        let missed: Bool
    }

    @Published private(set) var contacts: [ContactEntry] = []
    @Published private(set) var recentlyAddedContactIDs: Set<String> = []
    @Published private(set) var favoriteContactIDs: Set<String> = []
    @Published private(set) var isImporting = false
    @Published var infoMessage: String?
    @Published var errorMessage: String?
    @Published var permissionHelpAction: PermissionHelpAction?

    @Published private(set) var recents: [RecentCall] = [
        RecentCall(name: "Alex", type: .voice, duration: "12m 14s", timeLabel: "10m ago", missed: false),
        RecentCall(name: "Priya", type: .video, duration: "0m", timeLabel: "1h ago", missed: true),
        RecentCall(name: "Core Team", type: .voice, duration: "28m 02s", timeLabel: "Yesterday", missed: false)
    ]

    private let friendService: FriendService
    private let contactImportService: ContactImportService
    private let importedContactsStore: ImportedContactsStore

    init(
        friendService: FriendService,
        contactImportService: ContactImportService,
        importedContactsStore: ImportedContactsStore
    ) {
        self.friendService = friendService
        self.contactImportService = contactImportService
        self.importedContactsStore = importedContactsStore
        self.contacts = importedContactsStore.loadContacts()
        self.recentlyAddedContactIDs = importedContactsStore.loadAddedContactIDs()
        self.favoriteContactIDs = Set(UserDefaults.standard.stringArray(forKey: StorageKeys.favoriteContactIDs) ?? [])
    }

    func importFromDeviceContacts() async {
        isImporting = true
        defer { isImporting = false }

        let state = await contactImportService.requestAccessIfNeeded()

        switch state {
        case .authorized:
            break
        case .notDetermined:
            errorMessage = "Contacts permission request did not complete. Please try again."
            permissionHelpAction = nil
            return
        case .denied:
            errorMessage = "Contacts access is denied. Enable it in iOS Settings > Privacy & Security > Contacts > CipherChat."
            permissionHelpAction = .openSettings
            return
        case .restricted:
            errorMessage = "Contacts access is restricted on this device."
            permissionHelpAction = nil
            return
        }

        do {
            contacts = try await contactImportService.importContacts(limit: 200)
            persistImportedContacts()
            infoMessage = contacts.isEmpty ? "No contacts found with phone numbers." : "Imported \(contacts.count) contacts."
            errorMessage = nil
            permissionHelpAction = nil
        } catch {
            errorMessage = "Failed to import contacts."
            permissionHelpAction = nil
        }
    }

    func addContactAsFriend(_ contact: ContactEntry) async {
        guard !recentlyAddedContactIDs.contains(contact.id) else {
            infoMessage = "\(contact.displayName) is already in your contacts list."
            return
        }

        let handle = makeHandle(for: contact)

        do {
            _ = try await friendService.sendFriendRequest(handle: handle)
            recentlyAddedContactIDs.insert(contact.id)
            persistAddedContactIDs()
            infoMessage = "Friend request sent to \(contact.displayName)."
            errorMessage = nil
        } catch {
            errorMessage = "Could not send friend request."
        }
    }

    func addAllContactsAsFriends() async {
        guard !contacts.isEmpty else {
            infoMessage = "Import contacts first."
            return
        }

        var sentCount = 0
        for contact in contacts where !recentlyAddedContactIDs.contains(contact.id) {
            let handle = makeHandle(for: contact)
            do {
                _ = try await friendService.sendFriendRequest(handle: handle)
                recentlyAddedContactIDs.insert(contact.id)
                sentCount += 1
            } catch {
                continue
            }
        }

        persistAddedContactIDs()
        infoMessage = sentCount == 0 ? "All imported contacts are already added." : "Sent \(sentCount) friend request(s)."
        errorMessage = nil
    }

    private func persistImportedContacts() {
        importedContactsStore.saveContacts(contacts)
    }

    private func persistAddedContactIDs() {
        importedContactsStore.saveAddedContactIDs(recentlyAddedContactIDs)
    }

    private func makeHandle(for contact: ContactEntry) -> String {
        let base = contact.displayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .filter { $0.isLetter || $0.isNumber }
        let digits = contact.phoneNumber.filter(\.isNumber)
        let suffix = digits.suffix(4)
        return "@\(base.isEmpty ? "contact" : base)\(suffix)"
    }

    func deleteRecentCall(_ call: RecentCall) {
        recents.removeAll { $0.id == call.id }
    }

    func setFavorites(_ ids: Set<String>) {
        favoriteContactIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: StorageKeys.favoriteContactIDs)
        infoMessage = ids.isEmpty ? "Favorites cleared." : "Saved \(ids.count) favorite contact(s)."
    }
}
