import SwiftUI

struct LoginView: View {
    @State private var identifier: String = ""
    @State private var password: String = ""
    @State private var isSubmitting = false
    @State private var errorTitle = "OneWay"
    @State private var errorMessage: String?
    @State private var showsRetryLaterAction = false
    @State private var showSignup = false
    @State private var showForgotPassword = false
    @State private var revealsPassword = false

    let onAuthed: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayAuthBackdrop()
                    .contentShape(Rectangle())
                    .onTapGesture { OneWayKeyboard.dismiss() }

                ScrollView {
                    VStack(spacing: 16) {
                        authHeader
                            .zIndex(1)
                        authModeSelector
                        loginCard

                        VStack(spacing: 7) {
                            OneWayResolvedLabel("Your privacy comes first.", systemImage: "checkmark.shield")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color(red: 0.73, green: 0.69, blue: 1))
                            Text("Private calls, chats, and more.")
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.48))
                        }

                        Text("A  S A F E R,  K I N D E R  I N T E R N E T")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(3.2)
                            .foregroundStyle(Color(red: 0.63, green: 0.48, blue: 1))
                            .padding(.top, 5)

                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled(false)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showSignup) {
                SignupView(onAuthed: onAuthed)
            }
            .sheet(isPresented: $showForgotPassword) {
                PasswordResetView(initialIdentifier: identifier)
            }
            .alert(errorTitle, isPresented: Binding(
                get: { errorMessage != nil },
                set: { _ in
                    errorMessage = nil
                    showsRetryLaterAction = false
                }
            )) {
                Button("OK", role: .cancel) {}
                if showsRetryLaterAction {
                    Button("Retry Later", role: .cancel) {}
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .oneWayKeyboardManaged()
    }

    private var authHeader: some View {
        VStack(spacing: 8) {
            OneWayLogoView(size: 64, decorative: true)

            HStack(spacing: 0) {
                Text("One")
                    .foregroundStyle(.white)
                Text("Way")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.66, green: 0.37, blue: 1), Color(red: 0.42, green: 0.26, blue: 1)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .tracking(-1.8)

            Text("Private Calls. Chirp & Chat.")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color(red: 0.61, green: 0.63, blue: 0.78))

            Text("R E A L  C O N N E C T I O N S .\nO N  Y O U R  T E R M S .")
                .font(.system(size: 9, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .tracking(1.2)
                .foregroundStyle(Color(red: 0.63, green: 0.56, blue: 0.95))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            Text("A\nQuieter\nBrighter\nYou")
                .font(.custom("SnellRoundhand", size: 16))
                .lineSpacing(-4)
                .foregroundStyle(Color(red: 0.65, green: 0.48, blue: 0.94))
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(red: 0.65, green: 0.48, blue: 0.94))
                        .frame(width: 34, height: 0.6)
                }
                .rotationEffect(.degrees(-12))
                .padding(.trailing, 2)
                .offset(y: 2)
                .accessibilityLabel("A Quieter Brighter You")
        }
    }

    private var authModeSelector: some View {
        HStack(spacing: 0) {
            Text("Log In")
                .font(.headline.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.36, green: 0.16, blue: 0.78), Color(red: 0.49, green: 0.23, blue: 0.93)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .shadow(color: Color.purple.opacity(0.38), radius: 12)

            Button("Sign Up") { showSignup = true }
                .font(.headline.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.57))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .buttonStyle(.plain)
        }
        .padding(5)
        .background(Color.black.opacity(0.56), in: Capsule())
        .overlay(Capsule().stroke(Color(red: 0.31, green: 0.33, blue: 0.44).opacity(0.8), lineWidth: 1))
        .background {
            GeometryReader { proxy in
                Image("OneWayAuthMoonHorizon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width + 44, height: 220)
                    .clipped()
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.25),
                        .init(color: .white, location: 0.7),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .offset(x: -22, y: -95)
                    .accessibilityHidden(true)
            }
            .allowsHitTesting(false)
        }
    }

    private var loginCard: some View {
        VStack(spacing: 12) {
            authField(icon: "envelope", placeholder: "Email or phone") {
                TextField(
                    "Email or phone",
                    text: $identifier,
                    prompt: Text("Email or phone").foregroundStyle(Color(red: 0.47, green: 0.49, blue: 0.62))
                )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
            }

            authField(icon: "lock", placeholder: "Password", trailingIcon: revealsPassword ? "eye" : "eye.slash") {
                Group {
                    if revealsPassword {
                        TextField(
                            "Password",
                            text: $password,
                            prompt: Text("Password").foregroundStyle(Color(red: 0.47, green: 0.49, blue: 0.62))
                        )
                    } else {
                        SecureField(
                            "Password",
                            text: $password,
                            prompt: Text("Password").foregroundStyle(Color(red: 0.47, green: 0.49, blue: 0.62))
                        )
                    }
                }
                .textContentType(.password)
            } trailingAction: {
                revealsPassword.toggle()
            }

            Button("Forgot password?") { showForgotPassword = true }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(red: 0.66, green: 0.45, blue: 1))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(minHeight: 30)
                .accessibilityIdentifier("auth.login.forgotPassword")

            Button { submitLogin() } label: {
                HStack {
                    Spacer()
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Log In")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        OneWayResolvedIcon(systemName: "arrow.right")
                            .font(.title3.weight(.light))
                    }
                }
                .padding(.horizontal, 22)
                .frame(height: 50)
                .foregroundStyle(.white)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.42, green: 0.18, blue: 0.88), Color(red: 0.35, green: 0.17, blue: 0.75)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(red: 0.62, green: 0.42, blue: 1), lineWidth: 1))
                .shadow(color: Color.purple.opacity(0.34), radius: 13, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            .opacity(isSubmitting || identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty ? 0.62 : 1)
            .accessibilityIdentifier("auth.login.continue")

            HStack(spacing: 14) {
                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                Text("New to OneWay?")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.48))
                    .fixedSize()
                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
            }
            .padding(.top, 5)

            Button { showSignup = true } label: {
                Text("Create your OneWay account")
                    .font(.headline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color(red: 0.36, green: 0.38, blue: 0.50), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.93), Color.black.opacity(0.84)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 25, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color(red: 0.26, green: 0.28, blue: 0.38).opacity(0.9), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 25, y: 14)
    }

    private func authField<Field: View>(
        icon: String,
        placeholder: String,
        trailingIcon: String? = nil,
        @ViewBuilder field: () -> Field,
        trailingAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 14) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Color(red: 0.55, green: 0.57, blue: 0.70))
                .frame(width: 24)

            field()
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .tint(Color(red: 0.62, green: 0.42, blue: 1))

            if let trailingIcon, let trailingAction {
                Button(action: trailingAction) {
                    OneWayResolvedIcon(systemName: trailingIcon)
                        .font(.system(size: 18))
                        .foregroundStyle(Color(red: 0.55, green: 0.57, blue: 0.70))
                        .frame(width: 34, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealsPassword ? "Hide password" : "Show password")
            }
        }
        .padding(.horizontal, 17)
        .frame(height: 52)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(red: 0.25, green: 0.27, blue: 0.37).opacity(0.9), lineWidth: 1))
        .accessibilityLabel(placeholder)
        .accessibilityElement(children: .contain)
    }

    private func submitLogin() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        showsRetryLaterAction = false
        Task { @MainActor in
            await login()
        }
    }

    @MainActor
    private func login() async {
        defer { isSubmitting = false }

        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            prepareForAccountSwitch()
            #if DEBUG
            AuthTokenStore.shared.clearDebugAccountOverrides()
            #endif
            AuthTokenStore.shared.clearSession()

            let response = try await AuthAPIService.shared.login(
                identifier: trimmedIdentifier,
                password: password,
                source: "LoginView",
                retryCount: 0
            )
            UserDefaults.standard.set(trimmedIdentifier, forKey: "OneWay.LastLoginIdentifier")
            AuthTokenStore.shared.setSession(userID: response.user.id, token: response.token)
            onAuthed()
        } catch let apiError as APIClientError {
            presentLoginError(apiError)
        } catch {
            errorTitle = "Could Not Sign In"
            errorMessage = error.localizedDescription
        }
    }

    private func presentLoginError(_ error: APIClientError) {
        switch error {
        case .server(let statusCode, _) where statusCode == 429:
            errorTitle = "Too Many Login Attempts"
            errorMessage = "You've attempted to sign in too many times.\n\nPlease wait a moment before trying again.\n\nIf this continues, check your username and password."
            showsRetryLaterAction = true
        case .server(let statusCode, _) where statusCode == 401 || statusCode == 403:
            errorTitle = "Could Not Sign In"
            errorMessage = "Check your username and password, then try again."
            showsRetryLaterAction = false
        default:
            errorTitle = "Could Not Sign In"
            errorMessage = error.errorDescription ?? "Could not login."
            showsRetryLaterAction = false
        }
    }

    private func prepareForAccountSwitch() {
        AppWalkieMonitor.shared.stop()
        NetworkFriendService.disconnectRealtime()
        NetworkMessagingService.disconnectRealtime()
        CommunityRealtimeClient.shared.disconnect()
        URLCache.shared.removeAllCachedResponses()
    }
}

struct OneWayAuthBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.015, green: 0.018, blue: 0.035)

                Image("OneWaySignalConnectedGlobeHero")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .opacity(0.32)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.25),
                        Color(red: 0.03, green: 0.02, blue: 0.09).opacity(0.52),
                        Color.black.opacity(0.9)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [Color(red: 0.35, green: 0.16, blue: 0.83).opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadius: 10,
                    endRadius: proxy.size.width * 0.9
                )
            }
        }
        .ignoresSafeArea()
    }
}
