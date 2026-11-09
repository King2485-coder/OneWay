import SwiftUI

struct PrivacyFirstOnboardingView: View {
    @StateObject private var viewModel: PrivacyOnboardingViewModel
    let onFinish: () -> Void

    init(importedContactsStore: ImportedContactsStore, onFinish: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: PrivacyOnboardingViewModel(importedContactsStore: importedContactsStore))
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.step {
            case 0:
                OnboardingWelcomeStep(viewModel: viewModel)
            case 1:
                DisplayNameStep(viewModel: viewModel)
            case 2:
                PrivateUsernameStep(viewModel: viewModel)
            case 3:
                OneWayIDStep(viewModel: viewModel)
            case 4:
                OneWayEmailAliasStep(viewModel: viewModel)
            case 5:
                ClaimFreeNumbersStep(viewModel: viewModel)
            case 6:
                ImportSelectedContactsStep(viewModel: viewModel, onFinish: onFinish)
            default:
                OnboardingDoneStep(onFinish: onFinish)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.step)
        .alert("OneWay", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $viewModel.isShowingContactPicker) {
            ContactPickerSheet { contacts in
                viewModel.importSelectedContacts(contacts)
            }
        }
    }
}

private struct OnboardingScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    let showBack: Bool
    let onBack: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        if showBack, let onBack {
                            Button(action: onBack) {
                                OneWayResolvedLabel("Back", systemImage: "chevron.left")
                                    .font(.headline.weight(.semibold))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(title)
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    content

                    Spacer(minLength: 0)
                }
                .frame(minHeight: proxy.size.height, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
        }
    }
}

private struct OnboardingPrimaryButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 16)
            .background(Color.blue, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

private struct IdentityTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .padding(18)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .foregroundStyle(.white)
    }
}

private struct OnboardingWelcomeStep: View {
    @ObservedObject var viewModel: PrivacyOnboardingViewModel

    var body: some View {
        OnboardingScaffold(
            title: "Welcome",
            subtitle: "Set up a privacy-first OneWay identity with your own public ID, custom email alias, and two free numbers.",
            showBack: false,
            onBack: nil
        ) {
            VStack(alignment: .leading, spacing: 14) {
                bullet("Your username can stay completely hidden.")
                bullet("Your OneWay ID and OneWay email can be totally different.")
                bullet("You’ll claim 2 free OneWay numbers before entering the app.")
            }

            OnboardingPrimaryButton(title: "Start", isLoading: false) {
                viewModel.next()
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .padding(.top, 8)
            Text(text)
                .foregroundStyle(.white.opacity(0.86))
        }
    }
}

private struct DisplayNameStep: View {
    @ObservedObject var viewModel: PrivacyOnboardingViewModel

    var body: some View {
        OnboardingScaffold(
            title: "Display Name",
            subtitle: "What should people call you? This is the friendly public name, not necessarily your legal name.",
            showBack: true,
            onBack: viewModel.back
        ) {
            IdentityTextField(title: "Antonio", text: $viewModel.draft.displayName)
            OnboardingPrimaryButton(title: "Continue", isLoading: false) {
                viewModel.next()
            }
            .disabled(viewModel.draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct PrivateUsernameStep: View {
    @ObservedObject var viewModel: PrivacyOnboardingViewModel

    var body: some View {
        OnboardingScaffold(
            title: "Private Username",
            subtitle: "Create a private username. This can stay hidden and does not need to match your OneWay ID or email.",
            showBack: true,
            onBack: viewModel.back
        ) {
            IdentityTextField(title: "king_internal", text: $viewModel.draft.username)
            Toggle("Keep username hidden publicly", isOn: $viewModel.draft.usernameHidden)
                .foregroundStyle(.white)
            OnboardingPrimaryButton(title: "Continue", isLoading: false) {
                viewModel.next()
            }
            .disabled(viewModel.draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct OneWayIDStep: View {
    @ObservedObject var viewModel: PrivacyOnboardingViewModel

    var body: some View {
        OnboardingScaffold(
            title: "OneWay ID",
            subtitle: "Create your public OneWay ID. Use lowercase, include @, and make it something you want people to find.",
            showBack: true,
            onBack: viewModel.back
        ) {
            IdentityTextField(title: "@ghostsignal", text: $viewModel.draft.onewayId)
            OnboardingPrimaryButton(title: "Continue", isLoading: false) {
                viewModel.next()
            }
            .disabled(viewModel.draft.onewayId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct OneWayEmailAliasStep: View {
    @ObservedObject var viewModel: PrivacyOnboardingViewModel

    var body: some View {
        OnboardingScaffold(
            title: "OneWay Email",
            subtitle: "Create your OneWay email alias. It’s fully customizable and does not need to match your username or OneWay ID.",
            showBack: true,
            onBack: viewModel.back
        ) {
            IdentityTextField(title: "echo@oneway.app", text: $viewModel.draft.emailAlias)
            OnboardingPrimaryButton(title: "Create Identity", isLoading: viewModel.isLoading) {
                Task { await viewModel.createIdentity() }
            }
            .disabled(viewModel.draft.emailAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct ClaimFreeNumbersStep: View {
    @ObservedObject var viewModel: PrivacyOnboardingViewModel

    var body: some View {
        OnboardingScaffold(
            title: "Claim Free Numbers",
            subtitle: "Claim your 2 free OneWay numbers. We’ll label them Personal and Fun to get you started.",
            showBack: true,
            onBack: viewModel.back
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.claimedNumbers.isEmpty {
                    Text("Personal\nFun")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    ForEach(viewModel.claimedNumbers) { number in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(number.label ?? "OneWay number")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(number.number)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .padding(16)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }

            if viewModel.claimedNumbers.isEmpty {
                OnboardingPrimaryButton(title: "Claim My 2 Free Numbers", isLoading: viewModel.isLoading) {
                    Task { await viewModel.claimFreeNumbers() }
                }
            } else {
                OnboardingPrimaryButton(title: "Continue", isLoading: false) {
                    viewModel.next()
                }
            }
        }
    }
}

private struct ImportSelectedContactsStep: View {
    @ObservedObject var viewModel: PrivacyOnboardingViewModel
    let onFinish: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "Import Contacts",
            subtitle: "Import selected contacts only. Selected contacts stay in OneWay until you delete them later.",
            showBack: true,
            onBack: viewModel.back
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(viewModel.importedContacts.isEmpty
                     ? "No contacts selected yet."
                     : "Imported \(viewModel.importedContacts.count) selected contact\(viewModel.importedContacts.count == 1 ? "" : "s").")
                    .foregroundStyle(.white.opacity(0.75))

                Button {
                    viewModel.isShowingContactPicker = true
                } label: {
                    Text(viewModel.importedContacts.isEmpty ? "Import Selected Contacts" : "Add More Selected Contacts")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: "Enter OneWay", isLoading: false) {
                    onFinish()
                }

                Button("Skip for now") {
                    viewModel.skipContacts()
                    onFinish()
                }
                .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

private struct OnboardingDoneStep: View {
    let onFinish: () -> Void

    var body: some View {
        OnboardingScaffold(
            title: "You’re In",
            subtitle: "Your privacy-first OneWay identity is ready.",
            showBack: false,
            onBack: nil
        ) {
            OnboardingPrimaryButton(title: "Enter OneWay", isLoading: false, action: onFinish)
        }
    }
}
