import SwiftUI

struct ShopsMessagesView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onBack: () -> Void
    let onRoute: (MarketplaceRoute) -> Void

    var body: some View {
        ShopMessagingInboxView(viewModel: viewModel, mode: .buyer, onBack: onBack, onRoute: onRoute)
    }
}

struct SellerMessagesView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onBack: () -> Void
    let onRoute: (MarketplaceRoute) -> Void

    var body: some View {
        ShopMessagingInboxView(viewModel: viewModel, mode: .seller, onBack: nil, onRoute: onRoute)
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .top, spacing: 0) {
                MarketplaceBackBar(title: "Seller Messages", onBack: onBack)
            }
    }
}

struct ShopMessagingInboxView: View {
    enum Mode {
        case buyer
        case seller

        var title: String { self == .seller ? "Seller Messages" : "Shop Messages" }
        var subtitle: String {
            self == .seller
                ? "Buyer questions, order support, and custom requests."
                : "Conversations with shops and creators."
        }
        var emptyTitle: String { self == .seller ? "No buyer messages yet." : "No creator messages yet." }
        var emptySubtitle: String {
            self == .seller
                ? "Product questions and order conversations will appear here."
                : "Message a seller from a product or shop page to start."
        }
    }

    @ObservedObject var viewModel: MarketplaceViewModel
    let mode: Mode
    let onBack: (() -> Void)?
    let onRoute: (MarketplaceRoute) -> Void
    @State private var selectedFilter: ShopMessageInboxFilter = .all
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showBlocked = false

    private var visibleThreads: [ShopConversation] {
        mode == .seller
            ? viewModel.sellerThreads(filter: selectedFilter, search: searchText)
            : viewModel.buyerThreads(filter: selectedFilter, search: searchText)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if let onBack {
                    Button(action: onBack) {
                        OneWayResolvedIcon(systemName: "chevron.left")
                            .font(.title2.weight(.black))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(MarketplaceTheme.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .stroke(MarketplaceTheme.purple.opacity(0.65), lineWidth: 1.5)
                                    .allowsHitTesting(false)
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .zIndex(100)
                    .accessibilityLabel("Back")
                }
                header
                search
                filters
                actionCards
                if visibleThreads.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleThreads) { thread in
                        Button {
                            viewModel.markShopThreadRead(thread)
                            onRoute(mode == .seller ? .sellerChat(thread.id) : .chat(thread.id))
                        } label: {
                            ShopMessageThreadRow(
                                thread: thread,
                                product: thread.productID.flatMap { viewModel.product($0) },
                                shop: viewModel.shop(thread.shopID),
                                mode: mode
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .padding(.bottom, mode == .seller ? 36 : 110)
        }
        .background(MarketplaceTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            ShopMessageSettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showBlocked) {
            ShopBlockedContactsView(viewModel: viewModel)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-qa-message-settings") {
                showSettings = true
            }
            #endif
        }
        .task {
            await viewModel.syncShopConversations()
        }
        .refreshable {
            await viewModel.syncShopConversations()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            OneWayPhysicalIcon(
                role: .messages,
                size: 62,
                state: .selected,
                container: .feature,
                accessibilityLabel: mode.title
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(MarketplaceTheme.text)
                Text(mode.subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Menu {
                OneWayResolvedButton("Message Settings", systemImage: "slider.horizontal.3") { showSettings = true }
                OneWayResolvedButton("Blocked Contacts", systemImage: "hand.raised.fill") { showBlocked = true }
            } label: {
                OneWayPhysicalIcon(
                    role: .messageSettings,
                    size: 44,
                    container: .toolbar,
                    accessibilityLabel: "Message options"
                )
            }
        }
    }

    private var search: some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: "magnifyingglass")
                .foregroundStyle(MarketplaceTheme.purple)
            TextField("Search shop messages...", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .foregroundStyle(MarketplaceTheme.text)
        }
        .padding(13)
        .marketplaceCard(cornerRadius: 18)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ShopMessageInboxFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.caption.weight(.black))
                            .foregroundStyle(selectedFilter == filter ? .white : MarketplaceTheme.purple)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(selectedFilter == filter ? MarketplaceTheme.purple : MarketplaceTheme.lavenderCard, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actionCards: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            miniAction("Unread", "\(unreadCount)", .unread)
            miniAction("Blocked", "\(viewModel.blockedShopContacts.count)", .blocked)
        }
    }

    private var unreadCount: Int {
        let source = mode == .seller ? viewModel.sellerThreads(filter: .unread) : viewModel.buyerThreads(filter: .unread)
        return source.reduce(0) { $0 + max($1.unreadCount, 1) }
    }

    private func miniAction(_ title: String, _ value: String, _ role: OneWayIconRole) -> some View {
        HStack(spacing: 10) {
            OneWayPhysicalIcon(role: role, size: 46, container: .feature, accessibilityLabel: title)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title3.weight(.black)).foregroundStyle(MarketplaceTheme.text)
                Text(title).font(.caption.weight(.bold)).foregroundStyle(MarketplaceTheme.muted)
            }
            Spacer()
        }
        .padding(14)
        .marketplaceCard(cornerRadius: 20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            OneWayPhysicalIcon(role: .messages, size: 72, container: .showcase)
            Text(mode.emptyTitle)
                .font(.title3.weight(.black))
                .foregroundStyle(MarketplaceTheme.text)
            Text(mode.emptySubtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MarketplaceTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .marketplaceCard(cornerRadius: 26)
    }
}

private struct ShopMessageThreadRow: View {
    let thread: ShopConversation
    let product: MarketplaceProduct?
    let shop: MarketplaceShop?
    let mode: ShopMessagingInboxView.Mode

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(mode == .seller ? thread.buyerName : (shop?.name ?? thread.sellerName))
                        .font(.headline.weight(.black))
                        .foregroundStyle(MarketplaceTheme.text)
                        .lineLimit(1)
                    if thread.isMuted { OneWayResolvedIcon(systemName: "bell.slash.fill").foregroundStyle(MarketplaceTheme.faint) }
                    if thread.isBlocked { OneWayResolvedIcon(systemName: "hand.raised.fill").foregroundStyle(.red) }
                }
                Text(thread.subject)
                    .font(.caption.weight(.black))
                    .foregroundStyle(MarketplaceTheme.purple)
                    .lineLimit(1)
                Text(thread.lastMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .lineLimit(2)
                HStack {
                    Text(thread.type.rawValue)
                    if let product { Text("• \(product.price.currency)") }
                    Spacer()
                    Text(thread.lastMessageAt, style: .time)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(MarketplaceTheme.faint)
            }
            Spacer()
            if thread.unreadCount > 0 {
                Text("\(thread.unreadCount)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(MarketplaceTheme.purple, in: Circle())
            }
        }
        .padding(14)
        .marketplaceCard(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(mode == .seller ? thread.buyerName : (shop?.name ?? thread.sellerName)). \(thread.subject). \(thread.lastMessage). \(thread.unreadCount) unread."
        )
    }

    private var thumbnail: some View {
        Group {
            if let product {
                MarketplaceProductImageView(product: product, height: 54, cornerRadius: 14)
            } else {
                OneWayPhysicalIcon(role: .seller, size: 54, container: .feature, accessibilityLabel: shop?.name ?? "Shop")
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ShopMessageSettingsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ShopMessagingSettings
    private let initialSettings: ShopMessagingSettings

    init(viewModel: MarketplaceViewModel) {
        self.viewModel = viewModel
        let value = viewModel.shopMessagingSettings
        _settings = State(initialValue: value)
        initialSettings = value
    }

    var body: some View {
        ZStack {
            MarketplaceTheme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSection("Seller Settings") {
                        Menu {
                            Picker("Who can message my shop?", selection: $settings.sellerPermission) {
                                ForEach(ShopMessagingSettings.SellerPermission.allCases, id: \.self) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        } label: {
                            selectorRow(
                                "Who can message my shop?",
                                value: settings.sellerPermission.rawValue,
                                role: .visitors
                            )
                        }
                        settingToggle("Allow product questions", role: .productQuestion, isOn: $settings.allowProductQuestions)
                        settingToggle("Allow custom requests", role: .customRequest, isOn: $settings.allowCustomRequests)
                        settingToggle("Allow order-only messages", role: .orderMessage, isOn: $settings.allowOrderOnlyMessages)
                        settingToggle("Allow messages from new accounts", role: .profile, isOn: $settings.allowMessagesFromNewAccounts)
                        settingToggle("Allow attachments", role: .attachments, isOn: $settings.sellerAllowAttachments)
                        settingToggle("Allow links", role: .links, isOn: $settings.sellerAllowLinks)
                        settingToggle("Auto-close inactive conversations", role: .autoClose, isOn: $settings.autoCloseInactive)
                        settingToggle("Require order number for support", role: .orderNumber, isOn: $settings.requireOrderNumberForSupport)
                    }

                    settingsSection("Buyer Settings") {
                        Menu {
                            Picker("Who can message my buyer account?", selection: $settings.buyerPermission) {
                                ForEach(ShopMessagingSettings.BuyerPermission.allCases, id: \.self) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        } label: {
                            selectorRow(
                                "Who can message my buyer account?",
                                value: settings.buyerPermission.rawValue,
                                role: .seller
                            )
                        }
                        settingToggle("Allow order updates", role: .orders, isOn: $settings.allowOrderUpdates)
                        settingToggle("Allow promotional messages", role: .messages, isOn: $settings.allowPromotionalMessages)
                        settingToggle("Allow follow-up after order completion", role: .autoClose, isOn: $settings.allowFollowUpAfterOrder)
                        settingToggle("Allow custom-offer messages", role: .customRequest, isOn: $settings.allowCustomOfferMessages)
                        settingToggle("Allow attachments", role: .attachments, isOn: $settings.buyerAllowAttachments)
                        settingToggle("Allow links", role: .links, isOn: $settings.buyerAllowLinks)
                    }

                    settingsSection("Privacy") {
                        settingToggle("Show read receipts", role: .receipt, isOn: $settings.showReadReceipts)
                        settingToggle("Show typing indicator", role: .messages, isOn: $settings.showTypingIndicator)
                        settingToggle("Show activity status", role: .privacy, isOn: $settings.showActivityStatus)
                        Text("Transactional order updates can still appear when personal Shop messages are blocked.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MarketplaceTheme.muted)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(18)
                .padding(.bottom, 30)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button("Close") { dismiss() }
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .frame(minWidth: 64, minHeight: 44)
                    .background(MarketplaceTheme.card, in: Capsule())
                Spacer()
                Text("Message Settings")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                Button("Save") {
                    viewModel.saveShopMessagingSettings(settings)
                    dismiss()
                }
                .font(.subheadline.weight(.black))
                .foregroundStyle(.white)
                .frame(minWidth: 64, minHeight: 44)
                .background(MarketplaceTheme.purple.opacity(hasChanges ? 1 : 0.34), in: Capsule())
                .disabled(!hasChanges)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(MarketplaceTheme.background.opacity(0.98))
        }
    }

    private var hasChanges: Bool { settings != initialSettings }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.black))
                .tracking(1.2)
                .foregroundStyle(MarketplaceTheme.purple)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .marketplaceCard(cornerRadius: 24)
        }
    }

    private func selectorRow(_ title: String, value: String, role: OneWayIconRole) -> some View {
        HStack(spacing: 12) {
            OneWayPhysicalIcon(role: role, size: 42, container: .toolbar, accessibilityLabel: title)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.purple)
            }
            Spacer()
            OneWayResolvedIcon(systemName: "chevron.right")
                .foregroundStyle(MarketplaceTheme.faint)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func settingToggle(_ title: String, role: OneWayIconRole, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            OneWayPhysicalIcon(
                role: role,
                size: 42,
                state: isOn.wrappedValue ? .success : .disabled,
                container: .toolbar,
                accessibilityLabel: title
            )
            Toggle(title, isOn: isOn)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .tint(.green)
                .frame(minHeight: 54)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MarketplaceTheme.border.opacity(0.5))
                .frame(height: 1)
        }
    }
}

struct ShopBlockedContactsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if viewModel.blockedShopContacts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No blocked Shop contacts")
                            .font(.headline.weight(.black))
                        Text("People you block from Shop messages will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                } else {
                    ForEach(viewModel.blockedShopContacts) { contact in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(contact.displayName).font(.headline.weight(.bold))
                                Text("\(contact.handle) • \(contact.scope)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Blocked \(contact.blockedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Unblock") {
                                viewModel.unblockShopContact(contact)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MarketplaceTheme.purple)
                        }
                    }
                }
            }
            .navigationTitle("Blocked Contacts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
