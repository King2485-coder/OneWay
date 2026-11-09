import SwiftUI
import Combine

struct AddFriendView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AddFriendViewModel
    private let ownsNavigationStack: Bool

    init(friendService: FriendService, ownsNavigationStack: Bool = true) {
        _viewModel = StateObject(wrappedValue: AddFriendViewModel(friendService: friendService))
        self.ownsNavigationStack = ownsNavigationStack
    }

    @ViewBuilder
    var body: some View {
        if ownsNavigationStack {
            NavigationStack { content(showsDismissButton: true) }
        } else {
            content(showsDismissButton: false)
        }
    }

    private func content(showsDismissButton: Bool) -> some View {
        Form {
                Section("Add OneWay Contact") {
                    TextField("@handle or Chirp ID", text: $viewModel.handleInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)

                    Button("Search") {
                        Task { await viewModel.search() }
                    }
                    .disabled(viewModel.handleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Add Friend") {
                        Task { await viewModel.requestByHandle() }
                    }
                    .disabled(viewModel.handleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if viewModel.isSearching {
                    Section {
                        ProgressView()
                    }
                }

                if !viewModel.searchResults.isEmpty {
                    Section("OneWay Users") {
                        ForEach(viewModel.searchResults) { result in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.purple.opacity(0.24))
                                    .frame(width: 42, height: 42)
                                    .overlay {
                                        Text(initials(for: result.displayName ?? result.onewayId ?? "OW"))
                                            .font(.subheadline.weight(.bold))
                                    }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.displayName ?? "OneWay User")
                                        .font(.headline)
                                    Text([result.onewayId, result.chirpId].compactMap { $0 }.joined(separator: "  "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button(actionTitle(for: result.friendshipState)) {
                                    Task { await viewModel.request(result) }
                                }
                                .disabled(!canRequest(result.friendshipState))
                            }
                        }
                    }
                }

                Section("Invite Off App") {
                    Button("Generate Invite Link") {
                        Task { await viewModel.generateInvite() }
                    }

                    if let link = viewModel.generatedInviteLink {
                        ShareLink(item: link) {
                            OneWayResolvedLabel("Share Invite Link", systemImage: "square.and.arrow.up")
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
        .navigationTitle("Add Contact")
        .oneWayMenuBar()
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
            }
        }
        .alert("Add Friend", isPresented: errorAlertBinding) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private func initials(for value: String) -> String {
        let parts = value.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        let result = String(letters).uppercased()
        return result.isEmpty ? "OW" : result
    }

    private func actionTitle(for state: String?) -> String {
        switch state {
        case "accepted":
            return "Already Friends"
        case "pendingOutgoing":
            return "Request Sent"
        case "pendingIncoming":
            return "Accept"
        case "blocked":
            return "Blocked"
        default:
            return "Add Friend"
        }
    }

    private func canRequest(_ state: String?) -> Bool {
        switch state {
        case "accepted", "pendingOutgoing", "blocked":
            return false
        default:
            return true
        }
    }
}
