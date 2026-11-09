import SwiftUI

struct ShopsAccountView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onRoute: (MarketplaceRoute) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader
                profileCard
                sellerCard
                ordersCard
                infoCard(
                    title: "Saved Shops",
                    subtitle: savedShopsSubtitle,
                    role: .savedShops,
                    action: { onRoute(.savedShops) }
                )
                infoCard(
                    title: "Payment Privacy",
                    subtitle: "\(viewModel.marketplacePrivacy.badgeTitle) • \(viewModel.marketplaceProfile.defaultPaymentPreference)",
                    role: .paymentPrivacy,
                    action: { onRoute(.paymentPrivacy) }
                )
                infoCard(
                    title: "Shop Notifications",
                    subtitle: notificationSubtitle,
                    role: .shopSettings,
                    action: { onRoute(.shopNotifications) }
                )
                infoCard(
                    title: "Shipping Addresses",
                    subtitle: shippingSubtitle,
                    role: .package,
                    action: { onRoute(.shippingAddresses) }
                )
                infoCard(
                    title: "Shop Message Preferences",
                    subtitle: "Buyer and seller commerce message controls",
                    role: .messages,
                    action: { onRoute(.shopMessagePreferences) }
                )
                infoCard(
                    title: "Returns and Refunds",
                    subtitle: "Return requests, refund status, and policies",
                    role: .receipt,
                    action: { onRoute(.returnsRefunds) }
                )
                infoCard(
                    title: "Help and Marketplace Support",
                    subtitle: "Report an issue or contact OneWay marketplace support",
                    role: .messageSettings,
                    action: { onRoute(.marketplaceSupport) }
                )
            }
            .padding(18)
            .padding(.bottom, 156)
        }
        .background(MarketplaceTheme.background.ignoresSafeArea())
    }

    private var pageHeader: some View {
        HStack(spacing: 14) {
            OneWayPhysicalIcon(role: .profile, size: 62, state: .selected, container: .feature)
            VStack(alignment: .leading, spacing: 3) {
                Text("Account")
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(.white)
                Text("Your private marketplace profile.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
            }
        }
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onRoute(.marketplaceProfile)
            } label: {
            HStack(spacing: 14) {
                OneWayPhysicalIcon(
                    role: .sellerID,
                    size: 72,
                    state: .selected,
                    container: .showcase,
                    accessibilityLabel: "Marketplace identity"
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.marketplaceProfile.displayName)
                        .font(.title2.weight(.black))
                        .foregroundStyle(.white)
                    Text("Private marketplace profile")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MarketplaceTheme.muted)
                }
                Spacer()
                OneWayResolvedIcon(systemName: "chevron.right")
                    .foregroundStyle(MarketplaceTheme.purple)
            }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open marketplace profile")

            Button {
                onRoute(.marketplacePrivacy)
            } label: {
                HStack(spacing: 7) {
                    OneWayStatusIcon(role: .privacy, state: .selected, accessibilityLabel: viewModel.marketplacePrivacy.badgeTitle)
                    Text(viewModel.marketplacePrivacy.badgeTitle)
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(MarketplaceTheme.purple)
                    Spacer()
                    OneWayResolvedIcon(systemName: "chevron.right")
                        .foregroundStyle(MarketplaceTheme.purple)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open marketplace privacy settings")
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }

    private var sellerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                OneWayPhysicalIcon(role: .seller, size: 72, container: .showcase)
                VStack(alignment: .leading, spacing: 5) {
                    Text(viewModel.hasSellerShop ? "Your OneWay Shop" : "Start selling on OneWay")
                        .font(.title2.weight(.black))
                        .foregroundStyle(.white)
                    if viewModel.hasSellerShop {
                        Text(viewModel.sellerShop?.name ?? "Your shop")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(MarketplaceTheme.purple)
                        Text(viewModel.shopStatus(for: viewModel.sellerShop).rawValue)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(statusColor)
                    } else {
                        Text("Create your private storefront and sell securely.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MarketplaceTheme.muted)
                    }
                }
            }

            if viewModel.hasSellerShop {
                HStack(spacing: 10) {
                    accountButton("Manage My Shop", primary: true) { onRoute(.manageShop) }
                    accountButton("Preview Store", primary: false) {
                        if let shop = viewModel.sellerShop { onRoute(.shop(shop.id)) }
                    }
                }
            } else {
                Button {
                    onRoute(.createShop)
                } label: {
                    HStack(spacing: 10) {
                        OneWayPhysicalIcon(role: .quickAdd, size: 42, container: .toolbar)
                        Text("Create from the + menu")
                            .font(.subheadline.weight(.black))
                            .foregroundStyle(MarketplaceTheme.purple)
                        Spacer()
                        OneWayResolvedIcon(systemName: "chevron.right")
                            .foregroundStyle(MarketplaceTheme.purple)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start selling on OneWay")
                .accessibilityHint("Opens shop creation.")
            }
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }

    private var ordersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                onRoute(.orderHistory)
            } label: {
                HStack(spacing: 10) {
                    OneWayPhysicalIcon(role: .orders, size: 48, container: .feature)
                    Text("Orders")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("View All")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(MarketplaceTheme.purple)
                    OneWayResolvedIcon(systemName: "chevron.right")
                        .foregroundStyle(MarketplaceTheme.purple)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open order history")

            if viewModel.orders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    OneWayPhysicalIcon(role: .quickAdd, size: 42, container: .toolbar)
                    Text("No orders yet")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text("Your purchases will appear here after checkout.")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(MarketplaceTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(MarketplaceTheme.card.opacity(0.68), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                ForEach(viewModel.orders.prefix(3)) { order in
                    Button {
                        onRoute(.orderDetail(order.id))
                    } label: {
                        HStack(spacing: 12) {
                            OneWayPhysicalIcon(role: .package, size: 42, container: .toolbar)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(order.title)
                                    .font(.subheadline.weight(.black))
                                    .foregroundStyle(.white)
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
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open order details for \(order.title)")
                }
            }
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }

    private func infoCard(title: String, subtitle: String, role: OneWayIconRole, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                OneWayPhysicalIcon(role: role, size: 54, container: .feature, accessibilityLabel: title)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MarketplaceTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                OneWayResolvedIcon(systemName: "chevron.right")
                    .foregroundStyle(MarketplaceTheme.purple)
            }
            .padding(16)
            .marketplaceCard(cornerRadius: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func accountButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(primary ? Color.white : MarketplaceTheme.purple)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(primary ? MarketplaceTheme.purple : MarketplaceTheme.card, in: Capsule())
                .overlay(Capsule().stroke(MarketplaceTheme.purple.opacity(0.68), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch viewModel.shopStatus(for: viewModel.sellerShop) {
        case .active: return .green
        case .paymentSetupRequired, .verificationPending: return .orange
        case .restricted: return .red
        case .paused, .archived, .draft: return MarketplaceTheme.muted
        }
    }

    private var savedShopsSubtitle: String {
        let count = viewModel.savedShops().count
        return count == 0 ? "No saved shops yet" : "\(count) followed creator shop\(count == 1 ? "" : "s")"
    }

    private var notificationSubtitle: String {
        viewModel.marketplaceNotifications.promotionalNotifications
            ? "Order, shipping, message, and promo updates"
            : "Order, shipping, and Shop Message updates"
    }

    private var shippingSubtitle: String {
        let count = viewModel.shippingAddresses.count
        return count == 0 ? "Add a shipping address for checkout" : "\(count) saved address\(count == 1 ? "" : "es")"
    }
}

enum MarketplaceOrderStatusFormatter {
    static func display(_ order: MarketplaceOrder) -> String {
        if let refund = order.refundStatus, refund != .none { return refund.rawValue }
        if let dispute = order.disputeStatus, dispute != .none { return dispute.rawValue }
        if let payment = order.paymentStatus, payment != .paid { return payment.rawValue }
        return order.status
    }
}
