import SwiftUI
import Combine

struct PhoneFavoritesView: View {
    @ObservedObject var manager: CallManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PhonePanel(
                    title: "Favorites",
                    subtitle: "Your fastest way to reach the people you call most."
                ) {
                    if manager.favoriteFriends.isEmpty {
                        PhoneEmptyState(
                            title: "No favorites yet",
                            bodyText: "Mark a contact as a favorite from Contacts to see it here."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(manager.favoriteFriends) { friend in
                                HStack(spacing: 14) {
                                    Circle()
                                        .fill(Color.blue.opacity(0.18))
                                        .frame(width: 48, height: 48)
                                        .overlay(
                                            Text(String(friend.displayName.prefix(1)))
                                                .font(.headline.weight(.bold))
                                                .foregroundStyle(.blue)
                                        )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(friend.displayName)
                                            .font(.headline)
                                        Text(friend.handle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button {
                                        manager.toggleFavorite(friend)
                                    } label: {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                    }
                                    .buttonStyle(.plain)

                                    PhoneCallActionButton(systemImage: "phone.fill", tint: .green) {
                                        Task { await manager.startVoiceCall(with: friend) }
                                    }

                                    PhoneCallActionButton(systemImage: "video.fill", tint: .blue) {
                                        Task { await manager.startVideoCall(with: friend) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Favorites")
        .refreshable {
            await manager.refreshAll()
        }
    }
}
