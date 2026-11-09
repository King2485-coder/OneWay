import SwiftUI

struct PasswordResetView: View {
    private enum Step { case request, confirm, complete }

    @Environment(\.dismiss) private var dismiss
    @State private var identifier: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmedPassword = ""
    @State private var step: Step = .request
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(initialIdentifier: String) {
        _identifier = State(initialValue: initialIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { OneWayKeyboard.dismiss() }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(title)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                        Text(instructions)
                            .foregroundStyle(.white.opacity(0.72))

                        switch step {
                        case .request:
                            identifierField
                            primaryButton("Send reset code", action: requestCode)
                                .disabled(trimmedIdentifier.isEmpty || isSubmitting)
                        case .confirm:
                            confirmationFields
                            primaryButton("Update password", action: resetPassword)
                                .disabled(!canConfirm || isSubmitting)
                            Button("Send a new code") { requestCode() }
                                .foregroundStyle(.blue)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                        case .complete:
                            OneWayResolvedIcon(systemName: "checkmark.circle.fill")
                                .font(.system(size: 58))
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity)
                            primaryButton("Return to login") { dismiss() }
                        }
                    }
                    .padding(24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }.foregroundStyle(.white)
                }
            }
            .alert("Could Not Reset Password", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .oneWayKeyboardManaged()
    }

    private var identifierField: some View {
        TextField("Email, username, or @OneWayID", text: $identifier)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .oneWayResetFieldStyle()
            .accessibilityIdentifier("auth.reset.identifier")
    }

    private var confirmationFields: some View {
        VStack(spacing: 14) {
            TextField("8-character code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .oneWayResetFieldStyle()
                .accessibilityIdentifier("auth.reset.code")
            SecureField("New password", text: $newPassword)
                .textContentType(.newPassword)
                .oneWayResetFieldStyle()
                .accessibilityIdentifier("auth.reset.newPassword")
            SecureField("Confirm new password", text: $confirmedPassword)
                .textContentType(.newPassword)
                .oneWayResetFieldStyle()
                .accessibilityIdentifier("auth.reset.confirmPassword")
            if !confirmedPassword.isEmpty && newPassword != confirmedPassword {
                Text("Passwords don't match.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isSubmitting { ProgressView().tint(.white) }
                else { Text(label).font(.headline) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.blue, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .opacity(isSubmitting ? 0.7 : 1)
    }

    private var trimmedIdentifier: String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConfirm: Bool {
        code.replacingOccurrences(of: " ", with: "").count >= 8
            && newPassword.count >= 6
            && newPassword == confirmedPassword
    }

    private var title: String {
        switch step {
        case .request: return "Reset password"
        case .confirm: return "Check your email"
        case .complete: return "Password updated"
        }
    }

    private var instructions: String {
        switch step {
        case .request: return "Enter your account information and we'll email the address on the account a one-time code. Your account and data stay intact."
        case .confirm: return "Enter the code we sent. It expires in 15 minutes."
        case .complete: return "Your password has been changed and older signed-in sessions have been closed."
        }
    }

    private func requestCode() {
        guard !trimmedIdentifier.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                _ = try await AuthAPIService.shared.requestPasswordReset(identifier: trimmedIdentifier)
                step = .confirm
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resetPassword() {
        guard canConfirm, !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                _ = try await AuthAPIService.shared.confirmPasswordReset(
                    identifier: trimmedIdentifier,
                    code: code,
                    newPassword: newPassword
                )
                AuthTokenStore.shared.clearSession()
                step = .complete
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension View {
    func oneWayResetFieldStyle() -> some View {
        self
            .padding(16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))
            .foregroundStyle(.white)
    }
}
