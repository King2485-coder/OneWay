import SwiftUI

struct NewChatSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let messagingService: MessagingService
    let friendService: FriendService
    let groupService: GroupService
    let callService: CallService

    @State private var searchQuery = ""
    @State private var friends: [FriendConnection] = []
    @State private var directoryResults: [OneWayUserSearchResult] = []
    @State private var recentChats: [ChatSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var directorySearchError: String?
    @State private var selectedDirectoryUser: OneWayUserSearchResult?
    @State private var isShowingDirectoryChat = false
    @State private var contactActionUserID: String?
    @State private var isCreatingExternalChat = false
    @State private var selectedExternalChat: ChatSummary?
    @State private var isShowingExternalChat = false
    @State private var isShowingExternalMessage = false
    @State private var isShowingNewGroup = false
    @State private var privacyMode: DisappearingMessageMode = .off
    @State private var expirationSeconds = 60
    @State private var isShowingPrivacyInfo = false
    @FocusState private var recipientFieldFocused: Bool

    private let suggestedAvatarNames = [
        "NewMessageAvatarJessica",
        "NewMessageAvatarDavid",
        "NewMessageAvatarSophie",
        "NewMessageAvatarAlex",
        "NewMessageAvatarMarcus",
    ]

    init(
        messagingService: MessagingService,
        friendService: FriendService,
        groupService: GroupService,
        callService: CallService
    ) {
        self.messagingService = messagingService
        self.friendService = friendService
        self.groupService = groupService
        self.callService = callService
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-qa-new-message-reference") {
            _searchQuery = State(initialValue: "@ow-397704")
            _privacyMode = State(initialValue: .afterRead)
            _directoryResults = State(initialValue: [
                OneWayUserSearchResult(
                    id: "00000000-0000-0000-0000-000000397704",
                    displayName: "Marcus Reed",
                    onewayId: "@marcus",
                    chirpId: "OW-397704",
                    emailAlias: nil,
                    username: nil,
                    primaryNumber: nil,
                    isOneWayReachable: true,
                    friendshipState: nil
                )
            ])
            _recentChats = State(initialValue: Self.referenceRecentChats)
        }
#endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NewMessageTheme.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.bottom, 18)
                        recipientField
                            .padding(.bottom, 24)

                        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            suggestedContacts
                                .padding(.bottom, 22)
                        }

                        privacySection
                            .padding(.bottom, 24)

                        if let target = normalizedExternalTargetQuery,
                           !isLoading,
                           directoryResults.isEmpty {
                            externalRouteButton(target)
                                .padding(.bottom, 16)
                        }

                        recentConversations
                            .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { recipientFieldFocused = false }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadContent() }
            .task(id: searchQuery) { await searchDirectoryAfterDebounce() }
            .refreshable { await loadContent() }
            .alert("New chat", isPresented: Binding(
                get: { errorMessage != nil },
                set: { value in if !value { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Message Privacy", isPresented: $isShowingPrivacyInfo) {
                Button("Got it", role: .cancel) {}
            } message: {
                Text("Erase After Read starts only after every recipient visibly opens the message in the foreground. Screenshots and copies saved outside OneWay may remain.")
            }
            .sheet(isPresented: $isShowingExternalMessage) {
                ExternalMessageTargetSheet(
                    isCreating: isCreatingExternalChat,
                    onStart: { target in
                        Task { await openExternalChat(target) }
                    }
                )
            }
            .navigationDestination(isPresented: $isShowingNewGroup) {
                CloneNewGroupView()
            }
            .navigationDestination(isPresented: $isShowingExternalChat) {
                if let chat = selectedExternalChat {
                    ChatThreadView(
                        chat: chat,
                        messagingService: messagingService,
                        groupService: groupService,
                        friendService: friendService,
                        callService: callService
                    )
                }
            }
            .navigationDestination(isPresented: $isShowingDirectoryChat) {
                if let user = selectedDirectoryUser, let chat = chatSummary(for: user) {
                    ChatThreadView(
                        chat: chat,
                        messagingService: messagingService,
                        groupService: groupService,
                        friendService: friendService,
                        callService: callService
                    )
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { recipientFieldFocused = false }
                }
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("New Message")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(NewMessageTheme.text)

            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(NewMessageTheme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(NewMessageTheme.panel.opacity(0.7), in: Capsule())
                    .overlay(Capsule().stroke(NewMessageTheme.border, lineWidth: 1))
                Spacer()
            }
        }
        .frame(height: 36)
    }

    private var recipientField: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(NewMessageTheme.purple.opacity(0.15))
                OneWayResolvedIcon(systemName: "person.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(NewMessageTheme.purpleBright)
            }
            .frame(width: 38, height: 38)

            Rectangle()
                .fill(NewMessageTheme.border.opacity(0.7))
                .frame(width: 1, height: 28)

            TextField("Name, @OneWayID, phone, or email", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(searchQuery.contains("@") ? .emailAddress : .asciiCapable)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(NewMessageTheme.text)
                .tint(NewMessageTheme.purpleBright)
                .focused($recipientFieldFocused)
                .submitLabel(.done)
                .onSubmit { recipientFieldFocused = false }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    directoryResults = []
                } label: {
                    OneWayResolvedIcon(systemName: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(NewMessageTheme.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear recipient search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(NewMessageTheme.panel.opacity(0.62), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(NewMessageTheme.purple.opacity(0.85), lineWidth: 1))
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Message Privacy")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(NewMessageTheme.text)
                    Text("Choose when messages disappear.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(NewMessageTheme.secondary)
                }
                Spacer()
                Button { isShowingPrivacyInfo = true } label: {
                    HStack(spacing: 6) {
                        Text("Learn more")
                        OneWayResolvedIcon(systemName: "info.circle")
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(NewMessageTheme.purpleSoft)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                privacyChoice(
                    mode: .off,
                    title: "Keep Messages",
                    subtitle: "Messages stay until deleted",
                    icon: "message.fill"
                )
                privacyChoice(
                    mode: .afterRead,
                    title: "Erase After Read",
                    subtitle: "Messages disappear after they are read",
                    icon: "clock.arrow.circlepath"
                )
            }
            .padding(1)
            .background(NewMessageTheme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NewMessageTheme.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 7) {
                Text("Erase:")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(NewMessageTheme.text)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        durationChip("Immediately", seconds: 0)
                        durationChip("30 sec", seconds: 30)
                        durationChip("1 min", seconds: 60)
                        durationChip("5 min", seconds: 300)
                        durationChip("1 hr", seconds: 3_600)
                        durationChip("Custom", seconds: -1, icon: "calendar.badge.clock")
                    }
                }

                Divider().overlay(NewMessageTheme.border.opacity(0.75))

                HStack(alignment: .top, spacing: 9) {
                    OneWayResolvedIcon(systemName: "checkmark.shield")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(NewMessageTheme.purpleBright)
                    Text("Messages disappear after the recipient opens them. Screenshots, copies, forwarded content, or files saved outside OneWay may remain.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(NewMessageTheme.secondary)
                        .lineSpacing(1)
                }
            }
            .padding(8)
            .background(NewMessageTheme.panel.opacity(0.52), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewMessageTheme.border, lineWidth: 1))
        }
    }

    private func privacyChoice(mode: DisappearingMessageMode, title: String, subtitle: String, icon: String) -> some View {
        let selected = privacyMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { privacyMode = mode }
        } label: {
            HStack(spacing: 10) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(selected ? .white : NewMessageTheme.purpleBright)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(NewMessageTheme.text)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(selected ? NewMessageTheme.purpleSoft : NewMessageTheme.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                selected ? AnyShapeStyle(NewMessageTheme.selectedGradient) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .shadow(color: selected ? NewMessageTheme.purple.opacity(0.48) : .clear, radius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func durationChip(_ title: String, seconds: Int, icon: String? = nil) -> some View {
        let selected = expirationSeconds == seconds
        return Button {
            expirationSeconds = seconds
            if privacyMode == .off { privacyMode = .afterRead }
        } label: {
            HStack(spacing: 5) {
                if let icon { OneWayResolvedIcon(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(selected ? .white : NewMessageTheme.text)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(selected ? NewMessageTheme.purple.opacity(0.72) : NewMessageTheme.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? NewMessageTheme.purpleBright : NewMessageTheme.border, lineWidth: 1))
            .shadow(color: selected ? NewMessageTheme.purple.opacity(0.55) : .clear, radius: 9)
        }
        .buttonStyle(.plain)
    }

    private var suggestedContacts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(searchQuery.isEmpty ? "Suggested Contacts" : "OneWay Results")
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(NewMessageTheme.text)

            if isLoading && searchQuery.isEmpty && filteredFriends.isEmpty {
                ProgressView().tint(NewMessageTheme.purpleBright).frame(maxWidth: .infinity, minHeight: 88)
            } else if !searchQuery.isEmpty && isLoading {
                HStack(spacing: 10) {
                    ProgressView().tint(NewMessageTheme.purpleBright)
                    Text("Searching OneWay…")
                }
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(NewMessageTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else if let directorySearchError, !searchQuery.isEmpty {
                Button { Task { await performDirectorySearch() } } label: {
                    VStack(spacing: 5) {
                        Text(directorySearchError)
                        Text("Tap to retry").foregroundStyle(NewMessageTheme.purpleSoft)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }.buttonStyle(.plain)
            } else if !searchQuery.isEmpty && directoryResults.isEmpty {
                Text(normalizedExternalTargetQuery == nil ? "No OneWay user found." : "No OneWay account found. Continue below with SMS.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(NewMessageTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else if !searchQuery.isEmpty {
                VStack(spacing: 10) {
                    ForEach(directoryResults) { result in directoryResultCard(result) }
                }
            } else if filteredFriends.isEmpty {
                Text("Your OneWay contacts will appear here.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(NewMessageTheme.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(Array(filteredFriends.prefix(8).enumerated()), id: \.element.id) { index, friend in
                            NavigationLink {
                                chatThread(for: friend)
                            } label: {
                                suggestedContact(friend, index: index)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .contentMargins(.horizontal, -4, for: .scrollContent)
            }
        }
    }

    private func directoryResultCard(_ result: OneWayUserSearchResult) -> some View {
        HStack(spacing: 12) {
            Image("NewMessageAvatarMarcus")
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                .overlay(Circle().stroke(NewMessageTheme.purpleBright, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.displayName ?? "OneWay User").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(NewMessageTheme.text)
                if let identity = result.onewayId ?? result.username { Text(identity.hasPrefix("@") ? identity : "@\(identity)") }
                if let number = result.chirpId ?? result.primaryNumber { Text(number.lowercased()) }
                HStack(spacing: 6) {
                    OneWayResolvedIcon(systemName: "lock.shield.fill")
                    Text("OneWay Chat")
                }.foregroundStyle(NewMessageTheme.purpleSoft)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(NewMessageTheme.secondary)
            Spacer(minLength: 4)
            VStack(spacing: 8) {
                Button(contactTitle(result.friendshipState)) { Task { await addContact(result) } }
                    .disabled(!canAddContact(result.friendshipState) || contactActionUserID != nil)
                    .buttonStyle(NewMessageOutlineButtonStyle())
                Button("Message") { openDirectoryUser(result) }
                    .buttonStyle(NewMessagePrimaryButtonStyle())
            }
            .frame(width: 112)
        }
        .padding(14)
        .frame(minHeight: 132)
        .newMessageCard()
    }

    private func suggestedContact(_ friend: FriendConnection, index: Int) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Image(suggestedAvatarNames[index % suggestedAvatarNames.count])
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(NewMessageTheme.purpleBright, lineWidth: 1.2))
                Circle()
                    .fill(index == 3 ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(NewMessageTheme.backgroundColor, lineWidth: 1.5))
                    .offset(x: -2, y: -1)
                OneWayResolvedIcon(systemName: "person.2.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(NewMessageTheme.purpleSoft)
                    .frame(width: 20, height: 20)
                    .background(NewMessageTheme.purple.opacity(0.5), in: Circle())
                    .offset(x: 5, y: 3)
            }
            Text(friend.displayName)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(NewMessageTheme.text)
                .lineLimit(1)
            Text(friend.handle)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(NewMessageTheme.secondary)
                .lineLimit(1)
        }
        .frame(width: 68)
    }

    private var recentConversations: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent Conversations")
            if recentChats.isEmpty {
                Text("Your recent conversations will appear here.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(NewMessageTheme.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .newMessageCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentChats.prefix(2).enumerated()), id: \.element.id) { index, chat in
                        NavigationLink {
                            ChatThreadView(chat: chat, messagingService: messagingService, groupService: groupService, friendService: friendService, callService: callService)
                        } label: {
                            recentRow(chat, index: index)
                        }
                        .buttonStyle(.plain)
                        if index == 0 && recentChats.prefix(2).count > 1 {
                            Divider().overlay(NewMessageTheme.border.opacity(0.55)).padding(.leading, 58)
                        }
                    }
                }
                .newMessageCard()
            }
        }
    }

    private func recentRow(_ chat: ChatSummary, index: Int) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(NewMessageTheme.purple.opacity(0.17))
                if chat.isGroup {
                    OneWayResolvedIcon(systemName: "person.3.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(NewMessageTheme.purpleSoft)
                } else {
                    Image(suggestedAvatarNames[index % suggestedAvatarNames.count])
                        .resizable().scaledToFill().clipShape(Circle())
                        .overlay(Circle().stroke(NewMessageTheme.purpleBright, lineWidth: 1))
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(chat.participantName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(NewMessageTheme.text)
                Text(chat.lastMessagePreview)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(NewMessageTheme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(chat.lastMessageAt.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(NewMessageTheme.secondary)
                if chat.unreadCount > 0 {
                    Text("\(chat.unreadCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(NewMessageTheme.purple.opacity(0.75), in: Circle())
                } else if chat.isPinned {
                    OneWayResolvedIcon(systemName: "pin.fill")
                        .foregroundStyle(NewMessageTheme.purpleBright)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 74)
    }

    private var quickActions: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                quickAction(icon: "person.3.fill", title: "Create a shared\nconversation") { isShowingNewGroup = true }
                verticalDivider
                ShareLink(item: URL(string: "https://oneway.is/invite")!) {
                    quickActionLabel(icon: "person.badge.plus", title: "Invite someone\nto OneWay")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            Divider().overlay(NewMessageTheme.border.opacity(0.55)).padding(.horizontal, 12)
            HStack(spacing: 0) {
                quickAction(icon: "message.fill", title: "Send with smart\nSMS routing") { isShowingExternalMessage = true }
                verticalDivider
                ShareLink(item: URL(string: "https://oneway.is")!) {
                    quickActionLabel(icon: "paperplane.fill", title: "Bring someone\nto OneWay")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .newMessageCard()
    }

    private var verticalDivider: some View {
        Rectangle().fill(NewMessageTheme.border.opacity(0.55)).frame(width: 1, height: 46)
    }

    private func quickAction(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { quickActionLabel(icon: icon, title: title) }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
    }

    private func quickActionLabel(icon: String, title: String) -> some View {
        HStack(spacing: 11) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(NewMessageTheme.purpleBright)
                .frame(width: 32, height: 32)
                .background(NewMessageTheme.purple.opacity(0.15), in: Circle())
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(NewMessageTheme.purpleSoft)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(NewMessageTheme.text)
            Spacer()
            Button { } label: {
                HStack(spacing: 7) {
                    Text("View all")
                    OneWayResolvedIcon(systemName: "chevron.right")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(NewMessageTheme.purpleSoft)
            }
            .buttonStyle(.plain)
        }
    }

    private func externalRouteButton(_ target: String) -> some View {
        Button { Task { await openExternalChat(target) } } label: {
            HStack(spacing: 12) {
                OneWayResolvedIcon(systemName: target.contains("@") ? "envelope.fill" : "message.fill")
                    .foregroundStyle(NewMessageTheme.purpleBright)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCreatingExternalChat ? "Connecting…" : "Message \(target)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(NewMessageTheme.text)
                    Text(target.contains("@") ? "External email route" : "Smart SMS route")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(NewMessageTheme.secondary)
                }
                Spacer()
                Text("Start").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(NewMessageTheme.purpleSoft)
            }
            .padding(13)
            .newMessageCard()
        }
        .buttonStyle(.plain)
        .disabled(isCreatingExternalChat)
    }

    private func chatThread(for friend: FriendConnection) -> some View {
        ChatThreadView(
            chat: ChatSummary(
                id: friend.id,
                participantName: friend.displayName,
                participantHandle: friend.handle,
                lastMessagePreview: "Start a secure conversation",
                lastMessageAt: .now,
                unreadCount: 0,
                presence: .online,
                isPinned: false,
                isMuted: false,
                isArchived: false,
                isGroup: false,
                privacySettings: ConversationPrivacySettings(
                    expirationMode: privacyMode,
                    expirationDurationSeconds: privacyMode == .afterRead ? max(0, expirationSeconds) : nil,
                    allowForwarding: true,
                    allowCopying: true,
                    allowSavingAttachments: true,
                    version: 1
                )
            ),
            messagingService: messagingService,
            groupService: groupService,
            friendService: friendService,
            callService: callService
        )
    }

    private var filteredFriends: [FriendConnection] {
        let connected = friends.filter { $0.status == .connected }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return connected }
        return connected.filter {
            $0.displayName.lowercased().contains(query) || $0.handle.lowercased().contains(query)
        }
    }

    private func searchDirectoryAfterDebounce() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-qa-new-message-reference") { return }
#endif
        directorySearchError = nil
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { directoryResults = []; return }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard !Task.isCancelled else { return }
        await performDirectorySearch()
    }

    private func performDirectorySearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            directoryResults = try await friendService.searchUsers(query: query)
            directorySearchError = nil
        } catch {
            directoryResults = []
            directorySearchError = "Unable to search OneWay right now."
        }
    }

    private func addContact(_ result: OneWayUserSearchResult) async {
        contactActionUserID = result.id
        defer { contactActionUserID = nil }
        do {
            if result.friendshipState == "pendingIncoming" {
                let loadedFriends = try await friendService.fetchFriends()
                var pending: FriendConnection?
                for friend in loadedFriends {
                    let sameUser = friend.userID.caseInsensitiveCompare(result.id) == .orderedSame
                    if sameUser && friend.status == .pending {
                        pending = friend
                        break
                    }
                }
                guard let pending else {
                    directorySearchError = "This contact request changed. Refresh and try again."
                    return
                }
                _ = try await friendService.acceptFriendRequest(id: pending.id)
            } else {
                _ = try await friendService.sendFriendRequest(to: result.id)
            }
            await performDirectorySearch()
        } catch { directorySearchError = "Unable to add this contact. Tap to retry." }
    }

    private func openDirectoryUser(_ result: OneWayUserSearchResult) {
        guard chatSummary(for: result) != nil else { return }
        selectedDirectoryUser = result
        recipientFieldFocused = false
        isShowingDirectoryChat = true
    }

    private func chatSummary(for result: OneWayUserSearchResult) -> ChatSummary? {
        guard let userID = UUID(uuidString: result.id) else { return nil }
        return ChatSummary(
            id: userID,
            participantName: result.displayName ?? "OneWay User",
            participantHandle: result.onewayId ?? result.username ?? result.chirpId ?? result.id,
            lastMessagePreview: "Start a OneWay conversation",
            lastMessageAt: .now,
            unreadCount: 0,
            presence: .online,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            isGroup: false,
            privacySettings: ConversationPrivacySettings(
                expirationMode: privacyMode,
                expirationDurationSeconds: privacyMode == .afterRead ? max(0, expirationSeconds) : nil,
                allowForwarding: true,
                allowCopying: true,
                allowSavingAttachments: true,
                version: 1
            )
        )
    }

    private func initials(_ value: String) -> String {
        let letters = value.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "OW" : String(letters).uppercased()
    }

    private func contactTitle(_ state: String?) -> String {
        switch state { case "accepted": return "Contact"; case "pendingOutgoing": return "Sent"; case "pendingIncoming": return "Accept"; default: return "Add Contact" }
    }

    private func canAddContact(_ state: String?) -> Bool { !["accepted", "pendingOutgoing", "blocked"].contains(state ?? "") }

    private var normalizedExternalTargetQuery: String? {
        normalizeExternalTarget(searchQuery)
    }

    private func loadContent() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-qa-new-message-reference") { return }
#endif
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedFriends = friendService.fetchFriends()
            async let loadedChats = messagingService.fetchChats()
            friends = try await loadedFriends
            recentChats = (try? await loadedChats) ?? []
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load contacts."
        }
    }

#if DEBUG
    private static var referenceRecentChats: [ChatSummary] {
        [
            ChatSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                participantName: "Ava Chen",
                participantHandle: "@ava",
                lastMessagePreview: "Let’s meet up for coffee later!",
                lastMessageAt: .now.addingTimeInterval(-60),
                unreadCount: 2,
                presence: .online,
                isPinned: false,
                isMuted: false,
                isArchived: false,
                isGroup: false
            ),
            ChatSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
                participantName: "Jordan Ellis",
                participantHandle: "@jordan",
                lastMessagePreview: "That sounds good",
                lastMessageAt: .now.addingTimeInterval(-7_200),
                unreadCount: 0,
                presence: .offline,
                isPinned: false,
                isMuted: false,
                isArchived: false,
                isGroup: false
            )
        ]
    }
#endif

    private func openExternalChat(_ target: String) async {
        isCreatingExternalChat = true
        defer { isCreatingExternalChat = false }
        do {
            if isEmail(target) {
                let preflight = try await SMSBridgeService.shared.emailPreflight()
                print("Email preflight:", preflight)
                guard preflight.ok else {
                    errorMessage = "OneWay email bridge is not configured yet: \(preflight.missing.joined(separator: ", "))"
                    return
                }
            } else {
                let preflight = try await SMSBridgeService.shared.preflight()
                print("SMS preflight:", preflight)
                guard preflight.ok else {
                    if let reason = preflight.setupRequiredReason, !reason.isEmpty {
                        errorMessage = reason
                    } else if !preflight.missing.isEmpty {
                        errorMessage = "OneWay SMS bridge is not configured yet: \(preflight.missing.joined(separator: ", "))"
                    } else if !preflight.warnings.isEmpty {
                        errorMessage = preflight.warnings.joined(separator: "\n")
                    } else {
                        errorMessage = "OneWay SMS bridge is not ready yet."
                    }
                    return
                }
            }

            selectedExternalChat = try await SMSBridgeService.shared.startExternalConversation(to: target)
            isShowingExternalMessage = false
            isShowingExternalChat = true
            errorMessage = nil
        } catch {
            errorMessage = "Unable to start an external network chat."
        }
    }

    private func normalizeExternalTarget(_ raw: String) -> String? {
        if let email = normalizeEmail(raw) {
            return email
        }
        return normalizePhoneNumber(raw)
    }

    private func normalizeEmail(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"),
              trimmed.contains("."),
              trimmed.count <= 254,
              trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private func isEmail(_ raw: String) -> Bool {
        normalizeEmail(raw) != nil
    }

    private func normalizePhoneNumber(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard digits.count >= 7, digits.count <= 15 else { return nil }

        if trimmed.hasPrefix("+") {
            return "+\(digits)"
        }
        if digits.count == 10 {
            return "+1\(digits)"
        }
        if digits.count == 11, digits.hasPrefix("1") {
            return "+\(digits)"
        }
        return "+\(digits)"
    }

}

private enum NewMessageTheme {
    static let backgroundColor = Color(hex: 0x040612)
    static let panel = Color(hex: 0x0A0C21)
    static let border = Color(hex: 0x35365D)
    static let purple = Color(hex: 0x6D24D9)
    static let purpleBright = Color(hex: 0x9747FF)
    static let purpleSoft = Color(hex: 0xC4A6FF)
    static let text = Color(hex: 0xF8F6FF)
    static let secondary = Color(hex: 0xB8B3DD)
    static let background = ZStack {
        backgroundColor
        RadialGradient(colors: [purple.opacity(0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 280)
        RadialGradient(colors: [Color(hex: 0x20205A).opacity(0.13), .clear], center: .bottomLeading, startRadius: 10, endRadius: 340)
    }
    static let selectedGradient = LinearGradient(
        colors: [Color(hex: 0x5011B7), Color(hex: 0x7B19E7)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

private extension View {
    func newMessageCard() -> some View {
        background(NewMessageTheme.panel.opacity(0.58), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(NewMessageTheme.border, lineWidth: 1))
    }
}

private struct NewMessageOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(NewMessageTheme.purpleSoft)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(NewMessageTheme.panel.opacity(configuration.isPressed ? 0.9 : 0.55), in: Capsule())
            .overlay(Capsule().stroke(NewMessageTheme.purpleBright, lineWidth: 1))
    }
}

private struct NewMessagePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(NewMessageTheme.selectedGradient.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .shadow(color: NewMessageTheme.purple.opacity(0.55), radius: 8)
    }
}

private struct ExternalMessageTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var validationMessage: String?

    let isCreating: Bool
    let onStart: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Phone number or email", text: $target)
                        .textInputAutocapitalization(.never)
                        .keyboardType(target.contains("@") ? .emailAddress : .phonePad)

                    Text("OneWay will route phone numbers through the SMS bridge and email addresses through the email bridge. This does not use iMessage, SMS.app, or Mail.app.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)

                    Text("By providing your phone number, you agree to receive OneWay SMS messages for verification, account alerts, service notifications, support, and user-initiated communications. Message frequency varies. Message and data rates may apply. Reply STOP to opt out or HELP for help.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                } header: {
                    Text("Reach Outside OneWay")
                }

                if let normalizedTarget {
                    Section("Route") {
                        OneWayResolvedLabel(
                            normalizedTarget.contains("@") ? "External Email Bridge" : "External SMS Bridge",
                            systemImage: normalizedTarget.contains("@") ? "envelope.fill" : "message.fill"
                        )
                        Text(normalizedTarget)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { SideMenuBackground() }
            .oneWayMenuBar()
            .navigationTitle("External message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Connecting..." : "Start") {
                        guard let normalizedTarget else {
                            validationMessage = "Enter a valid phone number or email address."
                            return
                        }
                        validationMessage = nil
                        onStart(normalizedTarget)
                    }
                    .disabled(isCreating)
                }
            }
        }
    }

    private var normalizedTarget: String? {
        normalizeEmail(target) ?? normalizePhoneNumber(target)
    }

    private func normalizeEmail(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"),
              trimmed.contains("."),
              trimmed.count <= 254,
              trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private func normalizePhoneNumber(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard digits.count >= 7, digits.count <= 15 else { return nil }

        if trimmed.hasPrefix("+") {
            return "+\(digits)"
        }
        if digits.count == 10 {
            return "+1\(digits)"
        }
        if digits.count == 11, digits.hasPrefix("1") {
            return "+\(digits)"
        }
        return "+\(digits)"
    }
}
