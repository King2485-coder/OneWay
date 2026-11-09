import SwiftUI

struct PhoneContactsView: View {
    private enum ContactAction: Equatable {
        case message(UUID)
        case walkie(UUID)
        case call(UUID)
        case video(UUID)
        case favorite(UUID)
    }

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var manager: CallManager

    @State private var isManagingOneWayContacts = false
    @State private var searchText = ""
    @State private var selectedFriend: FriendConnection?
    @State private var selectedContact: ContactEntry?
    @State private var showAddOneWayContact = false
    @State private var selectedFilter = "All"
    @State private var activeContactAction: ContactAction?
    @State private var chatFriend: FriendConnection?
    @State private var walkieFriend: FriendConnection?

    private let filters = ["All", "OneWay", "Phone", "Favorites", "Nearby"]

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()

            GeometryReader { proxy in
                ScrollViewReader { _ in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: OneWaySignalContactsLayout.sectionSpacing) {
                            header
                            filtersRow
                            oneWayContactsSection
                            importedContactsSection
                        }
                        .padding(.horizontal, OneWaySignalContactsLayout.horizontalPadding)
                        .padding(.top, OneWaySignalContactsLayout.topPadding)
                        .padding(.bottom, OneWaySignalContactsLayout.bottomToolbarReservedHeight)
                        .frame(
                            maxWidth: OneWaySignalContactsLayout.maxContentWidth(
                                width: proxy.size.width,
                                horizontalSizeClass: horizontalSizeClass
                            ),
                            alignment: .top
                        )
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            await manager.refreshAll()
        }
        .sheet(isPresented: $manager.isShowingContactPicker) {
            ContactPickerSheet { contacts in
                manager.importSelectedContacts(contacts)
            }
        }
        .sheet(isPresented: $isManagingOneWayContacts, onDismiss: {
            Task { await manager.refreshAll() }
        }) {
            FriendsListView(friendService: environment.friendService)
        }
        .sheet(item: $selectedFriend) { friend in
            ContactProfileView(
                friend: friend,
                manager: manager,
                onClose: { selectedFriend = nil },
                onMessage: { onMessage(friend) },
                onWalkie: { onWalkie(friend) }
            )
        }
        .sheet(item: $selectedContact) { contact in
            ImportedContactProfileView(
                contact: contact,
                manager: manager,
                onClose: { selectedContact = nil }
            )
        }
        .sheet(isPresented: $showAddOneWayContact) {
            AddOneWayContactView {
                showAddOneWayContact = false
                isManagingOneWayContacts = true
            }
            .presentationDetents([.medium])
        }
        .navigationDestination(item: $chatFriend) { friend in
            DirectContactChatView(friend: friend)
        }
        .navigationDestination(item: $walkieFriend) { friend in
            DirectWalkieContactView(friend: friend)
        }
    }

    private var filteredFriends: [FriendConnection] {
        let base: [FriendConnection]
        switch selectedFilter {
        case "Favorites":
            base = manager.favoriteFriends
        case "Phone":
            base = []
        case "Blocked":
            base = []
        default:
            base = manager.connectedFriends
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.displayName.lowercased().contains(q)
            || $0.handle.lowercased().contains(q)
            || $0.id.uuidString.lowercased().contains(q)
        }
    }

    private var filteredImportedContacts: [ContactEntry] {
        guard selectedFilter == "All" || selectedFilter == "Phone" else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return manager.importedContacts }
        return manager.importedContacts.filter {
            $0.displayName.lowercased().contains(q)
            || $0.phoneNumber.lowercased().contains(q)
        }
    }

    private var header: some View {
        VStack(spacing: OneWaySignalContactsLayout.headerSpacing) {
            OneWaySignalHeroBanner()
                .padding(.horizontal, -OneWaySignalContactsLayout.horizontalPadding)

            VStack(spacing: 4) {
                Text("Contacts")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                    .foregroundStyle(OneWayCallTheme.text)
                    .multilineTextAlignment(.center)
                Text("Private calling for the people you care about.")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(OneWayCallTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            contactsSearchField
        }
    }

    private var contactsSearchField: some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: "magnifyingglass")
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
                .frame(width: 30, height: 30)

            TextField("Search people", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.search)
                .font(.headline.weight(.semibold))
                .foregroundStyle(OneWayCallTheme.text)
                .accessibilityLabel("Search people")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    OneWayResolvedIcon(systemName: "xmark.circle.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayCallTheme.muted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, searchText.isEmpty ? 16 : 4)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .background(Color(hex: 0x080718).opacity(0.94), in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(OneWayCallTheme.purple.opacity(0.46), lineWidth: 1.2)
        )
        .shadow(color: OneWayCallTheme.purple.opacity(0.13), radius: 14, x: 0, y: 8)
    }

    private var filtersRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(filters, id: \.self) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter)
                            .font(.caption.weight(.black))
                            .foregroundStyle(OneWayCallTheme.text)
                            .frame(minWidth: filter == "All" ? 54 : 84)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(selectedFilter == filter ? OneWayCallTheme.purpleGradient : LinearGradient(colors: [Color(hex: 0x111027), Color(hex: 0x0A091A)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                            .overlay(Capsule().stroke(OneWayCallTheme.purple.opacity(0.34), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 8)
        }
    }

    private var oneWayContactsSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                oneWaySignalBarsIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text("OneWay Signal")
                        .font(.title3.weight(.black))
                        .foregroundStyle(OneWayCallTheme.text)
                    Text("OneWay Contacts")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OneWayCallTheme.muted)
                }
                Spacer()
                Button {
                    isManagingOneWayContacts = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Manage")
                        OneWayResolvedIcon(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayCallTheme.purple)
                }
                .buttonStyle(.plain)
            }

            if let error = manager.contactsError, !manager.connectedFriends.isEmpty {
                contactsStatusBanner(
                    message: "Contacts could not refresh. Showing the latest saved results.",
                    detail: error
                )
            }

            if manager.isRefreshing, manager.connectedFriends.isEmpty, !manager.hasLoadedOneWayContacts {
                HStack(spacing: 12) {
                    ProgressView().tint(OneWayCallTheme.purple)
                    Text("Loading OneWay contacts…")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(OneWayCallTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 20))
            } else if let error = manager.contactsError, manager.connectedFriends.isEmpty {
                contactsStatusBanner(message: "Contacts could not load", detail: error)
            } else if filteredFriends.isEmpty {
                emptyCard("No OneWay contacts yet", "Add or accept friends to call, video, and Chirp privately.")
            } else {
                favoritesScroller
                featuredContactCard(filteredFriends[0])
            }
        }
        .padding(18)
        .oneWayCallGlass(cornerRadius: 30)
    }

    private var oneWaySignalBarsIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OneWayCallTheme.purpleGradient)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array([13, 20, 28, 36].enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(.white)
                        .frame(width: 5, height: CGFloat(height))
                        .shadow(color: .white.opacity(0.42), radius: 5)
                }
            }
            .frame(height: 38, alignment: .bottom)
        }
        .frame(width: 50, height: 50)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: OneWayCallTheme.purple.opacity(0.32), radius: 14, x: 0, y: 8)
        .accessibilityLabel("OneWay Signal")
    }

    private func contactsStatusBanner(message: String, detail: OneWayNetworkError) -> some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(OneWayCallTheme.text)
#if DEBUG
                Text(detail.localizedDescription)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayCallTheme.muted)
#endif
            }
            Spacer(minLength: 8)
            Button("Retry") {
                Task { await manager.refreshAll() }
            }
            .font(.caption.weight(.black))
            .foregroundStyle(OneWayCallTheme.purple)
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.28), lineWidth: 1))
    }

    private var favoritesScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(filteredFriends.prefix(12)) { friend in
                    Button {
                        selectedFriend = friend
                    } label: {
                        VStack(spacing: 7) {
                            avatar(title: friend.displayName, size: 72, online: true, speaking: manager.favoriteFriends.contains(friend))
                            Text(friend.displayName)
                                .font(.caption.weight(.black))
                                .foregroundStyle(OneWayCallTheme.text)
                                .lineLimit(1)
                            Text(manager.favoriteFriends.contains(friend) ? "Speaking" : "Online")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(manager.favoriteFriends.contains(friend) ? OneWayCallTheme.purple : .green)
                        }
                        .frame(width: 86)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    isManagingOneWayContacts = true
                } label: {
                    VStack(spacing: 7) {
                        Text("+2")
                            .font(.title2.weight(.black))
                            .foregroundStyle(OneWayCallTheme.text)
                            .frame(width: 72, height: 72)
                            .background(OneWayCallTheme.elevatedSurface, in: Circle())
                            .overlay(Circle().stroke(OneWayCallTheme.purple, lineWidth: 2))
                        Text("View All")
                            .font(.caption.weight(.black))
                            .foregroundStyle(OneWayCallTheme.text)
                        Text(" ")
                            .font(.caption2)
                    }
                    .frame(width: 86)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var importedContactsSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Imported Contacts")
                        .font(.title3.weight(.black))
                        .foregroundStyle(OneWayCallTheme.text)
                    Text("Available through OneWay External Network")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OneWayCallTheme.muted)
                }
                Spacer()
                Button {
                    Task { await manager.refreshAll() }
                } label: {
                    OneWayResolvedIcon(systemName: "arrow.clockwise")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayCallTheme.purple)
                        .frame(width: 38, height: 38)
                        .background(OneWayCallTheme.elevatedSurface, in: Circle())
                }
                .buttonStyle(.plain)
            }

            permissionCopy

            HStack(spacing: 10) {
                Button {
                    Task { await manager.importContacts() }
                } label: {
                    OneWayResolvedLabel("Import Contacts", systemImage: "person.crop.circle.badge.plus")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(OneWayCallTheme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(OneWayCallTheme.purple.opacity(0.22), in: Capsule())
                        .overlay(Capsule().stroke(OneWayCallTheme.purple.opacity(0.38), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(manager.isImportingContacts || manager.contactPermissionState == .restricted)

                Button {
                    manager.isShowingContactPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Imported \(manager.importedContacts.count)")
                        OneWayResolvedIcon(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(OneWayCallTheme.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(OneWayCallTheme.elevatedSurface, in: Capsule())
                    .overlay(Capsule().stroke(OneWayCallTheme.purple.opacity(0.26), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if filteredImportedContacts.isEmpty {
                emptyCard(
                    "No imported contacts",
                    manager.contactPermissionState == .authorized
                        ? "No phone contacts found yet."
                        : "Grant contact access to see people you already know."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(filteredImportedContacts) { contact in
                        importedContactCard(contact)
                    }
                }
            }
        }
        .padding(18)
        .oneWayCallGlass(cornerRadius: 30)
    }

    private func featuredContactCard(_ friend: FriendConnection) -> some View {
        VStack(spacing: 14) {
            Button {
                selectedFriend = friend
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    avatar(title: friend.displayName, size: 82, online: true, speaking: manager.favoriteFriends.contains(friend))
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Text(friend.displayName)
                                .font(.title3.weight(.black))
                                .foregroundStyle(OneWayCallTheme.text)
                            OneWayResolvedIcon(systemName: "checkmark.seal.fill")
                                .foregroundStyle(OneWayCallTheme.purple)
                        }
                        Text(friend.handle)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(OneWayCallTheme.muted)
                        HStack(spacing: 6) {
                            badge("Online", color: .green)
                            badge("OW-\(friend.id.uuidString.prefix(6).uppercased())", color: OneWayCallTheme.purple)
                            badge("Verified", color: OneWayCallTheme.purple)
                            badge("Private", color: OneWayCallTheme.purple)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Divider().overlay(OneWayCallTheme.purple.opacity(0.28))

            HStack(spacing: 0) {
                labeledAction("Message", "message.fill", isLoading: activeContactAction == .message(friend.id)) {
                    onMessage(friend)
                }
                labeledAction("Chirp", "dot.radiowaves.left.and.right", isLoading: activeContactAction == .walkie(friend.id)) {
                    onWalkie(friend)
                }
                labeledAction("Call", "phone.fill", isLoading: activeContactAction == .call(friend.id)) {
                    onCall(friend)
                }
                labeledAction("Video", "video.fill", isLoading: activeContactAction == .video(friend.id)) {
                    onVideo(friend)
                }
                labeledAction(
                    "Favorite",
                    manager.favoriteFriends.contains(friend) ? "star.fill" : "star",
                    isActive: manager.favoriteFriends.contains(friend),
                    isLoading: activeContactAction == .favorite(friend.id)
                ) {
                    onFavorite(friend)
                }
            }
        }
        .padding(16)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(OneWayCallTheme.purple.opacity(0.26), lineWidth: 1))
    }

    @ViewBuilder
    private var permissionCopy: some View {
        switch manager.contactPermissionState {
        case .authorized:
            if !manager.importedContacts.isEmpty {
                Text("Imported \(manager.importedContacts.count) contact\(manager.importedContacts.count == 1 ? "" : "s") from your iPhone.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayCallTheme.muted)
            }
        case .notDetermined:
            Text("OneWay never uploads contacts without your permission.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OneWayCallTheme.muted)
        case .denied:
            Text("Contacts access is off. Open Settings to enable Contacts for OneWay.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .restricted:
            Text("Contacts access is restricted on this device.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private func oneWayContactCard(_ friend: FriendConnection) -> some View {
        Button {
            selectedFriend = friend
        } label: {
            HStack(spacing: 13) {
                avatar(title: friend.displayName, size: 58, online: true, speaking: manager.favoriteFriends.contains(friend))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(friend.displayName)
                            .font(.headline.weight(.black))
                            .foregroundStyle(OneWayCallTheme.text)
                        OneWayResolvedIcon(systemName: "checkmark.seal.fill")
                            .font(.caption.weight(.black))
                            .foregroundStyle(OneWayCallTheme.purple)
                    }
                    Text(friend.handle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OneWayCallTheme.muted)
                    Text("Online • OW verified • Privacy High")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                }
                Spacer()
                actionButtons(friend: friend)
            }
            .padding(13)
            .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(OneWayCallTheme.purple.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func importedContactCard(_ contact: ContactEntry) -> some View {
        Button {
            selectedContact = contact
        } label: {
            HStack(spacing: 13) {
                avatar(title: contact.displayName, size: 56, online: manager.importedContactIsOneWayReachable(contact), speaking: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(contact.displayName)
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayCallTheme.text)
                    Text(contact.phoneNumber)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OneWayCallTheme.muted)
                    Text(manager.importedContactIsOneWayReachable(contact) ? "OneWay reachable" : "External Network")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(manager.importedContactIsOneWayReachable(contact) ? .green : OneWayCallTheme.purple)
                }
                Spacer()
                HStack(spacing: 8) {
                    if manager.importedContactHasPhoneNumber(contact) {
                        glowIcon("phone.fill", color: .green) {
                            Task { await manager.callImportedContactPhone(contact) }
                        }
                    }
                    glowIcon(manager.importedContactIsOneWayReachable(contact) ? "dot.radiowaves.left.and.right" : "person.badge.plus", color: OneWayCallTheme.purple) {
                        Task { await manager.callImportedContact(contact) }
                    }
                }
            }
            .padding(13)
            .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(OneWayCallTheme.purple.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func actionButtons(friend: FriendConnection) -> some View {
        HStack(spacing: 7) {
            glowIcon("message.fill", color: OneWayCallTheme.purple, isLoading: activeContactAction == .message(friend.id)) {
                onMessage(friend)
            }
            glowIcon("dot.radiowaves.left.and.right", color: OneWayCallTheme.purple, isLoading: activeContactAction == .walkie(friend.id)) {
                onWalkie(friend)
            }
            glowIcon("phone.fill", color: .green, isLoading: activeContactAction == .call(friend.id)) {
                onCall(friend)
            }
            glowIcon("video.fill", color: OneWayCallTheme.purple, isLoading: activeContactAction == .video(friend.id)) {
                onVideo(friend)
            }
            glowIcon(
                manager.favoriteFriends.contains(friend) ? "star.fill" : "star",
                color: .yellow,
                isLoading: activeContactAction == .favorite(friend.id)
            ) {
                onFavorite(friend)
            }
        }
    }

    private func onMessage(_ friend: FriendConnection) {
        guard friend.status == .connected else {
            manager.alertMessage = "Unable to start chat."
            return
        }
        activeContactAction = .message(friend.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            selectedFriend = nil
            chatFriend = friend
            activeContactAction = nil
        }
    }

    private func onWalkie(_ friend: FriendConnection) {
        guard friend.status == .connected else {
            manager.alertMessage = "Unable to start Chirp."
            return
        }
        activeContactAction = .walkie(friend.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            selectedFriend = nil
            walkieFriend = friend
            activeContactAction = nil
        }
    }

    private func onCall(_ friend: FriendConnection) {
        activeContactAction = .call(friend.id)
        Task {
            await manager.startVoiceCall(with: friend)
            activeContactAction = nil
        }
    }

    private func onVideo(_ friend: FriendConnection) {
        activeContactAction = .video(friend.id)
        Task {
            await manager.startVideoCall(with: friend)
            activeContactAction = nil
        }
    }

    private func onFavorite(_ friend: FriendConnection) {
        activeContactAction = .favorite(friend.id)
        manager.toggleFavorite(friend)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            activeContactAction = nil
        }
    }

    private func chatSummary(for friend: FriendConnection) -> ChatSummary {
        ChatSummary(
            id: friend.id,
            participantName: friend.displayName,
            participantHandle: friend.handle,
            lastMessagePreview: "Start a private OneWay chat.",
            lastMessageAt: Date(),
            unreadCount: 0,
            presence: .online,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            isGroup: false,
            isExternal: false
        )
    }

    private func sectionHeader(title: String, subtitle: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.black))
                    .foregroundStyle(OneWayCallTheme.text)
                Text(subtitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(OneWayCallTheme.muted)
            }
            Spacer()
            Button(actionTitle, action: action)
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayCallTheme.purple)
                .buttonStyle(.plain)
                .disabled(manager.isImportingContacts || manager.contactPermissionState == .restricted)
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(OneWayCallTheme.text)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(color.opacity(0.2), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.38), lineWidth: 1))
    }

    private func labeledAction(
        _ title: String,
        _ icon: String,
        isActive: Bool = false,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.yellow.opacity(0.95) : OneWayCallTheme.purple.opacity(0.9))
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        OneWayResolvedIcon(systemName: icon)
                            .font(.headline.weight(.black))
                            .foregroundStyle(OneWayCallTheme.text)
                    }
                }
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(OneWayCallTheme.border, lineWidth: 1))
                .shadow(color: (isActive ? Color.yellow : OneWayCallTheme.purple).opacity(0.34), radius: 10)
                Text(title)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(isActive ? Color.yellow : OneWayCallTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
            .opacity(isLoading ? 0.82 : 1)
            .scaleEffect(isLoading ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private func emptyCard(_ title: String, _ body: String) -> some View {
        VStack(spacing: 8) {
            OneWayResolvedIcon(systemName: "person.2.circle.fill")
                .font(.system(size: 42, weight: .black))
                .foregroundStyle(OneWayCallTheme.purple)
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayCallTheme.text)
            Text(body)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OneWayCallTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func avatar(title: String, size: CGFloat, online: Bool, speaking: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Text(String(title.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .black))
                .foregroundStyle(OneWayCallTheme.text)
                .frame(width: size, height: size)
                .background(OneWayCallTheme.purpleGradient, in: Circle())
                .overlay(Circle().stroke(speaking ? OneWayCallTheme.purple : Color.green.opacity(online ? 0.95 : 0.25), lineWidth: 3))
                .shadow(color: (speaking ? OneWayCallTheme.purple : Color.green).opacity(0.35), radius: 12)
            Circle()
                .fill(online ? Color.green : Color.gray)
                .frame(width: size * 0.22, height: size * 0.22)
                .overlay(Circle().stroke(OneWayCallTheme.surface, lineWidth: 2))
        }
    }

    private func glowIcon(_ icon: String, color: Color, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.92))
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    OneWayResolvedIcon(systemName: icon)
                        .font(.caption.weight(.black))
                        .foregroundStyle(OneWayCallTheme.text)
                }
            }
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(OneWayCallTheme.border, lineWidth: 1))
            .shadow(color: color.opacity(0.34), radius: 9)
            .scaleEffect(isLoading ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: icon)
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayCallTheme.text)
                .frame(width: 46, height: 46)
                .background(OneWayCallTheme.surface, in: Circle())
                .overlay(Circle().stroke(OneWayCallTheme.purple.opacity(0.6), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private enum OneWaySignalContactsLayout {
    static let horizontalPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let headerSpacing: CGFloat = 13
    static let topPadding: CGFloat = 8
    static let cardPadding: CGFloat = 16
    static let minimumTapTarget: CGFloat = 44
    static let toolbarHeight: CGFloat = 110
    static let toolbarContentGap: CGFloat = 36
    static let bottomToolbarReservedHeight: CGFloat = toolbarHeight + toolbarContentGap + 24

    static func maxContentWidth(width: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat? {
        guard horizontalSizeClass == .regular else { return nil }
        return min(1040, width)
    }

    static func heroHeight(for width: CGFloat) -> CGFloat {
        min(306, max(268, width * 0.66))
    }
}

private struct ContactProfileView: View {
    let friend: FriendConnection
    @ObservedObject var manager: CallManager
    let onClose: () -> Void
    let onMessage: () -> Void
    let onWalkie: () -> Void

    var body: some View {
        profileShell(title: friend.displayName, onClose: onClose) {
            profileHero(name: friend.displayName, subtitle: friend.handle)
            profileInfo([
                ("OneWay ID", friend.handle),
                ("OW Number", "OW-\(friend.id.uuidString.prefix(6).uppercased())"),
                ("Verification", "Verified • Privacy High"),
                ("Status", "Online")
            ])
            HStack(spacing: 12) {
                profileAction("Message", "message.fill", action: onMessage)
                profileAction("Call", "phone.fill") { Task { await manager.startVoiceCall(with: friend) } }
                profileAction("Video", "video.fill") { Task { await manager.startVideoCall(with: friend) } }
                profileAction("Chirp", "dot.radiowaves.left.and.right", action: onWalkie)
            }
            HStack {
                profileAction("Favorite", manager.favoriteFriends.contains(friend) ? "star.fill" : "star") {
                    manager.toggleFavorite(friend)
                }
                profileAction("Block", "hand.raised.fill") {
                    manager.alertMessage = "Block controls are coming to OneWay Contacts."
                }
                profileAction("Share", "square.and.arrow.up") {
                    manager.alertMessage = "Share Contact is coming to OneWay Contacts."
                }
            }
        }
    }
}

private struct ImportedContactProfileView: View {
    let contact: ContactEntry
    @ObservedObject var manager: CallManager
    let onClose: () -> Void

    var body: some View {
        profileShell(title: contact.displayName, onClose: onClose) {
            profileHero(name: contact.displayName, subtitle: contact.phoneNumber)
            profileInfo([
                ("Phone", contact.phoneNumber),
                ("Network", manager.importedContactIsOneWayReachable(contact) ? "OneWay Signal" : "External Network"),
                ("Privacy", "Number protected by OneWay routing")
            ])
            HStack(spacing: 12) {
                profileAction("Call", "phone.fill") { Task { await manager.callImportedContactPhone(contact) } }
                profileAction("Chirp", "dot.radiowaves.left.and.right") { Task { await manager.callImportedContact(contact) } }
                profileAction("Invite", "person.badge.plus") { Task { await manager.callImportedContact(contact) } }
            }
        }
    }
}

private struct DirectContactChatView: View {
    private struct LocalMessage: Identifiable, Codable, Equatable {
        let id: UUID
        let body: String
        let sentAt: Date
        let isMine: Bool
    }

    let friend: FriendConnection
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [LocalMessage] = []
    @State private var composerText = ""
    @State private var isSending = false

    private var storageKey: String {
        "contacts.directChat.\(friend.id.uuidString)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    OneWayResolvedIcon(systemName: "chevron.left")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayCallTheme.purple)
                        .frame(width: 42, height: 42)
                        .background(OneWayCallTheme.surface, in: Circle())
                        .overlay(Circle().stroke(OneWayCallTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)

                profileAvatar

                VStack(alignment: .leading, spacing: 3) {
                    Text(friend.displayName)
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayCallTheme.text)
                    Text(friend.handle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OneWayCallTheme.muted)
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(OneWayCallTheme.background)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if messages.isEmpty {
                        VStack(spacing: 10) {
                            OneWayResolvedIcon(systemName: "message.fill")
                                .font(.system(size: 42, weight: .black))
                                .foregroundStyle(OneWayCallTheme.purple)
                            Text("Start a private chat")
                                .font(.headline.weight(.black))
                                .foregroundStyle(OneWayCallTheme.text)
                            Text("Messages with \(friend.displayName) stay in this direct OneWay thread.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(OneWayCallTheme.muted)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 70)
                    } else {
                        ForEach(messages) { message in
                            HStack {
                                if message.isMine { Spacer(minLength: 52) }
                                Text(message.body)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(message.isMine ? .white : OneWayCallTheme.text)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        message.isMine
                                            ? AnyShapeStyle(OneWayCallTheme.purpleGradient)
                                            : AnyShapeStyle(OneWayCallTheme.elevatedSurface),
                                        in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    )
                                if !message.isMine { Spacer(minLength: 52) }
                            }
                        }
                    }
                }
                .padding(18)
            }

            HStack(spacing: 10) {
                Button {
                    // TODO: Connect attachments to the direct chat backend once contact thread creation exists.
                } label: {
                    OneWayResolvedIcon(systemName: "plus")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayCallTheme.purple)
                        .frame(width: 42, height: 42)
                        .background(OneWayCallTheme.lavenderSurface, in: Circle())
                }
                .buttonStyle(.plain)

                TextField("Message \(friend.displayName)", text: $composerText)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OneWayCallTheme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(OneWayCallTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))

                Button {
                    send()
                } label: {
                    ZStack {
                        Circle()
                            .fill(OneWayCallTheme.purpleGradient)
                        if isSending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            OneWayResolvedIcon(systemName: "paperplane.fill")
                                .font(.headline.weight(.black))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .disabled(isSending || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(OneWayCallTheme.background)
        }
        .background(OneWayCallTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: loadMessages)
    }

    private var profileAvatar: some View {
        Text(String(friend.displayName.prefix(1)).uppercased())
            .font(.headline.weight(.black))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(OneWayCallTheme.purpleGradient, in: Circle())
    }

    private func send() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        let message = LocalMessage(id: UUID(), body: trimmed, sentAt: Date(), isMine: true)
        messages.append(message)
        composerText = ""
        persist()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            isSending = false
        }
    }

    private func loadMessages() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LocalMessage].self, from: data) else {
            messages = []
            return
        }
        messages = decoded.sorted { $0.sentAt < $1.sentAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

private struct DirectWalkieContactView: View {
    let friend: FriendConnection
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = WalkieViewModel()
    @State private var isPressingTalk = false
    @State private var didPrepareSession = false

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()

            VStack(spacing: 22) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        OneWayResolvedLabel("Back", systemImage: "chevron.left")
                            .font(.subheadline.weight(.black))
                            .foregroundStyle(OneWayCallTheme.purple)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(OneWayCallTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    OneWayResolvedLabel("Direct", systemImage: "lock.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(OneWayCallTheme.purple)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(OneWayCallTheme.lavenderSurface, in: Capsule())
                }

                Spacer(minLength: 10)

                profileHero(name: friend.displayName, subtitle: "\(friend.handle) • Private Chirp")

                VStack(spacing: 8) {
                    Text(statusTitle)
                        .font(.title2.weight(.black))
                        .foregroundStyle(OneWayCallTheme.text)
                    Text(statusSubtitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(OneWayCallTheme.muted)
                        .multilineTextAlignment(.center)
                }

                ZStack {
                    Circle()
                        .fill(isPressingTalk ? Color.green.opacity(0.95) : OneWayCallTheme.purple.opacity(pttIsAvailable ? 0.95 : 0.58))
                        .frame(width: 190, height: 190)
                        .shadow(color: (isPressingTalk ? Color.green : OneWayCallTheme.purple).opacity(0.38), radius: 26)
                    VStack(spacing: 10) {
                        OneWayResolvedIcon(systemName: pttIcon)
                            .font(.system(size: 54, weight: .black))
                        Text(pttLabel)
                            .font(.headline.weight(.black))
                    }
                    .foregroundStyle(.white)
                }
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressingTalk else { return }
                            isPressingTalk = true
                            Task {
                                await ensureDirectChirpSessionIfNeeded()
                                await waitForDirectChirpReadyIfNeeded()
                                await viewModel.handlePushToTalkDown()
                            }
                        }
                        .onEnded { _ in
                            guard isPressingTalk else { return }
                            isPressingTalk = false
                            Task {
                                await viewModel.handlePushToTalkUp()
                            }
                        }
                )
                .opacity(pttIsAvailable ? 1 : 0.72)
                .accessibilityLabel("Hold to Chirp \(friend.displayName)")

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    OneWayResolvedLabel("OneWay", systemImage: "person.crop.circle.fill")
                    OneWayResolvedLabel("OneWay Signal", systemImage: "dot.radiowaves.left.and.right")
                }
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayCallTheme.muted)

                Spacer()
            }
            .padding(20)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await viewModel.handlePageOpened()
            await ensureDirectChirpSessionIfNeeded()
        }
        .onDisappear {
            Task { await viewModel.handlePageDismissed() }
        }
    }

    private var directChirpTarget: String {
        let chirpID = friend.chirpID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !chirpID.isEmpty { return chirpID }
        return friend.handle
    }

    private var pttIsAvailable: Bool {
        viewModel.activeSession != nil || viewModel.canStartSession
    }

    private var statusTitle: String {
        switch viewModel.state {
        case .connecting:
            return "Connecting..."
        case .listening, .talking:
            return "Direct Chirp Ready"
        case .unavailable:
            return "Chirp Unavailable"
        case .error:
            return "Connection Failed"
        default:
            return didPrepareSession ? "Ready" : "Creating Direct Chirp"
        }
    }

    private var statusSubtitle: String {
        switch viewModel.state {
        case .talking:
            return "Release to send your Chirp."
        case .listening:
            return "Hold to talk with \(friend.displayName)."
        case .connecting:
            return "Securing a private Chirp session."
        case .unavailable:
            return "Chirp is unavailable during an active OneWay call."
        case .error(let message):
            return message
        default:
            return "Preparing \(friend.displayName)'s private Chirp channel."
        }
    }

    private var pttIcon: String {
        if viewModel.pushToTalkState == .receiving { return "speaker.wave.3.fill" }
        return isPressingTalk ? "waveform.circle.fill" : "mic.fill"
    }

    private var pttLabel: String {
        if isPressingTalk { return "Talking" }
        switch viewModel.pushToTalkState {
        case .requestingChannel, .requestingPermission, .connectingMedia, .publishing:
            return "Starting"
        case .receiving:
            return "Receiving"
        case .failed:
            return "Retry"
        default:
            return "Hold to Talk"
        }
    }

    @MainActor
    private func ensureDirectChirpSessionIfNeeded() async {
        guard viewModel.activeSession == nil, viewModel.canStartSession else { return }
        viewModel.target = directChirpTarget
        didPrepareSession = true
        await viewModel.loadAssignedProfile()
        await viewModel.loadWalkieContacts(showErrors: false)
        await viewModel.startSession()
    }

    @MainActor
    private func waitForDirectChirpReadyIfNeeded() async {
        guard viewModel.activeSession == nil else { return }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if viewModel.activeSession != nil { return }
            if case .error = viewModel.state { return }
            if viewModel.state == .unavailable { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }
}

private struct AddOneWayContactView: View {
    let onManage: () -> Void

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Add OneWay Contact")
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(OneWayCallTheme.text)
                ForEach([
                    ("@OneWayID", "at"),
                    ("OW Number", "number"),
                    ("QR Code", "qrcode.viewfinder"),
                    ("Nearby", "location.fill"),
                    ("Invite via Link", "link")
                ], id: \.0) { item in
                    Button(action: onManage) {
                        OneWayResolvedLabel(item.0, systemImage: item.1)
                            .font(.headline.weight(.black))
                            .foregroundStyle(OneWayCallTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(15)
                            .oneWayCallGlass(cornerRadius: 18)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(20)
        }
    }
}

private struct ContactsSearchView: View {
    @Binding var searchText: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayCallTheme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Search People")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(OneWayCallTheme.text)

                    HStack(spacing: 12) {
                        OneWayResolvedIcon(systemName: "magnifyingglass")
                            .foregroundStyle(OneWayCallTheme.purple)
                        TextField("Name, @OneWayID, OW Number, Phone, Nearby", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .foregroundStyle(OneWayCallTheme.text)
                    }
                    .font(.headline.weight(.semibold))
                    .padding(15)
                    .oneWayCallGlass(cornerRadius: 22)

                    VStack(alignment: .leading, spacing: 10) {
                        OneWayResolvedLabel("@OneWayID", systemImage: "at")
                        OneWayResolvedLabel("OW Number", systemImage: "number")
                        OneWayResolvedLabel("Phone", systemImage: "phone.fill")
                        OneWayResolvedLabel("Nearby", systemImage: "location.fill")
                    }
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayCallTheme.muted)
                    .padding(16)
                    .oneWayCallGlass(cornerRadius: 22)

                    Spacer()
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

private func profileShell<Content: View>(title: String, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
    NavigationStack {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    content()
                }
                .padding(18)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close", action: onClose)
            }
        }
    }
}

private func profileHero(name: String, subtitle: String) -> some View {
    VStack(spacing: 10) {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(OneWayCallTheme.purpleGradient.opacity(0.42))
                .frame(height: 136)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 54, weight: .black))
                .foregroundStyle(OneWayCallTheme.text)
                .frame(width: 96, height: 96)
                .background(OneWayCallTheme.purpleGradient, in: Circle())
                .offset(y: 54)
        }
        .padding(.bottom, 50)
        Text(name)
            .font(.largeTitle.weight(.black))
            .foregroundStyle(OneWayCallTheme.text)
        Text(subtitle)
            .font(.headline.weight(.bold))
            .foregroundStyle(OneWayCallTheme.muted)
    }
    .padding(16)
    .oneWayCallGlass(cornerRadius: 30)
}

private func profileInfo(_ rows: [(String, String)]) -> some View {
    VStack(spacing: 10) {
        ForEach(rows, id: \.0) { row in
            HStack {
                Text(row.0).foregroundStyle(OneWayCallTheme.muted)
                Spacer()
                Text(row.1).foregroundStyle(OneWayCallTheme.text).fontWeight(.bold)
            }
            .font(.subheadline)
        }
    }
    .padding(16)
    .oneWayCallGlass(cornerRadius: 22)
}

private func profileAction(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(spacing: 7) {
            OneWayResolvedIcon(systemName: icon)
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayCallTheme.text)
                .frame(width: 48, height: 48)
                .background(OneWayCallTheme.purple, in: Circle())
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayCallTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
}

private struct OneWaySignalHeroBanner: View {
    private let featurePills: [(String, String)] = [
        ("shield.fill", "Privacy\nRoadmap"),
        ("bolt.fill", "Instant\nConnection"),
        ("phone.fill", "Call, Video,\nChirp Securely")
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .topLeading) {
                Image("OneWaySignalConnectedGlobeHero")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .accessibilityHidden(true)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.10),
                        Color.black.opacity(0.00),
                        Color.black.opacity(0.20)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: -1) {
                        HStack(spacing: 8) {
                            Text("OneWay")
                                .foregroundStyle(.white)
                            Text("Signal")
                                .foregroundStyle(OneWayCallTheme.purple)
                        }
                        Text("Contacts")
                            .foregroundStyle(.white)
                    }
                    .font(.system(size: width < 390 ? 32 : 37, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                    Text("Connected. Private-minded. Instant.")
                        .font(.system(size: width < 390 ? 16 : 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0xCFC1F7))
                        .lineLimit(1)

                    HStack(spacing: 7) {
                        ForEach(featurePills, id: \.1) { pill in
                            SignalFeaturePill(icon: pill.0, title: pill.1)
                        }
                    }
                    .frame(maxWidth: min(width - 34, 390), alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 21)
                .padding(.trailing, 16)
                .padding(.top, 32)
                .padding(.bottom, 20)
            }
            .clipShape(Rectangle())
        }
        .frame(height: 306)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OneWayCallTheme.purple.opacity(0.16))
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OneWay Signal Contacts")
        .accessibilityValue("Connected, privacy-minded, instant communication.")
    }
}

private struct SignalFeaturePill: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(OneWayCallTheme.purple)
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0xD8CCFF))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 109, height: 42)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(OneWayCallTheme.purple.opacity(0.32), lineWidth: 1))
    }
}
