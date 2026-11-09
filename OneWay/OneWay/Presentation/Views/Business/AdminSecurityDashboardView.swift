import SwiftUI

#if DEBUG
struct AdminSecurityDashboardView: View {
    @StateObject private var viewModel = AdminSecurityDashboardViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if viewModel.isLoading && viewModel.snapshot == nil {
                    loadingCard
                } else if let snapshot = viewModel.snapshot {
                    encryptionSection(snapshot.privacy)
                    auditSection(snapshot.audit, events: snapshot.recentAudit)
                    securityChecksSection(snapshot.security)
                    oneWayBankSection(snapshot.security)
                } else {
                    failureCard
                }

                if let message = viewModel.errorMessage, viewModel.snapshot != nil {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                }
            }
            .padding(16)
            .safeAreaPadding(.bottom, 96)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Security & Privacy")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        OneWayResolvedLabel("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoading)
            }
        }
        .refreshable { await viewModel.refresh() }
        .task { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            OneWayResolvedLabel("Admin only", systemImage: "lock.shield.fill")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.accentGold)
            Text("Security & Privacy")
                .font(.largeTitle.weight(.heavy))
            Text("Redacted health summaries for encryption, audit logs, security checks, and dormant OneWay Bank readiness.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var loadingCard: some View {
        statusPanel(title: "Loading protected status", icon: "shield.lefthalf.filled") {
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking redacted admin summaries...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var failureCard: some View {
        statusPanel(title: "Needs attention", icon: "exclamationmark.triangle.fill") {
            Text(viewModel.errorMessage ?? "We could not load this dashboard right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try again") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func encryptionSection(_ privacy: AdminPrivacyStatus) -> some View {
        statusPanel(title: "Encryption", icon: "lock.fill") {
            statusRow("Status", value: privacy.encryption.enabled ? "Protected" : "Disabled", tone: privacy.encryption.enabled ? .good : .warning)
            statusRow("Current key", value: shortID(privacy.encryption.currentKeyId), tone: .neutral)
            statusRow("Key count", value: "\(privacy.encryption.availableKeyCount ?? 0)", tone: (privacy.encryption.availableKeyCount ?? 0) > 0 ? .good : .warning)
            statusRow("Hash key", value: privacy.encryption.hashKeyConfigured ? "Configured" : "Needs attention", tone: privacy.encryption.hashKeyConfigured ? .good : .warning)
            statusRow("Legacy plaintext", value: "\(privacy.sensitiveData.legacyPlaintextCount)", tone: privacy.sensitiveData.legacyPlaintextCount == 0 ? .good : .warning)
        }
    }

    private func auditSection(_ audit: AdminAuditStatus, events: [AdminAuditEvent]) -> some View {
        statusPanel(title: "Audit Log", icon: "checklist.shield") {
            statusRow("Chain", value: audit.verification.ok ? "Protected" : "Check failed", tone: audit.verification.ok ? .good : .bad)
            statusRow("Events checked", value: "\(audit.verification.checked)", tone: .neutral)
            statusRow("Last verified", value: readableDate(audit.latestEventAt), tone: .neutral)

            if !events.isEmpty {
                Divider().overlay(Theme.divider)
                Text("Recent redacted events")
                    .font(.subheadline.weight(.semibold))
                ForEach(events.prefix(6)) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.action.replacingOccurrences(of: "_", with: " "))
                            .font(.footnote.weight(.semibold))
                        Text("\(event.actorType) - \(event.resourceType) - \(readableDate(event.createdAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func securityChecksSection(_ security: AdminSecurityStatus) -> some View {
        statusPanel(title: "Security Checks", icon: "waveform.path.ecg.rectangle") {
            checkRunRow("Audit check", run: security.latestAuditVerification)
            checkRunRow("Privacy check", run: security.latestPrivacyDiagnostics)
            checkRunRow("Secret scan", run: security.latestSecretScan)

            Divider().overlay(Theme.divider)
            if let alert = security.latestAlerts.first {
                statusRow("Latest alert", value: severityLabel(alert.severity), tone: tone(forSeverity: alert.severity))
                Text(alert.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                statusRow("Latest alert", value: "Protected", tone: .good)
            }
        }
    }

    private func oneWayBankSection(_ security: AdminSecurityStatus) -> some View {
        let privacyRun = security.latestPrivacyDiagnostics
        let bankEnabled = privacyRun?.details?["oneWayBankEnabled"]?.boolValue ?? false
        let approved = privacyRun?.details?["oneWayBankProductionApproved"]?.boolValue ?? false
        let unsafeEnabled = bankEnabled && !approved

        return statusPanel(title: "OneWay Bank", icon: "building.columns.fill") {
            statusRow("Status", value: bankEnabled ? (approved ? "Protected" : "Needs attention") : "Paused", tone: unsafeEnabled ? .bad : .neutral)
            Text(bankEnabled ? "Bank features appear enabled. Confirm production approval before live money movement." : "OneWay Bank is paused. Storefronts continue using payment links while banking is prepared.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func checkRunRow(_ title: String, run: AdminSecurityCheckRun?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            statusRow(title, value: run.map { label(forStatus: $0.status) } ?? "Disabled", tone: run.map { tone(forStatus: $0.status, severity: $0.severity) } ?? .neutral)
            if let run {
                Text(run.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private func statusPanel<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                OneWayResolvedIcon(systemName: icon)
                    .foregroundStyle(Theme.accentGold)
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            content()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.glassSurface))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private func statusRow(_ title: String, value: String, tone: StatusTone) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color(for: tone))
                .multilineTextAlignment(.trailing)
        }
    }

    private func label(forStatus status: String) -> String {
        switch status.lowercased() {
        case "passed": return "Protected"
        case "warning": return "Needs attention"
        case "failed": return "Check failed"
        default: return "Disabled"
        }
    }

    private func severityLabel(_ severity: String) -> String {
        switch severity.lowercased() {
        case "critical": return "Check failed"
        case "warning": return "Needs attention"
        default: return "Protected"
        }
    }

    private func tone(forStatus status: String, severity: String) -> StatusTone {
        if status.lowercased() == "failed" || severity.lowercased() == "critical" { return .bad }
        if status.lowercased() == "warning" || severity.lowercased() == "warning" { return .warning }
        return .good
    }

    private func tone(forSeverity severity: String) -> StatusTone {
        switch severity.lowercased() {
        case "critical": return .bad
        case "warning": return .warning
        default: return .good
        }
    }

    private func color(for tone: StatusTone) -> Color {
        switch tone {
        case .good: return .green
        case .warning: return Theme.accentGold
        case .bad: return .orange
        case .neutral: return Theme.textPrimary
        }
    }

    private func shortID(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Disabled" }
        return PrivacyLog.shortID(value, visible: 5)
    }

    private func readableDate(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Not run yet" }
        if let date = ISO8601DateFormatter.oneWayAdminFormatter.date(from: value)
            ?? ISO8601DateFormatter.oneWayAdminFallbackFormatter.date(from: value) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return PrivacyLog.redact(value)
    }

    private enum StatusTone {
        case good
        case warning
        case bad
        case neutral
    }
}

private extension ISO8601DateFormatter {
    static let oneWayAdminFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let oneWayAdminFallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
#endif
