import SwiftUI
import Combine

struct AddFriendView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AddFriendViewModel

    init(friendService: FriendService) {
        _viewModel = StateObject(wrappedValue: AddFriendViewModel(friendService: friendService))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Add In App") {
                    TextField("@handle", text: $viewModel.handleInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Send Friend Request") {
                        Task { await viewModel.requestByHandle() }
                    }
                    .disabled(viewModel.handleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Invite Off App") {
                    Button("Generate Invite Link") {
                        Task { await viewModel.generateInvite() }
                    }

                    if let link = viewModel.generatedInviteLink {
                        ShareLink(item: link) {
                            Label("Share Invite Link", systemImage: "square.and.arrow.up")
                        }
                        Text(link.absoluteString)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Redeem Invite") {
                    TextField("https://cipherchat.app/invite/...", text: $viewModel.inviteInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Redeem") {
                        Task { await viewModel.redeemInvite() }
                    }
                    .disabled(viewModel.inviteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let result = viewModel.recentResult {
                    Section("Status") {
                        Text(result)
                    }
                }
            }
            .navigationTitle("Add Friends")
            .oneWayMenuBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Add Friend", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}
