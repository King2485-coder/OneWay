import SwiftUI
import Combine

enum WalletShortcutPlacement {
    case topTrailing
    case topLeading
    case floatingTrailing
    case floatingLeading
    case headerInline
    case toolbarTrailing
    case hidden
}

@MainActor
final class WalletPresentationCoordinator: ObservableObject {
    enum Presentation: Identifiable {
        case compact
        case full

        var id: String {
            switch self {
            case .compact: return "compact"
            case .full: return "full"
            }
        }
    }

    @Published var presentation: Presentation?

    func openCompactWallet() {
        guard presentation == nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        presentation = .compact
    }

    func openFullWallet() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        presentation = .full
    }

    func dismiss() {
        presentation = nil
    }
}

struct GlobalWalletShortcut: View {
    var placement: WalletShortcutPlacement = .topTrailing
    var badgeCount: Int = 0
    var pendingPayment: Bool = false
    var securityAlert: Bool = false
    let action: () -> Void

    var body: some View {
        if placement != .hidden {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.62))
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                OneWayDesignSystem.Colors.purpleGlow.opacity(0.92),
                                                Color.white.opacity(0.2),
                                                OneWayDesignSystem.Colors.purple.opacity(0.54)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.2
                                    )
                            )
                            .shadow(color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.48), radius: 18, x: 0, y: 8)

                        OneWayResolvedIcon(systemName: "wallet.pass.fill")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, OneWayDesignSystem.Colors.purpleGlow],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .frame(width: 50, height: 50)

                    statusBadge
                }
                .frame(minWidth: 50, minHeight: 50)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Wallet")
            .accessibilityHint("View payments, balance, and recent activity.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if securityAlert {
            OneWayResolvedIcon(systemName: "exclamationmark")
                .font(.caption2.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(OneWayDesignSystem.Colors.danger, in: Circle())
                .accessibilityLabel("Wallet has a security alert.")
        } else if pendingPayment {
            Circle()
                .fill(OneWayDesignSystem.Colors.warning)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                .accessibilityLabel("Wallet has a pending payment.")
        } else if badgeCount > 0 {
            Text("\(min(badgeCount, 9))")
                .font(.caption2.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(OneWayDesignSystem.Colors.purpleGradient, in: Circle())
                .accessibilityLabel("Wallet has \(badgeCount) alert\(badgeCount == 1 ? "" : "s").")
        }
    }
}

struct CompactWalletSheet: View {
    let onOpenFullWallet: () -> Void
    let onClose: () -> Void
    @State private var wallet: CompactWalletSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayLightBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            OneWayResolvedIcon(systemName: "wallet.pass.fill")
                                .font(.title2.weight(.black))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(OneWayDesignSystem.Colors.purpleGradient, in: Circle())
                                .shadow(color: OneWayDesignSystem.Colors.purpleGlow.opacity(0.44), radius: 16, x: 0, y: 8)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("OneWay Wallet")
                                    .font(.title2.weight(.black))
                                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                                Text(wallet?.modeLabel ?? "Secure money controls.")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                            }

                            Spacer()

                            OneWayBackButton(action: onClose)
                        }

                        OneWayCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("Available Balance")
                                        .font(.headline.weight(.black))
                                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                                    Spacer()
                                    OneWayResolvedLabel("Protected", systemImage: "lock.shield.fill")
                                        .font(.caption.weight(.black))
                                        .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)
                                }

                                Text(wallet.map { compactMoney($0.balances.availableBalanceMinor, $0.balances.currency) } ?? "Loading")
                                    .font(.system(size: 38, weight: .black, design: .rounded))
                                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                                    .minimumScaleFactor(0.75)

                                Text("Pending: \(wallet.map { compactMoney($0.balances.pendingBalanceMinor, $0.balances.currency) } ?? "$0.00")")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                            }
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            compactAction("Send", "paperplane.fill")
                            compactAction("Receive", "qrcode")
                            compactAction("Pay", "creditcard.fill")
                            compactAction("Add Funds", "plus.circle.fill")
                        }

                        OneWayCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Recent Activity")
                                    .font(.headline.weight(.black))
                                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                                if let errorMessage {
                                    Text(errorMessage)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                                } else if let wallet, wallet.recentTransactions.isEmpty == false {
                                    ForEach(wallet.recentTransactions.prefix(3)) { transaction in
                                        HStack {
                                            Text(transaction.title)
                                                .font(.subheadline.weight(.bold))
                                                .foregroundStyle(OneWayDesignSystem.Colors.text)
                                            Spacer()
                                            Text(transaction.signedAmount)
                                                .font(.subheadline.weight(.black))
                                                .foregroundStyle(transaction.direction == "incoming" ? OneWayDesignSystem.Colors.mint : OneWayDesignSystem.Colors.text)
                                        }
                                    }
                                } else {
                                    Text(isLoading ? "Loading recent Wallet activity..." : "No recent Wallet activity yet.")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                                }
                            }
                        }

                        Button(action: onOpenFullWallet) {
                            OneWayResolvedLabel("Open Full Wallet", systemImage: "arrow.up.right.square.fill")
                                .font(.headline.weight(.black))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(OneWayDesignSystem.Colors.purpleGradient, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(18)
                    .padding(.bottom, 20)
                }
            }
            .navigationBarHidden(true)
            .task {
                await loadCompactWallet()
            }
        }
    }

    private func compactAction(_ title: String, _ icon: String) -> some View {
        Button { } label: {
            VStack(spacing: 9) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purpleGlow)
                    .frame(width: 44, height: 44)
                    .background(OneWayDesignSystem.Colors.lavender, in: Circle())
                Text(title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadCompactWallet() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let response: CompactWalletEnvelope = try await APIClient.shared.get("api/wallet")
            wallet = response.wallet
        } catch {
            errorMessage = "Wallet backend is unavailable. Open Full Wallet for recovery options."
        }
        isLoading = false
    }
}

private struct CompactWalletEnvelope: Decodable {
    let wallet: CompactWalletSnapshot
}

private struct CompactWalletSnapshot: Decodable {
    let mode: String
    let balances: CompactWalletBalances
    let recentTransactions: [CompactWalletTransaction]

    var modeLabel: String {
        mode.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct CompactWalletBalances: Decodable {
    let currency: String
    let availableBalanceMinor: Int
    let pendingBalanceMinor: Int
}

private struct CompactWalletTransaction: Decodable, Identifiable {
    let id: String
    let title: String
    let amountMinor: Int
    let currency: String
    let direction: String

    var signedAmount: String {
        let prefix = direction == "incoming" ? "+" : direction == "outgoing" ? "-" : ""
        return "\(prefix)\(compactMoney(abs(amountMinor), currency))"
    }
}

private func compactMoney(_ minor: Int, _ currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 2
    return formatter.string(from: NSNumber(value: Double(minor) / 100.0)) ?? "$0.00"
}
