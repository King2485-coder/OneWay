import Combine
import Foundation

enum AppSessionState: Equatable {
    case loading
    case unauthenticated
    case authenticatedComplete
    case authenticatedIncomplete
    case backendUnavailable
}

@MainActor
final class AppSessionViewModel: ObservableObject {
    @Published private(set) var state: AppSessionState = .loading

    private let profileService: AccountProfileService
    private let authService: AuthAPIService
    private var tokenObserver: NSObjectProtocol?
    private var isSigningOut = false
    private var refreshGeneration = 0
    #if DEBUG
    private var isApplyingDebugLogin = false
    #endif

    init(profileService: AccountProfileService = .shared, authService: AuthAPIService = .shared) {
        self.profileService = profileService
        self.authService = authService
        self.tokenObserver = NotificationCenter.default.addObserver(
            forName: AuthTokenStore.tokenDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    deinit {
        if let tokenObserver {
            NotificationCenter.default.removeObserver(tokenObserver)
        }
    }

    func refresh() async {
        if isSigningOut { return }

        refreshGeneration += 1
        let generation = refreshGeneration

        let previousState = state
        if previousState == .loading {
            state = .loading
        }

        if Self.explicitSignOutActive, AuthTokenStore.shared.token() == nil {
            guard isCurrentRefresh(generation) else { return }
            state = .unauthenticated
            return
        }

        #if DEBUG
        clearDebugLoginOverrideSessionIfNeeded()
        await applyDebugLoginOverrideIfNeeded()
        #endif

        let token = AuthTokenStore.shared.token()
        if token == nil {
            guard isCurrentRefresh(generation) else { return }
            state = .unauthenticated
            return
        }

        do {
            try await verifyAuthenticatedIdentity()
            guard isCurrentRefresh(generation) else { return }
            UserDefaults.standard.set(false, forKey: Self.explicitSignOutKey)

            let status = try await profileService.fetchProfileStatus()
            guard isCurrentRefresh(generation) else { return }
            if status.complete || profileCompleteHint {
                setProfileCompleteHint(true)
                state = .authenticatedComplete
            } else {
                setProfileCompleteHint(false)
                state = .authenticatedIncomplete
            }
        } catch let apiError as APIClientError {
            switch apiError {
            case .server(let statusCode, _) where statusCode == 401:
                // Token invalid. Clear locally; do not touch backend.
                guard isCurrentRefresh(generation) else { return }
                AuthTokenStore.shared.clearSession()
                state = .unauthenticated
            default:
                guard isCurrentRefresh(generation) else { return }
                recoverFromStartupNetworkFailure(previousState: previousState)
            }
        } catch let authError as AuthIdentityVerificationError {
            guard isCurrentRefresh(generation) else { return }
            print("AUTH_IDENTITY_MISMATCH", PrivacyLog.redact(authError.localizedDescription))
            AuthTokenStore.shared.clearSession()
            setProfileCompleteHint(false)
            state = .unauthenticated
        } catch {
            guard isCurrentRefresh(generation) else { return }
            recoverFromStartupNetworkFailure(previousState: previousState)
        }
    }

    func signOut(environment: AppEnvironment) async {
        guard !isSigningOut else { return }
        isSigningOut = true
        refreshGeneration += 1
        state = .loading
        UserDefaults.standard.set(true, forKey: Self.explicitSignOutKey)

        AppWalkieMonitor.shared.stop()
        setProfileCompleteHint(false)
        NetworkFriendService.disconnectRealtime()
        NetworkMessagingService.disconnectRealtime()
        CommunityRealtimeClient.shared.disconnect()

        if let activeCallUUID = CallKitManager.shared.activeCallUUID {
            try? await environment.callService.endCall(sessionID: activeCallUUID)
            CallKitManager.shared.endCall(uuid: activeCallUUID)
        }
        await LiveKitManager.shared.disconnect()
        URLCache.shared.removeAllCachedResponses()
        await AppDelegate.shared.unregisterEmailAlertsBeforeSignOut()

        #if DEBUG
        AuthTokenStore.shared.clearDebugAccountOverrides()
        #endif

        AuthTokenStore.shared.clearSession()
        state = .unauthenticated
        isSigningOut = false
    }

    func finishOnboardingAndEnter() {
        setProfileCompleteHint(true)
        UserDefaults.standard.set(false, forKey: Self.explicitSignOutKey)
        state = .authenticatedComplete
    }

    func logout() {
        setProfileCompleteHint(false)
        AuthTokenStore.shared.clearSession()
        UserDefaults.standard.set(true, forKey: Self.explicitSignOutKey)
        state = .unauthenticated
    }

    private func recoverFromStartupNetworkFailure(previousState: AppSessionState) {
        if !cachedSessionIdentityMatchesToken() {
            print("AUTH_IDENTITY_MISMATCH cached session does not match token subject")
            AuthTokenStore.shared.clearSession()
            setProfileCompleteHint(false)
            state = .unauthenticated
            return
        }

        switch previousState {
        case .authenticatedComplete, .authenticatedIncomplete:
            state = previousState
        case .loading, .unauthenticated, .backendUnavailable:
            // Backend reachability is advisory at launch. A communication app
            // should open its cached shell immediately and let individual
            // network-backed features show their own retry/offline state.
            setProfileCompleteHint(true)
            state = .authenticatedComplete
        }
    }

    private static let profileCompleteHintKey = "oneway.profileCompleteHint"
    private static let explicitSignOutKey = "OneWay.SessionExplicitlySignedOut"

    private var profileCompleteHint: Bool {
        UserDefaults.standard.bool(forKey: Self.profileCompleteHintKey(for: AuthTokenStore.shared.currentUserID()))
    }

    private func setProfileCompleteHint(_ value: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: Self.profileCompleteHintKey(for: AuthTokenStore.shared.currentUserID()))
    }

    private static func profileCompleteHintKey(for userID: String) -> String {
        "\(profileCompleteHintKey).\(userID)"
    }

    private static var explicitSignOutActive: Bool {
        UserDefaults.standard.bool(forKey: explicitSignOutKey)
    }

    private func verifyAuthenticatedIdentity() async throws {
        let authUser = try await authService.currentAuthenticatedUser()
        let storedUserID = AuthTokenStore.shared.storedUserID()
        if storedUserID?.caseInsensitiveCompare(authUser.userId) != .orderedSame {
            print(
                "auth.identity.user_id.corrected",
                "stored=\(PrivacyLog.shortID(storedUserID))",
                "verified=\(PrivacyLog.shortID(authUser.userId))"
            )
            AuthTokenStore.shared.setUserID(authUser.userId)
        }
    }

    private func isCurrentRefresh(_ generation: Int) -> Bool {
        generation == refreshGeneration && !isSigningOut
    }

    private func cachedSessionIdentityMatchesToken() -> Bool {
        guard let tokenSubject = AuthTokenStore.shared.tokenSubject() else { return true }
        guard let storedUserID = AuthTokenStore.shared.storedUserID() else { return false }
        return tokenSubject.caseInsensitiveCompare(storedUserID) == .orderedSame
    }

    #if DEBUG
    private func clearDebugLoginOverrideSessionIfNeeded() {
        guard !Self.debugLoginOverrideEnabled else { return }
        guard UserDefaults.standard.string(forKey: Self.debugLoginUserIDKey) != nil else { return }

        AuthTokenStore.shared.clearSession()
        AuthTokenStore.shared.clearDebugAccountOverrides()
    }

    private func applyDebugLoginOverrideIfNeeded() async {
        guard Self.debugLoginOverrideEnabled, !isApplyingDebugLogin else { return }

        let identifier = Self.debugLoginIdentifier
        let password = Self.debugLoginPassword
        guard !identifier.isEmpty, !password.isEmpty else { return }

        let storedIdentifier = UserDefaults.standard.string(forKey: Self.debugLoginIdentifierKey)
        let storedUserID = UserDefaults.standard.string(forKey: Self.debugLoginUserIDKey)
        if storedIdentifier == identifier,
           let storedUserID,
           AuthTokenStore.shared.currentUserID() == storedUserID {
            return
        }
        if AuthTokenStore.shared.token() != nil {
            guard Self.debugLoginForceEnabled else { return }
            AuthTokenStore.shared.clearSession()
        }

        isApplyingDebugLogin = true
        defer { isApplyingDebugLogin = false }

        do {
            let response = try await AuthAPIService.shared.login(identifier: identifier, password: password)
            AuthTokenStore.shared.setSession(userID: response.user.id, token: response.token)
            UserDefaults.standard.set(identifier, forKey: Self.debugLoginIdentifierKey)
            UserDefaults.standard.set(response.user.id, forKey: Self.debugLoginUserIDKey)
            print("🔐 DEBUG login override user:", PrivacyLog.shortID(response.user.id))
        } catch {
            print("🔐 DEBUG login override failed:", error.localizedDescription)
        }
    }

    private static let debugLoginIdentifierKey = "OneWay.DebugLoginIdentifier"
    private static let debugLoginUserIDKey = "OneWay.DebugLoginUserID"

    private static var debugLoginOverrideEnabled: Bool {
        let environmentValue = ProcessInfo.processInfo.environment["ONEWAY_DEBUG_LOGIN_ENABLED"]
        if let environmentValue {
            let normalized = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "1" || normalized == "true" || normalized == "yes"
        }
        return false
    }

    private static var debugLoginForceEnabled: Bool {
        let environmentValue = ProcessInfo.processInfo.environment["ONEWAY_DEBUG_LOGIN_FORCE"]
        if let environmentValue {
            let normalized = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "1" || normalized == "true" || normalized == "yes"
        }

        if let defaultsValue = UserDefaults.standard.object(forKey: "OneWay.DebugLoginForce") as? Bool {
            return defaultsValue
        }

        return false
    }

    private static var debugLoginIdentifier: String {
        ProcessInfo.processInfo.environment["ONEWAY_DEBUG_LOGIN_IDENTIFIER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }

    private static var debugLoginPassword: String {
        ProcessInfo.processInfo.environment["ONEWAY_DEBUG_LOGIN_PASSWORD"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }
    #endif
}
