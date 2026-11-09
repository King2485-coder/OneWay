import SwiftUI

struct WalkiePermissionsView: View {
    @State private var settings: WalkiePrivacySettings = .init(
        allowFriends: true,
        allowFriendsOfFriends: false,
        allowAnyone: true,
        allowDirectChirp: true,
        directChirpAudience: "everyone",
        askBeforeConnecting: true,
        allowRepeatChirps: false,
        silenceUnknownChirps: true,
        requireVerifiedAccount: false,
        hideProfilePhotoFromUnknownUsers: false,
        blockUnknownDuringDnd: true,
        autoBlockRepeatedAbuse: true
    )
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let service: WalkieService

    init(service: WalkieService = .shared) {
        self.service = service
    }

    var body: some View {
        Form {
            Section("Allow Chirp From") {
                Toggle(
                    "Friends",
                    isOn: Binding(
                        get: { settings.allowFriends },
                        set: { value in update(allowFriends: value) }
                    )
                )
                .disabled(isLoading || isSaving)

                Toggle(
                    "Friends of friends",
                    isOn: Binding(
                        get: { settings.allowFriendsOfFriends },
                        set: { value in update(allowFriendsOfFriends: value) }
                    )
                )
                .disabled(isLoading || isSaving)

                Toggle(
                    "Anyone",
                    isOn: Binding(
                        get: { settings.allowAnyone },
                        set: { value in update(allowAnyone: value) }
                    )
                )
                .disabled(isLoading || isSaving)
            }

            Section {
                Toggle(
                    "Allow Direct Chirp by Chirp ID",
                    isOn: Binding(
                        get: { settings.allowDirectChirp },
                        set: { value in
                            update(
                                allowDirectChirp: value,
                                directChirpAudience: value ? "everyone" : "nobody"
                            )
                        }
                    )
                )
                .disabled(isLoading || isSaving)

                Text("People who know your Chirp ID can request a direct Chirp without adding you as a friend first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Direct Chirp")
            }

            if settings.allowDirectChirp {
                Section("Who Can Chirp Me Directly") {
                    Picker(
                        "Who Can Chirp Me Directly",
                        selection: Binding(
                            get: { settings.directChirpAudience },
                            set: { update(directChirpAudience: $0) }
                        )
                    ) {
                        Text("Everyone with my Chirp ID").tag("everyone")
                        Text("People in My Contacts").tag("contacts")
                        Text("Friends of Friends").tag("friendsOfFriends")
                        Text("Verified OneWay Users").tag("verified")
                        Text("Nobody").tag("nobody")
                    }

                    Toggle("Ask Before Connecting", isOn: binding(\.askBeforeConnecting) { update(askBeforeConnecting: $0) })
                    Toggle("Allow Repeat Chirps", isOn: binding(\.allowRepeatChirps) { update(allowRepeatChirps: $0) })
                    Toggle("Silence Unknown Chirps", isOn: binding(\.silenceUnknownChirps) { update(silenceUnknownChirps: $0) })
                    Toggle("Require Verified Account", isOn: binding(\.requireVerifiedAccount) { update(requireVerifiedAccount: $0) })
                    Toggle("Hide My Profile Photo from Unknown Users", isOn: binding(\.hideProfilePhotoFromUnknownUsers) { update(hideProfilePhotoFromUnknownUsers: $0) })
                    Toggle("Block Unknown Chirps During Do Not Disturb", isOn: binding(\.blockUnknownDuringDnd) { update(blockUnknownDuringDnd: $0) })
                    Toggle("Auto-Block Repeated Abuse", isOn: binding(\.autoBlockRepeatedAbuse) { update(autoBlockRepeatedAbuse: $0) })
                }
            }

            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Chirp Permissions")
        .task { await load() }
        .alert(
            "Chirp",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await service.privacy()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update(
        allowFriends: Bool? = nil,
        allowFriendsOfFriends: Bool? = nil,
        allowAnyone: Bool? = nil,
        allowDirectChirp: Bool? = nil,
        directChirpAudience: String? = nil,
        askBeforeConnecting: Bool? = nil,
        allowRepeatChirps: Bool? = nil,
        silenceUnknownChirps: Bool? = nil,
        requireVerifiedAccount: Bool? = nil,
        hideProfilePhotoFromUnknownUsers: Bool? = nil,
        blockUnknownDuringDnd: Bool? = nil,
        autoBlockRepeatedAbuse: Bool? = nil
    ) {
        guard !isSaving else { return }
        let previous = settings
        let next = WalkiePrivacySettings(
            allowFriends: allowFriends ?? settings.allowFriends,
            allowFriendsOfFriends: allowFriendsOfFriends ?? settings.allowFriendsOfFriends,
            allowAnyone: allowAnyone ?? settings.allowAnyone,
            allowDirectChirp: allowDirectChirp ?? settings.allowDirectChirp,
            directChirpAudience: directChirpAudience ?? settings.directChirpAudience,
            askBeforeConnecting: askBeforeConnecting ?? settings.askBeforeConnecting,
            allowRepeatChirps: allowRepeatChirps ?? settings.allowRepeatChirps,
            silenceUnknownChirps: silenceUnknownChirps ?? settings.silenceUnknownChirps,
            requireVerifiedAccount: requireVerifiedAccount ?? settings.requireVerifiedAccount,
            hideProfilePhotoFromUnknownUsers: hideProfilePhotoFromUnknownUsers ?? settings.hideProfilePhotoFromUnknownUsers,
            blockUnknownDuringDnd: blockUnknownDuringDnd ?? settings.blockUnknownDuringDnd,
            autoBlockRepeatedAbuse: autoBlockRepeatedAbuse ?? settings.autoBlockRepeatedAbuse
        )

        settings = next
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                settings = try await service.updatePrivacy(next)
            } catch {
                settings = previous
                errorMessage = error.localizedDescription
            }
        }
    }

    private func binding(_ keyPath: KeyPath<WalkiePrivacySettings, Bool>, onChange: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { onChange($0) }
        )
    }
}
