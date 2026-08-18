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

    enum CallDialTarget: CustomStringConvertible, Equatable {
        case oneWayId(String)
        case oneWayNumber(String)
        case phoneNumber(String)
        case invalid

        var description: String {
            switch self {
            case .oneWayId(let value): return "oneWayId(\(value))"
            case .oneWayNumber(let value): return "oneWayNumber(\(value))"
            case .phoneNumber(let value): return "phoneNumber(\(value))"
            case .invalid: return "invalid"
            }
        }
    }

    struct ExternalDialRequest: Identifiable, Equatable {
        let id = UUID()
        let phoneNumber: String
        let prefersVideo: Bool
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
    @Published var pendingExternalDialRequest: ExternalDialRequest?
    @Published private(set) var favoriteFriendIDs: Set<UUID>

    private let friendService: FriendService
    private let contactImportService: ContactImportService
    private let importedContactsStore: ImportedContactsStore
    private let callService: CallService
    private let historyManager: CallHistoryManager
    private let voicemailManager: VoicemailManager
    private let apiClient: APIClient
    private let pstnBridgeService: PSTNBridgeService

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
        self.pstnBridgeService = PSTNBridgeService(client: apiClient)
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
            print("📞 CallManager using CallService path")
            let session = try await callService.startCall(chatID: friend.id, type: .voice)
            activeVoiceCall = ActiveVoiceCall(id: session.id, displayName: friend.displayName, type: .voice)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func startVideoCall(with friend: FriendConnection) async {
        do {
            print("📞 CallManager using CallService path")
            let session = try await callService.startCall(chatID: friend.id, type: .video)
            activeVoiceCall = ActiveVoiceCall(id: session.id, displayName: friend.displayName, type: .video)
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
        let input = dialedText
        print("📞 Dial target:", input)
        let target = classifyCallTarget(input)
        print("📞 Classified as:", target)

        switch target {
        case .oneWayId(let id):
            await startOneWayNativeCall(to: id, video: video)
        case .oneWayNumber(let number):
            await startOneWayNativeCall(to: number, video: video)
        case .phoneNumber(let phone):
            print("📞 External phone number selected")
            pendingExternalDialRequest = ExternalDialRequest(phoneNumber: phone, prefersVideo: video)
        case .invalid:
            alertMessage = "Enter a OneWay ID, OneWay number, or phone number."
        }
    }

    func confirmExternalDial() {
        guard let request = pendingExternalDialRequest else { return }
        print("📞 Network type:", CallNetworkType.pstnBridge.statusLabel)
        pendingExternalDialRequest = nil

        Task {
            do {
                let response = try await pstnBridgeService.startPSTNCall(to: request.phoneNumber, fromNumber: nil)
                if (response.provider ?? "stub") == "stub" {
                    alertMessage = "OneWay external phone bridge is not connected yet. Add Twilio/Telnyx credentials to place real off-network calls."
                } else {
                    alertMessage = "Using External Network — connecting through OneWay bridge."
                }
            } catch {
                alertMessage = "Failed to start OneWay external network call: \(error.localizedDescription)"
            }
        }
    }

    func cancelExternalDial() {
        pendingExternalDialRequest = nil
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


    private func classifyCallTarget(_ input: String) -> CallDialTarget {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = raw.components(separatedBy: .whitespacesAndNewlines).joined()

        guard !compact.isEmpty else {
            return .invalid
        }

        if compact.hasPrefix("@") {
            return .oneWayId(compact.lowercased())
        }

        if compact.uppercased().hasPrefix("OW-") {
            return .oneWayNumber(compact.uppercased())
        }

        let digits = compact.filter(\.isNumber)

        if digits.count >= 7 {
            return .phoneNumber(digits)
        }

        return .invalid
    }

    private func startOneWayNativeCall(to identity: String, video: Bool) async {
        print("📞 Starting OneWay-native call via backend")
        print("📞 Network type:", CallNetworkType.oneWayNative.statusLabel)

        guard let friend = resolveFriend(from: identity) else {
            alertMessage = "This OneWay target is not yet in your connected contacts. Add/accept them first."
            return
        }

        if video {
            await startVideoCall(with: friend)
        } else {
            await startVoiceCall(with: friend)
        }
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
