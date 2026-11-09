import SwiftUI

struct SignupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions = OneWaySignupSuggestions()
    @State private var registeredName: String?
    @State private var assignedIdentity: OneWayIdentity?
    @State private var assignedNumbers: [OneWayNumber] = []
    @State private var loadingContactIDs = false
    @State private var contactIDError: String?
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    let onAuthed: () -> Void

    var body: some View {
        ZStack {
            OneWayAuthBackdrop()
                .contentShape(Rectangle())
                .onTapGesture { OneWayKeyboard.dismiss() }

            if let registeredName {
                signupContactCard(registeredName)
            } else {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 7) {
                        OneWayLogoView(size: 60, decorative: true)
                        Text("Join OneWay")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Your connections. Your privacy. Your way.")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.58))
                    }

                    HStack(spacing: 0) {
                        Button("Log In") { dismiss() }
                            .font(.headline.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.57))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .buttonStyle(.plain)
                        Text("Sign Up")
                            .font(.headline.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(LinearGradient(colors: [Color(red: 0.36, green: 0.16, blue: 0.78), Color(red: 0.49, green: 0.23, blue: 0.93)], startPoint: .leading, endPoint: .trailing), in: Capsule())
                            .shadow(color: .purple.opacity(0.38), radius: 12)
                    }
                    .padding(5)
                    .background(Color.black.opacity(0.56), in: Capsule())
                    .overlay(Capsule().stroke(Color(red: 0.31, green: 0.33, blue: 0.44).opacity(0.8), lineWidth: 1))

                    VStack(spacing: 13) {
                        signupTextField("Display name", text: Binding(get: { suggestions.displayName }, set: { suggestions.setDisplayName($0) }))
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()

                        signupTextField("Email", text: $email)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)

                        HStack(spacing: 4) {
                            Text("@").foregroundStyle(.purple).fontWeight(.bold)
                            TextField("OneWay handle", text: Binding(get: { suggestions.handle }, set: { suggestions.setHandle($0) }))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }.oneWaySignupFieldStyle().accessibilityIdentifier("auth.signup.handle")

                        HStack(spacing: 4) {
                            TextField("OneWay email name", text: Binding(get: { suggestions.emailName }, set: { suggestions.setEmailName($0) }))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Text("@oneway.app").font(.caption).foregroundStyle(.secondary)
                        }.oneWaySignupFieldStyle().accessibilityIdentifier("auth.signup.alias")
                        Text("Your name fills your handle and OneWay email automatically. You can change each one.")
                            .font(.caption).foregroundStyle(.secondary)

                        SecureField(
                            "Password (6+ characters)",
                            text: $password,
                            prompt: Text("Password (6+ characters)").foregroundStyle(Color(red: 0.47, green: 0.49, blue: 0.62))
                        )
                            .textContentType(.newPassword)
                            .oneWaySignupFieldStyle()

                        Button {
                            Task { await register() }
                        } label: {
                            HStack {
                                Spacer()
                                if isSubmitting {
                                    ProgressView().tint(.white)
                                } else {
                                    Text("Create Account")
                                        .font(.title3.weight(.semibold))
                                    Spacer()
                                    OneWayResolvedIcon(systemName: "arrow.right")
                                        .font(.title3.weight(.light))
                                }
                            }
                            .padding(.horizontal, 22)
                            .frame(height: 58)
                            .background(LinearGradient(colors: [Color(red: 0.42, green: 0.18, blue: 0.88), Color(red: 0.35, green: 0.17, blue: 0.75)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(red: 0.62, green: 0.42, blue: 1), lineWidth: 1))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.count < 6)
                        .opacity(isSubmitting || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.count < 6 ? 0.62 : 1)
                        .accessibilityIdentifier("auth.signup.continue")
                    }
                    .padding(18)
                    .background(LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.93), Color.black.opacity(0.84)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color(red: 0.26, green: 0.28, blue: 0.38).opacity(0.9), lineWidth: 1))

                    OneWayResolvedLabel("Your privacy comes first.", systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(red: 0.73, green: 0.69, blue: 1))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            }
        }
        .interactiveDismissDisabled(registeredName != nil)
        .toolbar(.hidden, for: .navigationBar)
        .alert("OneWay", isPresented: Binding(
            get: { errorMessage != nil },
            set: { _ in errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func signupTextField(_ title: String, text: Binding<String>) -> some View {
        TextField(
            title,
            text: text,
            prompt: Text(title).foregroundStyle(Color(red: 0.47, green: 0.49, blue: 0.62))
        )
        .oneWaySignupFieldStyle()
    }

    private func register() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let identity = preparedIdentity()
            let response = try await AuthAPIService.shared.register(
                email: email,
                password: password,
                displayName: identity.displayName,
                username: identity.username,
                onewayId: identity.onewayId,
                emailAlias: identity.emailAlias,
                walkieName: identity.displayName
            )
            prepareForAccountSwitch()
            #if DEBUG
            AuthTokenStore.shared.clearDebugAccountOverrides()
            #endif
            AuthTokenStore.shared.setSession(userID: response.user.id, token: response.token)
            password = ""
            registeredName = response.user.displayName
            await loadAssignedContactIDs()
        } catch let apiError as APIClientError {
            errorMessage = apiError.errorDescription ?? "Could not create account."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preparedIdentity() -> (displayName: String, username: String, onewayId: String, emailAlias: String) {
        let emailLocalPart = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "@")
            .first
            .map(String.init) ?? "tester"
        let base = sanitizedIdentitySeed(nonBlank(suggestions.displayName) ?? emailLocalPart)
        let name = nonBlank(suggestions.displayName) ?? base.capitalized
        let username = base
        let id = suggestions.handle.isEmpty ? "@\(base)" : suggestions.onewayID
        let alias = suggestions.emailName.isEmpty ? "\(base)@oneway.app" : suggestions.emailAddress
        return (name, username, id, alias)
    }

    private func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitizedIdentitySeed(_ value: String) -> String {
        let cleaned = value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "member\(Int(Date().timeIntervalSince1970))" : String(cleaned.prefix(24))
    }

    private func signupContactCard(_ name: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                OneWayLogoView(size: 64, decorative: true)
                Text("Welcome, " + name).font(.largeTitle.bold())
                Text("Your OneWay contact card").font(.title2.bold())
                if loadingContactIDs { ProgressView("Loading your assigned contact details…") }
                if let identity = assignedIdentity {
                    contactLine("OneWay handle", identity.onewayId)
                    contactLine("OneWay email", identity.emailAlias.contains("@") ? identity.emailAlias : identity.emailAlias + "@oneway.app")
                    contactLine("Chirp ID", identity.chirpId.isEmpty ? "Assignment pending" : identity.chirpId)
                }
                ForEach(assignedNumbers) { number in contactLine(number.isPrimary ? "Primary OneWay number" : (number.label ?? "OneWay number"), number.number) }
                if !loadingContactIDs && assignedNumbers.isEmpty { Text("Your calling number is pending assignment. Check My Numbers in Settings.").font(.subheadline).foregroundStyle(.secondary) }
                if let contactIDError { Text(contactIDError).font(.caption).foregroundStyle(.orange); Button("Reload contact details") { Task { await loadAssignedContactIDs() } } }
                Button("Continue to OneWay", action: onAuthed).buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
                Text("These details come from your account. You can find them again in Settings → My Numbers and Privacy & Identity.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private func contactLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline).textSelection(.enabled) }
    }
    @MainActor private func loadAssignedContactIDs() async {
        guard !loadingContactIDs else { return }
        loadingContactIDs = true; contactIDError = nil
        defer { loadingContactIDs = false }
        do { assignedIdentity = try await OneWayIdentityService.shared.fetchMyIdentity() }
        catch { contactIDError = "Your account is created. Contact details could not load yet; retry or open Settings." }
        do { assignedNumbers = try await OneWayNumberService.shared.fetchMyNumbers().numbers }
        catch { contactIDError = "Your account is created. Some contact details are still unavailable; retry or open Settings." }
    }

    private func prepareForAccountSwitch() {
        AppWalkieMonitor.shared.stop()
        NetworkFriendService.disconnectRealtime()
        NetworkMessagingService.disconnectRealtime()
        CommunityRealtimeClient.shared.disconnect()
        URLCache.shared.removeAllCachedResponses()
    }
}

private extension View {
    func oneWaySignupFieldStyle() -> some View {
        self
            .padding(.horizontal, 17)
            .frame(height: 56)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(red: 0.25, green: 0.27, blue: 0.37).opacity(0.9), lineWidth: 1))
            .foregroundStyle(.white)
            .tint(Color(red: 0.62, green: 0.42, blue: 1))
    }
}
