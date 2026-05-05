import SwiftUI
import Combine

struct PhoneRecentsView: View {
    @ObservedObject var manager: CallManager

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            if manager.recentCalls.isEmpty {
                PhoneEmptyState(
                    title: "No recent calls",
                    bodyText: "Your completed and missed OneWay calls will appear here."
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(manager.recentCalls) { entry in
                    Button {
                        Task { await manager.redial(entry) }
                    } label: {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(entry.hasVideo ? Color.blue.opacity(0.16) : Color.green.opacity(0.16))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Image(systemName: entry.hasVideo ? "video.fill" : "phone.fill")
                                        .foregroundStyle(entry.hasVideo ? .blue : .green)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.direction == .incoming ? entry.callerId : entry.calleeId)
                                    .font(.headline)
                                    .foregroundStyle(manager.historyColor(for: entry))
                                Text(statusLine(for: entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text(relativeFormatter.localizedString(for: entry.startedAtDate, relativeTo: .now))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if entry.durationSeconds > 0 {
                                    Text(durationString(entry.durationSeconds))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Recents")
        .refreshable {
            await manager.refreshAll()
        }
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
