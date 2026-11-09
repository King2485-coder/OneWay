import SwiftUI

struct OneWayPlatformReadinessView: View {
    @StateObject private var viewModel = PlatformReadinessViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero

                if let message = viewModel.errorMessage {
                    statusBanner(message)
                }

                ForEach(viewModel.readiness.groups) { group in
                    capabilityGroupCard(group)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
        }
        .background { SideMenuBackground() }
        .navigationTitle("OneWay Platform")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PlatformCommandRoute.self) { route in
            switch route {
            case .messaging(let group):
                MessagingDetailView(group: group)
            case .calls(let group):
                CallsDetailView(group: group)
            case .privacy(let group):
                PrivacyDetailView(group: group)
            case .business(let group):
                BusinessSitesShopsDetailView(group: group)
            case .cloud(let group):
                CloudDetailView(group: group)
            case .ai(let group):
                AIDetailView(group: group)
            case .workspace(let group):
                WorkspaceDetailView(group: group)
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 62, height: 62)
                        .shadow(color: Theme.backgroundHighlight.opacity(0.55), radius: 20, x: 0, y: 10)

                    OneWayResolvedIcon(systemName: "paperplane.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }

                Spacer()

                readinessGauge
            }

            Text(viewModel.readiness.headline)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(viewModel.readiness.summary)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                privacyPill("Encryption roadmap", "lock.shield.fill")
                privacyPill("Modular APIs", "server.rack")
                privacyPill("AI gated", "sparkles")
            }
        }
        .padding(18)
        .background(platformGlass(cornerRadius: 28))
    }

    private var readinessGauge: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("\(Int(viewModel.readiness.readinessRatio * 100))%")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
            Text("\(viewModel.readiness.completedCount)/\(viewModel.readiness.totalCount) live or beta")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: viewModel.isLoading ? "arrow.triangle.2.circlepath" : "wifi.exclamationmark")
                .foregroundStyle(Theme.accentGold)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(platformGlass(cornerRadius: 18))
    }

    private func capabilityGroupCard(_ group: OneWayPlatformCapabilityGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                OneWayResolvedIcon(systemName: group.icon)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.backgroundHighlight)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.backgroundHighlight.opacity(0.18)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(group.promise)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text("\(group.completedCount)/\(group.totalCount)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.backgroundHighlight.opacity(0.35)))
            }

            VStack(spacing: 10) {
                ForEach(group.capabilities) { item in
                    NavigationLink(value: route(for: item, in: group)) {
                        capabilityRow(item)
                    }
                    .buttonStyle(.plain)
                }
            }

            NavigationLink(value: PlatformCommandRoute.route(for: group)) {
                OneWayResolvedLabel("Open Command Center", systemImage: "arrow.right.circle.fill")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Theme.backgroundHighlight.opacity(0.24)))
            }
            .buttonStyle(.plain)

            if group.title == "Cloud, AI, and Workspace" {
                HStack(spacing: 8) {
                    commandChip("Cloud", "externaldrive.fill", .cloud(group))
                    commandChip("AI", "sparkles", .ai(group))
                    commandChip("Workspace", "person.3.fill", .workspace(group))
                }
            }
        }
        .padding(16)
        .background(platformGlass(cornerRadius: 24))
    }

    private func commandChip(_ title: String, _ icon: String, _ route: PlatformCommandRoute) -> some View {
        NavigationLink(value: route) {
            OneWayResolvedLabel(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(Theme.backgroundHighlight.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    private func route(for item: OneWayPlatformCapability, in group: OneWayPlatformCapabilityGroup) -> PlatformCommandRoute {
        if item.id.hasPrefix("cloud.") { return .cloud(group) }
        if item.id.hasPrefix("ai.") { return .ai(group) }
        if item.id.hasPrefix("workspace.") { return .workspace(group) }
        if item.id.hasPrefix("privacy.") { return .privacy(group) }
        if item.id.hasPrefix("calls.") { return .calls(group) }
        if item.id.hasPrefix("business.") || item.id.hasPrefix("sites.") || item.id.hasPrefix("shops.") { return .business(group) }
        return .messaging(group)
    }

    private func capabilityRow(_ item: OneWayPlatformCapability) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(statusColor(item.status))
                .frame(width: 11, height: 11)
                .padding(.top, 6)
                .shadow(color: statusColor(item.status).opacity(0.7), radius: 8, x: 0, y: 0)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(item.status.label)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(statusColor(item.status))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusColor(item.status).opacity(0.14)))
                }

                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                OneWayResolvedLabel(item.privacyLevel, systemImage: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private func privacyPill(_ title: String, _ icon: String) -> some View {
        OneWayResolvedLabel(title, systemImage: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func platformGlass(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Theme.backgroundHighlight.opacity(0.75), Color.white.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Theme.backgroundHighlight.opacity(0.18), radius: 18, x: 0, y: 10)
    }

    private func statusColor(_ status: OneWayCapabilityStatus) -> Color {
        switch status {
        case .live: return Color.green
        case .beta: return Theme.accentGold
        case .planned: return Theme.backgroundHighlight
        case .needsProvider: return Color.orange
        }
    }
}
