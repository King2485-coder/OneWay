import SwiftUI
import Combine
#if canImport(LiveKit)
import LiveKit
#endif

#if canImport(LiveKit)
struct VideoTrackView: UIViewRepresentable {
    let track: VideoTrack?

    func makeUIView(context: Context) -> VideoView {
        let v = VideoView()
        v.contentMode = .scaleAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.track = track
    }
}
#else
struct VideoTrackView: View {
    let track: Any?
    var body: some View { Color.black }
}
#endif
