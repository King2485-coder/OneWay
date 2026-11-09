import SwiftUI

struct MarketplaceProfileView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MarketplaceBuyerProfile

    init(viewModel: MarketplaceViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.marketplaceProfile)
    }

    var body: some View {
        MarketplaceAccountScroll(title: "Marketplace Profile", onBack: { dismiss() }) {
            MarketplaceAccountHero(
                role: .sellerID,
                title: draft.displayName,
                subtitle: "Your shopper identity for OneWay Shops."
            )

            MarketplaceAccountSection(title: "Profile") {
                MarketplaceTextField(title: "Display Name", text: $draft.displayName)
                MarketplaceAccountToggle(title: "Use marketplace name", subtitle: "Hide your personal OneWay ID from sellers.", isOn: $draft.useMarketplaceName)
                MarketplaceChoiceRow(title: "Account Status", value: draft.accountStatus, role: .success)
            }

            MarketplaceAccountSection(title: "Preferences") {
                MarketplaceMenuRow(
                    title: "Receipts",
                    selection: $draft.receiptPreference,
                    options: ["Digital receipts", "Email receipts", "Both"]
                )
                MarketplaceMenuRow(
                    title: "Payment",
                    selection: $draft.defaultPaymentPreference,
                    options: ["Secure checkout", "Ask every time", "Private wallet"]
                )
            }

            MarketplacePrimaryButton(title: "Save Profile") {
                viewModel.saveMarketplaceProfile(draft)
                dismiss()
            }
        }
    }
}

struct MarketplacePrivacySettingsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MarketplacePrivacySettings

    init(viewModel: MarketplaceViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.marketplacePrivacy)
    }

    var body: some View {
        MarketplaceAccountScroll(title: "Marketplace Privacy", onBack: { dismiss() }) {
            MarketplaceAccountHero(
                role: .privacy,
                title: draft.badgeTitle,
                subtitle: "Control what shops and sellers can see."
            )

            MarketplaceAccountSection(title: "Buyer Privacy") {
                MarketplaceAccountToggle(title: "Hide purchase history", subtitle: "Sellers cannot see purchases outside their shop.", isOn: $draft.hidePurchaseHistory)
                MarketplaceAccountToggle(title: "Hide saved shops", subtitle: "Your followed shops stay private.", isOn: $draft.hideSavedShops)
                MarketplaceAccountToggle(title: "Hide marketplace activity", subtitle: "Browsing and favorites stay private.", isOn: $draft.hideMarketplaceActivity)
                MarketplaceAccountToggle(title: "Use marketplace display name", subtitle: "Show your shop-only name to sellers.", isOn: $draft.useMarketplaceDisplayName)
            }

            MarketplaceAccountSection(title: "Seller Access") {
                MarketplaceAccountToggle(title: "Limit seller profile access", subtitle: "Sellers only see order-related details.", isOn: $draft.limitSellerProfileAccess)
                MarketplaceAccountToggle(title: "Hide phone number", subtitle: "Keep phone contact private.", isOn: $draft.hidePhoneNumber)
                MarketplaceAccountToggle(title: "Hide personal OneWay ID", subtitle: "Use your marketplace identity instead.", isOn: $draft.hidePersonalOneWayID)
                MarketplaceAccountToggle(title: "Shop messages only", subtitle: "Keep seller chats separate from personal messages.", isOn: $draft.sellersUseShopMessagesOnly)
                MarketplaceAccountToggle(title: "Require order context", subtitle: "Support chats must be tied to a shop or order.", isOn: $draft.requireOrderContextForSupport)
            }

            MarketplacePrimaryButton(title: "Save Privacy") {
                viewModel.saveMarketplacePrivacy(draft)
                dismiss()
            }
        }
    }
}

struct MarketplaceOrderHistoryView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onOpenOrder: (MarketplaceOrder) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MarketplaceAccountScroll(title: "Order History", onBack: { dismiss() }) {
            if viewModel.orders.isEmpty {
                MarketplaceEmptyAccountState(role: .orders, title: "No orders yet", subtitle: "Completed purchases will appear here.")
            } else {
                MarketplaceAccountSection(title: "Orders") {
                    ForEach(viewModel.orders) { order in
                        Button { onOpenOrder(order) } label: {
                            MarketplaceOrderSummaryRow(order: order)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct MarketplaceOrderDetailView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let order: MarketplaceOrder
    let onRoute: (MarketplaceRoute) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MarketplaceAccountScroll(title: "Order Detail", onBack: { dismiss() }) {
            MarketplaceAccountHero(role: .orders, title: order.title, subtitle: MarketplaceOrderStatusFormatter.display(order))

            MarketplaceAccountSection(title: "Summary") {
                MarketplaceChoiceRow(title: "Total", value: order.total.currency, role: .paymentPrivacy)
                if let tax = order.tax { MarketplaceChoiceRow(title: "Tax", value: tax.currency, role: .receipt) }
                if let shipping = order.shipping { MarketplaceChoiceRow(title: "Shipping", value: shipping.currency, role: .package) }
                if let createdAt = order.createdAt {
                    MarketplaceChoiceRow(title: "Placed", value: createdAt.formatted(date: .abbreviated, time: .omitted), role: .calendar)
                }
            }

            MarketplaceAccountSection(title: "Status") {
                MarketplaceChoiceRow(title: "Order", value: order.status, role: .orders)
                MarketplaceChoiceRow(title: "Payment", value: order.paymentStatus?.rawValue ?? "Not available", role: .paymentPrivacy)
                MarketplaceChoiceRow(title: "Refund", value: order.refundStatus?.rawValue ?? "None", role: .receipt)
            }

            MarketplacePrimaryButton(title: "Message Shop Support") {
                if let threadID = viewModel.startOrderSupportConversation(order: order) {
                    onRoute(.chat(threadID))
                }
            }
        }
    }
}

struct SavedShopsListView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onOpenShop: (MarketplaceShop) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MarketplaceAccountScroll(title: "Saved Shops", onBack: { dismiss() }) {
            let shops = viewModel.savedShops()
            if shops.isEmpty {
                MarketplaceEmptyAccountState(role: .savedShops, title: "No saved shops yet", subtitle: "Follow shops to keep them here.")
            } else {
                MarketplaceAccountSection(title: "Following") {
                    ForEach(shops) { shop in
                        HStack(spacing: 12) {
                            Button { onOpenShop(shop) } label: {
                                MarketplaceShopSummary(shop: shop)
                            }
                            .buttonStyle(.plain)

                            Button {
                                viewModel.toggleFollow(shop)
                            } label: {
                                Text("Unfollow")
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(MarketplaceTheme.purple)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(MarketplaceTheme.lavenderCard, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct ShopNotificationsSettingsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MarketplaceNotificationSettings

    init(viewModel: MarketplaceViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.marketplaceNotifications)
    }

    var body: some View {
        MarketplaceAccountScroll(title: "Shop Notifications", onBack: { dismiss() }) {
            MarketplaceAccountSection(title: "Messages") {
                MarketplaceAccountToggle(title: "New Shop Message", subtitle: "Notify when sellers or buyers message you.", isOn: $draft.newShopMessage)
                MarketplaceAccountToggle(title: "Seller Reply", subtitle: "Notify when a seller responds.", isOn: $draft.sellerReply)
            }
            MarketplaceAccountSection(title: "Orders") {
                MarketplaceAccountToggle(title: "Order Updates", subtitle: "Confirmations, processing, and changes.", isOn: $draft.orderUpdates)
                MarketplaceAccountToggle(title: "Shipping Updates", subtitle: "Tracking and shipment events.", isOn: $draft.shippingUpdates)
                MarketplaceAccountToggle(title: "Delivery", subtitle: "Delivered package alerts.", isOn: $draft.delivery)
                MarketplaceAccountToggle(title: "Refunds and Returns", subtitle: "Return request and refund status updates.", isOn: $draft.refundsAndReturns)
            }
            MarketplaceAccountSection(title: "Discovery") {
                MarketplaceAccountToggle(title: "Saved Shop Updates", subtitle: "Updates from shops you follow.", isOn: $draft.savedShopUpdates)
                MarketplaceAccountToggle(title: "Promotions", subtitle: "Optional marketplace offers.", isOn: $draft.promotionalNotifications)
            }
            MarketplacePrimaryButton(title: "Save Notifications") {
                viewModel.saveMarketplaceNotifications(draft)
                dismiss()
            }
        }
    }
}

struct ShippingAddressesView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingAddress: MarketplaceShippingAddress?

    var body: some View {
        MarketplaceAccountScroll(title: "Shipping Addresses", onBack: { dismiss() }) {
            if viewModel.shippingAddresses.isEmpty {
                MarketplaceEmptyAccountState(role: .package, title: "No addresses yet", subtitle: "Add an address to speed up checkout.")
            } else {
                MarketplaceAccountSection(title: "Saved Addresses") {
                    ForEach(viewModel.shippingAddresses) { address in
                        MarketplaceAddressRow(address: address) {
                            editingAddress = address
                        } onDelete: {
                            viewModel.deleteShippingAddress(address)
                        }
                    }
                }
            }

            MarketplacePrimaryButton(title: "Add Address") {
                editingAddress = MarketplaceShippingAddress()
            }
        }
        .sheet(item: $editingAddress) { address in
            MarketplaceAddressEditorView(viewModel: viewModel, address: address)
        }
    }
}

struct PaymentPrivacyView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: MarketplaceBuyerProfile
    @State private var privacy: MarketplacePrivacySettings

    init(viewModel: MarketplaceViewModel) {
        self.viewModel = viewModel
        _profile = State(initialValue: viewModel.marketplaceProfile)
        _privacy = State(initialValue: viewModel.marketplacePrivacy)
    }

    var body: some View {
        MarketplaceAccountScroll(title: "Payment Privacy", onBack: { dismiss() }) {
            MarketplaceAccountHero(role: .paymentPrivacy, title: "Secure Checkout", subtitle: "Payment details stay separate from personal OneWay messaging.")
            MarketplaceAccountSection(title: "Payment") {
                MarketplaceMenuRow(title: "Default Method", selection: $profile.defaultPaymentPreference, options: ["Secure checkout", "Ask every time", "Private wallet"])
                MarketplaceMenuRow(title: "Receipts", selection: $profile.receiptPreference, options: ["Digital receipts", "Email receipts", "Both"])
            }
            MarketplaceAccountSection(title: "Privacy") {
                MarketplaceAccountToggle(title: "Hide phone number", subtitle: "Sellers never see your phone number.", isOn: $privacy.hidePhoneNumber)
                MarketplaceAccountToggle(title: "Hide OneWay ID", subtitle: "Use marketplace identity for transactions.", isOn: $privacy.hidePersonalOneWayID)
            }
            MarketplacePrimaryButton(title: "Save Payment Privacy") {
                viewModel.saveMarketplaceProfile(profile)
                viewModel.saveMarketplacePrivacy(privacy)
                dismiss()
            }
        }
    }
}

struct ShopMessagePreferencesView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ShopMessagingSettings

    init(viewModel: MarketplaceViewModel) {
        self.viewModel = viewModel
        _settings = State(initialValue: viewModel.shopMessagingSettings)
    }

    var body: some View {
        MarketplaceAccountScroll(title: "Shop Messages", onBack: { dismiss() }) {
            MarketplaceAccountHero(role: .messageSettings, title: "Shop Messages Only", subtitle: "Commerce conversations stay separate from OneWay chats.")
            MarketplaceAccountSection(title: "Buyer Controls") {
                MarketplaceAccountToggle(title: "Order-only support", subtitle: "Require order context before seller support.", isOn: $settings.requireOrderNumberForSupport)
                MarketplaceAccountToggle(title: "Auto-close old chats", subtitle: "Close inactive Shop Messages automatically.", isOn: $settings.autoCloseInactive)
                MarketplaceAccountToggle(title: "Attachments", subtitle: "Allow receipts, product photos, and order files.", isOn: $settings.buyerAllowAttachments)
                MarketplaceAccountToggle(title: "Links", subtitle: "Allow marketplace-safe links in Shop Messages.", isOn: $settings.buyerAllowLinks)
            }
            MarketplaceAccountSection(title: "Blocked Shop Contacts") {
                if viewModel.blockedShopContacts.isEmpty {
                    Text("No blocked shop contacts.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MarketplaceTheme.muted)
                } else {
                    ForEach(viewModel.blockedShopContacts, id: \.id) { contact in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(contact.displayName)
                                    .font(.headline.weight(.black))
                                    .foregroundStyle(.white)
                                Text(contact.scope)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(MarketplaceTheme.muted)
                            }
                            Spacer()
                            Button("Unblock") { viewModel.unblockShopContact(contact) }
                                .font(.caption.weight(.black))
                                .foregroundStyle(MarketplaceTheme.purple)
                        }
                    }
                }
            }
            MarketplacePrimaryButton(title: "Save Message Preferences") {
                viewModel.saveShopMessagingSettings(settings)
                dismiss()
            }
        }
    }
}

struct ReturnsRefundsView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onOpenOrder: (MarketplaceOrder) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MarketplaceAccountScroll(title: "Returns & Refunds", onBack: { dismiss() }) {
            let returnOrders = viewModel.orders.filter {
                ($0.refundStatus ?? .none) != .none || ($0.disputeStatus ?? .none) != .none || $0.status.localizedCaseInsensitiveContains("return")
            }
            if returnOrders.isEmpty {
                MarketplaceEmptyAccountState(role: .receipt, title: "No active returns", subtitle: "Refund and return requests will appear here.")
            } else {
                MarketplaceAccountSection(title: "Requests") {
                    ForEach(returnOrders) { order in
                        Button { onOpenOrder(order) } label: {
                            MarketplaceOrderSummaryRow(order: order)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct MarketplaceSupportView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onBack: () -> Void
    let onRoute: (MarketplaceRoute) -> Void
    @State private var status = "Choose a support option."

    var body: some View {
        MarketplaceAccountScroll(title: "Marketplace Support", onBack: onBack) {
            MarketplaceAccountHero(role: .messageSettings, title: "How can we help?", subtitle: status)
            MarketplaceAccountSection(title: "Support") {
                MarketplaceSupportAction(title: "Report an order issue", subtitle: "Open an order support conversation.", role: .orders) {
                    if let order = viewModel.orders.first, let threadID = viewModel.startOrderSupportConversation(order: order) {
                        status = "Support thread opened for \(order.title)."
                        viewModel.sellerValidationMessage = "Shop support thread ready."
                        _ = threadID
                    } else {
                        status = "No order is available for support yet."
                    }
                }
                MarketplaceSupportAction(title: "Report a shop", subtitle: "Flag marketplace safety concerns.", role: .report) {
                    status = "Report received. OneWay marketplace support will review it."
                    viewModel.sellerValidationMessage = "Report submitted."
                }
                MarketplaceSupportAction(title: "Privacy help", subtitle: "Review buyer privacy settings.", role: .privacy) {
                    status = "Open Marketplace Privacy from Account to adjust privacy."
                }
                MarketplaceSupportAction(title: "Seller tools", subtitle: "Manage your shop, products, and payments.", role: .seller) {
                    onRoute(viewModel.sellerToolsDestination)
                }
                .accessibilityLabel("Seller tools")
            }
        }
    }
}

private struct MarketplaceAccountScroll<Content: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(18)
            .padding(.bottom, 156)
        }
        .background(MarketplaceTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top) {
            MarketplaceBackBar(title: title, onBack: onBack)
        }
    }
}

private struct MarketplaceAccountHero: View {
    let role: OneWayIconRole
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            OneWayPhysicalIcon(role: role, size: 72, state: .selected, container: .showcase, accessibilityLabel: title)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }
}

private struct MarketplaceAccountSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.black))
                .tracking(4)
                .foregroundStyle(MarketplaceTheme.purple)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .marketplaceCard(cornerRadius: 22)
        }
    }
}

private struct MarketplaceTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(MarketplaceTheme.muted)
            TextField(title, text: $text)
                .font(.headline.weight(.bold))
                .foregroundStyle(MarketplaceTheme.text)
                .textInputAutocapitalization(.words)
                .padding(12)
                .background(MarketplaceTheme.lavenderCard.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MarketplaceTheme.border, lineWidth: 1))
        }
    }
}

private struct MarketplaceAccountToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(MarketplaceTheme.purple)
    }
}

private struct MarketplaceMenuRow: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) { selection = option }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selection)
                    OneWayResolvedIcon(systemName: "chevron.down")
                }
                .font(.caption.weight(.black))
                .foregroundStyle(MarketplaceTheme.purple)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(MarketplaceTheme.lavenderCard, in: Capsule())
                .frame(minHeight: 44)
            }
            .accessibilityLabel("\(title), \(selection)")
            .accessibilityHint("Opens available choices.")
        }
    }
}

private struct MarketplaceChoiceRow: View {
    let title: String
    let value: String
    let role: OneWayIconRole

    var body: some View {
        HStack(spacing: 12) {
            OneWayPhysicalIcon(role: role, size: 42, container: .toolbar, accessibilityLabel: title)
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.black))
                .foregroundStyle(MarketplaceTheme.muted)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct MarketplacePrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(MarketplaceTheme.gradient, in: Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct MarketplaceEmptyAccountState: View {
    let role: OneWayIconRole
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            OneWayPhysicalIcon(role: role, size: 64, state: .selected, container: .feature, accessibilityLabel: title)
            Text(title)
                .font(.title3.weight(.black))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MarketplaceTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .marketplaceCard(cornerRadius: 24)
    }
}

private struct MarketplaceOrderSummaryRow: View {
    let order: MarketplaceOrder

    var body: some View {
        HStack(spacing: 12) {
            OneWayPhysicalIcon(role: .orders, size: 46, container: .feature)
            VStack(alignment: .leading, spacing: 4) {
                Text(order.title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MarketplaceOrderStatusFormatter.display(order))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
            }
            Spacer()
            Text(order.total.currency)
                .font(.subheadline.weight(.black))
                .foregroundStyle(MarketplaceTheme.purple)
            OneWayResolvedIcon(systemName: "chevron.right")
                .foregroundStyle(MarketplaceTheme.purple)
        }
    }
}

private struct MarketplaceShopSummary: View {
    let shop: MarketplaceShop

    var body: some View {
        HStack(spacing: 12) {
            OneWayPhysicalIcon(role: .storefront, size: 46, container: .feature, accessibilityLabel: shop.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.name)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                Text("\(shop.category) • \(shop.rating, specifier: "%.1f") stars")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
            }
            Spacer()
            OneWayResolvedIcon(systemName: "chevron.right")
                .foregroundStyle(MarketplaceTheme.purple)
        }
    }
}

private struct MarketplaceAddressRow: View {
    let address: MarketplaceShippingAddress
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OneWayPhysicalIcon(role: .package, size: 46, container: .feature)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(address.label.isEmpty ? "Address" : address.label)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    if address.isDefault {
                        Text("Default")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MarketplaceTheme.purple, in: Capsule())
                    }
                }
                Text(address.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(spacing: 8) {
                Button("Edit", action: onEdit)
                Button("Delete", action: onDelete)
            }
            .font(.caption.weight(.black))
            .foregroundStyle(MarketplaceTheme.purple)
        }
    }
}

private struct MarketplaceAddressEditorView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MarketplaceShippingAddress

    init(viewModel: MarketplaceViewModel, address: MarketplaceShippingAddress) {
        self.viewModel = viewModel
        _draft = State(initialValue: address)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MarketplaceTextField(title: "Label", text: $draft.label)
                    MarketplaceTextField(title: "Recipient", text: $draft.recipient)
                    MarketplaceTextField(title: "Address Line 1", text: $draft.line1)
                    MarketplaceTextField(title: "Address Line 2", text: $draft.line2)
                    MarketplaceTextField(title: "City", text: $draft.city)
                    MarketplaceTextField(title: "State or Region", text: $draft.region)
                    MarketplaceTextField(title: "Postal Code", text: $draft.postalCode)
                    MarketplaceAccountToggle(title: "Default Address", subtitle: "Use this address first during checkout.", isOn: $draft.isDefault)
                    MarketplacePrimaryButton(title: "Save Address") {
                        viewModel.saveShippingAddress(draft)
                        dismiss()
                    }
                }
                .padding(18)
            }
            .background(MarketplaceTheme.background.ignoresSafeArea())
            .safeAreaInset(edge: .top) {
                MarketplaceBackBar(title: "Shipping Address", onBack: { dismiss() })
            }
        }
    }
}

private struct MarketplaceSupportAction: View {
    let title: String
    let subtitle: String
    let role: OneWayIconRole
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                OneWayPhysicalIcon(role: role, size: 46, container: .feature, accessibilityLabel: title)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MarketplaceTheme.muted)
                }
                Spacer()
                OneWayResolvedIcon(systemName: "chevron.right")
                    .foregroundStyle(MarketplaceTheme.purple)
            }
        }
        .buttonStyle(.plain)
    }
}
