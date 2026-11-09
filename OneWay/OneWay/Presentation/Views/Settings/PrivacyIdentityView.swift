import SwiftUI

struct PrivacyIdentityView: View {
    @StateObject private var viewModel = PrivacyIdentityViewModel()

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Display Name", text: $viewModel.displayName)
                TextField("Chirp Name", text: $viewModel.walkieName)
                TextField("Internal Username", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                TextField("OneWay ID", text: $viewModel.onewayId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                TextField("OneWay Email Alias", text: $viewModel.emailAlias)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Privacy") {
                Toggle("Hide Username", isOn: $viewModel.usernameHidden)
                Toggle("Show Email Alias", isOn: $viewModel.showEmailAlias)
                Toggle("Show OneWay ID", isOn: $viewModel.showOneWayId)
                Toggle("Show Numbers", isOn: $viewModel.showNumbers)
            }

            Section("Caller Identity") {
                Picker("Preferred Caller Identity", selection: $viewModel.preferredCallerIdentity) {
                    ForEach(OneWayIdentity.PreferredCallerIdentity.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
            }

            Section {
                Button {
                    Task { await viewModel.save() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Save Privacy & Identity")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(viewModel.isSaving)
            }

            Section {
                Text("Display name, Chirp name, public @OneWayID, internal username, email alias, and number visibility are all independent here. Hidden usernames never appear in caller ID.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        }
        .navigationTitle("Privacy & Identity")
        .task { await viewModel.load() }
        .alert("OneWay", isPresented: Binding(
            get: { viewModel.errorMessage != nil || viewModel.saveMessage != nil },
            set: { _ in
                viewModel.errorMessage = nil
                viewModel.saveMessage = nil
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? viewModel.saveMessage ?? "")
        }
    }
}
