import SwiftUI
import AVKit

struct RecordingsView: View {
    @State private var recordings: [CallRecording] = []
    @State private var selectedRecordingURL: IdentifiedURL?

    var body: some View {
        NavigationStack {
            List(recordings) { recording in
                Button {
                    if let url = URL(string: recording.fileUrl) {
                        selectedRecordingURL = IdentifiedURL(url: url)
                    }
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
            .sheet(item: $selectedRecordingURL) { item in
                RecordedVideoPlayerView(url: item.url)
            }
        }
    }
}

private struct RecordedVideoPlayerView: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView("Loading video...")
            }
        }
        .onAppear {
            guard player == nil else { return }
            SoundDiagnostics.logAudioPlayRequest(
                filename: url.lastPathComponent,
                soundID: url.absoluteString,
                systemSoundID: nil,
                avAudioPlayerURL: nil,
                avPlayerURL: url.absoluteString,
                category: .mediaPlayback,
                callId: nil,
                sourceFile: #fileID,
                sourceFunction: #function,
                line: #line
            )
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .ignoresSafeArea()
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
