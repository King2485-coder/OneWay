import SwiftUI

struct CloneAuthFlowView: View {
    enum Step {
        case onboarding
        case login
        case signup
        case done
    }

    private let authService: AuthService
    @State private var step: Step
    @State private var createdUser: UserProfile?
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(startAt: Step, authService: AuthService) {
        self.authService = authService
        _step = State(initialValue: startAt)
    }

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case .onboarding:
                OnboardingStepView(
                    onGetStarted: { step = .signup },
                    onExistingAccount: { step = .login }
                )
            case .login:
                LoginStepView(isSubmitting: isSubmitting) {
                    await authenticateAndFinish()
                } onCreateAccount: {
                    step = .signup
                }
            case .signup:
                SignupStepView(isSubmitting: isSubmitting) {
                    await authenticateAndFinish()
                } onExistingAccount: {
                    step = .login
                }
            case .done:
                AuthSuccessView(user: createdUser) {
                    step = .login
                    createdUser = nil
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { SideMenuBackground() }
        .navigationTitle("Auth Flow")
        .navigationBarTitleDisplayMode(.inline)
        .oneWayMenuBar()
        .alert("Authentication", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue { errorMessage = nil }
            }
        )
    }

    private func authenticateAndFinish() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let user = try await authService.signInAnonymously()
            createdUser = user
            step = .done
        } catch {
            errorMessage = "Could not continue. Please try again."
        }
    }
}

private struct OnboardingStepView: View {
    let onGetStarted: () -> Void
    let onExistingAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome to OneWay")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Text("Private messaging, stories, calls, and friends in one secure space.")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 10) {
                Capsule().fill(Theme.primaryBlue).frame(width: 32, height: 8)
                Capsule().fill(Theme.glassSurface).frame(width: 20, height: 8)
                Capsule().fill(Theme.glassSurface).frame(width: 20, height: 8)
            }

            VStack(spacing: 12) {
                Button("Get Started") {
                    onGetStarted()
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("I already have an account") {
                    onExistingAccount()
                }
                .foregroundStyle(Theme.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.divider, lineWidth: 1))
                .shadow(color: Theme.glassShadow, radius: 16, x: 0, y: 10)
        )
    }
}

private struct LoginStepView: View {
    @State private var phoneOrEmail = ""
    @State private var passcode = ""

    let isSubmitting: Bool
    let onSubmit: () async -> Void
    let onCreateAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Login")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            TextField("Phone or Email", text: $phoneOrEmail)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 14))

            SecureField("Passcode", text: $passcode)
                .padding(14)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 14))

            Button {
                Task { await onSubmit() }
            } label: {
                HStack {
                    if isSubmitting { ProgressView() }
                    Text("Continue")
                }
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(isSubmitting)

            Button("Create account") {
                onCreateAccount()
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.divider, lineWidth: 1))
        )
    }
}

private struct SignupStepView: View {
    @State private var displayName = ""
    @State private var handle = ""
    @State private var phone = ""

    let isSubmitting: Bool
    let onSubmit: () async -> Void
    let onExistingAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Account")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            TextField("Display Name", text: $displayName)
                .padding(14)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 14))

            TextField("Handle", text: $handle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 14))

            TextField("Phone", text: $phone)
                .keyboardType(.phonePad)
                .padding(14)
                .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 14))

            Button {
                Task { await onSubmit() }
            } label: {
                HStack {
                    if isSubmitting { ProgressView() }
                    Text("Create and Continue")
                }
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(isSubmitting)

            Button("I already have an account") {
                onExistingAccount()
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.divider, lineWidth: 1))
        )
    }
}

private struct AuthSuccessView: View {
    let user: UserProfile?
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.primaryBlue)

            Text("You're in")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            Text(user?.displayName ?? "Authenticated user")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)

            Button("Sign out (test)") {
                onSignOut()
            }
            .buttonStyle(PrimaryPillButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.divider, lineWidth: 1))
        )
    }
}
