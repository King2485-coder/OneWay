import SwiftUI
import AVKit

struct RecordingsView: View {
    @State private var recordings: [CallRecording] = []
    @State private var selectedURL: URL?

    var body: some View {
        NavigationStack {
            List(recordings) { recording in
                Button {
                    selectedURL = URL(string: recording.fileUrl)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recording.roomName)
                            .font(.headline)

                        Text(recording.createdAt)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Recordings")
            .task {
                recordings = (try? await RecordingService.shared.fetchRecordings()) ?? []
            }
            .sheet(item: $selectedURL) { url in
                VideoPlayer(player: AVPlayer(url: url))
                    .ignoresSafeArea()
            }
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
