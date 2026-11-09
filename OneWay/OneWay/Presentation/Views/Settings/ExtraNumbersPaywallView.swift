import SwiftUI

struct ExtraNumbersPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    let onUnlocked: () -> Void

    @State private var isPurchasing = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)

                Text("Add more OneWay numbers")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("Your first 2 numbers are free. Extra numbers are $7.99/month.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 14) {
                    OneWayResolvedLabel("Separate personal and business calls", systemImage: "person.2.fill")
                    OneWayResolvedLabel("Use different identities for privacy", systemImage: "lock.fill")
                    OneWayResolvedLabel("Creator, business, and support numbers", systemImage: "briefcase.fill")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await purchase() }
                } label: {
                    if isPurchasing {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Text("Unlock Extra Numbers — $7.99/month")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .background(Color.blue)
                .foregroundColor(.white)
                .clipShape(Capsule())
                .disabled(isPurchasing)

                Button {
                    Task { await restore() }
                } label: {
                    Text("Restore Purchase")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .foregroundStyle(.blue)
                .disabled(isPurchasing)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button("Not Now") {
                    dismiss()
                }
                .foregroundStyle(.secondary)

                Text("Cancel anytime.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 24)
            }
            .padding()
        }
        .presentationDetents([.medium, .large])
    }

    private func purchase() async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            try await InAppPurchaseService.shared.purchaseExtraNumbers()
            onUnlocked()
            dismiss()
        } catch InAppPurchaseError.purchaseCancelled {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore() async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            if try await InAppPurchaseService.shared.syncExtraNumbersEntitlement() {
                onUnlocked()
                dismiss()
            } else {
                errorMessage = "No active Extra Numbers subscription was found for this Apple ID."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
