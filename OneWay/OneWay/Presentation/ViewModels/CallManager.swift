import Foundation
import SwiftUI
import Combine

@MainActor
final class CallManager: ObservableObject {
    private enum StorageKeys {
        static let favoriteFriendIDs = "phone.favoriteFriendIDs.v2"
    }

    struct ActiveVoiceCall: Identifiable {
        let id: UUID
        let displayName: String
        let type: CallType
    }

    @Published private(set) var backendState: BackendConnectionState = .checking
    @Published private(set) var connectedFriends: [FriendConnection] = []
    @Published private(set) var importedContacts: [ContactEntry] = []
    @Published private(set) var recentCalls: [CallHistoryEntry] = []
    @Published private(set) var voicemails: [VoicemailEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isImportingContacts = false
    @Published var dialedText = ""
    @Published var alertMessage: String?
    @Published var activeVoiceCall: ActiveVoiceCall?
    @Published private(set) var favoriteFriendIDs: Set<UUID>

    private let friendService: FriendService
    private let contactImportService: ContactImportService
    private let importedContactsStore: ImportedContactsStore
    private let callService: CallService
    private let historyManager: CallHistoryManager
    private let voicemailManager: VoicemailManager
    private let apiClient: APIClient

    init(
        friendService: FriendService,
        contactImportService: ContactImportService,
        importedContactsStore: ImportedContactsStore,
        callService: CallService,
        apiClient: APIClient = .shared
    ) {
        self.friendService = friendService
        self.contactImportService = contactImportService
        self.importedContactsStore = importedContactsStore
        self.callService = callService
        self.apiClient = apiClient
        self.historyManager = CallHistoryManager(
            baseURL: apiClient.baseURL,
            userID: AppEnvironment.currentUserID()
        )
        self.voicemailManager = VoicemailManager(
            baseURL: apiClient.baseURL,
            userID: AppEnvironment.currentUserID()
        )
        self.importedContacts = importedContactsStore.loadContacts()
        self.favoriteFriendIDs = Set(
            (UserDefaults.standard.array(forKey: StorageKeys.favoriteFriendIDs) as? [String] ?? [])
                .compactMap(UUID.init(uuidString:))
        )
    }

    var favoriteFriends: [FriendConnection] {
        connectedFriends.filter { favoriteFriendIDs.contains($0.id) }
    }

    var keypadSuggestions: [FriendConnection] {
        let trimmed = dialedText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return favoriteFriends }

        return connectedFriends.filter { friend in
            friend.displayName.lowercased().contains(trimmed)
            || friend.handle.lowercased().contains(trimmed)
            || friend.id.uuidString.lowercased().contains(trimmed)
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        backendState = await apiClient.health()

        async let friendsTask: [FriendConnection] = loadFriends()
        async let historyTask: Void = historyManager.refresh()
        async let voicemailTask: Void = voicemailManager.refresh()

        connectedFriends = (try? await friendsTask) ?? []
        _ = await (historyTask, voicemailTask)
        recentCalls = historyManager.entries
        voicemails = voicemailManager.voicemails
        importedContacts = importedContactsStore.loadContacts()

        if connectedFriends.isEmpty, importedContacts.isEmpty, case .connected = backendState {
            alertMessage = "No contacts yet. Import contacts or add friends to start calling."
        }
    }

    func importContacts() async {
        guard !isImportingContacts else { return }
        isImportingContacts = true
        defer { isImportingContacts = false }

        let state = await contactImportService.requestAccessIfNeeded()

        switch state {
        case .authorized:
            break
        case .notDetermined:
            alertMessage = "Contacts permission did not complete. Please try again."
            return
        case .denied:
            alertMessage = "Contacts access is denied. Enable it in Settings to use Contacts."
            return
        case .restricted:
            alertMessage = "Contacts access is restricted on this device."
            return
        }

        do {
            importedContacts = try await contactImportService.importContacts(limit: 500)
            importedContactsStore.saveContacts(importedContacts)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func toggleFavorite(_ friend: FriendConnection) {
        if favoriteFriendIDs.contains(friend.id) {
            favoriteFriendIDs.remove(friend.id)
        } else {
            favoriteFriendIDs.insert(friend.id)
        }

        let ids = favoriteFriendIDs.map(\.uuidString)
        UserDefaults.standard.set(ids, forKey: StorageKeys.favoriteFriendIDs)
    }

    func startVoiceCall(with friend: FriendConnection) async {
        do {
            let session = try await callService.startCall(chatID: friend.id, type: .voice)
            activeVoiceCall = ActiveVoiceCall(id: session.id, displayName: friend.displayName, type: .voice)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func startVideoCall(with friend: FriendConnection) async {
        do {
            let callUUID = UUID()
            let roomName = "call-\(friend.id.uuidString.lowercased())-\(AppEnvironment.currentUserID())"
            CallKitManager.shared.startOutgoingCall(uuid: callUUID, handle: friend.displayName)
            try await LiveKitManager.shared.startCall(
                roomName: roomName,
                userId: AppEnvironment.currentUserID(),
                calleeUserId: friend.id.uuidString,
                callerName: AppEnvironment.currentUserID(),
                callUUID: callUUID
            )
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func redial(_ entry: CallHistoryEntry) async {
        guard let friend = resolveFriend(for: entry) else {
            alertMessage = "This recent call can’t be redialed until the contact is available in OneWay."
            return
        }

        if entry.hasVideo {
            await startVideoCall(with: friend)
        } else {
            await startVoiceCall(with: friend)
        }
    }

    func placeDialedCall(video: Bool) async {
        guard let friend = resolveFriend(from: dialedText) else {
            alertMessage = "Enter a saved OneWay contact name, handle, or UUID to place a call."
            return
        }

        if video {
            await startVideoCall(with: friend)
        } else {
            await startVoiceCall(with: friend)
        }
    }

    func playVoicemail(_ entry: VoicemailEntry) async {
        do {
            try await voicemailManager.play(entry)
            voicemails = voicemailManager.voicemails
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func stopVoicemail() {
        voicemailManager.stop()
    }

    func dismissCallSheet() {
        activeVoiceCall = nil
    }

    func historyColor(for entry: CallHistoryEntry) -> Color {
        historyManager.needsAttention(entry) ? .red : .primary
    }

    private func loadFriends() async throws -> [FriendConnection] {
        try await friendService.fetchFriends()
            .filter { $0.status == .connected }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func resolveFriend(for entry: CallHistoryEntry) -> FriendConnection? {
        let remoteID = historyManager.otherParty(entry)
        return connectedFriends.first { $0.id.uuidString.caseInsensitiveCompare(remoteID) == .orderedSame }
    }

    private func resolveFriend(from raw: String) -> FriendConnection? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        return connectedFriends.first { friend in
            friend.displayName.lowercased() == trimmed
            || friend.handle.lowercased() == trimmed
            || friend.id.uuidString.lowercased() == trimmed
        }
    }
}
