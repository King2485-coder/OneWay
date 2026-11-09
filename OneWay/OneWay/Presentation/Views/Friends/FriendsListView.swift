import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct FriendsListView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: FriendsListViewModel
    @State private var activeCall: FriendCallSession?
    @State private var isShowingAddFriend = false
    @State private var editingFriend: FriendConnection?
    @State private var deletingFriend: FriendConnection?

    init(friendService: FriendService) {
        _viewModel = StateObject(wrappedValue: FriendsListViewModel(friendService: friendService))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        .black,
                        Color(red: 0.03, green: 0.05, blue: 0.12),
                        .black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header

                        searchField

                        contactSection(title: "Connected", subtitle: "\(viewModel.connectedFriends.count) available") {
                            if viewModel.connectedFriends.isEmpty {
                                emptyState("No connected friends yet.")
                            } else {
                                ForEach(viewModel.connectedFriends) { friend in
                                    FriendRow(
                                        friend: friend,
                                        onAccept: nil,
                                        onDecline: nil,
                                        onEdit: { editingFriend = friend },
                                        onDelete: { deletingFriend = friend },
                                        onStartCall: { callType in
                                            Task { await startCall(with: friend, type: callType) }
                                        }
                                    )
                                }
                            }
                        }

                        contactSection(title: "Pending", subtitle: "\(viewModel.pendingFriends.count) requests") {
                            if viewModel.pendingFriends.isEmpty {
                                emptyState("No pending friend requests.")
                            } else {
                                ForEach(viewModel.pendingFriends) { friend in
                                    if friend.isIncomingRequest {
                                        FriendRow(
                                            friend: friend,
                                            onAccept: {
                                                Task { await viewModel.acceptPendingFriend(friend) }
                                            },
                                            onDecline: {
                                                Task { await viewModel.declinePendingFriend(friend) }
                                            },
                                            onEdit: { editingFriend = friend },
                                            onDelete: { deletingFriend = friend },
                                            onStartCall: nil
                                        )
                                    } else {
                                        FriendRow(
                                            friend: friend,
                                            onAccept: nil,
                                            onDecline: nil,
                                            onEdit: { editingFriend = friend },
                                            onDelete: { deletingFriend = friend },
                                            onStartCall: nil
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .oneWayMenuBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                        .foregroundStyle(.white.opacity(0.82))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingAddFriend = true
                    } label: {
                        OneWayResolvedIcon(systemName: "person.badge.plus")
                    }
                    .foregroundStyle(.white)
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView("Loading contacts…")
                        .tint(.white)
                }
            }
            .task {
                await viewModel.loadFriends()
                viewModel.startAutoRefresh()
            }
            .onDisappear {
                viewModel.stopAutoRefresh()
            }
            .refreshable {
                await viewModel.loadFriends()
            }
            .alert("Friends", isPresented: errorBinding) {
                Button("Retry") {
                    Task { await viewModel.loadFriends() }
                }
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .sheet(item: $activeCall) { session in
                CallSessionSheet(
                    callID: session.callID,
                    callType: session.type,
                    displayName: session.displayName,
                    callService: environment.callService
                ) {
                    activeCall = nil
                }
            }
            .sheet(isPresented: $isShowingAddFriend, onDismiss: {
                Task { await viewModel.loadFriends() }
            }) {
                AddFriendView(friendService: environment.friendService)
            }
            .sheet(item: $editingFriend) { friend in
                EditFriendSheet(friend: friend) { displayName in
                    Task { await viewModel.renameFriend(friend, displayName: displayName) }
                }
            }
            .alert(
                "Remove Contact?",
                isPresented: Binding(
                    get: { deletingFriend != nil },
                    set: { if !$0 { deletingFriend = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { deletingFriend = nil }
                Button("Remove", role: .destructive) {
                    guard let friend = deletingFriend else { return }
                    deletingFriend = nil
                    Task { await viewModel.deleteFriend(friend) }
                }
            } message: {
                Text("This removes the OneWay contact from your connected friends list.")
            }
            .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Contacts")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)

            Text("Private calling for the people you care about.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.68))
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.45))

            TextField("Search people", text: $viewModel.searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func contactSection<Content: View>(title: String,
                                               subtitle: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()
            }

            VStack(spacing: 12) {
                content()
            }
        }
    }

    private func emptyState(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.58))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue { viewModel.errorMessage = nil }
            }
        )
    }

    private func startCall(with friend: FriendConnection, type: CallType) async {
        do {
            let session = try await environment.callService.startCall(chatID: friend.id, type: type)
            FriendsHaptics.notify(.success)
            activeCall = FriendCallSession(
                callID: session.id,
                type: type,
                displayName: friend.displayName
            )
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private struct FriendRow: View {
    let friend: FriendConnection
    let onAccept: (() -> Void)?
    let onDecline: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onStartCall: ((CallType) -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.04, green: 0.52, blue: 1.0),
                            Color(red: 0.19, green: 0.82, blue: 0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(friend.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Circle()
                        .fill(friend.status == .connected ? Color(red: 0.19, green: 0.82, blue: 0.35) : .orange)
                        .frame(width: 7, height: 7)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(friend.status == .connected ? Color(red: 0.19, green: 0.82, blue: 0.35) : .orange)

                    Text([friend.handle, friend.chirpID].compactMap { $0 }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer()

            if friend.status == .connected {
                actionButton(icon: "phone.fill") {
                    onStartCall?(.voice)
                }

                actionButton(icon: "video.fill") {
                    onStartCall?(.video)
                }

                contactMenu
            } else if friend.isIncomingRequest {
                HStack(spacing: 8) {
                    Button("Decline") {
                        onDecline?()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
                    .buttonStyle(FriendActionButtonStyle())

                    Button("Accept") {
                        onAccept?()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.19, green: 0.82, blue: 0.35))
                    .clipShape(Capsule())
                    .buttonStyle(FriendActionButtonStyle())
                }

                contactMenu
            } else {
                Text("Sent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.14))
                    .clipShape(Capsule())

                contactMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var initials: String {
        let parts = friend.displayName.split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }

    private var statusText: String {
        if friend.status == .connected { return "Online" }
        return friend.isIncomingRequest ? "Incoming" : "Pending"
    }

    private var contactMenu: some View {
        Menu {
            Button {
                onEdit?()
            } label: {
                OneWayResolvedLabel("Edit Name", systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDelete?()
            } label: {
                OneWayResolvedLabel("Remove", systemImage: "trash")
            }
        } label: {
            OneWayResolvedIcon(systemName: "ellipsis")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func actionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.1))
                .clipShape(Circle())
        }
        .buttonStyle(FriendActionButtonStyle())
    }
}

private struct EditFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    let friend: FriendConnection
    let onSave: (String) -> Void
    @State private var displayName: String

    init(friend: FriendConnection, onSave: @escaping (String) -> Void) {
        self.friend = friend
        self.onSave = onSave
        _displayName = State(initialValue: friend.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact Name") {
                    TextField("Display name", text: $displayName)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    Text(friend.handle)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(displayName)
                        dismiss()
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct FriendActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private enum FriendsHaptics {
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(type)
        #endif
    }
}

private struct FriendCallSession: Identifiable {
    let callID: UUID
    var id: UUID { callID }
    let type: CallType
    let displayName: String
}
