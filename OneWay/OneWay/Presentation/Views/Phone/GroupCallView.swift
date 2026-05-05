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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if manager.remoteParticipants.isEmpty {
                VStack(spacing: 16) {
                    Text("Waiting for others to join…")
                        .foregroundColor(.white)
                        .font(.title3)

                    ProgressView()
                        .tint(.white)
                }
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
                            .tint(.white)

                        Text("Reconnecting…")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 18)
                } else if overflowParticipantCount > 0 {
                    Text("+\(overflowParticipantCount) more listening")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.top, 18)
                }

                Spacer()

                HStack(spacing: 24) {
                    Button {
                        Task { await manager.toggleMic() }
                    } label: {
                        Image(systemName: manager.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                            .callControlStyle()
                    }

                    Button {
                        Task { await manager.toggleCamera() }
                    } label: {
                        Image(systemName: manager.isCameraEnabled ? "video.fill" : "video.slash.fill")
                            .callControlStyle()
                    }

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
                        Image(systemName: recordingEgressId == nil ? "record.circle" : "stop.circle.fill")
                            .callControlStyle(color: recordingEgressId == nil ? .white : .red)
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
                        Image(systemName: "phone.down.fill")
                            .callControlStyle(color: .red)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 28)
            }
        }
        .task {
            guard manager.currentRoomName != roomName || !manager.isConnected else { return }
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
            Color.gray.opacity(0.2)

            if let track = participant.firstCameraVideoTrack ?? participant.firstScreenShareVideoTrack {
                VideoTrackView(track: track)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 54))
                        .foregroundColor(.white.opacity(0.7))

                    Text("Participant")
                        .foregroundColor(.white)
                }
            }
        }
    }
}

extension Image {
    func callControlStyle(color: Color = .white) -> some View {
        self
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(color)
            .frame(width: 58, height: 58)
            .background(Color.white.opacity(0.14))
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
        Color.black.ignoresSafeArea()
    }
}
#endif
