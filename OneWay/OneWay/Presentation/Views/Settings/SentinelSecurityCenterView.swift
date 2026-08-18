import SwiftUI

struct SentinelSecurityCenterView: View {
    @State private var scamProtection = true
    @State private var dangerousFileProtection = true
    @State private var communityProtection = true
    @State private var shopProtection = true
    @State private var trustedDeviceApproval = true
    @State private var isLockdownPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                statusCard
                protectionSection
                privacyCard
                lockdownButton
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .background { SideMenuBackground() }
        .navigationTitle("OneWay Sentinel")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Lock down this account?",
            isPresented: $isLockdownPresented,
            titleVisibility: .visible
        ) {
            Button("Lock Down Account", role: .destructive) {
                NotificationCenter.default.post(name: .oneWaySentinelLockdownRequested, object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This requests session revocation, pauses sensitive changes, and requires trusted-device verification.")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.green.opacity(0.16))
                        .frame(width: 58, height: 58)
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Sentinel is active")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.textPrimary)
                    Text("No immediate threats detected")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }

            Divider().overlay(Theme.divider)

            HStack {
                statusMetric("Account", value: "Protected")
                Spacer()
                statusMetric("Device", value: "Trusted")
                Spacer()
                statusMetric("Risk", value: "Low")
            }
        }
        .padding(18)
        .background(cardBackground)
    }

    private var protectionSection: some View {
        VStack(spacing: 0) {
            protectionToggle(
                icon: "person.badge.shield.checkmark",
                title: "Account & Identity",
                subtitle: "Device, session, login, and takeover protection",
                isOn: $trustedDeviceApproval
            )
            divider
            protectionToggle(
                icon: "message.badge.filled.fill",
                title: "Scam & Phishing",
                subtitle: "On-device message, link, and QR warnings",
                isOn: $scamProtection
            )
            divider
            protectionToggle(
                icon: "doc.badge.gearshape",
                title: "Dangerous Files",
                subtitle: "File-type checks and isolated preview decisions",
                isOn: $dangerousFileProtection
            )
            divider
            protectionToggle(
                icon: "person.3.sequence.fill",
                title: "Communities",
                subtitle: "Spam, harassment, farming, and child-safety signals",
                isOn: $communityProtection
            )
            divider
            protectionToggle(
                icon: "storefront.fill",
                title: "OneWay Shops",
                subtitle: "Seller, complaint, image, and chargeback signals",
                isOn: $shopProtection
            )
        }
        .background(cardBackground)
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Encryption stays intact", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Private message content is analyzed on this device. OneWay servers receive privacy-preserving security events, not decrypted conversations. Suspicious content is submitted only when a user chooses to report it.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(cardBackground)
    }

    private var lockdownButton: some View {
        Button {
            isLockdownPresented = true
        } label: {
            Label("Lock Down My Account", systemImage: "lock.trianglebadge.exclamationmark.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    private func protectionToggle(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.primaryBlue)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(16)
    }

    private func statusMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var divider: some View {
        Divider().overlay(Theme.divider).padding(.leading, 62)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.divider, lineWidth: 1)
            )
    }
}

extension Notification.Name {
    static let oneWaySentinelLockdownRequested = Notification.Name("oneWaySentinelLockdownRequested")
}

#Preview {
    NavigationStack {
        SentinelSecurityCenterView()
    }
}
