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
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    PhoneLightHeader(
                        title: "Voicemail",
                        subtitle: "Your missed calls",
                        symbol: "recordingtape"
                    )

                    Button {
                        manager.stopVoicemail()
                    } label: {
                        Text("Stop")
                            .font(.subheadline.weight(.black))
                            .foregroundStyle(OneWayCallTheme.purple)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(OneWayCallTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                PhonePanel(title: "Inbox", subtitle: "Private voicemail uploads appear here.") {
                    if manager.voicemails.isEmpty {
                        VStack(spacing: 18) {
                            voicemailIllustration
                            PhoneEmptyState(
                                title: "No voicemail",
                                bodyText: "Missed-call voicemails will appear here after they are uploaded."
                            )
                        }
                    } else {
                        VStack(spacing: 12) {
                            ForEach(manager.voicemails) { voicemail in
                                voicemailRow(voicemail)
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

    private var voicemailIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(OneWayCallTheme.lavenderSurface)
                .frame(width: 150, height: 110)
            HStack(spacing: 18) {
                Circle().stroke(OneWayCallTheme.purple, lineWidth: 7).frame(width: 42, height: 42)
                Circle().stroke(OneWayCallTheme.purple.opacity(0.55), lineWidth: 7).frame(width: 42, height: 42)
            }
            Capsule()
                .fill(OneWayCallTheme.purple.opacity(0.20))
                .frame(width: 94, height: 8)
                .offset(y: 36)
        }
        .shadow(color: OneWayCallTheme.purple.opacity(0.14), radius: 24, x: 0, y: 12)
        .frame(maxWidth: .infinity)
    }

    private func voicemailRow(_ voicemail: VoicemailEntry) -> some View {
        HStack(spacing: 14) {
            OneWayResolvedIcon(systemName: voicemail.listened ? "waveform" : "waveform.circle.fill")
                .font(.headline.weight(.black))
                .foregroundStyle(voicemail.listened ? OneWayCallTheme.faint : OneWayCallTheme.purple)
                .frame(width: 46, height: 46)
                .background(OneWayCallTheme.lavenderSurface, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(voicemail.callerId)
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayCallTheme.text)
                Text(formatter.string(from: voicemail.createdAtDate))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayCallTheme.muted)
            }

            Spacer()

            Button {
                Task { await manager.playVoicemail(voicemail) }
            } label: {
                OneWayResolvedIcon(systemName: "play.fill")
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(OneWayCallTheme.purple, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(OneWayCallTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(OneWayCallTheme.border, lineWidth: 1))
    }
}
