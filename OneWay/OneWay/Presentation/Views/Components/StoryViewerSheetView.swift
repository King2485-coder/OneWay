import SwiftUI

struct StoryViewerSheetView: View {
    let story: StoryItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    mediaView

                    Text(story.authorDisplayName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)

                    if !story.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(story.caption)
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                    }

                    Text("Posted \(RelativeDateTimeFormatter().localizedString(for: story.createdAt, relativeTo: .now))")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
            }
            .background { SideMenuBackground() }
            .navigationTitle("Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var mediaView: some View {
        if let media = story.media {
            switch media.mediaType {
            case .photo:
                if let image = UIImage(data: media.payload) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            case .video:
                TransientVideoPlayerView(videoData: media.payload)
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.glassSurface)
                .frame(height: 180)
                .overlay {
                    Text("Text-only story")
                        .foregroundStyle(Theme.textSecondary)
                }
        }
    }
}
