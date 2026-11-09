import SwiftUI
import Combine

@MainActor
final class AccountViewModel: ObservableObject {
    struct Snapshot: Codable, Equatable {
        var displayName: String? = nil
        var username: String? = nil
        var oneWayID: String? = nil
        var chirpID: String? = nil
        var email: String? = nil
        var primaryNumber: String? = nil
        var profilePhotoData: Data? = nil

        static let empty = Snapshot()
    }

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var blockedHandles: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSigningOut = false
    @Published var errorMessage: String?

    private let storyService: StoryService
    private let safetyService: SafetyService
    private let onSignOut: () async -> Void
    private let defaults: UserDefaults
    private let cacheKey: String
    private var currentLoadID: UUID?

    init(
        storyService: StoryService,
        safetyService: SafetyService,
        defaults: UserDefaults = .standard,
        onSignOut: @escaping () async -> Void
    ) {
        self.storyService = storyService
        self.safetyService = safetyService
        self.onSignOut = onSignOut
        self.defaults = defaults
        self.cacheKey = "oneway.account.safe-profile.\(AuthTokenStore.shared.currentUserID())"
        if let data = defaults.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = cached
        } else {
            snapshot = .empty
        }
    }

    func load() async {
        guard !isLoading else { return }
        let loadID = UUID()
        currentLoadID = loadID
        isLoading = true
        errorMessage = nil
        var errors: [String] = []

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.currentLoadID == loadID, self.isLoading else { return }
            self.isLoading = false
            self.errorMessage = "Account information is taking too long to refresh. Cached information is shown where available."
        }

        async let userRequest = fetchUser()
        async let identityRequest = fetchIdentity()
        async let numbersRequest = fetchNumbers()
        async let photoRequest = fetchPhoto()
        async let blockedRequest = fetchBlockedHandles()
        let (userResult, identityResult, numbersResult, photoResult, blockedResult) = await (
            userRequest, identityRequest, numbersRequest, photoRequest, blockedRequest
        )

        // A retry may have superseded this refresh while an offline request was
        // waiting for connectivity. Never let that older request overwrite the
        // newer Account state.
        guard currentLoadID == loadID else { return }

        switch userResult {
        case .success(let user):
            snapshot.displayName = nonBlank(user.displayName) ?? snapshot.displayName
            snapshot.username = nonBlank(user.username) ?? snapshot.username
            snapshot.oneWayID = nonBlank(user.handle) ?? snapshot.oneWayID
            snapshot.chirpID = nonBlank(user.chirpId) ?? snapshot.chirpID
            snapshot.email = nonBlank(user.email) ?? snapshot.email
            persistSnapshot()
        case .failure:
            errors.append("account")
        }

        switch identityResult {
        case .success(let identity):
            snapshot.displayName = nonBlank(identity.displayName) ?? snapshot.displayName
            snapshot.username = nonBlank(identity.username) ?? snapshot.username
            snapshot.oneWayID = nonBlank(identity.onewayId) ?? snapshot.oneWayID
            snapshot.chirpID = nonBlank(identity.chirpId) ?? snapshot.chirpID
            persistSnapshot()
        case .failure:
            errors.append("identity")
        }

        switch numbersResult {
        case .success(let response):
            snapshot.primaryNumber = response.numbers.first(where: \.isPrimary)?.number
                ?? response.numbers.first?.number
            persistSnapshot()
        case .failure:
            errors.append("numbers")
        }

        switch photoResult {
        case .success(let photo):
            if let photo {
                snapshot.profilePhotoData = photo
                persistSnapshot()
            }
        case .failure:
            errors.append("photo")
        }

        switch blockedResult {
        case .success(let handles):
            blockedHandles = handles
        case .failure:
            errors.append("blocked accounts")
        }

        isLoading = false
        currentLoadID = nil
        if !errors.isEmpty {
            errorMessage = "Some account information could not be refreshed. Cached information is shown where available."
        }
    }

    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        await onSignOut()
        isSigningOut = false
    }

    private func persistSnapshot() {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: cacheKey)
        }
    }

    private func fetchUser() async -> Result<AuthenticatedUserDTO, Error> {
        do { return .success(try await AuthAPIService.shared.currentAuthenticatedUser()) }
        catch { return .failure(error) }
    }

    private func fetchIdentity() async -> Result<OneWayIdentity, Error> {
        do { return .success(try await OneWayIdentityService.shared.fetchMyIdentity()) }
        catch { return .failure(error) }
    }

    private func fetchNumbers() async -> Result<OneWayNumbersResponse, Error> {
        do { return .success(try await OneWayNumberService.shared.fetchMyNumbers()) }
        catch { return .failure(error) }
    }

    private func fetchPhoto() async -> Result<Data?, Error> {
        do { return .success(try await storyService.loadMyProfilePhoto()) }
        catch { return .failure(error) }
    }

    private func fetchBlockedHandles() async -> Result<[String], Error> {
        do { return .success(try await safetyService.fetchBlockedHandles()) }
        catch { return .failure(error) }
    }

    private func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AccountView: View {
    @StateObject private var viewModel: AccountViewModel
    @State private var showsRecovery = false
    @State private var confirmsSignOut = false

    init(
        storyService: StoryService,
        safetyService: SafetyService,
        onSignOut: @escaping () async -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: AccountViewModel(
                storyService: storyService,
                safetyService: safetyService,
                onSignOut: onSignOut
            )
        )
    }

    var body: some View {
        Form {
            if viewModel.isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading account…")
                    }
                    .accessibilityIdentifier("account.loading")
                }
            }

            Section("Account Information") {
                HStack(spacing: 14) {
                    profilePhoto
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value(viewModel.snapshot.displayName))
                            .font(.headline)
                        Text(value(viewModel.snapshot.oneWayID))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                accountRow("Profile name", value: viewModel.snapshot.displayName)
                accountRow("Username", value: formattedUsername)
                accountRow("OneWay ID", value: viewModel.snapshot.oneWayID)
                accountRow("OW-number", value: viewModel.snapshot.primaryNumber)
                accountRow("Email", value: viewModel.snapshot.email)
                accountRow("Chirp ID", value: viewModel.snapshot.chirpID)
            }

            if let errorMessage = viewModel.errorMessage {
                Section("Connection") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Retry") { Task { await viewModel.load() } }
                        .disabled(viewModel.isLoading)
                        .accessibilityIdentifier("account.retry")
                }
            }

            Section("Security") {
                Button("Password and Account Recovery") {
                    showsRecovery = true
                }
                Text("Passkeys, biometric app lock, and trusted-device management are not shown because this account does not currently have server-backed controls for them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Blocked Users") {
                if viewModel.blockedHandles.isEmpty {
                    Text("No blocked accounts loaded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.blockedHandles, id: \.self) { handle in
                        Text(handle)
                    }
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    confirmsSignOut = true
                }
                .disabled(viewModel.isSigningOut)
                .accessibilityIdentifier("account.signOut")
            } footer: {
                Text("Permanent account deletion remains in the central + page.")
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background { SideMenuBackground() }
        .accessibilityIdentifier("account.screen")
        .task { await viewModel.load() }
        .sheet(isPresented: $showsRecovery) {
            PasswordResetView(initialIdentifier: viewModel.snapshot.email ?? viewModel.snapshot.oneWayID ?? "")
        }
        .confirmationDialog("Sign out of OneWay?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) {
                Task { await viewModel.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var profilePhoto: some View {
        Group {
            if let data = viewModel.snapshot.profilePhotoData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(OneWayDesignSystem.Colors.deepPurple)
                    .overlay {
                        Text(initials)
                            .font(.headline)
                    }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .accessibilityLabel("Profile photo")
    }

    private var formattedUsername: String? {
        guard let username = viewModel.snapshot.username else { return nil }
        return username.hasPrefix("@") ? username : "@\(username)"
    }

    private var initials: String {
        let name = viewModel.snapshot.displayName ?? ""
        let characters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return characters.isEmpty ? "U" : String(characters)
    }

    private func value(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Unavailable" }
        return value
    }

    private func accountRow(_ title: String, value: String?) -> some View {
        LabeledContent(title, value: self.value(value))
    }
}
