import Combine
import Foundation

import AVFoundation
import AudioToolbox
import LiveKit

@MainActor
final class WalkieViewModel: ObservableObject {
    @Published var target: String = "" {
        didSet { persistSelectedTarget() }
    }
    @Published var groupName: String = "Crew Chirp"
    @Published var groupTargetsText: String = ""
    @Published var state: WalkieState = .ready
    @Published var errorMessage: String?
    @Published var activeSession: WalkieSessionResponse?
    @Published var availableChannels: [WalkieChannel] = []
    @Published private(set) var walkieContacts: [WalkieContact] = []
    @Published private(set) var pendingRequests: [FriendConnection] = []
    @Published private(set) var incomingDirectChirpRequests: [DirectChirpRequest] = []
    @Published private(set) var outgoingDirectChirpRequests: [DirectChirpRequest] = []
    @Published private(set) var directChirpLookupResult: DirectChirpUser?
    @Published private(set) var isDirectChirpLoading = false
    @Published private(set) var pushToTalkState: PushToTalkState = .idle
    @Published var isRefreshingChannels = false
    @Published private(set) var myIdentity: OneWayIdentity?
    @Published private(set) var myNumbers: [OneWayNumber] = []
    @Published private(set) var myBusinessNumber: String?
    @Published private(set) var signalingConnected = false
    @Published private(set) var mediaConnected = false
    @Published private(set) var localAudioPublished = false
    @Published private(set) var remoteAudioSubscribed = false
    @Published private(set) var remoteAudioStarted = false
    @Published private(set) var lastMediaError: String?
    @Published private(set) var latestTransmissionTimeline: [String] = []

    private let service: WalkieService
    private let identityService: OneWayIdentityService
    private let numberService: OneWayNumberService
    private let businessService: BusinessPresenceServicing
    private let friendService: FriendService
    private let contactCache = WalkieContactCache()

    private var room: Room?
    private var autoRefreshTask: Task<Void, Never>?
    private var friendRealtimeTask: Task<Void, Never>?
    private var activeTransmission: WalkieTransmissionContext?
    private var releaseRequestedDuringStartup = false
    private var releaseRequestedBeforeTransmit = false
    private var chirpModeSessionID: UUID?
    private var activeTouchTransmissionId: String?
    private var autoJoinedIncomingSessionIDs = Set<String>()
    private let pollOwnerID = UUID().uuidString
    private static var activePollOwnerID: String?

    private var selectedTargetDefaultsKey: String {
        "OneWay.Chirp.SelectedTarget.\(AuthTokenStore.shared.currentUserID())"
    }

    init(
        service: WalkieService = .shared,
        identityService: OneWayIdentityService = .shared,
        numberService: OneWayNumberService = .shared,
        businessService: BusinessPresenceServicing = NetworkBusinessPresenceService(),
        friendService: FriendService = NetworkFriendService()
    ) {
        self.service = service
        self.identityService = identityService
        self.numberService = numberService
        self.businessService = businessService
        self.friendService = friendService
        restoreSelectedTarget()
        logChirp("CHIRP_VIEWMODEL_CREATED", "ownerId=\(PrivacyLog.shortID(pollOwnerID))")
        logChirpAuthState()
    }

    private func logChirp(_ event: String, _ fields: String...) {
#if DEBUG
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let mode = MediaModeCoordinator.shared.currentMode.rawValue
        let callId = PrivacyLog.shortID(MediaModeCoordinator.shared.isCallActive ? MediaModeCoordinator.shared.currentSessionId?.uuidString : nil)
        let session = activeSession
        let senderUserId = AuthTokenStore.shared.currentUserID()
        let recipientUserIds = (session?.participants ?? [])
            .map(\.userId)
            .filter { $0 != senderUserId }
            .map { PrivacyLog.shortID($0) }
            .joined(separator: ",")
        let transmissionId = PrivacyLog.shortID(activeTransmission?.transmissionId ?? activeTouchTransmissionId)
        print(([event] + [
            "transmissionId=\(transmissionId)",
            "senderUserId=\(PrivacyLog.shortID(senderUserId))",
            "recipientUserId=\(recipientUserIds.isEmpty ? "none" : recipientUserIds)",
            "sessionId=\(PrivacyLog.shortID(session?.sessionId))",
            "channelId=\(PrivacyLog.shortID(session?.channelId))",
            "deviceRole=\(session?.participants?.contains(where: { $0.userId == senderUserId }) == true ? "participant" : "local")",
            "sourceFile=WalkieViewModel.swift",
            "function=\(#function)"
        ] + fields + [
            "communicationMode=\(mode)",
            "callId=\(callId)",
            "timestamp=\(timestamp)"
        ]).joined(separator: " "))
#endif
    }

    private func logChirpAuthState() {
        logChirp(
            "CHIRP_AUTH_STATE",
            "userId=\(PrivacyLog.shortID(AuthTokenStore.shared.currentUserID()))",
            "tokenAvailable=\(AuthTokenStore.shared.token() != nil)"
        )
    }

    private func restoreSelectedTarget() {
        let saved = UserDefaults.standard.string(forKey: selectedTargetDefaultsKey) ?? ""
        guard !saved.isEmpty, target.isEmpty else { return }
        target = saved
    }

    private func persistSelectedTarget() {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: selectedTargetDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: selectedTargetDefaultsKey)
        }
    }

    private func normalizeTargetInput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.uppercased().hasPrefix("OW-") {
            return trimmed.uppercased()
        }

        if trimmed.hasPrefix("@") {
            return trimmed
        }

        if trimmed.contains("@") {
            return trimmed.lowercased()
        }

        let digits = trimmed.filter(\.isNumber)
        if digits.count >= 10,
           trimmed.range(of: #"^[+()0-9.\-\s]{10,24}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        // Accept bare OneWay handles, usernames, and Walkie names.
        if trimmed.range(of: #"^[A-Za-z0-9_.\-\s]{2,64}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        return nil
    }

    func handlePageOpened() async {
        logChirp("CHIRP_PAGE_OPENED")
        logChirpAuthState()
        restoreSelectedTarget()
        if MediaModeCoordinator.shared.isCallActive {
            state = .unavailable
            logChirp("CHIRP_FAILURE", "stage=page_open", "error=active_call")
        } else if case .error = state {
            // A failed contact lookup is not a backend disconnect. Re-enter
            // the ready state immediately and let the normal channel refresh
            // report genuine transport availability.
            state = .ready
        }
    }

    func handlePageDismissed() async {
        if pushToTalkState == .transmitting ||
            pushToTalkState == .publishing ||
            pushToTalkState == .requestingChannel ||
            pushToTalkState == .requestingPermission ||
            pushToTalkState == .connectingMedia ||
            pushToTalkState == .ready {
            await stopTalking()
        }
        stopAutoRefreshChannels()
    }

    func startAutoRefreshChannels(intervalSeconds: Double = 20.0) {
        if let activeOwner = Self.activePollOwnerID, activeOwner != pollOwnerID {
            logChirp("CHIRP_DUPLICATE_POLL_OWNER_BLOCKED", "ownerId=\(PrivacyLog.shortID(pollOwnerID))", "activeOwnerId=\(PrivacyLog.shortID(activeOwner))")
            return
        }
        Self.activePollOwnerID = pollOwnerID
        logChirp("CHIRP_CHANNEL_POLL_OWNER_CREATED", "ownerId=\(PrivacyLog.shortID(pollOwnerID))")

        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            var tick = 0
            while !Task.isCancelled {
                await self.refreshChannels()
                if tick.isMultiple(of: 5) {
                    await self.loadWalkieContacts(showErrors: false)
                }
                tick += 1
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }

        friendRealtimeTask?.cancel()
        friendRealtimeTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.friendService.observeFriendEvents() {
                switch event {
                case .requestReceived, .requestAccepted, .requestDenied, .requestIgnored, .requestBlocked, .removed, .online, .offline:
                    await self.loadWalkieContacts(showErrors: false)
                }
            }
        }
    }

    func stopAutoRefreshChannels() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        friendRealtimeTask?.cancel()
        friendRealtimeTask = nil
        if Self.activePollOwnerID == pollOwnerID {
            Self.activePollOwnerID = nil
        }
    }

    var canTransmit: Bool {
        guard !MediaModeCoordinator.shared.isCallActive else { return false }
        switch state {
        case .listening, .talking:
            return activeSession != nil && pushToTalkState != .requestingChannel && pushToTalkState != .releasing
        default:
            return false
        }
    }

    var canStartSession: Bool {
        state != .connecting && activeSession == nil && !MediaModeCoordinator.shared.isCallActive
    }

    var canStartGroupSession: Bool {
        canStartSession && normalizedGroupTargets().count >= 2
    }

    var canJoinSession: Bool {
        state != .connecting && activeSession == nil
    }

    var assignedWalkieName: String {
        let value = myIdentity?.walkieName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Not assigned" : value
    }

    var assignedEmailAlias: String {
        let value = myIdentity?.emailAlias.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Not assigned" : value
    }

    var assignedOneWayId: String {
        let value = myIdentity?.onewayId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Not assigned" : value
    }

    var assignedChirpId: String {
        let value = myIdentity?.chirpId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Not assigned" : value
    }

    var assignedOneWayNumber: String {
        let primary = myNumbers.first(where: { $0.isPrimary }) ?? myNumbers.first
        return primary?.number ?? "Not assigned"
    }

    var assignedBusinessNumber: String {
        let value = myBusinessNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Not assigned" : value
    }

    func loadAssignedProfile() async {
        async let identityTask: OneWayIdentity? = try? identityService.fetchMyIdentity()
        async let numbersTask: OneWayNumbersResponse? = try? numberService.fetchMyNumbers()
        async let businessTask: BusinessPresenceProfile? = try? businessService.fetchProfile()

        let identity = await identityTask
        let numbers = await numbersTask
        let business = await businessTask

        myIdentity = identity
        myNumbers = numbers?.numbers ?? []
        myBusinessNumber = business?.publicPhoneNumber
    }

    func loadWalkieContacts(showErrors: Bool = true) async {
        let userID = AuthTokenStore.shared.currentUserID()
        logChirp("CHIRP_CONTACTS_LOAD_STARTED", "userId=\(PrivacyLog.shortID(userID))")
        if walkieContacts.isEmpty {
            walkieContacts = contactCache.load(userID: userID)
        }

        do {
            async let contactsTask = service.contacts()
            async let friendsTask = friendService.fetchFriends()
            async let directIncomingTask = service.incomingDirectChirpRequests()
            async let directOutgoingTask = service.outgoingDirectChirpRequests()
            let response = try await contactsTask
            let friends = try await friendsTask
            let incomingDirect = try? await directIncomingTask
            let outgoingDirect = try? await directOutgoingTask
            walkieContacts = response.contacts
            pendingRequests = friends.filter { $0.status == .pending }
            incomingDirectChirpRequests = incomingDirect?.requests ?? incomingDirectChirpRequests
            outgoingDirectChirpRequests = outgoingDirect?.requests ?? outgoingDirectChirpRequests
            contactCache.save(response.contacts, userID: userID)
            errorMessage = nil
            logChirp("CHIRP_CONTACTS_LOAD_COMPLETED", "count=\(response.contacts.count)")
        } catch {
            logChirp("CHIRP_FAILURE", "stage=contacts_load", "error=\(PrivacyLog.redact(error.localizedDescription))")
            if showErrors && walkieContacts.isEmpty {
                errorMessage = "Unable to load Chirp contacts."
            }
        }
    }

    func refreshChannels(showErrors: Bool = false) async {
        guard !MediaModeCoordinator.shared.isCallActive else {
            logChirp("CHIRP_FAILURE", "stage=channels_refresh", "error=active_call")
            return
        }
        logChirp("CHIRP_CHANNELS_LOAD_STARTED")
        isRefreshingChannels = true
        defer { isRefreshingChannels = false }

        do {
            let response = try await service.channels()
            availableChannels = response.channels.filter { $0.status == "active" }
            logChirp("CHIRP_CHANNELS_LOAD_COMPLETED", "count=\(availableChannels.count)")
            await subscribeToIncomingChannelsIfNeeded()
            if !response.liveKitConfigured {
                state = .unavailable
            } else {
                switch state {
                case .unavailable, .error:
                    state = activeSession == nil ? .ready : .listening
                default:
                    break
                }
            }
        } catch {
            logChirp("CHIRP_FAILURE", "stage=channels_load", "error=\(PrivacyLog.redact(error.localizedDescription))")
            if showErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startSession() async {
        guard canStartSession else {
            logChirp("CHIRP_FAILURE", "stage=start_session", "error=not_available")
            return
        }

        guard let resolvedTarget = normalizeTargetInput(target) else {
            state = .error("Enter a Chirp name, OneWay email, OneWay ID, or number.")
            errorMessage = "Enter a Chirp name, OneWay email, OneWay ID, or number."
            logChirp("CHIRP_FAILURE", "stage=start_session", "error=missing_target")
            return
        }

        state = .connecting
        target = resolvedTarget
        let matchingContact = walkieContacts.first {
            $0.chirpId?.caseInsensitiveCompare(resolvedTarget) == .orderedSame ||
            $0.handle.caseInsensitiveCompare(resolvedTarget) == .orderedSame ||
            $0.displayName.caseInsensitiveCompare(resolvedTarget) == .orderedSame
        }
        logChirp(
            "CHIRP_TARGET_VALIDATED",
            "displayedHandle=\(PrivacyLog.redact(resolvedTarget))",
            "resolvedRecipientUserId=\(PrivacyLog.shortID(matchingContact?.userId))",
            "currentUserId=\(PrivacyLog.shortID(AuthTokenStore.shared.currentUserID()))",
            "recipientUserIdIsDifferentFromCurrentUser=\(matchingContact?.userId != AuthTokenStore.shared.currentUserID())",
            "authorizationState=\(matchingContact?.status ?? "server_validated")",
            "blockedState=\(matchingContact?.availability == "blocked")",
            "onlineState=\(matchingContact?.isOnline == true)"
        )
        logChirp("CHIRP_TARGET_SELECTED", "targetType=direct", "targetId=\(PrivacyLog.redact(resolvedTarget))")
        print("📡 Walkie target:", PrivacyLog.redact(resolvedTarget))

        do {
            logChirp("CHIRP_SESSION_LOOKUP_STARTED", "targetType=direct")
            logChirp("CHIRP_SESSION_CREATE_STARTED", "targetType=direct")
            logChirp("CHIRP_SOCKET_CONNECT_STARTED", "targetType=direct", "targetId=\(PrivacyLog.redact(resolvedTarget))")
            let session = try await service.startSession(target: resolvedTarget)
            logChirp(
                "CHIRP_SESSION_CREATED",
                "result=success",
                "sessionId=\(PrivacyLog.shortID(session.sessionId))",
                "recipientUserId=\(PrivacyLog.shortID(session.participants?.first(where: { $0.userId != AuthTokenStore.shared.currentUserID() })?.userId))"
            )
            print("🎙 WALKIE sessionId:", PrivacyLog.shortID(session.sessionId))
            print("🎙 WALKIE roomName:", PrivacyLog.shortID(session.roomName))
            print("🎙 WALKIE liveKitUrl:", PrivacyLog.redact(session.liveKitUrl ?? "nil"))
            print("🎙 WALKIE token exists:", (session.token?.isEmpty == false))
            print("🎙 WALKIE target:", PrivacyLog.redact(session.target ?? "nil"))
            try await connectAudio(for: session)
            logChirp("CHIRP_SOCKET_CONNECTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))")
            activeSession = session
            target = session.target ?? resolvedTarget
            await loadWalkieContacts(showErrors: false)
            await refreshChannels()
        } catch {
            logChirp("CHIRP_SOCKET_CONNECT_FAILED", "error=\(PrivacyLog.redact(error.localizedDescription))")
            logChirp("CHIRP_SESSION_LOOKUP_RESULT", "result=failed", "error=\(PrivacyLog.redact(error.localizedDescription))")
            logChirp("CHIRP_FAILURE", "stage=start_session", "error=\(PrivacyLog.redact(error.localizedDescription))")
            presentSessionStartFailure(error, attemptedTarget: resolvedTarget)
        }
    }

    private func presentSessionStartFailure(_ error: Error, attemptedTarget: String) {
        if case let APIClientError.server(statusCode, message) = error,
           (400..<500).contains(statusCode) {
            // Recipient validation, privacy, and stale identifiers are
            // request-level failures. The app and Chirp backend remain online.
            state = .ready

            let normalizedMessage = message.lowercased()
            if statusCode == 404,
               normalizedMessage.contains("not reachable") || normalizedMessage.contains("no current oneway account") {
                target = ""
                errorMessage = "Chirp is online, but no current OneWay account matches \(attemptedTarget). Confirm the recipient’s current Chirp ID and try again."
            } else {
                errorMessage = message
            }
            return
        }

        state = .error(error.localizedDescription)
        errorMessage = "Chirp lost its connection. It will retry automatically. \(error.localizedDescription)"
    }

    func handlePushToTalkDown() async {
        activeTouchTransmissionId = UUID().uuidString
        logChirp("CHIRP_TOUCH_DOWN")
        releaseRequestedBeforeTransmit = false

        guard !MediaModeCoordinator.shared.isCallActive else {
            state = .unavailable
            logChirp("CHIRP_FAILURE", "stage=touch_down", "error=active_call")
            return
        }

        if !canTransmit, activeSession == nil, canStartSession {
            let normalized = normalizeTargetInput(target)
            guard normalized != nil else {
                errorMessage = "Choose a Chirp contact or channel first."
                logChirp("CHIRP_FAILURE", "stage=touch_down", "error=missing_target")
                return
            }
            await startSession()
        }

        guard !releaseRequestedBeforeTransmit else {
            logChirp("CHIRP_FAILURE", "stage=touch_down", "error=released_before_ready")
            if activeSession != nil {
                await endSession()
            }
            return
        }

        await startTalking()
    }

    func handlePushToTalkUp() async {
        logChirp("CHIRP_TOUCH_UP")
        if activeSession == nil || room == nil {
            releaseRequestedBeforeTransmit = true
            logChirp("CHIRP_FAILURE", "stage=touch_up", "error=no_active_transmit")
            return
        }
        await stopTalking()
    }

    private func subscribeToIncomingChannelsIfNeeded() async {
        guard activeSession == nil else { return }
        guard !MediaModeCoordinator.shared.isCallActive else {
            logChirp("CHIRP_FAILURE", "stage=receiver_subscribe", "error=active_call")
            return
        }
        guard let incoming = availableChannels.first(where: { $0.isIncoming == true && !autoJoinedIncomingSessionIDs.contains($0.sessionId ?? $0.id) }) else {
            return
        }

        let sessionId = incoming.sessionId ?? incoming.id
        autoJoinedIncomingSessionIDs.insert(sessionId)
        logChirp(
            "CHIRP_RECEIVER_SUBSCRIBED",
            "sessionId=\(PrivacyLog.shortID(sessionId))",
            "senderUserId=\(PrivacyLog.shortID(incoming.participants?.first(where: { $0.userId != AuthTokenStore.shared.currentUserID() })?.userId))"
        )
        await join(channel: incoming)
    }

    func startGroupSession() async {
        guard canStartSession else { return }

        let members = normalizedGroupTargets()
        guard members.count >= 2 else {
            state = .error("Add at least two people for a group Chirp.")
            errorMessage = "Add at least two people for a group Chirp."
            logChirp("CHIRP_FAILURE", "stage=start_group_session", "error=missing_targets")
            return
        }

        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .connecting
        logChirp("CHIRP_TARGET_SELECTED", "targetType=group", "targetId=\(PrivacyLog.redact(name.isEmpty ? "Crew Chirp" : name))")
        print("📡 Walkie group targets:", members.map { PrivacyLog.redact($0) }.joined(separator: ", "))

        do {
            logChirp("CHIRP_SOCKET_CONNECT_STARTED", "targetType=group", "targetId=\(PrivacyLog.redact(name.isEmpty ? "Crew Chirp" : name))")
            let session = try await service.startGroupSession(
                name: name.isEmpty ? "Crew Chirp" : name,
                targets: members
            )
            print("🎙 WALKIE group sessionId:", PrivacyLog.shortID(session.sessionId))
            print("🎙 WALKIE group roomName:", PrivacyLog.shortID(session.roomName))
            print("🎙 WALKIE group participants:", session.participants?.count ?? 0)
            try await connectAudio(for: session)
            logChirp("CHIRP_SOCKET_CONNECTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))")
            activeSession = session
            target = session.target ?? session.groupName ?? name
            groupTargetsText = ""
            await loadWalkieContacts(showErrors: false)
            await refreshChannels()
        } catch {
            logChirp("CHIRP_SOCKET_CONNECT_FAILED", "error=\(PrivacyLog.redact(error.localizedDescription))")
            logChirp("CHIRP_FAILURE", "stage=start_group_session", "error=\(PrivacyLog.redact(error.localizedDescription))")
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func join(channel: WalkieChannel) async {
        guard canJoinSession else { return }

        let sessionId = channel.sessionId ?? channel.id
        state = .connecting
        logChirp("CHIRP_TARGET_SELECTED", "targetType=channel", "targetId=\(PrivacyLog.shortID(sessionId))")
        print("📡 Walkie channel:", PrivacyLog.shortID(channel.roomName))

        do {
            logChirp("CHIRP_SOCKET_CONNECT_STARTED", "targetType=channel", "targetId=\(PrivacyLog.shortID(sessionId))")
            let session = try await service.joinSession(sessionId: sessionId)
            print("🎙 WALKIE sessionId:", PrivacyLog.shortID(session.sessionId))
            print("🎙 WALKIE roomName:", PrivacyLog.shortID(session.roomName))
            print("🎙 WALKIE liveKitUrl:", PrivacyLog.redact(session.liveKitUrl ?? "nil"))
            print("🎙 WALKIE token exists:", (session.token?.isEmpty == false))
            print("🎙 WALKIE target:", PrivacyLog.redact(session.target ?? "nil"))
            try await connectAudio(for: session)
            logChirp("CHIRP_SOCKET_CONNECTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))")
            activeSession = session
            target = session.target ?? target
            await loadWalkieContacts(showErrors: false)
            await refreshChannels()
        } catch {
            logChirp("CHIRP_SOCKET_CONNECT_FAILED", "error=\(PrivacyLog.redact(error.localizedDescription))")
            logChirp("CHIRP_FAILURE", "stage=join_channel", "error=\(PrivacyLog.redact(error.localizedDescription))")
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func join(sessionId: String) async {
        guard canJoinSession else { return }

        state = .connecting
        logChirp("CHIRP_TARGET_SELECTED", "targetType=session", "targetId=\(PrivacyLog.shortID(sessionId))")
        print("📡 Walkie join session:", PrivacyLog.shortID(sessionId))

        do {
            logChirp("CHIRP_SOCKET_CONNECT_STARTED", "targetType=session", "targetId=\(PrivacyLog.shortID(sessionId))")
            let session = try await service.joinSession(sessionId: sessionId)
            print("🎙 WALKIE sessionId:", PrivacyLog.shortID(session.sessionId))
            print("🎙 WALKIE roomName:", PrivacyLog.shortID(session.roomName))
            print("🎙 WALKIE liveKitUrl:", PrivacyLog.redact(session.liveKitUrl ?? "nil"))
            print("🎙 WALKIE token exists:", (session.token?.isEmpty == false))
            print("🎙 WALKIE target:", PrivacyLog.redact(session.target ?? "nil"))
            try await connectAudio(for: session)
            logChirp("CHIRP_SOCKET_CONNECTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))")
            activeSession = session
            target = session.target ?? target
            await loadWalkieContacts(showErrors: false)
            await refreshChannels()
        } catch {
            logChirp("CHIRP_SOCKET_CONNECT_FAILED", "error=\(PrivacyLog.redact(error.localizedDescription))")
            logChirp("CHIRP_FAILURE", "stage=join_session", "error=\(PrivacyLog.redact(error.localizedDescription))")
            state = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func startTalking() async {
        logChirp("CHIRP_PTT_PRESS_RECEIVED")
        guard canTransmit else {
            logChirp("CHIRP_FAILURE", "stage=ptt_press", "error=not_ready")
            return
        }
        guard let room else {
            logChirp("CHIRP_FAILURE", "stage=ptt_press", "error=missing_room")
            return
        }
        guard let session = activeSession else {
            logChirp("CHIRP_FAILURE", "stage=ptt_press", "error=missing_session")
            return
        }

        let transmission = WalkieTransmissionContext(
            transmissionId: UUID().uuidString,
            session: session,
            senderUserId: AuthTokenStore.shared.currentUserID()
        )
        activeTransmission = transmission
        releaseRequestedDuringStartup = false
        localAudioPublished = false
        lastMediaError = nil
        latestTransmissionTimeline = []

        pushToTalkState = .requestingChannel
        logChirp("CHIRP_TRANSMIT_START_REQUESTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))")
        logMediaStage("chirp.ptt.pressed", transmission: transmission, room: room)
        logMediaStage("chirp.channel.requested", transmission: transmission, room: room)

        let grant: WalkieTransmitResponse
        do {
            grant = try await service.requestTransmit(sessionId: session.sessionId)
        } catch {
            let message = error.localizedDescription
            lastMediaError = message
            pushToTalkState = .failed(message)
            errorMessage = message
            logChirp("CHIRP_FAILURE", "stage=transmit_request", "error=\(PrivacyLog.redact(message))")
            logMediaStage("chirp.channel.request_failed", transmission: transmission, room: room, error: error)
            return
        }

        guard grant.status == "granted" else {
            let message = grant.message ?? "Another user is currently speaking."
            lastMediaError = message
            pushToTalkState = .failed(message)
            errorMessage = message
            logChirp("CHIRP_FAILURE", "stage=transmit_request", "error=\(PrivacyLog.redact(message))")
            logMediaStage("chirp.channel.denied", transmission: transmission, room: room, errorDescription: message)
            return
        }

        logMediaStage("chirp.channel.granted", transmission: transmission, room: room)

        if releaseRequestedDuringStartup {
            await releaseTransmitLock(sessionId: session.sessionId, transmission: transmission, room: room)
            resetTransmitStateAfterCancelledStart()
            return
        }

        pushToTalkState = .requestingPermission
        let permissionStatus = AVAudioApplication.shared.recordPermission
        logChirp("CHIRP_MIC_PERMISSION_CHECKED", "microphone=\(permissionStatus.chirpLogValue)")
        logChirp("CHIRP_PERMISSION_STATE", "microphone=\(permissionStatus.chirpLogValue)")
        logMediaStage("chirp.microphone.permission.checked", transmission: transmission, room: room)
        guard await requestMicrophonePermission() else {
            let message = "Microphone Access Required\n\nEnable microphone access in Settings to use Chirp."
            lastMediaError = "microphone_permission_denied"
            pushToTalkState = .failed(message)
            errorMessage = message
            logChirp("CHIRP_PERMISSION_STATE", "microphone=denied")
            logChirp("CHIRP_FAILURE", "stage=microphone_permission", "error=denied")
            logMediaStage("chirp.microphone.permission.denied", transmission: transmission, room: room)
            await releaseTransmitLock(sessionId: session.sessionId, transmission: transmission, room: room)
            return
        }
        logChirp("CHIRP_PERMISSION_STATE", "microphone=granted")
        logChirp("CHIRP_MIC_GRANTED")

        pushToTalkState = .connectingMedia
        logMediaStage("chirp.media.room.connected", transmission: transmission, room: room)

        if !hasRemoteParticipant(in: room), session.isGroup != true {
            do {
                try await waitForRemoteParticipant(in: room, timeoutSeconds: 5.0, transmission: transmission)
            } catch {
                let message = "Could not connect to the Chirp audio channel."
                lastMediaError = message
                pushToTalkState = .failed(message)
                errorMessage = message
                logChirp("CHIRP_FAILURE", "stage=remote_participant", "error=timeout")
                logMediaStage("chirp.remote.participant.wait_failed", transmission: transmission, room: room, error: error)
                await releaseTransmitLock(sessionId: session.sessionId, transmission: transmission, room: room)
                return
            }
        }

        if releaseRequestedDuringStartup {
            await releaseTransmitLock(sessionId: session.sessionId, transmission: transmission, room: room)
            resetTransmitStateAfterCancelledStart()
            return
        }

        do {
            guard MediaModeCoordinator.shared.canStartChirp() else {
                logChirp("CHIRP_FAILURE", "stage=audio_session", "error=active_call")
                await releaseTransmitLock(sessionId: session.sessionId, transmission: transmission, room: room)
                return
            }
            try activateChirpAudioSession()
            logChirp("CHIRP_AUDIO_SESSION_READY", "route=\(PrivacyLog.redact(audioRouteDescription()))")
            logMediaStage("chirp.audio.session.activated", transmission: transmission, room: room)

            print("🎙 Walkie start transmit")
            pushToTalkState = .publishing
            logMediaStage("chirp.local.track.publishing", transmission: transmission, room: room)
            try await room.localParticipant.setMicrophone(enabled: true)
            localAudioPublished = true
            logChirp("CHIRP_AUDIO_CAPTURE_STARTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))")
            logChirp("CHIRP_RECORDING_STARTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))")
            logChirp("CHIRP_ENCODER_STARTED", "codec=livekit_opus", "frameDuration=livekit_managed")
            logChirp("CHIRP_PACKET_ENCRYPTION_READY", "transport=livekit_srtp")
            logChirp("CHIRP_PACKET_CREATED", "sequence=livekit_managed", "bytes=livekit_managed")
            logChirp("CHIRP_PACKET_SENT", "sequence=livekit_managed", "bytes=livekit_managed")
            logChirp("CHIRP_AUDIO_FRAME_SENT", "sequence=livekit_managed", "bytes=livekit_managed")
            logMediaStage("chirp.local.track.published", transmission: transmission, room: room)

            if releaseRequestedDuringStartup {
                await stopPublishedTransmission(room: room, sessionId: session.sessionId, transmission: transmission)
                return
            }

            playChirpCue(.chirpStart, cueType: "local_start", transmission: transmission)
            pushToTalkState = .ready
            pushToTalkState = .transmitting
            state = .talking
            logChirp("CHIRP_TRANSMIT_STARTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))")
        } catch {
            let message = "Your voice could not be sent."
            state = .error(message)
            localAudioPublished = false
            lastMediaError = error.localizedDescription
            pushToTalkState = .failed(message)
            errorMessage = message
            logChirp("CHIRP_FAILURE", "stage=audio_publish", "error=\(PrivacyLog.redact(error.localizedDescription))")
            logMediaStage("chirp.local.track.publish_failed", transmission: transmission, room: room, error: error)
            await releaseTransmitLock(sessionId: session.sessionId, transmission: transmission, room: room)
        }
    }

    func stopTalking() async {
        logChirp("CHIRP_PTT_RELEASE_RECEIVED")
        guard let room else {
            logChirp("CHIRP_FAILURE", "stage=ptt_release", "error=missing_room")
            return
        }
        let sessionId = activeSession?.sessionId
        let transmission = activeTransmission

        logMediaStage("chirp.ptt.released", transmission: transmission, room: room)

        switch pushToTalkState {
        case .requestingChannel, .requestingPermission, .connectingMedia, .publishing, .ready:
            releaseRequestedDuringStartup = true
            pushToTalkState = .stopping
            return
        default:
            break
        }

        guard let sessionId else {
            logChirp("CHIRP_FAILURE", "stage=ptt_release", "error=missing_session")
            return
        }
        await stopPublishedTransmission(room: room, sessionId: sessionId, transmission: transmission)
    }

    private func stopPublishedTransmission(
        room: Room,
        sessionId: String,
        transmission: WalkieTransmissionContext?
    ) async {
        do {
            pushToTalkState = .releasing
            print("🛑 Walkie stop transmit")
            try await room.localParticipant.setMicrophone(enabled: false)
            localAudioPublished = false
            logMediaStage("chirp.local.track.unpublished", transmission: transmission, room: room)
            await releaseTransmitLock(sessionId: sessionId, transmission: transmission, room: room)
            playChirpCue(.chirpEnd, cueType: "local_end", transmission: transmission)
            if activeSession != nil {
                pushToTalkState = .readyToTransmit
                state = .listening
            }
            logChirp("CHIRP_TRANSMIT_STOPPED", "sessionId=\(PrivacyLog.shortID(sessionId))")
            logChirp("CHIRP_STREAM_FINISHED", "sessionId=\(PrivacyLog.shortID(sessionId))")
            logMediaStage("chirp.transmission.completed", transmission: transmission, room: room)
            activeTransmission = nil
            releaseRequestedDuringStartup = false
        } catch {
            let message = "Could not stop microphone."
            state = .error(message)
            lastMediaError = error.localizedDescription
            pushToTalkState = .failed(message)
            errorMessage = message
            logChirp("CHIRP_FAILURE", "stage=audio_unpublish", "error=\(PrivacyLog.redact(error.localizedDescription))")
            logMediaStage("chirp.local.track.unpublish_failed", transmission: transmission, room: room, error: error)
        }
    }

    func endSession() async {
        if state == .talking {
            await stopTalking()
        }

        if let sessionId = activeSession?.sessionId {
            _ = try? await service.releaseTransmit(sessionId: sessionId)
            try? await service.endSession(sessionId: sessionId)
        }

        await room?.disconnect()
        if !MediaModeCoordinator.shared.isCallActive {
            try? AudioManager.shared.setEngineAvailability(.none)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            #if DEBUG
            print("chirp.audio.deactivation.skipped reason=activeCall timestamp=\(ISO8601DateFormatter().string(from: Date()))")
            #endif
        }
        room = nil

        if let chirpModeSessionID {
            MediaModeCoordinator.shared.deactivate(mode: .chirp, sessionId: chirpModeSessionID)
        }
        chirpModeSessionID = nil
        activeSession = nil
        activeTransmission = nil
        releaseRequestedDuringStartup = false
        releaseRequestedBeforeTransmit = false
        signalingConnected = false
        mediaConnected = false
        localAudioPublished = false
        remoteAudioSubscribed = false
        remoteAudioStarted = false
        pushToTalkState = .idle
        state = .ended
        await loadWalkieContacts(showErrors: false)
        await refreshChannels()
    }

    func startSession(with contact: WalkieContact) async {
        guard contact.availability == "available" || contact.availability == "offline" else {
            errorMessage = "\(contact.displayName) is unavailable for Chirp right now."
            return
        }
        target = contact.chirpId ?? contact.handle
        await startSession()
    }

    func toggleFavorite(_ contact: WalkieContact) async {
        do {
            let response = try await service.setFavorite(!contact.isFavorite, userId: contact.userId)
            walkieContacts = response.contacts
            contactCache.save(response.contacts, userID: AuthTokenStore.shared.currentUserID())
        } catch {
            errorMessage = "Could not update Chirp favorite."
        }
    }

    func acceptPendingRequest(_ friend: FriendConnection) async {
        do {
            _ = try await friendService.acceptFriendRequest(id: friend.id)
            await loadWalkieContacts(showErrors: false)
        } catch {
            errorMessage = "Could not accept Chirp request."
        }
    }

    func declinePendingRequest(_ friend: FriendConnection) async {
        do {
            try await friendService.declineFriendRequest(id: friend.id)
            await loadWalkieContacts(showErrors: false)
        } catch {
            errorMessage = "Could not deny Chirp request."
        }
    }

    func ignorePendingRequest(_ friend: FriendConnection) async {
        do {
            try await friendService.ignoreFriendRequest(id: friend.id)
            await loadWalkieContacts(showErrors: false)
        } catch {
            errorMessage = "Could not ignore Chirp request."
        }
    }

    func blockPendingRequest(_ friend: FriendConnection) async {
        do {
            try await friendService.blockFriendRequest(id: friend.id)
            await loadWalkieContacts(showErrors: false)
        } catch {
            errorMessage = "Could not block Chirp request."
        }
    }

    func cancelPendingRequest(_ friend: FriendConnection) async {
        do {
            try await friendService.cancelFriendRequest(id: friend.id)
            await loadWalkieContacts(showErrors: false)
        } catch {
            errorMessage = "Could not cancel Chirp request."
        }
    }

    func lookupDirectChirp(_ rawChirpId: String) async {
        guard let normalized = normalizeTargetInput(rawChirpId) else {
            errorMessage = "Enter a valid Chirp ID."
            return
        }
        isDirectChirpLoading = true
        defer { isDirectChirpLoading = false }
        do {
            let result = try await service.lookupDirectChirp(chirpId: normalized)
            directChirpLookupResult = result.user
            if !result.found {
                errorMessage = "No available Direct Chirp match. They may have Direct Chirp turned off."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestDirectChirp(_ rawChirpId: String) async {
        guard let normalized = normalizeTargetInput(rawChirpId) else {
            errorMessage = "Enter a valid Chirp ID."
            return
        }
        isDirectChirpLoading = true
        defer { isDirectChirpLoading = false }
        do {
            let response = try await service.requestDirectChirp(chirpId: normalized)
            if let existingIndex = outgoingDirectChirpRequests.firstIndex(where: { $0.id == response.request.id }) {
                outgoingDirectChirpRequests[existingIndex] = response.request
            } else {
                outgoingDirectChirpRequests.insert(response.request, at: 0)
            }
            target = normalized
            errorMessage = "Direct Chirp request sent."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func acceptDirectChirp(_ request: DirectChirpRequest) async {
        do {
            let response = try await service.acceptDirectChirpRequest(id: request.id)
            incomingDirectChirpRequests.removeAll { $0.id == request.id }
            if let session = response.session {
                try await connectAudio(for: session)
                activeSession = session
                target = session.target ?? request.displayName
            }
            await loadWalkieContacts(showErrors: false)
            await refreshChannels()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func declineDirectChirp(_ request: DirectChirpRequest) async {
        await updateDirectRequest(request) { try await service.declineDirectChirpRequest(id: request.id) }
    }

    func ignoreDirectChirp(_ request: DirectChirpRequest) async {
        await updateDirectRequest(request) { try await service.ignoreDirectChirpRequest(id: request.id) }
    }

    func blockDirectChirp(_ request: DirectChirpRequest) async {
        await updateDirectRequest(request) { try await service.blockDirectChirpRequest(id: request.id) }
    }

    func cancelDirectChirp(_ request: DirectChirpRequest) async {
        await updateDirectRequest(request) { try await service.cancelDirectChirpRequest(id: request.id) }
    }

    private func updateDirectRequest(
        _ request: DirectChirpRequest,
        action: () async throws -> DirectChirpRequestResponse
    ) async {
        do {
            _ = try await action()
            incomingDirectChirpRequests.removeAll { $0.id == request.id }
            outgoingDirectChirpRequests.removeAll { $0.id == request.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connectAudio(for session: WalkieSessionResponse) async throws {
        guard MediaModeCoordinator.shared.canStartChirp() else {
            state = .unavailable
            logChirp("CHIRP_FAILURE", "stage=socket_connect", "error=active_call")
            throw WalkieError.unavailable("Chirp is paused during calls.")
        }
        guard session.liveKitConfigured != false else {
            state = .unavailable
            logChirp("CHIRP_SOCKET_CONNECT_FAILED", "error=livekit_unconfigured")
            throw WalkieError.unavailable(session.message ?? "Chirp audio is unavailable.")
        }

        guard let liveKitUrl = session.liveKitUrl,
              let token = session.token else {
            state = .unavailable
            logChirp("CHIRP_SOCKET_CONNECT_FAILED", "error=missing_credentials")
            throw WalkieError.unavailable("Chirp session is missing LiveKit audio credentials.")
        }
        guard let url = URL(string: liveKitUrl) else {
            throw WalkieError.invalidLiveKitURL(liveKitUrl)
        }
        guard isLiveKitWebSocketURL(url), !isAPIBackendURL(url), !url.absoluteString.contains(":3000") else {
            throw WalkieError.invalidLiveKitURL(
                "\(liveKitUrl) is not a LiveKit signaling URL. Expected ws(s):// LiveKit, not the OneWay API backend."
            )
        }
        let modeSessionID = UUID(uuidString: session.sessionId) ?? UUID()
        chirpModeSessionID = modeSessionID
        MediaModeCoordinator.shared.activate(mode: .chirp, sessionId: modeSessionID)
        var didConnectChirpSession = false
        defer {
            if !didConnectChirpSession {
                MediaModeCoordinator.shared.deactivate(mode: .chirp, sessionId: modeSessionID)
                if chirpModeSessionID == modeSessionID {
                    chirpModeSessionID = nil
                }
            }
        }
        print("📡 Walkie channel:", PrivacyLog.shortID(session.roomName))
        logChirp("CHIRP_TRANSPORT_CONNECT_STARTED", "url=\(PrivacyLog.redact(liveKitUrl))", "authenticatedState=true", "sessionId=\(PrivacyLog.shortID(session.sessionId))", "recipientUserId=\(PrivacyLog.shortID(session.participants?.first(where: { $0.userId != AuthTokenStore.shared.currentUserID() })?.userId))", "reconnectState=initial")
        logChirp("CHIRP_SOCKET_CONNECT_STARTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))", "roomName=\(PrivacyLog.shortID(session.roomName))")
        logMediaStage("chirp.media.room.connecting", session: session)

        let connectOptions = ConnectOptions(
            autoSubscribe: true,
            reconnectAttempts: 8,
            reconnectAttemptDelay: 0.8,
            reconnectMaxDelay: 6.0,
            iceTransportPolicy: .all
        )
        let roomOptions = RoomOptions(
            defaultAudioCaptureOptions: AudioCaptureOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true
            ),
            adaptiveStream: true,
            dynacast: true
        )

        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        // Walkie does not go through CallKit, so ensure LiveKit's audio engine is enabled.
        try? AudioManager.shared.setEngineAvailability(.default)
        try activateChirpAudioSession()

        let room = Room(delegate: self, connectOptions: connectOptions, roomOptions: roomOptions)
        print("LiveKit connect caller:", #fileID, #function)
        print("LiveKit connect URL:", PrivacyLog.redact(url.absoluteString))
        try await room.connect(url: url.absoluteString, token: token)
        try await room.localParticipant.setMicrophone(enabled: false)

        self.room = room
        signalingConnected = true
        mediaConnected = true
        localAudioPublished = false
        remoteAudioSubscribed = false
        remoteAudioStarted = false
        lastMediaError = nil
        logMediaStage("chirp.media.room.connected", session: session, room: room)
        print("✅ WALKIE connected")
        print("👤 WALKIE local identity:", PrivacyLog.shortID(room.localParticipant.identity?.stringValue))
        print("👥 WALKIE remote count:", room.remoteParticipants.count)
        print("🛑 WALKIE mic initially OFF")
        logChirp("CHIRP_TRANSPORT_CONNECTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))", "roomName=\(PrivacyLog.shortID(session.roomName))")
        logChirp("CHIRP_SOCKET_CONNECTED", "sessionId=\(PrivacyLog.shortID(session.sessionId))", "roomName=\(PrivacyLog.shortID(session.roomName))")
        pushToTalkState = .readyToTransmit
        state = .listening
        didConnectChirpSession = true
    }

    private func normalizedGroupTargets() -> [String] {
        let separators = CharacterSet(charactersIn: ",\n;")
        return groupTargetsText
            .components(separatedBy: separators)
            .compactMap { normalizeTargetInput($0) }
            .reduce(into: [String]()) { result, value in
                if !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                    result.append(value)
                }
            }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func activateChirpAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        // Keep the Chirp button's tactile clicks available while the microphone is active.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        try? session.overrideOutputAudioPort(.speaker)
        logAudioRoute(context: "chirp.audio.session.activated")
    }

    private func hasRemoteParticipant(in room: Room) -> Bool {
        !room.remoteParticipants.isEmpty
    }

    private func waitForRemoteParticipant(
        in room: Room,
        timeoutSeconds: TimeInterval,
        transmission: WalkieTransmissionContext
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if releaseRequestedDuringStartup {
                return
            }
            if hasRemoteParticipant(in: room) {
                logMediaStage("chirp.remote.participant.detected", transmission: transmission, room: room)
                return
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw WalkieMediaError.remoteParticipantUnavailable
    }

    private func releaseTransmitLock(
        sessionId: String,
        transmission: WalkieTransmissionContext?,
        room: Room?
    ) async {
        _ = try? await service.releaseTransmit(sessionId: sessionId)
        logMediaStage("chirp.channel.released", transmission: transmission, room: room)
    }

    private func playChirpCue(_ sound: OneWaySound, cueType: String, transmission: WalkieTransmissionContext?) {
        logChirp("CHIRP_CUE_PLAY_REQUESTED", "cueType=\(cueType)", "filename=\(sound.rawValue)", "scope=\(cueType.hasPrefix("remote") ? "remote" : "local")")
        ChirpSoundController.shared.play(sound)
        logChirp("CHIRP_CUE_PLAYED", "cueType=\(cueType)", "filename=\(sound.rawValue)")
    }

    private func resetTransmitStateAfterCancelledStart() {
        activeTransmission = nil
        releaseRequestedDuringStartup = false
        localAudioPublished = false
        if activeSession != nil {
            pushToTalkState = .readyToTransmit
            state = .listening
        } else {
            pushToTalkState = .idle
            state = .ready
        }
    }

    private func logMediaStage(
        _ stage: String,
        session: WalkieSessionResponse? = nil,
        transmission: WalkieTransmissionContext? = nil,
        room: Room? = nil,
        error: Error? = nil,
        errorDescription: String? = nil
    ) {
        let active = session ?? transmission?.session ?? activeSession
        let currentUserId = AuthTokenStore.shared.currentUserID()
        let senderUserId = transmission?.senderUserId ?? currentUserId
        let participantIdentity = room?.localParticipant.identity?.stringValue ?? currentUserId
        let receiverUserIds = (active?.participants ?? [])
            .map(\.userId)
            .filter { $0 != senderUserId }
            .map { PrivacyLog.shortID($0) }
            .joined(separator: ",")
        let route = audioRouteDescription()
        let errorText = errorDescription ?? error?.localizedDescription
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = [
            "event=\(stage)",
            "timestamp=\(timestamp)",
            "transmissionId=\(PrivacyLog.shortID(transmission?.transmissionId))",
            "channelId=\(PrivacyLog.shortID(active?.channelId))",
            "sessionId=\(PrivacyLog.shortID(active?.sessionId))",
            "senderUserId=\(PrivacyLog.shortID(senderUserId))",
            "receiverUserIds=\(receiverUserIds.isEmpty ? "none" : receiverUserIds)",
            "roomName=\(PrivacyLog.shortID(active?.roomName ?? room?.name))",
            "participantIdentity=\(PrivacyLog.shortID(participantIdentity))",
            "remoteParticipants=\(room?.remoteParticipants.count ?? 0)",
            "localAudioPublished=\(localAudioPublished)",
            "remoteAudioSubscribed=\(remoteAudioSubscribed)",
            "audioRoute=\(route)",
            "error=\(PrivacyLog.redact(errorText ?? "none"))"
        ].joined(separator: " ")

        latestTransmissionTimeline.append(line)
        if latestTransmissionTimeline.count > 80 {
            latestTransmissionTimeline.removeFirst(latestTransmissionTimeline.count - 80)
        }

#if DEBUG
        print("🎙 CHIRP MEDIA", line)
#endif
    }

    private func audioRouteDescription() -> String {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: "|")
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: "|")
        return "category=\(session.category.rawValue),mode=\(session.mode.rawValue),inputs=\(inputs.isEmpty ? "none" : inputs),outputs=\(outputs.isEmpty ? "none" : outputs),sampleRate=\(session.sampleRate),ioBuffer=\(session.ioBufferDuration)"
    }

    private func logAudioRoute(context: String) {
#if DEBUG
        print("🎧 WALKIE audio route \(context): \(audioRouteDescription())")
#endif
    }

    private func isLiveKitWebSocketURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "ws" || scheme == "wss"
    }

    private func isAPIBackendURL(_ url: URL) -> Bool {
        guard let apiBaseURL = URL(string: APIConfig.baseURL),
              let liveKitHost = url.host?.lowercased(),
              let apiHost = apiBaseURL.host?.lowercased(),
              liveKitHost == apiHost else {
            return false
        }
        return resolvedPort(for: url) == resolvedPort(for: apiBaseURL)
    }

    private func resolvedPort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http", "ws":
            return 80
        case "https", "wss":
            return 443
        default:
            return nil
        }
    }
}

private extension AVAudioApplication.recordPermission {
    var chirpLogValue: String {
        switch self {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .undetermined:
            return "undetermined"
        @unknown default:
            return "unknown"
        }
    }
}

private enum WalkieError: LocalizedError {
    case unavailable(String)
    case invalidLiveKitURL(String)
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .invalidLiveKitURL(let value):
            return "Invalid LiveKit URL: \(value)"
        case .microphoneDenied:
            return "Microphone permission is required for Chirp."
        }
    }
}

private enum WalkieMediaError: LocalizedError {
    case remoteParticipantUnavailable

    var errorDescription: String? {
        switch self {
        case .remoteParticipantUnavailable:
            return "No receiver joined the Chirp audio channel."
        }
    }
}

private struct WalkieTransmissionContext {
    let transmissionId: String
    let session: WalkieSessionResponse
    let senderUserId: String
}

extension WalkieViewModel: RoomDelegate {
    nonisolated func roomDidConnect(_ room: Room) {
        print("✅ WALKIE roomDidConnect")
        Task { @MainActor in
            self.signalingConnected = true
            self.mediaConnected = true
            self.logMediaStage("chirp.media.room.connected", room: room)
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        print("👤 WALKIE participant connected:", PrivacyLog.shortID(participant.identity?.stringValue))
        Task { @MainActor in
            self.logMediaStage("chirp.remote.participant.detected", room: room)
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let kind = publication.kind
        print("🔊 WALKIE subscribed track kind:", kind)
        print("🔊 WALKIE remote participant:", PrivacyLog.shortID(participant.identity?.stringValue))
        if kind == .audio {
            Task { @MainActor in
            self.remoteAudioSubscribed = true
            self.remoteAudioStarted = true
            self.lastMediaError = nil
                if self.pushToTalkState != .transmitting && self.pushToTalkState != .publishing {
                    self.pushToTalkState = .receiving
                    self.state = .listening
                }
                self.logMediaStage("chirp.remote.track.subscribed", room: room)
                self.logChirp("CHIRP_PACKET_RECEIVED", "sequence=livekit_managed", "bytes=livekit_managed")
                self.logChirp("CHIRP_PACKET_DECRYPTED", "sequence=livekit_managed", "transport=livekit_srtp")
                self.logChirp("CHIRP_DECODER_STARTED", "codec=livekit_opus")
                self.logChirp("CHIRP_AUDIO_FRAME_RECEIVED", "sequence=livekit_managed", "bytes=livekit_managed")
                self.playChirpCue(.chirpIncoming, cueType: "remote_start", transmission: nil)
                self.logChirp("CHIRP_PLAYBACK_STARTED", "participantId=\(PrivacyLog.shortID(participant.identity?.stringValue))")
                self.logMediaStage("chirp.remote.audio.started", room: room)
            }
        }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        print("📤 WALKIE local didPublishTrack kind:", publication.kind)
        if publication.kind == .audio {
            Task { @MainActor in
                self.localAudioPublished = true
                self.logMediaStage("chirp.local.track.published", room: room)
            }
        }
    }

    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            if connectionState == .connected {
                self.signalingConnected = true
                self.mediaConnected = true
                self.logChirp("CHIRP_TRANSPORT_CONNECTED", "reconnectState=\(oldConnectionState == .reconnecting ? "reconnected" : "connected")")
                self.logMediaStage("chirp.media.room.connected", room: room)
            } else if connectionState == .reconnecting {
                self.mediaConnected = false
                self.pushToTalkState = .reconnecting
                self.logChirp("CHIRP_TRANSPORT_DISCONNECTED", "reconnectState=reconnecting")
            } else if connectionState == .disconnected, self.activeSession != nil {
                self.signalingConnected = false
                self.mediaConnected = false
                self.localAudioPublished = false
                self.remoteAudioSubscribed = false
                self.remoteAudioStarted = false
                self.pushToTalkState = .reconnecting
                self.state = .ended
                self.logChirp("CHIRP_TRANSPORT_DISCONNECTED", "reconnectState=disconnected")
            }
        }
    }

    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        Task { @MainActor in
            self.signalingConnected = false
            self.mediaConnected = false
            self.lastMediaError = error?.localizedDescription ?? "Chirp failed to connect."
            self.state = .error(error?.localizedDescription ?? "Chirp failed to connect.")
            self.pushToTalkState = .failed(error?.localizedDescription ?? "Chirp failed to connect.")
            self.errorMessage = error?.localizedDescription ?? "Chirp failed to connect."
            self.logChirp("CHIRP_TRANSPORT_ERROR", "error=\(PrivacyLog.redact(error?.localizedDescription ?? "unknown"))")
            self.logChirp("CHIRP_SOCKET_CONNECT_FAILED", "error=\(PrivacyLog.redact(error?.localizedDescription ?? "unknown"))")
            self.logMediaStage("chirp.media.room.connect_failed", room: room, error: error)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            self.signalingConnected = false
            self.mediaConnected = false
            self.localAudioPublished = false
            self.remoteAudioSubscribed = false
            self.remoteAudioStarted = false
            if let error {
                self.lastMediaError = error.localizedDescription
                self.state = .error(error.localizedDescription)
                self.pushToTalkState = .failed(error.localizedDescription)
                self.errorMessage = error.localizedDescription
                self.logChirp("CHIRP_TRANSPORT_ERROR", "error=\(PrivacyLog.redact(error.localizedDescription))")
                self.logChirp("CHIRP_SOCKET_FAILED", "error=\(PrivacyLog.redact(error.localizedDescription))")
                self.logMediaStage("chirp.media.room.disconnected", room: room, error: error)
            } else if self.activeSession != nil {
                self.pushToTalkState = .idle
                self.state = .ended
                self.logMediaStage("chirp.media.room.disconnected", room: room)
            }
        }
    }
}

private struct WalkieContactCache {
    private let defaults = UserDefaults.standard
    private let keyPrefix = "OneWay.WalkieContacts."

    func load(userID: String) -> [WalkieContact] {
        guard let data = defaults.data(forKey: keyPrefix + userID) else { return [] }
        return (try? JSONDecoder().decode([WalkieContact].self, from: data)) ?? []
    }

    func save(_ contacts: [WalkieContact], userID: String) {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        defaults.set(data, forKey: keyPrefix + userID)
    }
}

@MainActor
final class ChirpSoundController {
    static let shared = ChirpSoundController()

    private init() {}

    func play(_ sound: OneWaySound) {
        let currentMode = MediaModeCoordinator.shared.currentMode
        let currentSessionId = MediaModeCoordinator.shared.currentSessionId
        let chirpEvent = ChirpSoundEvent(sound: sound)
        guard CallSoundSuppressionController.shared.mayPlayChirpSound() else {
            #if DEBUG
            print(
                "CHIRP_SOUND_HARD_BLOCKED",
                "sound=\(sound.rawValue)",
                "source=ChirpSoundController.play",
                "callIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            print(
                "CHIRP_SOUND_EVENT_DROPPED_DURING_CALL",
                "eventId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                "sound=\(sound.rawValue)",
                "callIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
                "source=ChirpSoundController.play",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return
        }
        #if DEBUG
        print(
            "CHIRP_SOUND_REQUESTED",
            "sound=\(sound.rawValue)",
            "eventType=\(chirpEvent?.rawValue ?? sound.rawValue)",
            "communicationMode=\(currentMode.rawValue)",
            "callOrChirpId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
            "sourceFile=WalkieViewModel.swift",
            "function=ChirpSoundController.play",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif

        guard let chirpEvent else {
            #if DEBUG
            print(
                "CHIRP_SOUND_BLOCKED",
                "sound=\(sound.rawValue)",
                "eventType=\(sound.rawValue)",
                "communicationMode=\(currentMode.rawValue)",
                "callOrChirpId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                "reason=not_chirp_sound_event",
                "sourceFile=WalkieViewModel.swift",
                "function=ChirpSoundController.play",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return
        }

        guard CommunicationSoundPolicy.allowsChirpSound(currentMode: currentMode, event: chirpEvent) else {
            #if DEBUG
            print(
                "CHIRP_SOUND_BLOCKED",
                "sound=\(sound.rawValue)",
                "eventType=\(chirpEvent.rawValue)",
                "communicationMode=\(currentMode.rawValue)",
                "callOrChirpId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                "reason=communication_mode_not_chirp",
                "sourceFile=WalkieViewModel.swift",
                "function=ChirpSoundController.play",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            if currentMode == .audioCall || currentMode == .videoCall {
                print(
                    "CHIRP_SOUND_BLOCKED_FOR_CALL",
                    "sound=\(sound.rawValue)",
                    "eventType=\(chirpEvent.rawValue)",
                    "communicationMode=\(currentMode.rawValue)",
                    "callId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                    "sourceFile=WalkieViewModel.swift",
                    "function=ChirpSoundController.play",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
            }
            #endif
            return
        }

        switch sound {
        case .chirpStart:
            OneWayChirpPlayer.shared.play(.ready)
        case .chirpEnd:
            OneWayChirpPlayer.shared.play(.end)
        case .chirpIncoming, .chirpRequest:
            OneWayChirpPlayer.shared.play(.incoming)
        case .incomingCallRingtone, .outgoingRingback, .callConnected, .callEnded:
            #if DEBUG
            print(
                "CHIRP_SOUND_REJECTED_CALL_SOUND",
                "sound=\(sound.rawValue)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
        }
    }
}

@MainActor
private final class OneWayChirpPlayer {
    enum ChirpKind {
        case ready
        case end
        case incoming
    }

    static let shared = OneWayChirpPlayer()

    private var players: [String: AVAudioPlayer] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    private init() {
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .callSoundSuppressionAcquired,
                object: nil,
                queue: nil
            ) { _ in
                Task { @MainActor in
                    OneWayChirpPlayer.shared.stopAllActiveAudio(reason: "call_sound_suppression_acquired")
                }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .callSoundSuppressionClearedChirpAudio,
                object: nil,
                queue: nil
            ) { _ in
                Task { @MainActor in
                    OneWayChirpPlayer.shared.stopAllActiveAudio(reason: "call_sound_suppression_cleared_chirp_audio")
                }
            }
        )
    }

    func play(_ kind: ChirpKind) {
        let sound = oneWaySound(for: kind)
        let currentMode = MediaModeCoordinator.shared.currentMode
        let currentSessionId = MediaModeCoordinator.shared.currentSessionId
        let descriptor = AppSoundDescriptor(name: sound.rawValue, category: .chirp)
        guard CallSoundSuppressionController.shared.mayPlayChirpSound() else {
            #if DEBUG
            assertionFailure("Chirp audio reached playback during call suppression")
            print(
                "CHIRP_SOUND_HARD_BLOCKED",
                "sound=\(sound.rawValue)",
                "source=OneWayChirpPlayer.play",
                "callIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            print(
                "CHIRP_SOUND_EVENT_DROPPED_DURING_CALL",
                "eventId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                "sound=\(sound.rawValue)",
                "callIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
                "source=OneWayChirpPlayer.play",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return
        }
        SoundDiagnostics.logRequested(
            sound: descriptor,
            mode: currentMode,
            callId: MediaModeCoordinator.shared.isCallActive ? currentSessionId : nil,
            chirpId: MediaModeCoordinator.shared.isCallActive ? nil : currentSessionId,
            sourceFile: #fileID,
            sourceFunction: #function
        )
        let chirpEvent = ChirpSoundEvent(sound: sound)!
        guard CommunicationSoundPolicy.allowsChirpSound(currentMode: currentMode, event: chirpEvent),
              ManualSoundAuthorization.isAllowed(sound: descriptor, communicationMode: currentMode) else {
            SoundDiagnostics.logBlocked(
                sound: descriptor,
                mode: currentMode,
                callId: MediaModeCoordinator.shared.isCallActive ? currentSessionId : nil,
                chirpId: MediaModeCoordinator.shared.isCallActive ? nil : currentSessionId,
                reason: "communication_mode_not_chirp",
                sourceFile: #fileID,
                sourceFunction: #function
            )
            #if DEBUG
            print(
                "CHIRP_SOUND_BLOCKED",
                "sound=\(sound.rawValue)",
                "eventType=\(chirpEvent.rawValue)",
                "communicationMode=\(currentMode.rawValue)",
                "callOrChirpId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                "reason=communication_mode_not_chirp",
                "sourceFile=WalkieViewModel.swift",
                "function=OneWayChirpPlayer.play",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            if currentMode == .audioCall || currentMode == .videoCall {
                print(
                    "CHIRP_SOUND_BLOCKED_FOR_CALL",
                    "sound=\(sound.rawValue)",
                    "eventType=\(chirpEvent.rawValue)",
                    "communicationMode=\(currentMode.rawValue)",
                    "callId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                    "sourceFile=WalkieViewModel.swift",
                    "function=OneWayChirpPlayer.play",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
            }
            #endif
            return
        }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "OneWay.Walkie.ChirpSoundsOn") as? Bool ?? true else { return }
        guard isEnabled(kind, defaults: defaults) else { return }

        do {
            let key = cacheKey(for: kind, defaults: defaults)
            let player: AVAudioPlayer
            if let cached = players[key] {
                player = cached
            } else {
                let fresh = try makePlayer(for: kind, defaults: defaults)
                players[key] = fresh
                player = fresh
            }
            players[key] = player
            player.currentTime = 0
            player.volume = Float(defaults.object(forKey: "OneWay.Walkie.ChirpVolume") as? Double ?? 0.72)
            SoundDiagnostics.logAudioPlayRequest(
                filename: "synthesized_OneWayChirpPlayer_\(kind).wav",
                soundID: sound.rawValue,
                systemSoundID: nil,
                avAudioPlayerURL: "AVAudioPlayer(data:synthesized_OneWayChirpPlayer_\(kind))",
                avPlayerURL: nil,
                category: .chirp,
                callId: MediaModeCoordinator.shared.isCallActive ? currentSessionId : nil,
                sourceFile: #fileID,
                sourceFunction: #function,
                line: #line
            )
            player.play()
            SoundDiagnostics.logPlayed(
                sound: descriptor,
                mode: currentMode,
                callId: nil,
                chirpId: currentSessionId,
                sourceFile: #fileID,
                sourceFunction: #function
            )
            if defaults.object(forKey: "OneWay.Walkie.VibrateOnChirp") as? Bool ?? true {
                let vibration = AppSoundDescriptor(name: "SystemSoundID:1519", category: .audioServices)
                SoundDiagnostics.logRequested(
                    sound: vibration,
                    mode: currentMode,
                    callId: MediaModeCoordinator.shared.isCallActive ? currentSessionId : nil,
                    chirpId: MediaModeCoordinator.shared.isCallActive ? nil : currentSessionId,
                    sourceFile: #fileID,
                    sourceFunction: #function
                )
                if ManualSoundAuthorization.isAllowed(sound: vibration, communicationMode: currentMode) {
                    SoundDiagnostics.logAudioPlayRequest(
                        filename: "SystemSoundID:1519",
                        soundID: "1519",
                        systemSoundID: "1519",
                        avAudioPlayerURL: nil,
                        avPlayerURL: nil,
                        category: .audioServices,
                        callId: MediaModeCoordinator.shared.isCallActive ? currentSessionId : nil,
                        sourceFile: #fileID,
                        sourceFunction: #function,
                        line: #line
                    )
                    AudioServicesPlaySystemSound(1519)
                    SoundDiagnostics.logPlayed(
                        sound: vibration,
                        mode: currentMode,
                        callId: nil,
                        chirpId: currentSessionId,
                        sourceFile: #fileID,
                        sourceFunction: #function
                    )
                } else {
                    SoundDiagnostics.logBlocked(
                        sound: vibration,
                        mode: currentMode,
                        callId: MediaModeCoordinator.shared.isCallActive ? currentSessionId : nil,
                        chirpId: MediaModeCoordinator.shared.isCallActive ? nil : currentSessionId,
                        reason: "manual_sound_blocked_during_call",
                        sourceFile: #fileID,
                        sourceFunction: #function
                    )
                }
            }
            #if DEBUG
            print(
                "CHIRP_SOUND_PLAYED",
                "sound=\(sound.rawValue)",
                "asset=synthesized_OneWayChirpPlayer_\(kind)",
                "eventType=\(chirpEvent.rawValue)",
                "communicationMode=\(currentMode.rawValue)",
                "callOrChirpId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                "sourceFile=WalkieViewModel.swift",
                "function=OneWayChirpPlayer.play",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
        } catch {
            #if DEBUG
            print("⚠️ Walkie chirp failed:", PrivacyLog.redact(error.localizedDescription))
            #endif
        }
    }

    private func stopAllActiveAudio(reason: String) {
        guard !players.isEmpty else { return }
        for (key, player) in players {
            player.stop()
            player.currentTime = 0
            #if DEBUG
            print(
                "ACTIVE_CHIRP_AUDIO_STOPPED_FOR_CALL",
                "player=OneWayChirpPlayer",
                "cacheKey=\(key)",
                "reason=\(reason)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
        }
        players.removeAll()
    }

    private func isEnabled(_ kind: ChirpKind, defaults: UserDefaults) -> Bool {
        switch kind {
        case .ready:
            return defaults.object(forKey: "OneWay.Walkie.TransmitChirp") as? Bool ?? true
        case .end:
            return defaults.object(forKey: "OneWay.Walkie.EndChirp") as? Bool ?? true
        case .incoming:
            return defaults.object(forKey: "OneWay.Walkie.IncomingChirp") as? Bool ?? true
        }
    }

    private func oneWaySound(for kind: ChirpKind) -> OneWaySound {
        switch kind {
        case .ready: return .chirpStart
        case .end: return .chirpEnd
        case .incoming: return .chirpIncoming
        }
    }

    private func cacheKey(for kind: ChirpKind, defaults: UserDefaults) -> String {
        "\(kind)-\(defaults.string(forKey: "OneWay.Walkie.SoundTheme") ?? "OneWay Classic")"
    }

    private func makePlayer(for kind: ChirpKind, defaults: UserDefaults) throws -> AVAudioPlayer {
        let theme = defaults.string(forKey: "OneWay.Walkie.SoundTheme") ?? "OneWay Classic"
        let data = synthesizeWAV(kind: kind, theme: theme)
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        return player
    }

    private func synthesizeWAV(kind: ChirpKind, theme: String) -> Data {
        let sampleRate = 44_100
        let duration: Double = 0.24
        let sampleCount = Int(Double(sampleRate) * duration)
        let frequencies = frequencyPair(kind: kind, theme: theme)
        var pcm = Data(capacity: sampleCount * 2)

        for sampleIndex in 0..<sampleCount {
            let t = Double(sampleIndex) / Double(sampleRate)
            let split = sampleCount / 2
            let frequency = sampleIndex < split ? frequencies.0 : frequencies.1
            let envelope = amplitudeEnvelope(sampleIndex: sampleIndex, sampleCount: sampleCount)
            let value = sin(2.0 * Double.pi * frequency * t) * envelope * 0.55
            var intSample = Int16(max(-1.0, min(1.0, value)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &intSample) { pcm.append(contentsOf: $0) }
        }

        return wavData(fromPCM: pcm, sampleRate: sampleRate)
    }

    private func frequencyPair(kind: ChirpKind, theme: String) -> (Double, Double) {
        let base: (Double, Double)
        switch theme {
        case "Minimal":
            base = (880, 1174)
        case "Soft":
            base = (659, 880)
        case "Tactical":
            base = (1200, 760)
        case "Silent":
            base = (0, 0)
        default:
            base = (1046, 1568)
        }

        switch kind {
        case .ready:
            return base
        case .end:
            return (base.1 * 0.82, base.0 * 0.72)
        case .incoming:
            return (base.0 * 0.9, base.1 * 1.1)
        }
    }

    private func amplitudeEnvelope(sampleIndex: Int, sampleCount: Int) -> Double {
        let attack = max(1, Int(Double(sampleCount) * 0.08))
        let releaseStart = Int(Double(sampleCount) * 0.76)
        if sampleIndex < attack {
            return Double(sampleIndex) / Double(attack)
        }
        if sampleIndex > releaseStart {
            return max(0, Double(sampleCount - sampleIndex) / Double(sampleCount - releaseStart))
        }
        return 1
    }

    private func wavData(fromPCM pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + pcm.count), to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(UInt32(sampleRate), to: &data)
        appendUInt32(UInt32(sampleRate * 2), to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
