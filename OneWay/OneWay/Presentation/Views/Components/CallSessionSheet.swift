import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(LiveKit)
import LiveKit
#endif

struct CallSessionSheet: View {
    let callID: UUID?
    let callType: CallType
    let displayName: String
    let callService: (any CallService)?
    let onEnd: () -> Void

    @State private var statusText: String = "Preparing call…"
    @State private var lastError: String?
    @State private var activeSession: CallSession?
    @State private var connectedAt: Date?
    @State private var now: Date = Date()
    @State private var controlsVisible = false
    @State private var pipOffset: CGSize = .zero
    @State private var hasConnectedHaptic = false

    init(callType: CallType, displayName: String, onEnd: @escaping () -> Void) {
        self.callID = nil
        self.callType = callType
        self.displayName = displayName
        self.callService = nil
        self.onEnd = onEnd
    }

    init(callID: UUID, callType: CallType, displayName: String, callService: any CallService, onEnd: @escaping () -> Void) {
        self.callID = callID
        self.callType = callType
        self.displayName = displayName
        self.callService = callService
        self.onEnd = onEnd
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                callBackground

                liveVideoStage(in: proxy.size)

                VStack(spacing: 0) {
                    headerOverlay
                    Spacer()
                    footerOverlay
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    controlsVisible.toggle()
                }
            }
        }
        .task(id: callID) {
            guard let callID, let callService else { return }
            for await session in callService.observeActiveCalls() {
                guard session.id == callID else { continue }
                let previousState = activeSession?.state
                activeSession = session
                statusText = "Status: \(session.state.rawValue)"
                if session.state == .connected, connectedAt == nil {
                    connectedAt = Date()
                }
                withAnimation(.easeInOut(duration: 0.28)) {
                    controlsVisible = session.state == .connected || session.state == .ringing
                }
                if session.state != previousState {
                    handleStateTransition(session.state)
                }
            }
        }
        .task(id: connectedAt) {
            guard connectedAt != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
            }
        }
        .task {
            guard callService == nil else { return }
            statusText = "LiveKit call service required."
        }
        .preferredColorScheme(.dark)
    }

    private var callBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.03, green: 0.07, blue: 0.16),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.32),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 420
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.1),
                    Color.black.opacity(0.45),
                    Color.black.opacity(0.9)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var headerOverlay: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: 42, height: 5)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(displayName)
                    .font(.system(size: 34, weight: .semibold, design: .default))
                    .foregroundStyle(.white)

                Text(primaryStatusLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))

                if let lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(Color(red: 1.0, green: 0.27, blue: 0.23))
                }
            }
            .multilineTextAlignment(.center)
            .padding(.top, 10)
        }
    }

    private var footerOverlay: some View {
        VStack(spacing: 18) {
            if let session = activeSession, session.state == .ringing, !session.isLocal, let callID, let callService {
                incomingActions(callID: callID, callService: callService)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let callID, let callService, let session = activeSession {
                controls(callID: callID, callService: callService, session: session)
                    .opacity(controlsVisible ? 1 : 0)
                    .offset(y: controlsVisible ? 0 : 16)
                    .animation(.easeInOut(duration: 0.3), value: controlsVisible)
            } else {
                endOnlyButton
            }
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func liveVideoStage(in size: CGSize) -> some View {
        #if canImport(LiveKit)
        if callType == .video, let room = activeLiveKitRoom {
            ZStack(alignment: .topTrailing) {
                if let remoteTrack = firstRemoteVideoTrack(in: room) {
                    VideoTrackView(track: remoteTrack)
                        .transition(.opacity)
                } else {
                    remotePlaceholder
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.15), .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                if let localTrack = room.localParticipant.firstCameraVideoTrack {
                    VideoTrackView(track: localTrack)
                        .frame(width: 132, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.28), radius: 16, y: 12)
                        .offset(pipOffset)
                        .padding(.top, 64)
                        .padding(.trailing, 18)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    pipOffset = value.translation
                                }
                                .onEnded { value in
                                    let snapInset = min(size.width * 0.22, 42)
                                    let targetX = value.translation.width > 0 ? snapInset : -snapInset
                                    let targetY = min(max(value.translation.height, -36), 54)
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                        pipOffset = CGSize(width: targetX, height: targetY)
                                    }
                                }
                        )
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    @ViewBuilder
    private func controls(callID: UUID, callService: any CallService, session: CallSession) -> some View {
        HStack(spacing: 20) {
            premiumCallButton(icon: session.muted ? "mic.slash.fill" : "mic.fill",
                              isActive: !session.muted) {
                Task {
                    do {
                        try await callService.toggleMute(sessionID: callID, isMuted: !session.muted)
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
            }
            if callType == .video {
                premiumCallButton(icon: session.cameraOn ? "video.fill" : "video.slash.fill",
                                  isActive: session.cameraOn) {
                    Task {
                        do {
                            try await callService.toggleCamera(sessionID: callID, isOn: !session.cameraOn)
                        } catch {
                            lastError = error.localizedDescription
                        }
                    }
                }

                premiumCallButton(icon: "camera.rotate.fill", isActive: true) {
                    Task {
                        do {
                            try await callService.switchCamera(sessionID: callID)
                        } catch {
                            lastError = error.localizedDescription
                        }
                    }
                }
            }

            premiumCallButton(icon: session.speakerOn ? "speaker.wave.3.fill" : "speaker.slash.fill",
                              isActive: session.speakerOn) {
                Task {
                    do {
                        try await callService.toggleSpeaker(sessionID: callID, isOn: !session.speakerOn)
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
            }

            premiumCallButton(icon: "phone.down.fill", isDestructive: true) {
                Task {
                    do {
                        try await callService.endCall(sessionID: callID)
                        Haptics.notify(.error)
                        onEnd()
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, y: 14)
    }

    private func incomingActions(callID: UUID, callService: any CallService) -> some View {
        HStack(spacing: 28) {
            actionPill(title: "Decline", systemImage: "phone.down.fill", color: Color(red: 1.0, green: 0.27, blue: 0.23)) {
                Task {
                    try? await callService.declineCall(sessionID: callID)
                    Haptics.notify(.warning)
                    onEnd()
                }
            }

            actionPill(title: "Accept", systemImage: "phone.fill", color: Color(red: 0.19, green: 0.82, blue: 0.35), pulse: true) {
                Task {
                    do {
                        try await callService.answerCall(sessionID: callID)
                        Haptics.notify(.success)
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    private var endOnlyButton: some View {
        Button(role: .destructive) {
            Haptics.notify(.error)
            onEnd()
        } label: {
            Text("End Call")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(red: 1.0, green: 0.27, blue: 0.23))
                .clipShape(Capsule())
        }
    }

    private var remotePlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.07, blue: 0.16),
                    .black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 14) {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 108, height: 108)
                    .overlay {
                        Text(initials(for: displayName))
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }

                Text(callType == .video ? "Waiting for video…" : "Voice call in progress")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private var primaryStatusLine: String {
        if let session = activeSession {
            if let connectedAt, session.state == .connected {
                return formatDuration(now.timeIntervalSince(connectedAt))
            }
            return session.state.rawValue.capitalized
        }
        return statusText
    }

    private func premiumCallButton(icon: String,
                                   isActive: Bool = true,
                                   isDestructive: Bool = false,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(
                            isDestructive
                            ? Color(red: 1.0, green: 0.27, blue: 0.23)
                            : (isActive ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                        )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isDestructive ? 0 : 0.08), lineWidth: 1)
                )
        }
        .buttonStyle(PressScaleButtonStyle())
    }

    private func actionPill(title: String,
                            systemImage: String,
                            color: Color,
                            pulse: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
                    .fontWeight(.semibold)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(color)
            .clipShape(Capsule())
            .shadow(color: color.opacity(0.3), radius: 16, y: 12)
            .scaleEffect(pulse ? 1.02 : 1)
        }
        .buttonStyle(PressScaleButtonStyle())
        .modifier(PulseModifier(isActive: pulse))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    #if canImport(LiveKit)
    private var activeLiveKitRoom: Room? {
        (callService as? LiveKitCallService)?.currentLiveKitRoom()
    }

    private func firstRemoteVideoTrack(in room: Room) -> VideoTrack? {
        room.remoteParticipants.values
            .compactMap { $0.firstCameraVideoTrack ?? $0.firstScreenShareVideoTrack }
            .first
    }
    #endif

    private func initials(for name: String) -> String {
        let words = name.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }
        let value = String(letters)
        return value.isEmpty ? "OW" : value.uppercased()
    }

    private func handleStateTransition(_ state: CallConnectionState) {
        switch state {
        case .connected:
            guard !hasConnectedHaptic else { return }
            hasConnectedHaptic = true
            Haptics.notify(.success)
        case .ended, .failed, .missed:
            Haptics.notify(.warning)
        default:
            break
        }
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct PulseModifier: ViewModifier {
    let isActive: Bool
    @State private var animate = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && animate ? 1.05 : 0.98)
            .animation(
                isActive
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .default,
                value: animate
            )
            .onAppear { animate = true }
    }
}

private enum Haptics {
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(type)
        #endif
    }
}
