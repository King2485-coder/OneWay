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
    @State private var selectedFilter = "All"
    @State private var toastMessage: String?

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
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        searchBar
                        favoritesRow
                        filterChips
                        if isSelectingChats {
                            selectionActionsBar
                        }
                        chatsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .background { OneWayLightBackground() }

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
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(OneWayDesignSystem.Colors.purpleGradient, in: Capsule())
                        .shadow(color: OneWayDesignSystem.Colors.purple.opacity(0.25), radius: 16, x: 0, y: 8)
                        .padding(.bottom, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                                self.toastMessage = nil
                            }
                        }
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView("Loading chats...")
                }
            }
            .task {
                await viewModel.loadChats()
                viewModel.startRealtimeUpdates()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    await viewModel.loadChats(showLoading: false)
                }
                viewModel.stopRealtimeUpdates()
            }
            .onDisappear {
                viewModel.stopRealtimeUpdates()
            }
#if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-qa-new-message") {
                    isShowingNewChat = true
                }
            }
#endif
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
            HStack(spacing: 12) {
                OneWayLogoMark(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Chats")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                        .lineLimit(1)
                    Text("Your world. Connected.")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        isShowingCameraCapture = true
                    } label: {
                        headerActionIcon(
                            systemName: "camera.viewfinder",
                            foreground: OneWayDesignSystem.Colors.text,
                            background: AnyShapeStyle(OneWayDesignSystem.Colors.elevatedSurface)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open camera")

                    Button {
                        isShowingNewChat = true
                    } label: {
                        headerActionIcon(
                            systemName: "square.and.pencil",
                            foreground: .white,
                            background: AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient),
                            highlighted: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New message")
                }
            }

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
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }
        }
    }

    private func headerActionIcon(
        systemName: String,
        foreground: Color,
        background: AnyShapeStyle,
        highlighted: Bool = false
    ) -> some View {
        OneWayResolvedIcon(systemName: systemName)
            .font(.system(size: 20, weight: .black))
            .foregroundStyle(foreground)
            .frame(width: 46, height: 46)
            .background(background, in: Circle())
            .overlay(Circle().stroke(OneWayDesignSystem.Colors.border, lineWidth: highlighted ? 0 : 1))
            .shadow(color: OneWayDesignSystem.Colors.purple.opacity(highlighted ? 0.25 : 0.12), radius: highlighted ? 12 : 8, x: 0, y: 6)
            .contentShape(Circle())
    }

    private var searchBar: some View {
        OneWaySearchBar(placeholder: "Search or ask AI", text: $viewModel.searchQuery)
    }

    private var favoritesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Array(viewModel.visibleChats.prefix(8)), id: \.id) { chat in
                    VStack(spacing: 6) {
                        OneWayAvatar(name: chat.participantName, size: 58, verified: chat.isPinned, online: chat.unreadCount > 0)
                        Text(chat.participantName.components(separatedBy: " ").first ?? chat.participantName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                            .lineLimit(1)
                            .frame(width: 66)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(["All", "Unread", "Groups", "Channels"], id: \.self) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    OneWayChip(title: filter, isSelected: selectedFilter == filter)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chatsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.visibleChats.isEmpty {
                OneWayCard {
                    VStack(spacing: 10) {
                        OneWayLogoMark(size: 44)
                        Text("No chats found")
                            .font(.title3.weight(.black))
                            .foregroundStyle(OneWayDesignSystem.Colors.text)
                        Text("Start a private chat or ask OneWay AI to help you find someone.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
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
                                OneWayResolvedIcon(systemName: selectedChatIDs.contains(chat.id) ? "checkmark.circle.fill" : "circle")
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
                        .accessibilityIdentifier("chat.row.\(index)")
                        .contextMenu {
                            Button("Reply") {
                                isShowingNewChat = true
                            }

                            Button(chat.isPinned ? "Unpin" : "Pin") {
                                viewModel.togglePinned(chat)
                            }

                            Button("Mark Unread") {
                                toastMessage = "Marked unread"
                            }

                            Button(chat.isMuted ? "Unmute" : "Mute") {
                                viewModel.toggleMuted(chat)
                            }

                            Button(chat.isArchived ? "Unarchive" : "Archive") {
                                viewModel.toggleArchived(chat)
                            }

                            Button("View Contact") {
                                isShowingFriendsList = true
                            }

                            if !chat.isExternal {
                                OneWayResolvedButton("Start Call", systemImage: "phone.fill") {
                                    toastMessage = "Opening call..."
                                }
                                OneWayResolvedButton("Start Video Call", systemImage: "video.fill") {
                                    toastMessage = "Opening video..."
                                }
                            }

                            Button("Delete", role: .destructive) {
                                viewModel.delete(chatIDs: Set([chat.id]))
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                viewModel.delete(chatIDs: Set([chat.id]))
                            } label: {
                                OneWayResolvedLabel("Delete", systemImage: "trash.fill")
                            }
                            Button {
                                viewModel.toggleArchived(chat)
                            } label: {
                                OneWayResolvedLabel("Archive", systemImage: "archivebox.fill")
                            }
                            .tint(.gray)
                            Button {
                                viewModel.toggleMuted(chat)
                            } label: {
                                OneWayResolvedLabel(chat.isMuted ? "Unmute" : "Mute", systemImage: chat.isMuted ? "bell.fill" : "bell.slash.fill")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                viewModel.markAsRead(chatIDs: Set([chat.id]))
                            } label: {
                                OneWayResolvedLabel("Read", systemImage: "checkmark.message.fill")
                            }
                            .tint(.green)
                            Button {
                                viewModel.togglePinned(chat)
                            } label: {
                                OneWayResolvedLabel(chat.isPinned ? "Unpin" : "Pin", systemImage: "pin.fill")
                            }
                            .tint(OneWayDesignSystem.Colors.purple)
                            Button {
                                toastMessage = "Added to favorites"
                            } label: {
                                OneWayResolvedLabel("Favorite", systemImage: "star.fill")
                            }
                            .tint(.yellow)
                        }
                    }

                    if index < viewModel.visibleChats.count - 1 {
                        Divider().overlay(OneWayDesignSystem.Colors.border.opacity(0.7)).padding(.leading, 72)
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
                OneWayResolvedLabel("Read", systemImage: "checkmark.bubble.fill")
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(selectedChatIDs.isEmpty)

            Button {
                viewModel.archive(chatIDs: selectedChatIDs)
                selectedChatIDs.removeAll()
                isSelectingChats = false
            } label: {
                OneWayResolvedLabel("Archive", systemImage: "archivebox.fill")
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(selectedChatIDs.isEmpty)

            Button(role: .destructive) {
                viewModel.delete(chatIDs: selectedChatIDs)
                selectedChatIDs.removeAll()
                isSelectingChats = false
            } label: {
                OneWayResolvedLabel("Delete", systemImage: "trash.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red.opacity(0.9))
            .disabled(selectedChatIDs.isEmpty)

            Spacer()

            Button("Cancel") {
                selectedChatIDs.removeAll()
                isSelectingChats = false
            }
            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OneWayDesignSystem.Colors.elevatedSurface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
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
                        .stroke(OneWayDesignSystem.Colors.border.opacity(0.55), lineWidth: 1.2)
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
                OneWayResolvedIcon(systemName: icon)
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
        HStack(alignment: .top, spacing: 13) {
            OneWayAvatar(name: chat.participantName, size: 62, verified: chat.isPinned, online: chat.unreadCount > 0)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat.participantName)
                        .font(.system(size: 18, weight: chat.unreadCount > 0 ? .black : .bold))
                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                        .lineLimit(1)

                    if chat.isPinned { OneWayResolvedIcon(systemName: "pin.fill").font(.caption2.weight(.bold)).foregroundStyle(OneWayDesignSystem.Colors.purple) }
                    if chat.isMuted { OneWayResolvedIcon(systemName: "bell.slash.fill").font(.caption2.weight(.bold)).foregroundStyle(OneWayDesignSystem.Colors.secondaryText) }
                    if chat.isGroup { OneWayResolvedIcon(systemName: "person.3.fill").font(.caption2.weight(.bold)).foregroundStyle(OneWayDesignSystem.Colors.secondaryText) }
                }

                HStack(spacing: 5) {
                    Text(chat.isExternal ? "SMS" : "OneWay chat")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(chat.isExternal ? Color.orange : OneWayDesignSystem.Colors.purple)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((chat.isExternal ? Color.orange : OneWayDesignSystem.Colors.purple).opacity(0.12), in: Capsule())

                    if chat.lastMessagePreview.lowercased().contains("call") {
                        OneWayResolvedIcon(systemName: "phone.arrow.up.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                    }
                    Text(chat.lastMessagePreview)
                        .font(.system(size: 15, weight: chat.unreadCount > 0 ? .bold : .medium))
                        .foregroundStyle(chat.unreadCount > 0 ? OneWayDesignSystem.Colors.text : OneWayDesignSystem.Colors.secondaryText)
                        .lineLimit(2)
                }

                if chat.lastMessagePreview.lowercased().contains("typing") {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(OneWayDesignSystem.Colors.purple.opacity(0.75))
                                .frame(width: 4, height: 4)
                                .scaleEffect(index == 1 ? 1.25 : 1)
                        }
                        Text("typing...")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OneWayDesignSystem.Colors.purple)
                    }
                    .transition(.opacity)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(formattedDate(chat.lastMessageAt))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(chat.unreadCount > 0 ? OneWayDesignSystem.Colors.purple : OneWayDesignSystem.Colors.secondaryText)

                if chat.unreadCount > 0 {
                    Text("\(chat.unreadCount)")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white)
                        .frame(minWidth: 23, minHeight: 23)
                        .padding(.horizontal, chat.unreadCount > 9 ? 4 : 0)
                        .background(OneWayDesignSystem.Colors.purple, in: Capsule())
                } else {
                    OneWayResolvedIcon(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText.opacity(0.55))
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(OneWayDesignSystem.Colors.panelGlass)
                .shadow(
                    color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.14),
                    radius: 18,
                    x: 0,
                    y: 10
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(OneWayDesignSystem.Colors.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
