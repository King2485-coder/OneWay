import SwiftUI
import AVKit

struct TransientVideoPlayerView: View {
    let videoData: Data

    @State private var player: AVPlayer?
    @State private var tempURL: URL?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView("Loading video...")
            }
        }
        .onAppear {
            preparePlayerIfNeeded()
        }
        .onDisappear {
            player?.pause()
            player = nil
            cleanup()
        }
    }

    @MainActor
    private func preparePlayerIfNeeded() {
        guard player == nil else { return }
        let directory = FileManager.default.temporaryDirectory
        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")

        do {
            try videoData.write(to: fileURL, options: .atomic)
            tempURL = fileURL
            SoundDiagnostics.logAudioPlayRequest(
                filename: fileURL.lastPathComponent,
                soundID: fileURL.absoluteString,
                systemSoundID: nil,
                avAudioPlayerURL: nil,
                avPlayerURL: fileURL.absoluteString,
                category: .mediaPlayback,
                callId: nil,
                sourceFile: #fileID,
                sourceFunction: #function,
                line: #line
            )
            player = AVPlayer(url: fileURL)
        } catch {
            cleanup()
        }
    }

    private func cleanup() {
        guard let tempURL else { return }
        try? FileManager.default.removeItem(at: tempURL)
        self.tempURL = nil
    }
}
