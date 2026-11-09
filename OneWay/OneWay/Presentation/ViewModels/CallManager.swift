import Foundation
import SwiftUI
import Combine
import OSLog
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

private enum PSTNFlowError: LocalizedError {
    case timeout(operation: String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .timeout(operation, seconds):
            return "Live PSTN failed: \(operation) timed out after \(seconds)s."
        }
    }
}

private actor PSTNNetworkExecutor {
    static let shared = PSTNNetworkExecutor()

    func fetchPreflight() async throws -> PSTNBridgePreflight {
        try await PSTNBridgePreflightService.shared.fetchStatus()
    }

    func startCall(
        to phoneNumber: String,
        fromNumber: String?,
        callerCallKitUUID: UUID?,
        timeoutSeconds: Int
    ) async throws -> PSTNCallStartResponse {
        try await withTimeout(seconds: timeoutSeconds, operation: "POST /api/pstn/calls/start") {
            try await PSTNBridgeService.shared.startPSTNCall(
                to: phoneNumber,
                fromNumber: fromNumber,
                callerCallKitUUID: callerCallKitUUID
            )
        }
    }

    func fetchCallStatus(callSessionId: String) async throws -> PSTNCallStatusResponse {
        try await PSTNBridgeService.shared.fetchPSTNCallStatus(callSessionId: callSessionId)
    }

    func endCall(callSessionId: String) async throws {
        try await PSTNBridgeService.shared.endPSTNCall(callSessionId: callSessionId)
    }

    private func withTimeout<T: Sendable>(
        seconds: Int,
        operation: String,
        task: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await task()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw PSTNFlowError.timeout(operation: operation, seconds: seconds)
            }

            guard let value = try await group.next() else {
                throw PSTNFlowError.timeout(operation: operation, seconds: seconds)
            }
            group.cancelAll()
            return value
        }
    }
}

@MainActor
final class CallManager: ObservableObject {
    private enum StorageKeys {
        static let favoriteFriendIDs = "phone.favoriteFriendIDs.v2"
    }

    enum DialTarget: Equatable {
        case onewayId(String)
        case onewayNumber(String)
        case phoneNumber(String)
        case invalid
    }

    struct ActiveVoiceCall: Identifiable {
        let id: UUID
        let displayName: String
        let type: CallType
        let routeLabel: String?
        let statusText: String?

        init(
            id: UUID,
            displayName: String,
            type: CallType,
            routeLabel: String? = nil,
            statusText: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.type = type
            self.routeLabel = routeLabel
            self.statusText = statusText
        }
    }

    struct ExternalCallConfirmation: Identifiable {
        let id = UUID()
        let phoneNumber: String
        let title: String
        let message: String
        let actionTitle: String

        init(
            phoneNumber: String,
            title: String = "External Network Call",
            message: String = "This call will use OneWay's external phone network instead of your iPhone carrier.",
            actionTitle: String = "Use OneWay External Network"
        ) {
            self.phoneNumber = phoneNumber
            self.title = title
            self.message = message
            self.actionTitle = actionTitle
        }
    }

    @Published private(set) var backendState: BackendConnectionState = .checking
    @Published private(set) var connectedFriends: [FriendConnection] = []
    @Published private(set) var contactsError: OneWayNetworkError?
    @Published private(set) var hasLoadedOneWayContacts = false
    @Published private(set) var importedContacts: [ContactEntry] = []
    @Published private(set) var recentCalls: [CallHistoryEntry] = []
    @Published private(set) var voicemails: [VoicemailEntry] = []
    @Published private(set) var myNumbers: [OneWayNumber] = []
    @Published private(set) var myIdentity: OneWayIdentity?
    @Published private(set) var oneWaySearchResults: [OneWayUserSearchResult] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isImportingContacts = false
    @Published private(set) var contactPermissionState: ContactPermissionState
    @Published var isShowingContactPicker = false
    @Published var dialedText = ""
    @Published var alertMessage: String?
    @Published var activeVoiceCall: ActiveVoiceCall?
    @Published var externalCallConfirmation: ExternalCallConfirmation?
    @Published private(set) var isStartingExternalPSTNCall = false
    @Published private(set) var favoriteFriendIDs: Set<UUID>
    let signedInUserID: String

    private let friendService: FriendService
    private let contactImportService: ContactImportService
    private let importedContactsStore: ImportedContactsStore
    private let callService: CallService
    private let historyManager: CallHistoryManager
    private let voicemailManager: VoicemailManager
    private let apiClient: APIClient
    private let numberService: OneWayNumberService
    private let identityService: OneWayIdentityService
    private let pstnNetworkExecutor: PSTNNetworkExecutor
    private let connectivityLogger = Logger(subsystem: "app.oneway.ios", category: "backend-lifecycle")
    private var searchTask: Task<Void, Never>?
    private var pstnStatusPollTask: Task<Void, Never>?
    private var activePSTNCallSessionID: String?
    private var activePSTNUICallID: UUID?

    init(
        friendService: FriendService,
        contactImportService: ContactImportService,
        importedContactsStore: ImportedContactsStore,
        callService: CallService,
        apiClient: APIClient = .shared,
        numberService: OneWayNumberService = .shared,
        identityService: OneWayIdentityService = .shared
    ) {
        let signedInUserID = AppEnvironment.currentUserID()
        self.friendService = friendService
        self.contactImportService = contactImportService
        self.importedContactsStore = importedContactsStore
        self.callService = callService
        self.apiClient = apiClient
        self.numberService = numberService
        self.identityService = identityService
        self.pstnNetworkExecutor = .shared
        self.signedInUserID = signedInUserID
        self.historyManager = CallHistoryManager(
            baseURL: apiClient.baseURL,
            userID: signedInUserID
        )
        self.voicemailManager = VoicemailManager(
            baseURL: apiClient.baseURL,
            userID: signedInUserID
        )
        self.contactPermissionState = contactImportService.permissionState()
        self.importedContacts = importedContactsStore.loadContacts()
        self.favoriteFriendIDs = Set(
            (UserDefaults.standard.array(forKey: StorageKeys.favoriteFriendIDs) as? [String] ?? [])
                .compactMap(UUID.init(uuidString:))
        )
        self.connectedFriends = loadCachedFriends(userID: signedInUserID)
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

    var primaryOneWayNumber: OneWayNumber? {
        myNumbers.first(where: \.isPrimary) ?? myNumbers.first
    }

    var canImportContacts: Bool {
        contactPermissionState == .notDetermined || contactPermissionState == .authorized
    }

    var contactsImportButtonTitle: String {
        if isImportingContacts {
            return "Importing…"
        }

        switch contactPermissionState {
        case .authorized:
            return importedContacts.isEmpty ? "Import from iPhone Contacts" : "Refresh Imported Contacts"
        case .notDetermined:
            return "Allow Contacts Access"
        case .denied:
            return "Open Settings to Allow Contacts"
        case .restricted:
            return "Contacts Unavailable on This Device"
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        backendState = await apiClient.health()
        contactPermissionState = contactImportService.permissionState()
        await reloadBackendData()
    }

    /// Keeps the Calls experience attached to the backend for as long as its
    /// view is alive. Temporary outages use bounded exponential backoff; a
    /// successful probe immediately refreshes backend-owned data.
    func runConnectionLifecycle() async {
        await refreshAll()

        var consecutiveFailures = isBackendConnected ? 0 : 1

        while !Task.isCancelled {
            let delaySeconds: UInt64
            if isBackendConnected {
                delaySeconds = 30
            } else {
                delaySeconds = UInt64(min(30, 1 << min(consecutiveFailures, 4)))
            }

            do {
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            } catch {
                return
            }

            let wasConnected = isBackendConnected
            backendState = await apiClient.health()

            if isBackendConnected {
                consecutiveFailures = 0
                if !wasConnected {
                    connectivityLogger.notice("Backend connection recovered; refreshing Calls data")
                    await refreshAfterReconnect()
                }
            } else {
                consecutiveFailures += 1
                connectivityLogger.warning(
                    "Backend remains unavailable; retrying with bounded exponential backoff"
                )
            }
        }
    }

    private var isBackendConnected: Bool {
        if case .connected = backendState { return true }
        return false
    }

    private func refreshAfterReconnect() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        contactPermissionState = contactImportService.permissionState()
        await reloadBackendData()
    }

    private func reloadBackendData() async {
        async let friendsTask: [FriendConnection] = loadFriends()
        async let historyTask: Void = historyManager.refresh()
        async let voicemailTask: Void = voicemailManager.refresh()
        async let numbersTask: OneWayNumbersResponse = numberService.fetchMyNumbers()
        async let identityTask: OneWayIdentity = identityService.fetchMyIdentity()

        do {
            let friends = try await friendsTask
            connectedFriends = friends
            saveCachedFriends(friends, userID: signedInUserID)
            contactsError = nil
            hasLoadedOneWayContacts = true
        } catch {
            contactsError = OneWayNetworkError.classify(error)
            hasLoadedOneWayContacts = !connectedFriends.isEmpty
#if DEBUG
            print(
                "[ContactsAPI] refresh.failed",
                "cachedCount=\(connectedFriends.count)",
                "category=\(contactsError.map(String.init(describing:)) ?? "unknown")",
                "detail=\(PrivacyLog.redact(error.localizedDescription))"
            )
#endif
        }
        _ = await (historyTask, voicemailTask)
        recentCalls = historyManager.entries
        voicemails = voicemailManager.voicemails
        importedContacts = importedContactsStore.loadContacts()
        if let numbersResponse = try? await numbersTask {
            myNumbers = numbersResponse.numbers
        }
        myIdentity = try? await identityTask

        // A normal empty result or transient refresh failure is represented
        // inline by PhoneContactsView, never as a blocking alert.
    }

    func importContacts() async {
        if contactPermissionState == .denied {
            openAppSettings()
            return
        }

        if contactPermissionState == .restricted {
            alertMessage = "Contacts access is restricted on this device."
            return
        }

        guard !isImportingContacts else { return }
        isImportingContacts = true
        defer { isImportingContacts = false }

        let state = await contactImportService.requestAccessIfNeeded()
        contactPermissionState = state

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
            if importedContacts.isEmpty {
                isShowingContactPicker = true
            } else {
                alertMessage = "Imported \(importedContacts.count) contact\(importedContacts.count == 1 ? "" : "s")."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func importSelectedContacts(_ contacts: [ContactEntry]) {
        guard !contacts.isEmpty else {
            alertMessage = "No iPhone contacts were selected."
            return
        }

        var merged: [String: ContactEntry] = Dictionary(
            uniqueKeysWithValues: importedContacts.map { ($0.id, $0) }
        )
        for contact in contacts {
            merged[contact.id] = contact
        }

        importedContacts = merged.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        importedContactsStore.saveContacts(importedContacts)
        alertMessage = "Imported \(contacts.count) selected contact\(contacts.count == 1 ? "" : "s")."
    }

    func openAppSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
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
            alertMessage = "Unable to start call: \(error.localizedDescription)"
        }
    }

    func startVideoCall(with friend: FriendConnection) async {
        do {
            let session = try await callService.startCall(chatID: friend.id, type: .video)
            activeVoiceCall = ActiveVoiceCall(
                id: session.id,
                displayName: friend.displayName,
                type: .video,
                routeLabel: "OneWay Signal",
                statusText: "Starting video..."
            )
        } catch {
            alertMessage = "Unable to start video: \(error.localizedDescription)"
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
        if let friend = resolveFriend(from: dialedText) {
            if video {
                await startVideoCall(with: friend)
            } else {
                await startVoiceCall(with: friend)
            }
            return
        }

        switch classifyDialTarget(dialedText) {
        case .onewayId(let id):
            await startOneWayNetworkCall(to: id, video: video)
        case .onewayNumber(let number):
            await startOneWayNetworkCall(to: number, video: video)
        case .phoneNumber(let phone):
            if video {
                alertMessage = "Video calls require a OneWay ID or OneWay number."
            } else {
                await requestExternalNetworkCall(phone)
            }
        case .invalid:
            alertMessage = "Enter a OneWay ID, OneWay number, or phone number."
        }
    }

    func updateDialedText(_ value: String) {
        dialedText = value
        searchTask?.cancel()

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldSearchOneWayUsers(for: trimmed) else {
            oneWaySearchResults = []
            return
        }

        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            do {
                self.oneWaySearchResults = try await self.numberService.searchUsers(query: trimmed)
            } catch {
                self.oneWaySearchResults = []
            }
        }
    }

    func selectSearchResult(_ result: OneWayUserSearchResult) {
        dialedText = result.onewayId ?? result.primaryNumber ?? result.displayName ?? result.id
        oneWaySearchResults = []
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
        stopPSTNStatusPolling()
        activeVoiceCall = nil
    }

    func historyColor(for entry: CallHistoryEntry) -> Color {
        historyManager.needsAttention(entry) ? .red : .primary
    }

    private func loadFriends() async throws -> [FriendConnection] {
        let loaded = try await friendService.fetchFriends()
            .filter { $0.status == .connected }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return loaded
    }

    private func loadCachedFriends(userID: String) -> [FriendConnection] {
        let key = "OneWay.CallContacts.\(userID)"
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([FriendConnection].self, from: data)) ?? []
    }

    private func saveCachedFriends(_ friends: [FriendConnection], userID: String) {
        guard let data = try? JSONEncoder().encode(friends) else { return }
        UserDefaults.standard.set(data, forKey: "OneWay.CallContacts.\(userID)")
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

    private func resolveOneWayTarget(from raw: String) -> String? {
        switch classifyDialTarget(raw) {
        case .onewayId(let id):
            return id
        case .onewayNumber(let number):
            return number
        case .phoneNumber, .invalid:
            return nil
        }
    }

    func classifyDialTarget(_ input: String) -> DialTarget {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }

        if trimmed.hasPrefix("@") {
            let lowercased = trimmed.lowercased()
            if lowercased.range(of: #"^@[a-z0-9._-]{2,32}$"#, options: .regularExpression) != nil {
                return .onewayId(lowercased)
            }
            return .invalid
        }

        let uppercased = trimmed.uppercased()
        if uppercased.hasPrefix("OW-"),
           uppercased.range(of: #"^OW-[0-9]+(?:-[0-9]+)*$"#, options: .regularExpression) != nil,
           uppercased.filter(\.isNumber).count >= 6 {
            return .onewayNumber(uppercased)
        }

        let phone = normalizePhoneNumber(trimmed)
        if phone.count >= 7 {
            return .phoneNumber(phone)
        }

        return .invalid
    }

    func callImportedContact(_ contact: ContactEntry) async {
        guard let target = resolveOneWayTarget(from: contact.phoneNumber) else {
            alertMessage = "This contact is not on OneWay yet. Invite them to OneWay before calling."
            return
        }

        dialedText = target
        oneWaySearchResults = []
        await startOneWayNetworkCall(to: target, video: false)
    }

    func importedContactIsOneWayReachable(_ contact: ContactEntry) -> Bool {
        resolveOneWayTarget(from: contact.phoneNumber) != nil
    }

    func importedContactHasPhoneNumber(_ contact: ContactEntry) -> Bool {
        switch classifyDialTarget(contact.phoneNumber) {
        case .phoneNumber:
            return true
        case .onewayId, .onewayNumber, .invalid:
            return false
        }
    }

    func importedContactActionTitle(_ contact: ContactEntry) -> String {
        importedContactIsOneWayReachable(contact) ? "Call on OneWay" : "Invite to OneWay"
    }

    func callImportedContactPhone(_ contact: ContactEntry) async {
        switch classifyDialTarget(contact.phoneNumber) {
        case .phoneNumber(let phone):
            await requestExternalNetworkCall(phone)
        case .onewayId, .onewayNumber, .invalid:
            alertMessage = "This contact does not have a regular phone number."
        }
    }

    func dismissExternalCallConfirmation() {
        externalCallConfirmation = nil
    }

    func confirmExternalCall() async {
        guard !isStartingExternalPSTNCall else { return }
        guard let pending = externalCallConfirmation else { return }
        externalCallConfirmation = nil
        let selectedOneWayNumber = primaryOneWayNumber?.number

        isStartingExternalPSTNCall = true
        defer { isStartingExternalPSTNCall = false }

        await startBridgeFallbackCall(to: pending.phoneNumber, fromNumber: selectedOneWayNumber)
    }

    func confirmExternalDial() async {
        await confirmExternalCall()
    }

    private func selectedCallerIdentity() -> String? {
        guard let identity = myIdentity else { return nil }
        switch identity.preferredCallerIdentity {
        case .onewayId:
            return identity.onewayId
        case .number:
            return primaryOneWayNumber?.number ?? identity.onewayId
        }
    }

    private func startOneWayNetworkCall(to target: String, video: Bool) async {
        if await startResolvedOneWaySignalCall(to: target, video: video) {
            return
        }

        let fromNumber = primaryOneWayNumber?.number
        let fromIdentity = selectedCallerIdentity()

        guard fromNumber != nil || fromIdentity != nil else {
            alertMessage = "OneWay network unavailable. Try again when connected."
            return
        }

        var canonicalCallUUID: UUID?
        do {
            let response = try await numberService.startOneWayNetworkCall(
                fromIdentity: fromIdentity,
                fromNumber: fromNumber,
                to: target,
                hasVideo: video
            )

            // `/calls/start` creates the authoritative backend CallSession.
            // Its ID must also be the CallKit and LiveKit call UUID; using a
            // fresh local UUID makes remote `call:ended` events target a
            // different session and leaves the other phone's UI ringing.
            guard let callUUID = UUID(uuidString: response.callId) else {
                throw APIClientError.invalidResponse
            }
            canonicalCallUUID = callUUID

            let callType: CallType = video ? .video : .voice
            let session = try await callService.adoptOutgoingCall(
                sessionID: callUUID,
                chatID: callUUID,
                type: callType
            )
            activeVoiceCall = ActiveVoiceCall(
                id: session.id,
                displayName: response.callerDisplay,
                type: callType,
                routeLabel: "OneWay Signal",
                statusText: video ? "Starting video..." : "Calling..."
            )
        } catch {
            if let canonicalCallUUID {
                CallKitManager.shared.endCall(uuid: canonicalCallUUID)
            }
            alertMessage = error.localizedDescription
        }
    }

    private func startResolvedOneWaySignalCall(to target: String, video: Bool) async -> Bool {
        do {
            guard let result = try await matchingOneWayUser(for: target) else {
                return false
            }
            guard let calleeID = UUID(uuidString: result.id) else {
                return false
            }

            let callType: CallType = video ? .video : .voice
            let session = try await callService.startCall(chatID: calleeID, type: callType)
            activeVoiceCall = ActiveVoiceCall(
                id: session.id,
                displayName: result.displayName ?? result.onewayId ?? result.primaryNumber ?? (video ? "OneWay Video" : "OneWay Call"),
                type: callType,
                routeLabel: "OneWay Signal",
                statusText: video ? "Starting video..." : "Calling..."
            )
            return true
        } catch {
            alertMessage = error.localizedDescription
            return true
        }
    }

    private func matchingOneWayUser(for target: String) async throws -> OneWayUserSearchResult? {
        let normalized = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let users = try await numberService.searchUsers(query: normalized)
        let lowercased = normalized.lowercased()
        let uppercased = normalized.uppercased()

        if let exact = users.first(where: { result in
            result.id.caseInsensitiveCompare(normalized) == .orderedSame
                || result.onewayId?.lowercased() == lowercased
                || result.primaryNumber?.uppercased() == uppercased
        }) {
            return exact
        }

        return users.count == 1 ? users[0] : nil
    }

    private func requestExternalNetworkCall(_ phone: String) async {
        let normalized = normalizePhoneNumber(phone)
        guard normalized.count >= 7 else {
            alertMessage = "Invalid phone number."
            return
        }
        guard hasCallAuthorization(forPath: "api/pstn/preflight") else {
            alertMessage = "Your session expired. Please sign in again before starting a call."
            debugPSTN("auth.not_ready path=api/pstn/preflight baseURL=\(apiClient.baseURL.absoluteString)")
            return
        }

        debugPSTN("backend baseURL: \(apiClient.baseURL.absoluteString)")
        #if DEBUG
        if !isUsingDevPSTNBackend(apiClient.baseURL) {
            let configMessage = "warning: PSTN is not using a local dev endpoint. Current baseURL: \(apiClient.baseURL.absoluteString)"
            debugPSTN(configMessage)
        }
        #endif

        let preflight: PSTNBridgePreflight
        do {
            preflight = try await pstnNetworkExecutor.fetchPreflight()
            logPSTNPreflight(preflight)
        } catch {
            debugPSTN("preflight request failed: \(error.localizedDescription)")
            alertMessage = "Unable to check external network preflight: \(error.localizedDescription)"
            return
        }

        if preflight.ok && preflight.mode.caseInsensitiveCompare("live") == .orderedSame {
            logSelectedRoute("live_pstn")
            #if DEBUG
            print("PSTN route selected: live_pstn")
            #endif
            guard !isStartingExternalPSTNCall else { return }
            isStartingExternalPSTNCall = true
            defer { isStartingExternalPSTNCall = false }
            await startLivePSTNCall(
                to: normalized,
                fromNumber: primaryOneWayNumber?.number,
                preflight: preflight
            )
            return
        }

        if isMisconfiguredPSTNPreflight(preflight) {
            alertMessage = preflightFailureMessage(preflight)
            debugPSTN("preflight misconfigured before fallback: \(preflightFailureMessage(preflight))")
            return
        }

        logSelectedRoute("bridge_fallback")
        triggerBridgeFallback(for: normalized, reason: livePSTNUnavailableMessage(preflight))
    }

    private func startBridgeFallbackCall(
        to phone: String,
        fromNumber: String?
    ) async {
        logSelectedRoute("bridge_fallback")
        await startLivePSTNCall(
            to: phone,
            fromNumber: fromNumber,
            preflight: nil,
            allowNonLivePreflight: true,
            allowFallbackPrompt: false
        )
    }

    private func startLivePSTNCall(
        to phone: String,
        fromNumber: String?,
        preflight: PSTNBridgePreflight? = nil,
        allowNonLivePreflight: Bool = false,
        allowFallbackPrompt: Bool = true
    ) async {
        let normalized = normalizePhoneNumber(phone)
        guard normalized.count >= 7 else {
            alertMessage = "Invalid phone number."
            return
        }
        stopPSTNStatusPolling()

        let resolvedPreflight: PSTNBridgePreflight
        if let preflight {
            resolvedPreflight = preflight
        } else {
            do {
                resolvedPreflight = try await pstnNetworkExecutor.fetchPreflight()
                logPSTNPreflight(resolvedPreflight)
            } catch {
                debugPSTN("preflight before calls/start failed: \(error.localizedDescription)")
                alertMessage = "Unable to check external network preflight: \(error.localizedDescription)"
                return
            }
        }

        if !allowNonLivePreflight && !(resolvedPreflight.ok && resolvedPreflight.mode.caseInsensitiveCompare("live") == .orderedSame) {
            let reason = livePSTNUnavailableMessage(resolvedPreflight)
            debugPSTN("live preflight rejected before calls/start: \(reason)")
            handleLivePSTNFailure(
                phone: normalized,
                reason: reason,
                allowFallbackPrompt: allowFallbackPrompt
            )
            return
        }

        if isMisconfiguredPSTNPreflight(resolvedPreflight) {
            let reason = preflightFailureMessage(resolvedPreflight)
            debugPSTN("misconfigured preflight rejected before calls/start: \(reason)")
            alertMessage = reason
            return
        }

        if resolvedPreflight.provider.caseInsensitiveCompare("stub") == .orderedSame {
            let reason = "OneWay external phone bridge is not connected yet. Add Twilio/Telnyx credentials to place real off-network calls."
            handleLivePSTNFailure(
                phone: normalized,
                reason: reason,
                allowFallbackPrompt: allowFallbackPrompt
            )
            return
        }

        let endpoint = apiClient.baseURL.appendingPathComponent("api/pstn/calls/start").absoluteString
        logBackendEndpoint(endpoint)
        guard hasCallAuthorization(forPath: "api/pstn/calls/start") else {
            alertMessage = "Your session expired. Please sign in again before starting a call."
            debugPSTN("auth.not_ready path=api/pstn/calls/start baseURL=\(apiClient.baseURL.absoluteString)")
            return
        }
        #if DEBUG
        print("Starting PSTN backend request")
        #endif

        let callUUID = UUID()
        do {
            let response = try await pstnNetworkExecutor.startCall(
                to: normalized,
                fromNumber: fromNumber,
                callerCallKitUUID: callUUID,
                timeoutSeconds: 15
            )
            logPSTNResponse(response)
            #if DEBUG
            print("PSTN backend response:", sanitizedPSTNStartSummary(response))
            #endif

            let provider = response.provider.lowercased()
            let status = response.status.lowercased()
            let mediaBridgeStatus = response.mediaBridgeStatus?.lowercased()
            let providerLabel = providerDisplayName(provider)
            let liveSIPDispatchReady = hasLivePSTNParticipant(
                sipParticipantId: response.sipParticipantId,
                participantIdentity: response.participantIdentity
            )

            if shouldTriggerBridgeFallbackFromStartResponse(response) {
                let reason = fallbackReasonFromStartResponse(response)
                handleLivePSTNFailure(
                    phone: normalized,
                    reason: "Live PSTN failed: \(reason)",
                    allowFallbackPrompt: allowFallbackPrompt
                )
                return
            }

            let waitingForCalleeAcceptance = isWaitingForPSTNDisclosureAcceptance(status)
            guard status == "initiated" || waitingForCalleeAcceptance else {
                stopPSTNStatusPolling()
                if let message = response.message, !message.isEmpty {
                    alertMessage = message
                } else {
                    alertMessage = "External network call could not be started."
                }
                return
            }

            activePSTNCallSessionID = response.callSessionId
            activePSTNUICallID = callUUID

            CallKitManager.shared.startOutgoingCall(
                uuid: callUUID,
                handle: "External Network Call",
                hasVideo: false,
                callSessionId: response.callSessionId
            )
            await CallKitManager.shared.waitForAudioSessionActivation(timeoutSeconds: 3)
            if waitingForCalleeAcceptance {
                setExternalCallStatus("Calling through OneWay. Waiting for the recipient to accept.", id: callUUID)
            } else if liveSIPDispatchReady {
                debugPSTN(
                    "live PSTN ready from start response: callSessionId=\(response.callSessionId) " +
                    "sipParticipantId=\(response.sipParticipantId ?? "nil") " +
                    "participantIdentity=\(response.participantIdentity ?? "nil")"
                )
                setExternalCallStatus("External network call started. Connecting audio...", id: callUUID)
            } else {
                setExternalCallStatus("Connecting to external network...", id: callUUID)
            }
            startPSTNStatusPolling(
                callSessionId: response.callSessionId,
                phoneNumber: normalized,
                providerLabel: providerLabel,
                uiCallID: callUUID,
                allowFallbackPrompt: allowFallbackPrompt
            )

            let hasBridgeToken = (response.token?.isEmpty == false) && (response.liveKitUrl?.isEmpty == false)
            let hasRoom = (response.roomName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            let shouldAttemptBridgeJoin = mediaBridgeStatus != "failed" && mediaBridgeStatus != "not_configured"

            guard shouldAttemptBridgeJoin else {
                return
            }

            do {
                var didConnectLiveKitAudio = false
                if hasBridgeToken, hasRoom,
                   let roomName = response.roomName,
                   let token = response.token,
                   let liveKitUrl = response.liveKitUrl {
                    try await LiveKitManager.shared.connectExternalBridge(
                        roomName: roomName,
                        userId: AppEnvironment.currentUserID(),
                        liveKitURL: liveKitUrl,
                        token: token,
                        callUUID: callUUID
                    )
                    didConnectLiveKitAudio = true
                } else if hasRoom, let roomName = response.roomName {
                    try await LiveKitManager.shared.startCall(
                        roomName: roomName,
                        userId: AppEnvironment.currentUserID(),
                        callerName: "External Network Call",
                        callUUID: callUUID
                    )
                    didConnectLiveKitAudio = true
                }

                if didConnectLiveKitAudio {
                    debugPSTN(
                        "caller.livekit.joined callSessionId=\(response.callSessionId) " +
                        "callKitUUID=\(callUUID.uuidString) roomName=\(response.roomName ?? "nil")"
                    )
                    if waitingForCalleeAcceptance {
                        setExternalCallStatus("Calling through OneWay. Waiting for the recipient to accept.", id: callUUID)
                    } else {
                        setExternalCallStatus("Waiting for external network audio...", id: callUUID)
                    }
                }
            } catch {
                CallKitManager.shared.endCall(uuid: callUUID)
                setExternalCallStatus("External network audio connection failed.", id: callUUID)
                alertMessage = userSafeCallMessage(for: error, fallback: "Unable to connect to the secure call room.")
                #if DEBUG
                print("PSTN failed:", error)
                #endif

                if shouldTriggerBridgeFallback(for: error) {
                    handleLivePSTNFailure(
                        phone: normalized,
                        reason: "Live PSTN failed: \(error.localizedDescription)",
                        allowFallbackPrompt: allowFallbackPrompt
                    )
                }
                return
            }
        } catch {
            debugPSTN("calls/start failed: \(error.localizedDescription)")
            #if DEBUG
            print("PSTN failed:", error)
            #endif
            stopPSTNStatusPolling()
            if shouldTriggerBridgeFallback(for: error) {
                handleLivePSTNFailure(
                    phone: normalized,
                    reason: "Live PSTN unavailable: \(error.localizedDescription)",
                    allowFallbackPrompt: allowFallbackPrompt
                )
            } else {
                alertMessage = userSafeCallMessage(for: error, fallback: "OneWay calling service is temporarily unreachable.")
            }
        }
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "twilio":
            return "Twilio"
        case "telnyx":
            return "Telnyx"
        case "sinch":
            return "Sinch"
        case "stub":
            return "Stub"
        default:
            return provider.uppercased()
        }
    }

    private func preflightFailureMessage(_ preflight: PSTNBridgePreflight) -> String {
        var lines: [String] = ["OneWay Bridge is not ready yet."]

        if !preflight.missing.isEmpty {
            lines.append("Missing: \(preflight.missing.joined(separator: ", "))")
        }

        if !preflight.warnings.isEmpty {
            lines.append("Warnings: \(preflight.warnings.joined(separator: " | "))")
        }

        return lines.joined(separator: "\n")
    }

    private func isMisconfiguredPSTNPreflight(_ preflight: PSTNBridgePreflight) -> Bool {
        !preflight.ok && preflight.mode.caseInsensitiveCompare("misconfigured") == .orderedSame
    }

    private func livePSTNUnavailableMessage(_ preflight: PSTNBridgePreflight) -> String {
        let detail = preflightFailureMessage(preflight)
        if let firstLine = detail.split(separator: "\n").first {
            if firstLine.lowercased().contains("not ready") {
                return "Live PSTN unavailable: \(detail)"
            }
        }
        return "Live PSTN unavailable: \(detail)"
    }

    private func handleLivePSTNFailure(
        phone: String,
        reason: String,
        allowFallbackPrompt: Bool
    ) {
        if allowFallbackPrompt {
            triggerBridgeFallback(for: phone, reason: reason)
            return
        }
        alertMessage = reason
    }

    private func triggerBridgeFallback(for phone: String, reason: String) {
        #if DEBUG
        print("Bridge fallback triggered")
        #endif
        // Keep bridge confirmation as the only presented alert UI.
        let confirmation = ExternalCallConfirmation(
            phoneNumber: phone,
            title: "External Network Call",
            message: "\(reason)\n\nUse OneWay Bridge fallback?",
            actionTitle: "Use Bridge Fallback"
        )
        presentExternalCallConfirmation(confirmation, dismissActiveCallSheet: activeVoiceCall != nil)
    }

    private func presentExternalCallConfirmation(
        _ confirmation: ExternalCallConfirmation,
        dismissActiveCallSheet: Bool = false
    ) {
        alertMessage = nil
        externalCallConfirmation = nil

        guard dismissActiveCallSheet else {
            externalCallConfirmation = confirmation
            return
        }

        // SwiftUI cannot reliably present an alert over the active call sheet in
        // the same run loop. Dismiss first, then offer the fallback.
        activeVoiceCall = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.externalCallConfirmation == nil, self.activeVoiceCall == nil else {
                return
            }
            self.externalCallConfirmation = confirmation
        }
    }

    private func shouldTriggerBridgeFallback(for error: Error) -> Bool {
        shouldTriggerBridgeFallbackReason(error.localizedDescription) || isTimeoutError(error)
    }

    private func shouldTriggerBridgeFallbackReason(_ reason: String) -> Bool {
        let text = reason.lowercased()
        return text.contains("pstn_preflight_failed")
            || text.contains("oneway bridge is not ready")
            || text.contains("sip participant")
            || text.contains("livekit bridge setup failed")
            || text.contains("media bridge failed")
            || text.contains("connection timeout")
            || text.contains("timed out")
            || text.contains("timeout")
    }

    private func shouldTriggerBridgeFallbackFromStartResponse(_ response: PSTNCallStartResponse) -> Bool {
        let status = response.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mediaBridgeStatus = response.mediaBridgeStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let message = response.message?.lowercased() ?? ""

        if isWaitingForPSTNDisclosureAcceptance(status) {
            return false
        }
        if message.contains("pstn_preflight_failed") {
            return true
        }
        if mediaBridgeStatus == "failed" || mediaBridgeStatus == "not_configured" {
            return true
        }
        if message.contains("sip participant") || message.contains("livekit bridge setup failed") || message.contains("media bridge failed") {
            return true
        }
        if status == "failed" && (message.contains("sip") || message.contains("bridge")) {
            return true
        }
        return false
    }

    private func fallbackReasonFromStartResponse(_ response: PSTNCallStartResponse) -> String {
        let message = response.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return message
        }

        let bridgeStatus = response.mediaBridgeStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if bridgeStatus == "failed" || bridgeStatus == "not_configured" {
            return "SIP participant creation failed."
        }

        return "External network setup failed."
    }

    private func isUsingDevPSTNBackend(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "api.oneway.app" || host == "api.oneway.is" {
            return false
        }

        let port = url.port ?? 80
        return url.scheme?.lowercased() == "http" && (port == 3214 || port == 3000)
    }

    private func logPSTNPreflight(_ preflight: PSTNBridgePreflight) {
        #if DEBUG
        print("PSTN preflight:", preflight)
        #endif
    }

    private func logSelectedRoute(_ route: String) {
        #if DEBUG
        print("Selected route:", route)
        #endif
    }

    private func logBackendEndpoint(_ endpoint: String) {
        #if DEBUG
        print("Calling backend:", PrivacyLog.redact(endpoint))
        #endif
    }

    private func logPSTNResponse(_ response: PSTNCallStartResponse) {
        #if DEBUG
        print("PSTN response:", sanitizedPSTNStartSummary(response))
        #endif
    }

    private func logPSTNStatusSnapshot(_ status: PSTNCallStatusResponse) {
        #if DEBUG
        print(
            "PSTN status snapshot: callSessionId=\(PrivacyLog.shortID(status.callSessionId)) " +
            "status=\(status.status) mediaBridgeStatus=\(status.mediaBridgeStatus ?? "nil") " +
            "provider=\(status.provider) providerCallId=\(PrivacyLog.shortID(status.providerCallId)) " +
            "sipParticipantId=\(PrivacyLog.shortID(status.sipParticipantId)) " +
            "participantIdentity=\(PrivacyLog.shortID(status.participantIdentity)) " +
            "calleeDisclosure=\(status.calleeDisclosure?.status ?? "nil") " +
            "failureReason=\(PrivacyLog.redact(status.failureReason ?? "nil"))"
        )
        #endif
    }

    private func hasLivePSTNParticipant(sipParticipantId: String?, participantIdentity: String?) -> Bool {
        let hasSIPParticipantId = !(sipParticipantId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasParticipantIdentity = !(participantIdentity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasSIPParticipantId && hasParticipantIdentity
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("timed out")
            || text.contains("timeout")
    }

    private func isPSTNStatusEndpointMissing(_ error: Error) -> Bool {
        guard case let APIClientError.server(statusCode, message) = error else {
            return false
        }
        guard statusCode == 404 else {
            return false
        }
        let lower = message.lowercased()
        return lower.contains("cannot get /api/pstn/calls/")
            || lower.contains("endpoint not found on current server")
            || lower.contains("not found")
    }

    private func setExternalCallStatus(_ text: String, id: UUID? = nil) {
        activeVoiceCall = ActiveVoiceCall(
            id: id ?? activeVoiceCall?.id ?? UUID(),
            displayName: "External Network Call",
            type: .voice,
            routeLabel: "Using External Network",
            statusText: text
        )
    }

    private func stopPSTNStatusPolling() {
        pstnStatusPollTask?.cancel()
        pstnStatusPollTask = nil
    }

    private func finishExternalPSTNCall(uiCallID: UUID) async {
        stopPSTNStatusPolling()
        if activePSTNUICallID == uiCallID {
            activePSTNCallSessionID = nil
            activePSTNUICallID = nil
        }
        CallKitManager.shared.endCall(uuid: uiCallID)
        await LiveKitManager.shared.disconnect()
        if activeVoiceCall?.id == uiCallID {
            activeVoiceCall = nil
        }
    }

    func endActiveVoiceCall(callID: UUID) async throws {
        guard activePSTNUICallID == callID,
              let callSessionID = activePSTNCallSessionID else {
            try await callService.endCall(
                sessionID: callID,
                reason: .localHangup,
                source: .inCallButton
            )
            return
        }

        do {
            try await pstnNetworkExecutor.endCall(callSessionId: callSessionID)
        } catch {
            connectivityLogger.error(
                "PSTN end request failed callSessionId=\(callSessionID, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public)"
            )
            await finishExternalPSTNCall(uiCallID: callID)
            throw error
        }

        await finishExternalPSTNCall(uiCallID: callID)
    }

    func setExternalCallMuted(callID: UUID, muted: Bool) async throws {
        guard activePSTNUICallID == callID else { return }
        try await CallKitBridge.shared.setMuted(uuid: callID, muted: muted)
        if LiveKitManager.shared.isMicrophoneEnabled == muted {
            await LiveKitManager.shared.toggleMic()
        }
    }

    func setExternalCallSpeakerEnabled(callID: UUID, enabled: Bool) async throws {
        guard activePSTNUICallID == callID else { return }
        let session = AVAudioSession.sharedInstance()
        try session.overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    private func startPSTNStatusPolling(
        callSessionId: String,
        phoneNumber: String,
        providerLabel: String,
        uiCallID: UUID,
        allowFallbackPrompt: Bool = true
    ) {
        stopPSTNStatusPolling()
        pstnStatusPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var setupDeadline = Date().addingTimeInterval(25)
            var setupCompleted = false
            var didReportCallKitConnected = false
            var consecutiveStatusFailures = 0
            var wasWaitingForCalleeAcceptance = false

            while !Task.isCancelled {
                guard !Task.isCancelled else { return }

                do {
                    let status = try await pstnNetworkExecutor.fetchCallStatus(callSessionId: callSessionId)
                    consecutiveStatusFailures = 0
                    let normalizedStatus = status.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let normalizedBridge = status.mediaBridgeStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let waitingForCalleeAcceptance = isWaitingForPSTNDisclosureAcceptance(normalizedStatus)
                    if wasWaitingForCalleeAcceptance && !waitingForCalleeAcceptance {
                        setupDeadline = Date().addingTimeInterval(25)
                    }
                    wasWaitingForCalleeAcceptance = waitingForCalleeAcceptance
                    let hasSIPParticipant = hasLivePSTNParticipant(
                        sipParticipantId: status.sipParticipantId,
                        participantIdentity: status.participantIdentity
                    )
                    let failureText = status.failureReason ?? status.message

                    logPSTNStatusSnapshot(status)

                    if let text = statusTextForPSTNStatus(
                        status: normalizedStatus,
                        mediaBridgeStatus: normalizedBridge,
                        providerLabel: providerLabel,
                        failureText: failureText,
                        hasSIPParticipant: hasSIPParticipant
                    ) {
                        setExternalCallStatus(text, id: uiCallID)
                    }

                    if normalizedStatus == "connected"
                        || normalizedBridge == "connected"
                        || ((normalizedStatus == "ringing" || normalizedStatus == "answered" || normalizedStatus == "initiated") && hasSIPParticipant) {
                        if !setupCompleted {
                            debugPSTN(
                                "live PSTN marked ready: callSessionId=\(status.callSessionId) " +
                                "status=\(status.status) mediaBridgeStatus=\(status.mediaBridgeStatus ?? "nil") " +
                                "sipParticipantId=\(status.sipParticipantId ?? "nil") " +
                                "participantIdentity=\(status.participantIdentity ?? "nil")"
                            )
                        }
                        setupCompleted = true
                    }

                    if normalizedStatus == "failed" {
                        let reason = failureText ?? "External network call failed."
                        await finishExternalPSTNCall(uiCallID: uiCallID)
                        if isPSTNDisclosureNotAccepted(status: status) {
                            alertMessage = "The recipient did not accept the OneWay call."
                        } else if shouldTriggerBridgeFallbackReason(reason) {
                            handleLivePSTNFailure(
                                phone: phoneNumber,
                                reason: "Live PSTN failed: \(reason)",
                                allowFallbackPrompt: allowFallbackPrompt
                            )
                        } else {
                            alertMessage = "Live PSTN failed: \(reason)"
                        }
                        stopPSTNStatusPolling()
                        return
                    }

                    if normalizedStatus == "ended" {
                        await finishExternalPSTNCall(uiCallID: uiCallID)
                        return
                    }

                    if normalizedStatus == "connected" || (normalizedStatus == "answered" && normalizedBridge == "connected") {
                        if !didReportCallKitConnected {
                            CallKitManager.shared.reportOutgoingCallConnected(uuid: uiCallID)
                            didReportCallKitConnected = true
                        }
                    }

                    if !setupCompleted, !waitingForCalleeAcceptance, Date() >= setupDeadline {
                        debugPSTN(
                            "setup timeout: callSessionId=\(status.callSessionId) status=\(status.status) " +
                            "mediaBridgeStatus=\(status.mediaBridgeStatus ?? "nil") provider=\(status.provider) " +
                            "sipParticipantId=\(status.sipParticipantId ?? "nil") " +
                            "participantIdentity=\(status.participantIdentity ?? "nil")"
                        )
                        let reason = normalizedStatus == "answered" && !hasSIPParticipant
                            ? "The phone answered, but the OneWay phone network bridge did not join the call."
                            : "The OneWay phone network bridge did not join the call in time."
                        setExternalCallStatus(reason, id: uiCallID)
                        handleLivePSTNFailure(
                            phone: phoneNumber,
                            reason: "Live PSTN bridge timeout: status=\(status.status), mediaBridgeStatus=\(status.mediaBridgeStatus ?? "nil"), sipParticipantId=\(status.sipParticipantId ?? "nil").",
                            allowFallbackPrompt: allowFallbackPrompt
                        )
                        stopPSTNStatusPolling()
                        return
                    }
                } catch {
                    debugPSTN("calls/status failed: \(error.localizedDescription)")

                    if isPSTNStatusEndpointMissing(error) {
                        debugPSTN("calls/status endpoint missing on this backend; stopping poll")
                        setExternalCallStatus(
                            "External network call in progress (status unavailable on this server).",
                            id: uiCallID
                        )
                        stopPSTNStatusPolling()
                        return
                    }

                    consecutiveStatusFailures += 1
                    if consecutiveStatusFailures >= 3 {
                        debugPSTN("calls/status failed repeatedly; stopping poll")
                        if setupCompleted {
                            debugPSTN("status polling failed after live PSTN was ready; leaving call UI active")
                            stopPSTNStatusPolling()
                            return
                        }
                        if shouldTriggerBridgeFallback(for: error) {
                            handleLivePSTNFailure(
                                phone: phoneNumber,
                                reason: "Live PSTN status failed: \(error.localizedDescription)",
                                allowFallbackPrompt: allowFallbackPrompt
                            )
                        } else {
                            alertMessage = userSafeCallMessage(for: error, fallback: "Unable to fetch external call status.")
                        }
                        stopPSTNStatusPolling()
                        return
                    }
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

        }
    }

    private func statusTextForPSTNStatus(
        status: String,
        mediaBridgeStatus: String?,
        providerLabel: String,
        failureText: String?,
        hasSIPParticipant: Bool
    ) -> String? {
        switch status {
        case "starting":
            return "Starting external network setup..."
        case "waiting_for_callee_acceptance":
            return "Calling through OneWay. Waiting for the recipient to accept."
        case "connected":
            return "Connected to external network"
        case "ringing":
            return "External phone is ringing…"
        case "answered":
            if mediaBridgeStatus == "connected" {
                return "Connected to external network"
            }
            if !hasSIPParticipant {
                return "Phone answered. Waiting for OneWay audio bridge..."
            }
            return "Phone answered. Connecting call audio..."
        case "failed":
            if let failureText, !failureText.isEmpty {
                return "Live PSTN failed: \(failureText)"
            }
            return "Live PSTN failed with \(providerLabel)."
        case "ended":
            return "External network call ended."
        case "initiated":
            if mediaBridgeStatus == "connected" {
                return "Connected to external network"
            }
            if hasSIPParticipant {
                return "External network call started. Connecting audio..."
            }
            return "Connecting to external network..."
        default:
            return nil
        }
    }

    private func hasCallAuthorization(forPath path: String) -> Bool {
        AuthTokenStore.shared.token() != nil
            || DevAuth.supportsDevelopmentBearer(forPath: path, baseURL: apiClient.baseURL)
    }

    private func userSafeCallMessage(for error: Error, fallback: String) -> String {
        if let apiError = error as? APIClientError {
            switch apiError {
            case .server(let statusCode, let message):
                let lower = message.lowercased()
                if statusCode == 401 || statusCode == 403 || lower.contains("auth") || lower.contains("token") {
                    return "Your session expired. Please sign in again."
                }
                if lower.contains("livekit") && lower.contains("token") {
                    return "OneWay could not create a secure call token."
                }
                if lower.contains("sip") {
                    return "The phone network bridge did not join the call."
                }
                if lower.contains("webhook") || lower.contains("twilio") {
                    return "OneWay could not complete the phone network connection."
                }
                if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "OneWay calling service returned status \(statusCode)."
            case .invalidBaseURL:
                return "OneWay calling is using an invalid network address."
            case .invalidResponse, .emptyResponse:
                return "OneWay calling service returned an unreadable response."
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "OneWay calling service is temporarily unreachable."
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "OneWay calling service is temporarily unreachable."
            default:
                break
            }
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }

    private func isWaitingForPSTNDisclosureAcceptance(_ status: String) -> Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "waiting_for_callee_acceptance"
    }

    private func isPSTNDisclosureNotAccepted(status: PSTNCallStatusResponse) -> Bool {
        let disclosureStatus = status.calleeDisclosure?.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if disclosureStatus == "declined" {
            return true
        }

        let failureText = [
            status.failureReason,
            status.message,
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return failureText.contains("callee_disclosure")
            || failureText.contains("not_accept")
            || failureText.contains("not accepted")
            || failureText.contains("declined")
    }

    private func debugPSTN(_ message: String) {
        #if DEBUG
        print("📞 PSTN:", PrivacyLog.redact(message))
        #endif
    }

    private func sanitizedPSTNStartSummary(_ response: PSTNCallStartResponse) -> String {
        [
            "callSessionId=\(PrivacyLog.shortID(response.callSessionId))",
            "roomName=\(PrivacyLog.shortID(response.roomName))",
            "networkType=\(response.networkType)",
            "provider=\(response.provider)",
            "status=\(response.status)",
            "providerCallId=\(PrivacyLog.shortID(response.providerCallId))",
            "sipParticipantId=\(PrivacyLog.shortID(response.sipParticipantId))",
            "participantIdentity=\(PrivacyLog.shortID(response.participantIdentity))",
            "liveKitUrl=\(PrivacyLog.redact(response.liveKitUrl ?? "nil"))",
            "token=\(response.token?.isEmpty == false ? "[REDACTED_TOKEN]" : "nil")",
            "mediaBridgeStatus=\(response.mediaBridgeStatus ?? "nil")",
            "calleeDisclosure=\(response.calleeDisclosure?.status ?? "nil")",
            "message=\(PrivacyLog.redact(response.message ?? "nil"))"
        ].joined(separator: " ")
    }

    private func shouldSearchOneWayUsers(for query: String) -> Bool {
        guard !query.isEmpty else { return false }
        let uppercase = query.uppercased()
        if uppercase.hasPrefix("OW-") || query.hasPrefix("@") { return true }
        return query.count >= 3 && !query.filter(\.isLetter).isEmpty
    }

    private func normalizePhoneNumber(_ value: String) -> String {
        var result = ""
        for (index, character) in value.enumerated() {
            if character.isNumber {
                result.append(character)
            } else if character == "+", index == 0 {
                result.append(character)
            }
        }
        return result
    }

}
