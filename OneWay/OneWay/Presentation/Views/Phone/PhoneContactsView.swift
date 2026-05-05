import SwiftUI
import Combine

struct PhoneContactsView: View {
    @ObservedObject var manager: CallManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PhonePanel(
                    title: "OneWay Contacts",
                    subtitle: "Connected friends can be reached instantly over Wi‑Fi or cellular."
                ) {
                    if manager.connectedFriends.isEmpty {
                        PhoneEmptyState(
                            title: "No connected friends",
                            bodyText: "Add or accept friends to place OneWay voice and video calls."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(manager.connectedFriends) { friend in
                                HStack(spacing: 14) {
                                    Circle()
                                        .fill(Color.green.opacity(0.18))
                                        .frame(width: 46, height: 46)
                                        .overlay(
                                            Text(String(friend.displayName.prefix(1)))
                                                .font(.headline.weight(.bold))
                                                .foregroundStyle(.green)
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
                                        Image(systemName: manager.favoriteFriends.contains(friend) ? "star.fill" : "star")
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

                PhonePanel(
                    title: "Imported Contacts",
                    subtitle: "Use device contacts to grow your reachable network."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            Task { await manager.importContacts() }
                        } label: {
                            Label(
                                manager.isImportingContacts ? "Importing…" : "Import from iPhone Contacts",
                                systemImage: "person.crop.circle.badge.plus"
                            )
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.isImportingContacts)

                        if manager.importedContacts.isEmpty {
                            PhoneEmptyState(
                                title: "No imported contacts",
                                bodyText: "Grant contact access to see people you already know."
                            )
                        } else {
                            ForEach(manager.importedContacts) { contact in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(contact.displayName)
                                            .font(.headline)
                                        Text(contact.phoneNumber)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Contacts")
        .refreshable {
            await manager.refreshAll()
        }
    }
}
