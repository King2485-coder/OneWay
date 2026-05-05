import SwiftUI
import Combine
import UIKit

struct ChatsListView: View {
    private let messagingService: MessagingService
    private let friendService: FriendService
    private let groupService: GroupService
    private let callService: CallService
    @EnvironmentObject private var tabVisibilityManager: TabVisibilityManager

    @StateObject private var viewModel: ChatsListViewModel
    @State private var isShowingNewChat = false
    @State private var isShowingFriendsList = false
    @State private var isShowingCameraCapture = false
    @State private var capturedCameraImage: UIImage?
    @State private var isShowingOverflowMenu = false
    @State private var isSelectingChats = false
    @State private var selectedChatIDs: Set<UUID> = []

    init(
        messagingService: MessagingService,
        friendService: FriendService,
        storyService: StoryService,
        groupService: GroupService,
        callService: CallService
    ) {
        self.messagingService = messagingService
        self.friendService = friendService
        self.groupService = groupService
        self.callService = callService
        _viewModel = StateObject(wrappedValue: ChatsListViewModel(messagingService: messagingService, storyService: storyService))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        searchBar
                        if isSelectingChats {
                            selectionActionsBar
                        }
                        chatsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .background { SideMenuBackground() }

                if isShowingOverflowMenu {
                    Rectangle()
                        .fill(Color.black.opacity(0.34))
                        .ignoresSafeArea()
                        .onTapGesture {
                            isShowingOverflowMenu = false
                        }

                    overflowMenu
                        .padding(.leading, 16)
                        .padding(.top, 82)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
                }
            }
            .oneWayMenuBar()
            .overlay {
                if viewModel.isLoading {
                    ProgressView("Loading chats...")
                }
            }
            .task {
                await viewModel.loadChats()
            }
            .refreshable {
                await viewModel.loadChats()
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .sheet(isPresented: $isShowingNewChat) {
                NewChatSheetView(
                    messagingService: messagingService,
                    friendService: friendService,
                    groupService: groupService,
                    callService: callService
                )
            }
            .sheet(isPresented: $isShowingFriendsList) {
                FriendsListView(friendService: friendService)
            }
            .fullScreenCover(isPresented: $isShowingCameraCapture) {
                CameraCaptureView { image in
                    capturedCameraImage = image
                }
            }
            .sheet(isPresented: capturedPreviewPresentedBinding) {
                NavigationStack {
                    VStack(spacing: 16) {
                        if let capturedCameraImage {
                            Image(uiImage: capturedCameraImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 420)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        Text("Captured photo ready.")
                            .foregroundStyle(Theme.textSecondary)

                        Button("Start New Chat") {
                            capturedCameraImage = nil
                            isShowingNewChat = true
                        }
                        .buttonStyle(PrimaryPillButtonStyle())

                        Button("Close") {
                            capturedCameraImage = nil
                        }
                        .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(16)
                    .background { SideMenuBackground() }
                    .navigationTitle("Camera")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle()
                    .fill(Theme.glassSurface)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .onTapGesture { isShowingOverflowMenu.toggle() }

                Spacer()

                HStack(spacing: 12) {
                    Circle()
                        .fill(Theme.glassSurface)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "camera.fill")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .onTapGesture { isShowingCameraCapture = true }

                    Circle()
                        .fill(Color(hex: 0x25D366))
                        .frame(width: 52, height: 52)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.black.opacity(0.92))
                        }
                        .onTapGesture { isShowingNewChat = true }
                }
            }

            Text("Chats")
                .font(.system(size: 64, weight: .bold, design: .default))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            if viewModel.showArchived {
                Button {
                    isShowingFriendsList = true
                } label: {
                    Text("Archived")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Theme.glassSurface)
                                .overlay(Capsule().stroke(Theme.divider, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
            }

            if isSelectingChats {
                Text("\(selectedChatIDs.count) selected")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Ask Meta AI or Search", text: $viewModel.searchQuery)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.glassSurface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.divider, lineWidth: 1))
        )
    }

    private var chatsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.visibleChats.isEmpty {
                Text("No chats found.")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
            } else {
                ForEach(Array(viewModel.visibleChats.enumerated()), id: \.element.id) { index, chat in
                    if isSelectingChats {
                        Button {
                            if selectedChatIDs.contains(chat.id) {
                                selectedChatIDs.remove(chat.id)
                            } else {
                                selectedChatIDs.insert(chat.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedChatIDs.contains(chat.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedChatIDs.contains(chat.id) ? Color(hex: 0x25D366) : Theme.textSecondary)
                                ChatRowView(chat: chat)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            ChatThreadView(
                                chat: chat,
                                messagingService: messagingService,
                                groupService: groupService,
                                friendService: friendService,
                                callService: callService
                            )
                            .onAppear { tabVisibilityManager.isTabBarHidden = true }
                            .onDisappear { tabVisibilityManager.isTabBarHidden = false }
                        } label: {
                            ChatRowView(chat: chat)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(chat.isPinned ? "Unpin" : "Pin") {
                                viewModel.togglePinned(chat)
                            }

                            Button(chat.isMuted ? "Unmute" : "Mute") {
                                viewModel.toggleMuted(chat)
                            }

                            Button(chat.isArchived ? "Unarchive" : "Archive") {
                                viewModel.toggleArchived(chat)
                            }
                        }
                    }

                    if index < viewModel.visibleChats.count - 1 {
                        Divider().overlay(Theme.divider.opacity(0.7)).padding(.leading, 72)
                    }
                }
            }
        }
    }

    private var capturedPreviewPresentedBinding: Binding<Bool> {
        Binding(
            get: { capturedCameraImage != nil },
            set: { updated in
                if !updated {
                    capturedCameraImage = nil
                }
            }
        )
    }

    private var selectionActionsBar: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.markAsRead(chatIDs: selectedChatIDs)
                selectedChatIDs.removeAll()
                isSelectingChats = false
            } label: {
                Label("Read", systemImage: "checkmark.bubble.fill")
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(selectedChatIDs.isEmpty)

            Button {
                viewModel.archive(chatIDs: selectedChatIDs)
                selectedChatIDs.removeAll()
                isSelectingChats = false
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(selectedChatIDs.isEmpty)

            Button(role: .destructive) {
                viewModel.delete(chatIDs: selectedChatIDs)
                selectedChatIDs.removeAll()
                isSelectingChats = false
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red.opacity(0.9))
            .disabled(selectedChatIDs.isEmpty)

            Spacer()

            Button("Cancel") {
                selectedChatIDs.removeAll()
                isSelectingChats = false
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.divider, lineWidth: 1))
        )
    }

    private var overflowMenu: some View {
        VStack(spacing: 0) {
            overflowMenuRow(
                title: "Select chats",
                icon: "checkmark.circle",
                action: {
                    isSelectingChats.toggle()
                    if !isSelectingChats {
                        selectedChatIDs.removeAll()
                    }
                    isShowingOverflowMenu = false
                }
            )

            Divider().overlay(Theme.divider)

            overflowMenuRow(
                title: "Read all",
                icon: "checkmark.bubble",
                action: {
                    viewModel.markAllAsRead()
                    isShowingOverflowMenu = false
                }
            )
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1.2)
                )
        )
        .shadow(color: Color.black.opacity(0.6), radius: 22, x: 0, y: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.appBackground.opacity(0.28))
        )
    }

    private func overflowMenuRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.98))
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.98))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .buttonStyle(.plain)
    }
}

private struct ChatRowView: View {
    let chat: ChatSummary

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 54, height: 54)
                .overlay {
                    Text(initials(for: chat.participantName))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(chat.participantName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)

                    if chat.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.textSecondary) }
                    if chat.isMuted { Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(Theme.textSecondary) }
                    if chat.isGroup { Image(systemName: "person.3.fill").font(.caption).foregroundStyle(Theme.textSecondary) }
                }

                HStack(spacing: 6) {
                    if chat.lastMessagePreview.lowercased().contains("call") {
                        Image(systemName: "phone.arrow.up.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(chat.lastMessagePreview)
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(formattedDate(chat.lastMessageAt))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(chat.unreadCount > 0 ? Color(hex: 0x25D366) : Theme.textSecondary)

                if chat.unreadCount > 0 {
                    Text("\(chat.unreadCount)")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(hex: 0x25D366), in: Capsule())
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func initials(for name: String) -> String {
        let comps = name.split(separator: " ")
        let chars = comps.prefix(2).compactMap { $0.first }
        return chars.isEmpty ? "?" : String(chars)
    }

    private func formattedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month().day().year(.twoDigits))
    }
}
