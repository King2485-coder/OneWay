import SwiftUI
import Combine

struct WalletView: View {
    var onBack: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel = WalletViewModel()
    @State private var selectedAction: WalletAction?
    @State private var selectedTransaction: WalletTransaction?
    @State private var isRegulatoryBannerExpanded = false

    init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WalletPremiumBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        statusBanner
                        primaryActions
                        balanceOverview
                        oneWayRewards
                        transactionHistory
                        payoutSummary
                        securityStatus
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 118)
                }
                .refreshable {
                    await viewModel.load(force: true)
                }

                if viewModel.isLoading && viewModel.wallet == nil {
                    WalletLoadingOverlay(reduceMotion: reduceMotion)
                }
            }
            .navigationBarHidden(true)
            .task {
                await viewModel.load()
            }
            .sheet(item: $selectedAction) { action in
                WalletActionSheet(action: action, wallet: viewModel.wallet) {
                    selectedAction = nil
                }
            }
            .sheet(item: $selectedTransaction) { transaction in
                WalletTransactionDetailView(transaction: transaction)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let onBack {
                walletCircleButton(icon: "chevron.left", action: onBack)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wallet")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.75)
                Text("Your secure money hub.")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WalletTheme.textSecondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = viewModel.errorMessage {
            walletErrorNotice(title: "Wallet temporarily unavailable", message: "\(message). Your money is safe. Pull to refresh or try again.", icon: "wifi.exclamationmark")
        } else if let wallet = viewModel.wallet, !wallet.capabilities.sendMoney {
            regulatoryBanner(wallet)
        }
    }

    private var heroBalanceCard: some View {
        WalletPressableButton {
            selectedAction = .balanceDetails
        } label: {
            WalletSignatureCard(shimmer: viewModel.wallet != nil && viewModel.errorMessage == nil, reduceMotion: reduceMotion) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AVAILABLE BALANCE")
                                .font(.caption2.weight(.black))
                                .tracking(0.8)
                                .foregroundStyle(WalletTheme.textSecondary)
                            if viewModel.balances.availableBalanceMinor == 0 {
                                Text("You're ready.")
                                    .font(.system(size: 31, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                    .minimumScaleFactor(0.58)
                                    .lineLimit(1)
                                Text("Add funds or receive a payment.")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(WalletTheme.textSecondary)
                                    .lineLimit(2)
                            } else {
                                Text(MoneyFormatter.format(viewModel.balances.availableBalanceMinor, currency: viewModel.balances.currency))
                                    .font(.system(size: 36, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                    .minimumScaleFactor(0.42)
                                    .lineLimit(1)
                                    .contentTransition(.numericText())
                            }
                        }

                        HStack(spacing: 8) {
                            WalletStatusDot(color: heroStateColor, isActive: viewModel.isLoading || viewModel.balances.pendingBalanceMinor > 0, reduceMotion: reduceMotion)
                            Text(heroStatusText)
                                .font(.caption.weight(.black))
                                .foregroundStyle(heroStateColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Spacer(minLength: 0)
                            OneWayResolvedIcon(systemName: "chevron.right")
                                .font(.caption.weight(.black))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(WalletTheme.deepControl, in: Circle())
                                .overlay(Circle().stroke(WalletTheme.border, lineWidth: 1))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    OneWayCoreView(state: heroCoreState, reduceMotion: reduceMotion)
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Available balance, \(MoneyFormatter.accessible(viewModel.balances.availableBalanceMinor, currency: viewModel.balances.currency)). \(heroStatusText).")
    }

    private var heroCoreState: OneWayCoreState {
        if viewModel.errorMessage != nil { return .offline }
        if viewModel.balances.negativeBalanceMinor > 0 { return .problem }
        if viewModel.balances.pendingBalanceMinor > 0 { return .pending }
        if viewModel.transactions.contains(where: { $0.direction == .incoming }) { return .receiving }
        if viewModel.transactions.contains(where: { $0.direction == .outgoing }) { return .sending }
        return .protected
    }

    private var heroStateColor: Color {
        switch heroCoreState {
        case .offline, .pending: return WalletTheme.orange
        case .problem, .error: return WalletTheme.red
        case .receiving, .protected, .idle, .active, .completed: return WalletTheme.green
        case .sending, .syncing: return WalletTheme.blue
        }
    }

    private var heroStatusText: String {
        switch heroCoreState {
        case .offline: return "Offline balance"
        case .problem: return "Needs attention"
        case .error: return "Action needed"
        case .pending: return "Settlement pending"
        case .receiving: return "Receiving activity"
        case .sending: return "Outgoing activity"
        case .syncing: return "Syncing"
        case .completed: return "Completed"
        case .active, .protected, .idle: return "Ready to use"
        }
    }

    private var primaryActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroBalanceCard
            Text("Quick Actions")
                .font(.caption.weight(.black))
                .foregroundStyle(WalletTheme.textSecondary)
            HStack(spacing: 10) {
                walletAction(.send, enabled: viewModel.wallet?.capabilities.sendMoney == true)
                walletAction(.receive, enabled: true)
                walletAction(.pay, enabled: true)
                walletAction(.addMoney, enabled: viewModel.wallet?.capabilities.addMoney == true)
            }
        }
    }

    private func walletAction(_ action: WalletAction, enabled: Bool) -> some View {
        WalletPressableButton {
            selectedAction = action
        } label: {
            VStack(spacing: 8) {
                OneWayResolvedIcon(systemName: action.icon)
                    .font(.title3.weight(.black))
                    .foregroundStyle(enabled ? WalletTheme.purpleBright : WalletTheme.textMuted)
                    .frame(width: 42, height: 42)
                    .background(WalletTheme.deepControl, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(WalletTheme.border, lineWidth: 1))
                Text(action.title)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(enabled ? .white : WalletTheme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(WalletTheme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(WalletTheme.border, lineWidth: 1))
            .shadow(color: WalletTheme.purpleBright.opacity(enabled ? 0.12 : 0.02), radius: 14, x: 0, y: 8)
        }
        .accessibilityLabel(action.accessibilityTitle)
        .accessibilityHint(enabled ? action.subtitle : "This regulated Wallet feature is disabled until provider rails are enabled.")
    }

    private var balanceOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Balance Overview")
                .font(.caption.weight(.black))
                .foregroundStyle(WalletTheme.textSecondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                balanceStatusCard("Pending", amount: viewModel.balances.pendingBalanceMinor, subtitle: "Still settling", icon: "clock.fill", color: WalletTheme.orange)
                balanceStatusCard("Seller Earnings", amount: viewModel.balances.sellerEarningsMinor, subtitle: "Cleared shop earnings", icon: "storefront.fill", color: WalletTheme.purpleBright)
                balanceStatusCard("Pending Payouts", amount: viewModel.balances.pendingSellerPayoutsMinor, subtitle: "Moving to bank", icon: "arrow.up.right.circle.fill", color: WalletTheme.blue)
                balanceStatusCard("Protection", amount: 0, subtitle: "Monitoring active", icon: "shield.checkered", color: WalletTheme.green)
            }
        }
    }

    private func balanceStatusCard(_ title: String, amount: Int, subtitle: String, icon: String, color: Color) -> some View {
        WalletPressableButton {
            selectedAction = title == "Pending Payouts" ? .payouts : title == "Seller Earnings" ? .sellerEarnings : .receipts
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.caption.weight(.black))
                    .foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(color.opacity(0.16), in: Circle())
                    .overlay(Circle().stroke(color.opacity(0.42), lineWidth: 1))
                Text(title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(MoneyFormatter.format(amount, currency: viewModel.balances.currency))
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.68)
                HStack(spacing: 4) {
                    Text(subtitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 2)
                    OneWayResolvedIcon(systemName: "chevron.right")
                        .font(.caption2.weight(.black))
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(WalletTheme.cardFill, in: OneWaySignatureCardShape())
            .overlay(OneWaySignatureCardShape().stroke(color.opacity(0.34), lineWidth: 1))
        }
        .accessibilityLabel("\(title), \(MoneyFormatter.accessible(amount, currency: viewModel.balances.currency)). \(subtitle)")
    }

    private var transactionHistory: some View {
        WalletPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    OneWayResolvedLabel("Recent Activity", systemImage: "clock")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(viewModel.transactions.isEmpty ? "Retry" : "View all") {
                        Task { await viewModel.load(force: true) }
                    }
                    .font(.caption.weight(.black))
                    .foregroundStyle(WalletTheme.purpleBright)
                }

                if viewModel.transactions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No Wallet activity yet")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                        Text("Shop purchases, seller earnings, receipts, refunds, and payouts will appear here after backend verification.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WalletTheme.textSecondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.transactions.prefix(4)) { transaction in
                    WalletPressableButton {
                        selectedTransaction = transaction
                    } label: {
                        transactionRow(transaction)
                    }
                }
            }
        }
        }
    }

    private var oneWayRewards: some View {
        WalletPressableButton {
            selectedAction = .rewards
        } label: {
            WalletSignatureCard(shimmer: false, reduceMotion: reduceMotion) {
                HStack(spacing: 14) {
                    ZStack {
                        OneWayCoreView(state: .idle, reduceMotion: true)
                            .frame(width: 62, height: 62)
                        OneWayResolvedIcon(systemName: "sparkles")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("OneWay Rewards")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                        Text("Marketplace, Shops, Ads, referrals, and future subscriptions will feed this rewards hub.")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(WalletTheme.textSecondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    OneWayResolvedIcon(systemName: "chevron.right")
                        .font(.caption.weight(.black))
                        .foregroundStyle(WalletTheme.textMuted)
                }
            }
        }
        .accessibilityLabel("OneWay Rewards. Future rewards hub.")
    }

    private func transactionRow(_ transaction: WalletTransaction) -> some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: transaction.icon)
                .font(.headline.weight(.black))
                .foregroundStyle(transaction.direction == .incoming ? WalletTheme.green : WalletTheme.purpleBright)
                .frame(width: 42, height: 42)
                .background(WalletTheme.deepControl, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(WalletTheme.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.title)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(.white)
                Text("\(transaction.counterparty) • \(transaction.status.capitalized)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(transaction.signedAmount)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(transaction.direction == .incoming ? WalletTheme.green : .white)
                Text(transaction.relativeDate)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WalletTheme.textMuted)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transaction.title), \(transaction.signedAmount), \(transaction.status), \(transaction.counterparty)")
    }

    private var payoutSummary: some View {
        WalletPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Payout Summary")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        selectedAction = .payouts
                    } label: {
                        OneWayResolvedIcon(systemName: "chevron.right")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(WalletTheme.deepControl, in: Circle())
                    }
                }
                payoutLine("Next Payout", viewModel.balances.pendingSellerPayoutsMinor > 0 ? "Tomorrow" : "Not scheduled")
                payoutLine("Amount", MoneyFormatter.format(viewModel.balances.pendingSellerPayoutsMinor, currency: viewModel.balances.currency))
                payoutLine("Method", viewModel.wallet?.capabilities.sellerPayouts == true ? "OneWay Bank" : "Provider required")
                Divider().overlay(WalletTheme.border)
                payoutLine("This Month", MoneyFormatter.format(viewModel.balances.sellerEarningsMinor, currency: viewModel.balances.currency))
            }
        }
    }

    private var securityStatus: some View {
        WalletPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    OneWayResolvedIcon(systemName: viewModel.wallet?.provider.available == true ? "checkmark" : "lock.shield.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(viewModel.wallet?.provider.available == true ? WalletTheme.green : WalletTheme.purpleBright, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.wallet?.provider.available == true ? "Your Wallet is Secure" : "Wallet Protection Active")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                        Text(viewModel.wallet?.provider.available == true ? "Provider rails verified" : "Transfers limited until setup is complete")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(WalletTheme.textSecondary)
                    }
                    Spacer()
                }
                securityButton("Identity", value: viewModel.wallet?.provider.available == true ? "Verified" : "Required", icon: "person.text.rectangle.fill", color: viewModel.wallet?.provider.available == true ? WalletTheme.green : WalletTheme.orange)
                securityButton("Two-factor", value: "Security settings", icon: "key.fill", color: WalletTheme.purpleBright)
                securityButton("Trusted Devices", value: "Protected", icon: "iphone.gen3", color: WalletTheme.green)
                securityButton("Transaction Monitoring", value: "Active", icon: "shield.lefthalf.filled", color: WalletTheme.green)
                securityButton("Recovery", value: "Review", icon: "arrow.counterclockwise.circle.fill", color: WalletTheme.blue)
                securityButton("Payment Protection", value: viewModel.wallet?.provider.available == true ? "Active" : "Limited", icon: "lock.shield.fill", color: viewModel.wallet?.provider.available == true ? WalletTheme.green : WalletTheme.orange)

                Button {
                    selectedAction = .security
                } label: {
                    HStack {
                        Text("Manage Security Settings")
                        Spacer()
                        OneWayResolvedIcon(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(WalletTheme.deepControl, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(WalletTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func payoutLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(WalletTheme.textSecondary)
            Spacer()
            Text(value)
                .fontWeight(.black)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func securityLine(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.14), in: Circle())
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(WalletTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(color)
        }
    }

    private func securityButton(_ label: String, value: String, icon: String, color: Color) -> some View {
        WalletPressableButton {
            selectedAction = .security
        } label: {
            securityLine(label, value: value, icon: icon, color: color)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(label), \(value)")
    }

    private var securityAndLimits: some View {
        VStack(spacing: 12) {
            walletNotice(title: "Wallet Security", message: "Face ID, withdrawal alerts, transfer notifications, and trusted-device review are required for sensitive Wallet actions.", icon: "faceid", color: OneWayDesignSystem.Colors.purple)
            walletNotice(title: "Compliance Guardrails", message: "Deposits, withdrawals, stored balances, and P2P transfers stay locked until provider confirmation, KYC, AML, sanctions screening, and legal coverage are active.", icon: "building.columns.fill", color: OneWayDesignSystem.Colors.warning)
        }
    }

    private func walletNotice(title: String, message: String, icon: String, color: Color) -> some View {
        WalletPanel {
            HStack(alignment: .top, spacing: 12) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.title3.weight(.black))
                    .foregroundStyle(color)
                    .frame(width: 42, height: 42)
                    .background(WalletTheme.deepControl, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WalletTheme.textSecondary)
                }
            }
        }
    }

    private func walletErrorNotice(title: String, message: String, icon: String) -> some View {
        WalletPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    OneWayResolvedIcon(systemName: icon)
                        .font(.title3.weight(.black))
                        .foregroundStyle(WalletTheme.orange)
                        .frame(width: 42, height: 42)
                        .background(WalletTheme.orange.opacity(0.16), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                        Text(message)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WalletTheme.textSecondary)
                    }
                }
                Button {
                    Task { await viewModel.load(force: true) }
                } label: {
                    OneWayResolvedLabel("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(WalletTheme.purpleGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func regulatoryBanner(_ wallet: WalletSnapshot) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
                isRegulatoryBannerExpanded.toggle()
            }
        } label: {
            WalletPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        OneWayResolvedIcon(systemName: "lock.shield.fill")
                            .font(.headline.weight(.black))
                            .foregroundStyle(WalletTheme.purpleBright)
                            .frame(width: 38, height: 38)
                            .background(WalletTheme.purpleBright.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Wallet transfer features are currently limited.")
                                .font(.subheadline.weight(.black))
                                .foregroundStyle(.white)
                            Text(isRegulatoryBannerExpanded ? (wallet.notices.first ?? "Money movement requires provider rails and compliance approval.") : "Learn more")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(WalletTheme.textSecondary)
                        }
                        Spacer()
                        OneWayResolvedIcon(systemName: isRegulatoryBannerExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.black))
                            .foregroundStyle(WalletTheme.textMuted)
                    }

                    if isRegulatoryBannerExpanded {
                        VStack(spacing: 8) {
                            complianceRow("Stored balances", "Limited")
                            complianceRow("Deposits", "Provider required")
                            complianceRow("Withdrawals", "Provider required")
                            complianceRow("Peer transfers", "Provider required")
                            complianceRow("KYC / AML", "Required before launch")
                            complianceRow("Payment rails", wallet.provider.available ? "Available" : "Not connected")
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Wallet transfer features are currently limited. \(isRegulatoryBannerExpanded ? "Expanded" : "Collapsed")")
    }

    private func complianceRow(_ label: String, _ status: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(WalletTheme.textSecondary)
            Spacer()
            Text(status)
                .fontWeight(.black)
                .foregroundStyle(status == "Limited" || status.contains("required") || status.contains("Required") || status.contains("Not") ? WalletTheme.orange : WalletTheme.green)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func walletCircleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: icon)
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(WalletTheme.glass, in: Circle())
                .overlay(Circle().stroke(WalletTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private enum WalletTheme {
    static let backgroundTop = Color(hex: 0x02030B)
    static let backgroundMid = Color(hex: 0x070B1B)
    static let backgroundBottom = Color(hex: 0x15052B)
    static let cardFill = Color(hex: 0x12152C).opacity(0.86)
    static let glass = Color(hex: 0x191B37).opacity(0.76)
    static let deepControl = Color(hex: 0x17142E).opacity(0.94)
    static let border = Color(hex: 0x7D48FF).opacity(0.34)
    static let purpleBright = Color(hex: 0xA855F7)
    static let purpleSoft = Color(hex: 0x6D28D9)
    static let textSecondary = Color(hex: 0xCAC2EF)
    static let textMuted = Color(hex: 0x9188B4)
    static let green = Color(hex: 0x22C55E)
    static let orange = Color(hex: 0xF59E0B)
    static let blue = Color(hex: 0x4F8CFF)
    static let red = Color(hex: 0xEF4444)
    static let purpleGradient = LinearGradient(
        colors: [Color(hex: 0xC084FC), Color(hex: 0x7C3AED), Color(hex: 0x4C1D95)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private struct WalletPremiumBackground: View {
    var body: some View {
        LinearGradient(
            colors: [WalletTheme.backgroundTop, WalletTheme.backgroundMid, WalletTheme.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            Circle()
                .fill(WalletTheme.purpleBright.opacity(0.22))
                .frame(width: 280, height: 140)
                .blur(radius: 70)
                .offset(x: 100, y: 115)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(WalletTheme.purpleSoft.opacity(0.18))
                .frame(width: 300, height: 220)
                .blur(radius: 80)
                .offset(x: -130, y: 60)
        }
        .ignoresSafeArea()
    }
}

private struct WalletPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(WalletTheme.cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(WalletTheme.border, lineWidth: 1))
            .shadow(color: WalletTheme.purpleBright.opacity(0.14), radius: 24, x: 0, y: 14)
    }
}

private struct WalletPressableButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            action()
        } label: {
            label
        }
        .buttonStyle(WalletPressStyle())
    }
}

private struct WalletPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .shadow(color: WalletTheme.purpleBright.opacity(configuration.isPressed ? 0.2 : 0), radius: configuration.isPressed ? 18 : 0, x: 0, y: 10)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private struct WalletStatusDot: View {
    let color: Color
    let isActive: Bool
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 2)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.55)
            }
            .onAppear {
                guard isActive, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}

private struct WalletLoadingOverlay: View {
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WalletSkeletonCard(height: 126, reduceMotion: reduceMotion)
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    WalletSkeletonCard(height: 74, reduceMotion: reduceMotion)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    WalletSkeletonCard(height: 126, reduceMotion: reduceMotion)
                }
            }
        }
        .padding(18)
        .background(.black.opacity(0.32))
        .transition(.opacity)
        .accessibilityLabel("Loading Wallet")
    }
}

private struct WalletSkeletonCard: View {
    let height: CGFloat
    let reduceMotion: Bool
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(WalletTheme.cardFill)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(WalletTheme.textMuted.opacity(0.24)).frame(width: 84, height: 9)
                    RoundedRectangle(cornerRadius: 5).fill(WalletTheme.textSecondary.opacity(0.18)).frame(width: 132, height: 18)
                    RoundedRectangle(cornerRadius: 4).fill(WalletTheme.textMuted.opacity(0.18)).frame(width: 96, height: 8)
                }
                .padding(16)
            }
            .overlay {
                if !reduceMotion {
                    LinearGradient(colors: [.clear, .white.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom)
                        .rotationEffect(.degrees(18))
                        .offset(x: shimmer ? 220 : -220)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(WalletTheme.border, lineWidth: 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    shimmer = true
                }
            }
    }
}

private struct WalletSignatureCard<Content: View>: View {
    var shimmer: Bool = false
    var reduceMotion: Bool = false
    @ViewBuilder var content: Content
    @State private var lightSweep = false

    var body: some View {
        content
            .padding(18)
            .background {
                ZStack {
                    OneWaySignatureCardShape()
                        .fill(WalletTheme.purpleGradient)
                    OneWaySignatureCardShape()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), Color.clear, Color.black.opacity(0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    waveOverlay
                    if shimmer && !reduceMotion {
                        LinearGradient(colors: [.clear, .white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                            .rotationEffect(.degrees(22))
                            .offset(x: lightSweep ? 260 : -260)
                            .blendMode(.screen)
                    }
                }
            }
            .clipShape(OneWaySignatureCardShape())
            .overlay(OneWaySignatureCardShape().stroke(Color(hex: 0xB983FF).opacity(0.66), lineWidth: 1.1))
            .shadow(color: WalletTheme.purpleBright.opacity(0.36), radius: 30, x: 0, y: 18)
            .onAppear {
                guard shimmer, !reduceMotion else { return }
                withAnimation(.linear(duration: 3.8).repeatForever(autoreverses: false)) {
                    lightSweep = true
                }
            }
    }

    private var waveOverlay: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height * 0.72))
                    path.addCurve(
                        to: CGPoint(x: width, y: height * 0.76),
                        control1: CGPoint(x: width * 0.34, y: height * 0.48),
                        control2: CGPoint(x: width * 0.62, y: height * 0.98)
                    )
                }
                .stroke(Color(hex: 0xB983FF).opacity(0.38), lineWidth: 1)

                Path { path in
                    path.move(to: CGPoint(x: width * 0.64, y: 0))
                    path.addCurve(
                        to: CGPoint(x: width, y: height * 0.04),
                        control1: CGPoint(x: width * 0.76, y: height * 0.08),
                        control2: CGPoint(x: width * 0.86, y: -height * 0.04)
                    )
                    path.addLine(to: CGPoint(x: width, y: height * 0.42))
                    path.addCurve(
                        to: CGPoint(x: width * 0.64, y: 0),
                        control1: CGPoint(x: width * 0.9, y: height * 0.2),
                        control2: CGPoint(x: width * 0.76, y: height * 0.14)
                    )
                }
                .fill(Color.white.opacity(0.08))
            }
        }
        .clipShape(OneWaySignatureCardShape())
    }
}

private struct WalletActionSheet: View {
    let action: WalletAction
    let wallet: WalletSnapshot?
    let onClose: () -> Void

    @State private var recipient = ""
    @State private var amount = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayLightBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            OneWayResolvedIcon(systemName: action.icon)
                                .font(.title2.weight(.black))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(OneWayDesignSystem.Colors.purpleGradient, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title)
                                    .font(.title.weight(.black))
                                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                                Text(action.subtitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                            }
                            Spacer()
                            OneWayBackButton(action: onClose)
                        }

                        if action.requiresProvider && action.isEnabled(in: wallet) == false {
                            OneWayCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    OneWayResolvedLabel("Provider Required", systemImage: "lock.shield.fill")
                                        .font(.headline.weight(.black))
                                        .foregroundStyle(OneWayDesignSystem.Colors.purple)
                                    Text("OneWay will not simulate this regulated money movement. This action unlocks after the Wallet provider, KYC, AML, sanctions screening, limits, and webhook verification are active.")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                                }
                            }
                        }

                        if action == .send || action == .request {
                            formCard
                            reviewCard
                        } else {
                            detailsCard
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 24)
                }
            }
            .navigationBarHidden(true)
        }
    }

    private var formCard: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(action == .send ? "Recipient" : "Person")
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                TextField("@OneWayID, username, or verified contact", text: $recipient)
                    .textInputAutocapitalization(.never)
                    .padding(14)
                    .background(OneWayDesignSystem.Colors.lavender, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                TextField("Amount", text: $amount)
                    .keyboardType(.decimalPad)
                    .padding(14)
                    .background(OneWayDesignSystem.Colors.lavender, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                TextField(action == .send ? "Optional note" : "Reason", text: $note)
                    .padding(14)
                    .background(OneWayDesignSystem.Colors.lavender, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var reviewCard: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review")
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                reviewRow("Recipient", recipient.isEmpty ? "Not selected" : recipient)
                reviewRow("Amount", amount.isEmpty ? "$0.00" : amount)
                reviewRow("Fee", action == .send ? "Provider authoritative" : "$0.00")
                reviewRow("Status", action.isEnabled(in: wallet) ? "Ready for authentication" : "Locked")
                Button(action.isEnabled(in: wallet) ? "Continue" : "Unavailable") {}
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(action.isEnabled(in: wallet) ? OneWayDesignSystem.Colors.purpleGradient : LinearGradient(colors: [.gray], startPoint: .leading, endPoint: .trailing), in: Capsule())
                    .disabled(action.isEnabled(in: wallet) == false)
            }
        }
    }

    private var detailsCard: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(action.title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                Text(action.detailCopy)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                if let wallet {
                    reviewRow("Wallet Mode", wallet.mode.replacingOccurrences(of: "_", with: " ").capitalized)
                    reviewRow("Provider", wallet.provider.provider.capitalized)
                }
            }
        }
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            Spacer()
            Text(value).foregroundStyle(OneWayDesignSystem.Colors.text).fontWeight(.bold)
        }
        .font(.subheadline)
    }
}

private struct WalletTransactionDetailView: View {
    let transaction: WalletTransaction

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayLightBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        OneWayCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(transaction.title)
                                    .font(.title.weight(.black))
                                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                                Text(transaction.signedAmount)
                                    .font(.system(size: 42, weight: .black, design: .rounded))
                                    .foregroundStyle(transaction.direction == .incoming ? OneWayDesignSystem.Colors.mint : OneWayDesignSystem.Colors.text)
                                Text(transaction.status.capitalized)
                                    .font(.headline.weight(.black))
                                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                            }
                        }

                        OneWayCard {
                            VStack(spacing: 10) {
                                detailRow("Counterparty", transaction.counterparty)
                                detailRow("Reference", transaction.reference)
                                detailRow("Payment Method", transaction.paymentMethod ?? "Not available")
                                detailRow("Created", transaction.createdAt)
                                if let completedAt = transaction.completedAt {
                                    detailRow("Completed", completedAt)
                                }
                                ForEach(transaction.fees) { fee in
                                    detailRow(fee.label, MoneyFormatter.format(fee.amountMinor, currency: transaction.currency))
                                }
                            }
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            Spacer(minLength: 18)
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(OneWayDesignSystem.Colors.text)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

@MainActor
private final class WalletViewModel: ObservableObject {
    @Published var wallet: WalletSnapshot?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service = WalletAPIService()

    var balances: WalletBalances {
        wallet?.balances ?? .zero
    }

    var transactions: [WalletTransaction] {
        wallet?.recentTransactions ?? []
    }

    func load(force: Bool = false) async {
        if isLoading && !force { return }
        isLoading = true
        errorMessage = nil
        do {
            wallet = try await service.fetchWallet()
        } catch {
            errorMessage = error.localizedDescription
            if wallet == nil {
                wallet = .offlineFallback
            }
        }
        isLoading = false
    }
}

private struct WalletAPIService {
    private let client = APIClient.shared

    func fetchWallet() async throws -> WalletSnapshot {
        let response: WalletEnvelope = try await client.get("api/wallet")
        return response.wallet
    }
}

private struct WalletEnvelope: Decodable {
    let ok: Bool
    let wallet: WalletSnapshot
}

private struct WalletSnapshot: Decodable {
    let userId: String
    let mode: String
    let provider: WalletProvider
    let capabilities: WalletCapabilities
    let balances: WalletBalances
    let recentTransactions: [WalletTransaction]
    let notices: [String]

    static let offlineFallback = WalletSnapshot(
        userId: "offline",
        mode: "offline_cached",
        provider: WalletProvider(available: false, provider: "unavailable", enabled: false, mockMode: false, message: "Wallet backend is unavailable.", testModeWarning: nil),
        capabilities: WalletCapabilities(
            walletBalanceRead: true,
            transactionHistory: true,
            shopPurchases: true,
            sellerEarnings: true,
            paymentRequests: false,
            sendMoney: false,
            addMoney: false,
            withdrawMoney: false,
            bankLinking: false,
            paymentMethodLinking: false,
            sellerPayouts: false
        ),
        balances: .zero,
        recentTransactions: [],
        notices: ["Wallet backend is unavailable. Balances shown here are not confirmed."]
    )
}

private struct WalletProvider: Decodable {
    let available: Bool
    let provider: String
    let enabled: Bool
    let mockMode: Bool
    let message: String
    let testModeWarning: String?
}

private struct WalletCapabilities: Decodable {
    let walletBalanceRead: Bool
    let transactionHistory: Bool
    let shopPurchases: Bool
    let sellerEarnings: Bool
    let paymentRequests: Bool
    let sendMoney: Bool
    let addMoney: Bool
    let withdrawMoney: Bool
    let bankLinking: Bool
    let paymentMethodLinking: Bool
    let sellerPayouts: Bool
}

private struct WalletBalances: Decodable {
    let currency: String
    let availableBalanceMinor: Int
    let pendingBalanceMinor: Int
    let sellerEarningsMinor: Int
    let pendingSellerPayoutsMinor: Int
    let totalOneWayFundsMinor: Int
    let negativeBalanceMinor: Int

    static let zero = WalletBalances(
        currency: "USD",
        availableBalanceMinor: 0,
        pendingBalanceMinor: 0,
        sellerEarningsMinor: 0,
        pendingSellerPayoutsMinor: 0,
        totalOneWayFundsMinor: 0,
        negativeBalanceMinor: 0
    )
}

private struct WalletTransaction: Decodable, Identifiable {
    let id: String
    let type: String
    let title: String
    let counterparty: String
    let amountMinor: Int
    let currency: String
    let direction: Direction
    let status: String
    let createdAt: String
    let completedAt: String?
    let reference: String
    let paymentMethod: String?
    let fees: [WalletFee]
    let receiptAvailable: Bool
    let category: String

    enum Direction: String, Decodable {
        case incoming
        case outgoing
        case neutral
    }

    var icon: String {
        switch category {
        case "shop_purchase": return "bag.fill"
        case "seller_earning": return "storefront.fill"
        case "withdrawal": return "arrow.up.right.circle.fill"
        case "deposit": return "arrow.down.left.circle.fill"
        case "refund": return "arrow.uturn.backward.circle.fill"
        default: return "wallet.pass.fill"
        }
    }

    var signedAmount: String {
        let prefix = direction == .incoming ? "+" : direction == .outgoing ? "-" : ""
        return "\(prefix)\(MoneyFormatter.format(abs(amountMinor), currency: currency))"
    }

    var relativeDate: String {
        guard let date = ISO8601DateFormatter().date(from: createdAt) else { return "" }
        return date.formatted(.relative(presentation: .named))
    }
}

private struct WalletFee: Decodable, Identifiable {
    var id: String { label }
    let label: String
    let amountMinor: Int
}

private enum WalletAction: String, Identifiable, CaseIterable {
    case send
    case request
    case receive
    case pay
    case addMoney
    case scan
    case balanceDetails
    case rewards
    case withdraw
    case paymentMethods
    case bankAccounts
    case oneWayFees
    case automaticPayments
    case invoices
    case subscriptions
    case sellerEarnings
    case payouts
    case receipts
    case security
    case limits
    case support

    var id: String { rawValue }

    static let secondary: [WalletAction] = [.oneWayFees, .automaticPayments, .paymentMethods, .bankAccounts, .invoices, .subscriptions, .sellerEarnings, .payouts, .receipts, .security, .limits, .support]

    var title: String {
        switch self {
        case .send: return "Send"
        case .request: return "Request"
        case .receive: return "Receive"
        case .pay: return "Pay"
        case .addMoney: return "Add Money"
        case .scan: return "Scan"
        case .balanceDetails: return "Balance Details"
        case .rewards: return "Rewards"
        case .withdraw: return "Withdraw"
        case .paymentMethods: return "Payment Methods"
        case .bankAccounts: return "Bank Accounts"
        case .oneWayFees: return "OneWay Fees"
        case .automaticPayments: return "Automatic Payments"
        case .invoices: return "Invoices"
        case .subscriptions: return "Subscriptions"
        case .sellerEarnings: return "Seller Earnings"
        case .payouts: return "Payouts"
        case .receipts: return "Receipts"
        case .security: return "Security"
        case .limits: return "Limits"
        case .support: return "Support"
        }
    }

    var subtitle: String {
        switch self {
        case .send: return "Move money to a verified OneWay recipient."
        case .request: return "Ask a person to pay you securely."
        case .receive: return "Generate a QR code or share a OneWay payment link."
        case .pay: return "Pay through OneWay marketplace and checkout flows."
        case .addMoney: return "Fund Wallet through approved rails."
        case .scan: return "Scan a payment or receipt QR code."
        case .balanceDetails: return "Review available, pending, seller, and payout balances."
        case .rewards: return "Track OneWay rewards from marketplace, shops, ads, and future programs."
        case .withdraw: return "Move eligible funds to a destination."
        case .paymentMethods: return "Cards, Apple Pay, and provider tokens."
        case .bankAccounts: return "Provider-hosted bank linking."
        case .oneWayFees: return "Marketplace and service-fee policy."
        case .automaticPayments: return "Scoped autopay, off by default."
        case .invoices: return "Manual service-fee payments."
        case .subscriptions: return "Approved recurring service plans."
        case .sellerEarnings: return "Shop earnings and fee detail."
        case .payouts: return "Seller payout schedule and history."
        case .receipts: return "View, share, and email receipts."
        case .security: return "Face ID, alerts, and trusted devices."
        case .limits: return "Provider-authoritative limits."
        case .support: return "Report payment or Wallet problems."
        }
    }

    var detailCopy: String {
        switch self {
        case .balanceDetails:
            return "Available, pending, seller, and payout funds are separated so OneWay never implies money is spendable before it is eligible."
        case .receive:
            return "Receive will generate a OneWay QR code or payment link after the provider flow is connected. Until then, incoming marketplace payments appear in activity."
        case .pay:
            return "Use Pay from OneWay Shops and marketplace checkout. Direct wallet payments remain limited until payment rails and verification are complete."
        case .rewards:
            return "OneWay Rewards is the future home for marketplace, Shops, Ads, referrals, and subscription rewards. Rewards never replace regulated wallet balances."
        case .oneWayFees:
            return "OneWay’s active physical-commerce fee is the $0.30 marketplace order fee. Digital feature fees remain policy-gated until App Store review is complete."
        case .automaticPayments:
            return "Autopay is off by default. Users must choose eligible fee scopes, add a Stripe payment method through SetupIntent, accept terms, and can pause or revoke later."
        case .invoices:
            return "Manual OneWay service-fee invoices list each fee, credits, taxes where applicable, due date, and payment status."
        case .subscriptions:
            return "Recurring service subscriptions use Stripe Billing only after payment-policy approval. Access is provisioned from provider-confirmed payment or trial state."
        case .paymentMethods:
            return "OneWay will use provider-hosted setup sessions. Card numbers and CVV are never stored on OneWay servers."
        case .bankAccounts:
            return "Bank linking must happen through an approved provider. Users should never type online banking credentials into OneWay."
        case .sellerEarnings:
            return "Seller earnings remain separate from Wallet peer transfers. Completed Shop orders include customer total, OneWay sale fee, processor fee, and seller net earnings."
        case .payouts:
            return "Payouts are separated from ordinary Wallet transfers and require verified payout destinations."
        case .receipts:
            return "Receipts show safe transaction details without exposing full bank or card data."
        case .security:
            return "Sensitive operations require recent Wallet authentication, Face ID where available, and clear security notifications."
        case .limits:
            return "Transfer, deposit, withdrawal, request, and payout limits are supplied by the backend and payment provider."
        case .support:
            return "Users can report unauthorized transactions, disputes, refunds, and account restrictions without losing access to history."
        default:
            return subtitle
        }
    }

    var icon: String {
        switch self {
        case .send: return "paperplane.fill"
        case .request: return "qrcode"
        case .receive: return "arrow.down.left.circle.fill"
        case .pay: return "creditcard.fill"
        case .addMoney: return "plus.circle.fill"
        case .scan: return "qrcode.viewfinder"
        case .balanceDetails: return "wallet.pass.fill"
        case .rewards: return "sparkles"
        case .withdraw: return "arrow.up.right.circle.fill"
        case .paymentMethods: return "creditcard.fill"
        case .bankAccounts: return "building.columns.fill"
        case .oneWayFees: return "centsign.circle.fill"
        case .automaticPayments: return "arrow.triangle.2.circlepath.circle.fill"
        case .invoices: return "doc.plaintext.fill"
        case .subscriptions: return "calendar.badge.checkmark"
        case .sellerEarnings: return "storefront.fill"
        case .payouts: return "calendar.badge.clock"
        case .receipts: return "doc.text.fill"
        case .security: return "lock.shield.fill"
        case .limits: return "speedometer"
        case .support: return "questionmark.bubble.fill"
        }
    }

    var requiresProvider: Bool {
        [.send, .addMoney, .withdraw, .paymentMethods, .bankAccounts, .payouts].contains(self)
    }

    var accessibilityTitle: String {
        switch self {
        case .send: return "Send Money"
        case .request: return "Request Money"
        case .receive: return "Receive Money"
        case .pay: return "Pay"
        case .addMoney: return "Add Money"
        case .scan: return "Scan Wallet Code"
        case .balanceDetails: return "Balance Details"
        case .rewards: return "OneWay Rewards"
        case .withdraw: return "Withdraw Money"
        default: return title
        }
    }

    func isEnabled(in wallet: WalletSnapshot?) -> Bool {
        guard let capabilities = wallet?.capabilities else { return false }
        switch self {
        case .send: return capabilities.sendMoney
        case .request: return capabilities.paymentRequests
        case .receive: return true
        case .pay: return capabilities.shopPurchases
        case .addMoney: return capabilities.addMoney
        case .withdraw: return capabilities.withdrawMoney
        case .scan: return true
        case .balanceDetails: return capabilities.walletBalanceRead
        case .paymentMethods: return capabilities.paymentMethodLinking
        case .bankAccounts: return capabilities.bankLinking
        case .sellerEarnings: return capabilities.sellerEarnings
        case .payouts: return capabilities.sellerPayouts
        case .rewards, .oneWayFees, .automaticPayments, .invoices, .subscriptions, .receipts, .security, .limits, .support: return true
        }
    }
}

private enum MoneyFormatter {
    static func format(_ minor: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: Double(minor) / 100.0)) ?? "$0.00"
    }

    static func accessible(_ minor: Int, currency: String) -> String {
        format(minor, currency: currency)
    }
}
