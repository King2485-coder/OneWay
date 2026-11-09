import SwiftUI
import Combine

#if canImport(LiveKit)
import LiveKit

@MainActor
struct GroupCallView: View {
    @StateObject private var manager = LiveKitManager.shared
    @State private var recordingEgressId: String?
    @State private var connectionError: String?

    let roomName: String
    let userId: String
    let inviteeUserID: String?
    let callerName: String?
    let callUUID: UUID?

    init(
        roomName: String,
        userId: String,
        inviteeUserID: String? = nil,
        callerName: String? = nil,
        callUUID: UUID? = nil
    ) {
        self.roomName = roomName
        self.userId = userId
        self.inviteeUserID = inviteeUserID
        self.callerName = callerName
        self.callUUID = callUUID
    }

    private var visibleParticipants: [RemoteParticipant] {
        Array(manager.remoteParticipants.prefix(4))
    }

    private var overflowParticipantCount: Int {
        max(0, manager.remoteParticipants.count - visibleParticipants.count)
    }

    private var isExternalPSTNRoom: Bool {
        roomName.hasPrefix("pstn-")
    }

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()

            if manager.remoteParticipants.isEmpty {
                VStack(spacing: 16) {
                    OneWayCallLogo(size: 72)
                    Text("Waiting for others to join…")
                        .foregroundColor(OneWayCallTheme.text)
                        .font(.title3.weight(.black))

                    ProgressView()
                        .tint(OneWayCallTheme.purple)
                }
                .padding(28)
                .oneWayCallGlass(cornerRadius: 30)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ],
                        spacing: 10
                    ) {
                        ForEach(visibleParticipants, id: \.sid) { participant in
                            RemoteParticipantTile(participant: participant)
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .clipped()
                        }
                    }
                    .padding()
                }
            }

            VStack {
                if let connectionError {
                    Text(connectionError)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(.top, 18)
                }

                if manager.isReconnecting {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(OneWayCallTheme.purple)

                        Text("Reconnecting…")
                            .foregroundColor(OneWayCallTheme.text)
                            .font(.headline)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(OneWayCallTheme.surface)
                    .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
                    .clipShape(Capsule())
                    .padding(.top, 18)
                } else if overflowParticipantCount > 0 {
                    Text("+\(overflowParticipantCount) more listening")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(OneWayCallTheme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(OneWayCallTheme.surface)
                        .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
                        .clipShape(Capsule())
                        .padding(.top, 18)
                }

                Spacer()

                HStack(spacing: 24) {
                    Button {
                        Task { await manager.toggleMic() }
                    } label: {
                        OneWayResolvedIcon(systemName: manager.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                            .callControlStyle()
                    }

                    if !isExternalPSTNRoom {
                        Button {
                            Task { await manager.toggleCamera() }
                        } label: {
                            OneWayResolvedIcon(systemName: manager.isCameraEnabled ? "video.fill" : "video.slash.fill")
                                .callControlStyle()
                        }
                    }

                    if !isExternalPSTNRoom {
                        Button {
                            Task {
                                if let egressId = recordingEgressId {
                                    try? await RecordingService.shared.stopRecording(egressId: egressId)
                                    recordingEgressId = nil
                                } else if let activeRoom = manager.currentRoomName {
                                    recordingEgressId = try? await RecordingService.shared.startRecording(roomName: activeRoom)
                                }
                            }
                        } label: {
                            OneWayResolvedIcon(systemName: recordingEgressId == nil ? "record.circle" : "stop.circle.fill")
                                .callControlStyle(color: recordingEgressId == nil ? .white : .red)
                        }
                    }

                    Button {
                        Task {
                            if let egressId = recordingEgressId {
                                try? await RecordingService.shared.stopRecording(egressId: egressId)
                                recordingEgressId = nil
                            }

                            if let uuid = callUUID ?? manager.activeCallUUID {
                                CallKitManager.shared.endCall(uuid: uuid)
                            } else {
                                await manager.disconnect()
                            }
                        }
                    } label: {
                        OneWayResolvedIcon(systemName: "phone.down.fill")
                            .callControlStyle(color: .red)
                    }
                }
                .padding()
                .background(OneWayCallTheme.surface)
                .overlay(Capsule().stroke(OneWayCallTheme.border, lineWidth: 1))
                .clipShape(Capsule())
                .padding(.bottom, 28)
            }
        }
        .task {
            if isExternalPSTNRoom {
                return
            }
            guard manager.currentRoomName != roomName || manager.room == nil else { return }
            do {
                try await manager.startCall(
                    roomName: roomName,
                    userId: userId,
                    calleeUserId: inviteeUserID,
                    callerName: callerName,
                    callUUID: callUUID
                )
                connectionError = nil
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }
}

struct RemoteParticipantTile: View {
    let participant: RemoteParticipant

    var body: some View {
        ZStack {
            OneWayCallTheme.lavenderSurface

            if let track = participant.firstCameraVideoTrack ?? participant.firstScreenShareVideoTrack {
                VideoTrackView(track: track)
            } else {
                VStack(spacing: 10) {
                    OneWayResolvedIcon(systemName: "person.crop.circle.fill")
                        .font(.system(size: 54))
                        .foregroundColor(OneWayCallTheme.purple)

                    Text("Participant")
                        .foregroundColor(OneWayCallTheme.text)
                }
            }
        }
    }
}

extension OneWayResolvedIcon {
    func callControlStyle(color: Color = .white) -> some View {
        self
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(color == .white ? OneWayCallTheme.purple : color)
            .frame(width: 58, height: 58)
            .background(OneWayCallTheme.lavenderSurface)
            .overlay(Circle().stroke(OneWayCallTheme.purple.opacity(0.14), lineWidth: 1))
            .clipShape(Circle())
    }
}
#else
@MainActor
struct GroupCallView: View {
    let roomName: String
    let userId: String
    let inviteeUserID: String?
    let callerName: String?
    let callUUID: UUID?

    init(
        roomName: String,
        userId: String,
        inviteeUserID: String? = nil,
        callerName: String? = nil,
        callUUID: UUID? = nil
    ) {
        self.roomName = roomName
        self.userId = userId
        self.inviteeUserID = inviteeUserID
        self.callerName = callerName
        self.callUUID = callUUID
    }

    var body: some View {
        OneWayCallTheme.background.ignoresSafeArea()
    }
}
#endif
