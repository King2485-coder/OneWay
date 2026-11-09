import SwiftUI
import Combine

struct PhoneFavoritesView: View {
    @ObservedObject var manager: CallManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                PhoneLightHeader(
                    title: "Favorites",
                    subtitle: "Your favorite contacts",
                    symbol: "star.fill"
                )

                PhonePanel(title: "Favorites", subtitle: "Reach your closest OneWay contacts quickly.") {
                    if manager.favoriteFriends.isEmpty {
                        VStack(spacing: 18) {
                            softIllustration(symbol: "star.fill")
                            PhoneEmptyState(
                                title: "No favorites yet",
                                bodyText: "Mark a contact as a favorite from Contacts to see it here."
                            )
                        }
                    } else {
                        VStack(spacing: 12) {
                            ForEach(manager.favoriteFriends) { friend in
                                favoriteRow(friend)
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

    private func favoriteRow(_ friend: FriendConnection) -> some View {
        HStack(spacing: 14) {
            OneWayAvatar(name: friend.displayName, size: 52, verified: true, online: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(friend.displayName)
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayCallTheme.text)
                Text(friend.handle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayCallTheme.muted)
            }

            Spacer()

            Button {
                manager.toggleFavorite(friend)
            } label: {
                OneWayResolvedIcon(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 36, height: 36)
                    .background(OneWayCallTheme.lavenderSurface, in: Circle())
            }
            .buttonStyle(.plain)

            PhoneCallActionButton(systemImage: "phone.fill", tint: .green) {
                Task { await manager.startVoiceCall(with: friend) }
            }

            PhoneCallActionButton(systemImage: "video.fill", tint: OneWayCallTheme.purple) {
                Task { await manager.startVideoCall(with: friend) }
            }
        }
        .padding(12)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(OneWayCallTheme.border, lineWidth: 1))
    }

    private func softIllustration(symbol: String) -> some View {
        OneWayResolvedIcon(systemName: symbol)
            .font(.system(size: 62, weight: .black))
            .foregroundStyle(OneWayCallTheme.purple)
            .frame(width: 122, height: 122)
            .background(OneWayCallTheme.lavenderSurface, in: Circle())
            .shadow(color: OneWayCallTheme.purple.opacity(0.14), radius: 24, x: 0, y: 12)
            .frame(maxWidth: .infinity)
    }
}
