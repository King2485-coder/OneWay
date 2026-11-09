import Foundation
import Combine

@MainActor
final class AppLaunchViewModel: ObservableObject {
    private enum StorageKeys {
        static let profileCompleteHint = "oneway.profileCompleteHint"

        static func profileCompleteHintKey(for userID: String?) -> String {
            guard let userID, !userID.isEmpty else { return profileCompleteHint }
            return "\(profileCompleteHint).\(userID)"
        }
    }

    enum State: Equatable {
        case loading
        case needsOnboarding
        case ready
        case unableToVerify(String)
    }

    @Published private(set) var state: State = .loading

    private let profileService: AccountProfileService
    private let identityService: OneWayIdentityService
    private let numberService: OneWayNumberService

    init(profileService: AccountProfileService = .shared) {
        self.profileService = profileService
        self.identityService = .shared
        self.numberService = .shared
    }

    func load() async {
        do {
            let status = try await profileService.fetchProfileStatus()
            if status.complete {
                setProfileCompleteHint(true)
                state = .ready
                return
            }

            // Protect against false onboarding: confirm with backend identity + numbers.
            async let identityTask: OneWayIdentity = identityService.fetchMyIdentity()
            async let numbersTask: OneWayNumbersResponse = numberService.fetchMyNumbers()

            do {
                let identity = try await identityTask
                let numbers = try await numbersTask
                let isIdentityComplete = !identity.onewayId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !identity.emailAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasTwoFreeNumbers = numbers.numbers.count >= 2

                let complete = isIdentityComplete && hasTwoFreeNumbers
                setProfileCompleteHint(complete)
                state = complete ? .ready : .needsOnboarding
            } catch {
                // If the profile-status endpoint worked but the detail fetch failed,
                // do not force onboarding; the backend is in a partial/unreliable state.
                state = .unableToVerify("Unable to verify session.")
            }
        } catch let apiError as APIClientError {
            switch apiError {
            case .server(let statusCode, _) where statusCode == 401:
                // Auth token invalid/missing (in prod). In dev mode, this should be rare.
                setProfileCompleteHint(false)
                state = .needsOnboarding
            case .invalidResponse, .invalidBaseURL, .emptyResponse:
                state = .unableToVerify("Unable to verify session.")
            case .server(_, let message):
                // For non-401 server errors, avoid forcing onboarding.
                state = .unableToVerify(message.isEmpty ? "Unable to verify session." : message)
            }
        } catch {
            // Network reachability must never block app launch. Open the cached
            // shell and let network-backed features present their own retry UI.
            setProfileCompleteHint(true)
            state = .ready
        }
    }

    func finishOnboarding() {
        setProfileCompleteHint(true)
        state = .ready
    }

    func continueOfflineIfPreviouslyComplete() {
        let hint = Self.hasProfileCompleteHint()
        guard hint else { return }
        state = .ready
    }

    func restartOnboarding() {
        setProfileCompleteHint(false)
        state = .needsOnboarding
    }

    static func hasProfileCompleteHint() -> Bool {
        UserDefaults.standard.bool(
            forKey: StorageKeys.profileCompleteHintKey(for: AuthTokenStore.shared.storedUserID())
        )
    }

    private func setProfileCompleteHint(_ value: Bool) {
        UserDefaults.standard.set(
            value,
            forKey: StorageKeys.profileCompleteHintKey(for: AuthTokenStore.shared.storedUserID())
        )
    }
}
