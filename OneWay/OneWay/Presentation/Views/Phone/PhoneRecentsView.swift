import SwiftUI
import Combine

struct PhoneRecentsView: View {
    @ObservedObject var manager: CallManager
    @State private var selectedFilter = "All"

    private let filters = ["All", "Missed", "Outgoing", "Incoming"]
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var filteredCalls: [CallHistoryEntry] {
        switch selectedFilter {
        case "Missed":
            return manager.recentCalls.filter { $0.status.rawValue.lowercased().contains("missed") || $0.status.rawValue.lowercased().contains("failed") }
        case "Outgoing":
            return manager.recentCalls.filter { $0.direction == .outgoing }
        case "Incoming":
            return manager.recentCalls.filter { $0.direction == .incoming }
        default:
            return manager.recentCalls
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                PhoneLightHeader(
                    title: "Recents",
                    subtitle: "Your recent calls",
                    symbol: "clock.arrow.circlepath",
                    iconSize: 52,
                    symbolFont: .system(size: 21, weight: .black, design: .rounded)
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(filters, id: \.self) { filter in
                            Button {
                                selectedFilter = filter
                            } label: {
                                OneWayChip(title: filter, isSelected: selectedFilter == filter)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                PhonePanel(title: "Call History", subtitle: "Tap a row to redial through OneWay.") {
                    if filteredCalls.isEmpty {
                        PhoneEmptyState(
                            symbol: "clock.arrow.circlepath",
                            title: "No recent calls",
                            bodyText: "Your completed and missed OneWay calls will appear here."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(filteredCalls) { entry in
                                recentRow(entry)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 116)
        }
        .background(OneWayCallTheme.background.ignoresSafeArea())
        .refreshable { await manager.refreshAll() }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func recentRow(_ entry: CallHistoryEntry) -> some View {
        Button {
            Task { await manager.redial(entry) }
        } label: {
            HStack(spacing: 14) {
                OneWayResolvedIcon(systemName: entry.hasVideo ? "video.fill" : "phone.fill")
                    .foregroundStyle(entry.hasVideo ? OneWayCallTheme.purple : .green)
                    .frame(width: 46, height: 46)
                    .background(OneWayCallTheme.lavenderSurface, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.direction == .incoming ? entry.callerId : entry.calleeId)
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayCallTheme.text)
                        .lineLimit(1)
                    Text(statusLine(for: entry))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OneWayCallTheme.muted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(relativeFormatter.localizedString(for: entry.startedAtDate, relativeTo: .now))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OneWayCallTheme.muted)
                    if entry.durationSeconds > 0 {
                        Text(durationString(entry.durationSeconds))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(OneWayCallTheme.faint)
                    }
                }
            }
            .padding(12)
            .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(OneWayCallTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func statusLine(for entry: CallHistoryEntry) -> String {
        let direction = entry.direction == .incoming ? "Incoming" : "Outgoing"
        let mode = entry.hasVideo ? "Video" : "Voice"
        return "\(direction) • \(mode) • \(entry.status.rawValue.capitalized)"
    }

    private func durationString(_ durationSeconds: Int) -> String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
