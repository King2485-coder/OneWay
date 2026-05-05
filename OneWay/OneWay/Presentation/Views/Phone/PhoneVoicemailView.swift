import SwiftUI
import Combine

struct PhoneVoicemailView: View {
    @ObservedObject var manager: CallManager

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            if manager.voicemails.isEmpty {
                PhoneEmptyState(
                    title: "No voicemail",
                    bodyText: "Missed-call voicemails will appear here after they are uploaded."
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(manager.voicemails) { voicemail in
                    HStack(spacing: 14) {
                        Circle()
                            .fill(voicemail.listened ? Color.gray.opacity(0.18) : Color.blue.opacity(0.18))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: voicemail.listened ? "waveform" : "waveform.circle.fill")
                                    .foregroundColor(voicemail.listened ? .secondary : .blue)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(voicemail.callerId)
                                .font(.headline)
                            Text(formatter.string(from: voicemail.createdAtDate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task { await manager.playVoicemail(voicemail) }
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Voicemail")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Stop") {
                    manager.stopVoicemail()
                }
            }
        }
        .refreshable {
            await manager.refreshAll()
        }
    }
}
