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
    let routeLabel: String?
    let callService: (any CallService)?
    let onEndRequest: (() async throws -> Void)?
    let onMuteRequest: ((Bool) async throws -> Void)?
    let onSpeakerRequest: ((Bool) async throws -> Void)?
    let onEnd: () -> Void

    @State private var statusText: String
    @State private var lastError: String?
    @State private var activeSession: CallSession?
    @State private var connectedAt: Date?
    @State private var now: Date = Date()
    @State private var controlsVisible = false
    @State private var pipOffset: CGSize = .zero
    @State private var hasConnectedHaptic = false
    @State private var liveKitRoomRenderTick = 0
    @State private var selectedPanel: VideoCallPanel?
    @State private var selectedQuality: VideoQualityMode = .auto
    @State private var blurLevel: VideoEffectStrength = .off
    @State private var backgroundReplacement = false
    @State private var lowLightBoost = false
    @State private var portraitEnhance = false
    @State private var autoFraming = false
    @State private var subtleBeauty = false
    @State private var inCallChatDraft = ""
    @State private var showDebugMetrics = false
    @State private var activeReaction: VideoReaction?
    @State private var isEndingCall = false
    @State private var didRequestDismissal = false
    @State private var externalMuted = false
    @State private var externalSpeakerEnabled = false
    @State private var showExternalKeypad = false
    @State private var enteredDigits = ""

    init(
        callType: CallType,
        displayName: String,
        routeLabel: String? = nil,
        statusText: String? = nil,
        onEnd: @escaping () -> Void
    ) {
        self.callID = nil
        self.callType = callType
        self.displayName = displayName
        self.routeLabel = routeLabel
        self.callService = nil
        self.onEndRequest = nil
        self.onMuteRequest = nil
        self.onSpeakerRequest = nil
        self.onEnd = onEnd
        _statusText = State(initialValue: statusText ?? "Preparing call...")
    }

    init(
        callID: UUID,
        callType: CallType,
        displayName: String,
        routeLabel: String? = nil,
        statusText: String? = nil,
        callService: any CallService,
        onEndRequest: (() async throws -> Void)? = nil,
        onMuteRequest: ((Bool) async throws -> Void)? = nil,
        onSpeakerRequest: ((Bool) async throws -> Void)? = nil,
        onEnd: @escaping () -> Void
    ) {
        self.callID = callID
        self.callType = callType
        self.displayName = displayName
        self.routeLabel = routeLabel
        self.callService = callService
        self.onEndRequest = onEndRequest
        self.onMuteRequest = onMuteRequest
        self.onSpeakerRequest = onSpeakerRequest
        self.onEnd = onEnd
        _statusText = State(initialValue: statusText ?? "Preparing call...")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                callBackground

                liveVideoStage(in: proxy.size)

                if let reaction = activeReaction {
                    Text(reaction.symbol)
                        .font(.system(size: 78))
                        .shadow(color: .black.opacity(0.32), radius: 16, y: 10)
                        .transition(.scale(scale: 0.55).combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    headerOverlay
                    Spacer()
                    footerOverlay
                }
                .padding(.horizontal, 18)
                .padding(.top, proxy.safeAreaInsets.top + 8)
                .padding(.bottom, proxy.safeAreaInsets.bottom + 10)
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    controlsVisible.toggle()
                    if !controlsVisible {
                        selectedPanel = nil
                    }
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
                    controlsVisible = session.state == .connecting || session.state == .connected || session.state == .reconnecting
                }
                if session.state != previousState {
                    handleStateTransition(session.state)
                }
            }

        }
        .sheet(isPresented: $showExternalKeypad) {
            externalKeypad
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: callID) {
            #if canImport(LiveKit)
            guard let liveKitCallService = callService as? LiveKitCallService else { return }
            for await _ in liveKitCallService.liveKitRoomUpdates {
                liveKitRoomRenderTick &+= 1
                #if DEBUG
                if let room = liveKitCallService.currentLiveKitRoom() {
                    let remoteVideoCount = room.remoteParticipants.values.reduce(0) { count, participant in
                        count + ((participant.firstCameraVideoTrack ?? participant.firstScreenShareVideoTrack) == nil ? 0 : 1)
                    }
                    print("Video call render tick=\(liveKitRoomRenderTick) room=\(PrivacyLog.shortID(room.name)) remoteParticipants=\(room.remoteParticipants.count) remoteVideoTracks=\(remoteVideoCount)")
                } else {
                    print("Video call render tick=\(liveKitRoomRenderTick) room=nil")
                }
                #endif
            }
            #endif
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
                    Color(red: 0.025, green: 0.03, blue: 0.09),
                    Color(red: 0.06, green: 0.02, blue: 0.13),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.45, green: 0.2, blue: 1.0).opacity(0.42),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 30,
                endRadius: 430
            )

            RadialGradient(
                colors: [
                    Color(red: 0.02, green: 0.52, blue: 1.0).opacity(0.24),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 360
            )

            ForEach(0..<34, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index.isMultiple(of: 5) ? 0.34 : 0.12))
                    .frame(width: CGFloat(index % 3 + 1), height: CGFloat(index % 3 + 1))
                    .offset(x: CGFloat((index * 37) % 340) - 170, y: CGFloat((index * 71) % 680) - 340)
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.04),
                    Color.black.opacity(0.26),
                    Color.black.opacity(0.82)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var headerOverlay: some View {
        VStack(spacing: 12) {
            HStack {
                statusBadge(icon: "phone.fill", title: "OneWay Call")
                Spacer()
                statusBadge(icon: networkIcon, title: networkLabel, tint: networkTint)
            }

            VStack(spacing: 8) {
                OneWayCallLogo(size: 46)

                Text(displayName)
                    .font(.system(size: 32, weight: .semibold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let routeLabel, !routeLabel.isEmpty {
                    Text(routeLabel)
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.72))
                }

                HStack(spacing: 8) {
                    Text(primaryStatusLine)
                    Text("•")
                    Text(selectedQuality.label)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

                if let lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.38))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.42), in: Capsule())
                }
            }
            .multilineTextAlignment(.center)

            #if DEBUG
            if showDebugMetrics {
                qualityDebugOverlay
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            #endif
        }
    }

    private var footerOverlay: some View {
        VStack(spacing: 12) {
            if let callID, let callService, let session = activeSession {
                VStack(spacing: 12) {
                    if let selectedPanel {
                        callPanel(selectedPanel, session: session)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    reactionStrip

                    controls(callID: callID, callService: callService, session: session)
                }
                .opacity(controlsVisible ? 1 : 0)
                .offset(y: controlsVisible ? 0 : 16)
                .animation(.easeInOut(duration: 0.24), value: controlsVisible)
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selectedPanel)
            } else if onEndRequest != nil {
                externalCallControls
            } else {
                endOnlyButton
            }
        }
    }

    @ViewBuilder
    private func liveVideoStage(in size: CGSize) -> some View {
        #if canImport(LiveKit)
        let _ = liveKitRoomRenderTick
        if shouldShowVideoStage, let room = activeLiveKitRoom {
            ZStack(alignment: .topTrailing) {
                if let remoteTrack = firstRemoteVideoTrack(in: room) {
                    VideoTrackView(track: remoteTrack)
                        .transition(.opacity)
                        .overlay(effectOverlay)
                } else {
                    remotePlaceholder
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.12), .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                if let localTrack = room.localParticipant.firstCameraVideoTrack {
                    VideoTrackView(track: localTrack)
                        .frame(width: min(size.width * 0.32, 138), height: min(size.height * 0.22, 196))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.28), radius: 18, y: 12)
                        .offset(pipOffset)
                        .padding(.top, 104)
                        .padding(.trailing, 18)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    pipOffset = value.translation
                                }
                                .onEnded { value in
                                    let snapInset = min(size.width * 0.22, 46)
                                    let targetX = value.translation.width > 0 ? snapInset : -snapInset
                                    let targetY = min(max(value.translation.height, -44), 70)
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                        pipOffset = CGSize(width: targetX, height: targetY)
                                    }
                                }
                        )
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
        } else {
            remotePlaceholder
        }
        #else
        remotePlaceholder
        #endif
    }

    @ViewBuilder
    private func controls(callID: UUID, callService: any CallService, session: CallSession) -> some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    toolbarButton(title: session.muted ? "Unmute" : "Mute",
                                  icon: session.muted ? "mic.slash.fill" : "mic.fill",
                                  isActive: !session.muted) {
                        Task {
                            await runCallAction {
                                try await callService.toggleMute(sessionID: callID, isMuted: !session.muted)
                            }
                        }
                    }

                    toolbarButton(title: session.cameraOn ? "Camera" : "Video",
                                  icon: session.cameraOn ? "video.fill" : "video.slash.fill",
                                  isActive: session.cameraOn) {
                        Task {
                            await runCallAction {
                                try await callService.toggleCamera(sessionID: callID, isOn: !session.cameraOn)
                            }
                        }
                    }

                    toolbarButton(title: "Flip", icon: "camera.rotate.fill", isActive: session.cameraOn) {
                        Task {
                            await runCallAction {
                                try await callService.switchCamera(sessionID: callID)
                            }
                        }
                    }
                    .disabled(!session.cameraOn)
                    .opacity(session.cameraOn ? 1 : 0.52)

                    toolbarButton(title: "People", icon: "person.2.fill", isActive: selectedPanel == .participants) {
                        togglePanel(.participants)
                    }

                    toolbarButton(title: session.speakerOn ? "Speaker" : "Audio",
                                  icon: session.speakerOn ? "speaker.wave.3.fill" : "speaker.slash.fill",
                                  isActive: session.speakerOn) {
                        Task {
                            await runCallAction {
                                try await callService.toggleSpeaker(sessionID: callID, isOn: !session.speakerOn)
                            }
                        }
                    }

                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            if onEndRequest == nil {
                toolbarButton(title: isEndingCall ? "Ending" : "End", icon: "phone.down.fill", isDestructive: true) {
                    guard !isEndingCall else { return }
                    isEndingCall = true
                    Task {
                        do {
                            try await callService.endCall(sessionID: callID, reason: .localHangup, source: .inCallButton)
                            Haptics.notify(.error)
                            onEnd()
                        } catch {
                            lastError = error.localizedDescription
                            isEndingCall = false
                        }
                    }
                }
                .disabled(isEndingCall)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.42, green: 0.17, blue: 1.0).opacity(0.28), radius: 26, y: 14)
    }

    @ViewBuilder
    private func callPanel(_ panel: VideoCallPanel, session: CallSession) -> some View {
        switch panel {
        case .effects:
            effectsPanel
        case .share:
            sharePanel
        case .chat:
            chatPanel
        case .participants:
            participantsPanel(session)
        case .more:
            morePanel
        }
    }

    private var effectsPanel: some View {
        panelSurface(title: "Live Effects", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(VideoEffectStrength.allCases, id: \.self) { strength in
                        optionChip(strength.label, selected: blurLevel == strength) {
                            blurLevel = strength
                            Haptics.impact()
                        }
                    }
                }

                optionToggle("Background replacement", subtitle: "Use OneWay-safe virtual scenes.", isOn: $backgroundReplacement)
                optionToggle("Low-light boost", subtitle: "Lift exposure without washing out faces.", isOn: $lowLightBoost)
                optionToggle("Portrait enhance", subtitle: "Keep the speaker crisp in motion.", isOn: $portraitEnhance)
                optionToggle("Auto framing", subtitle: "Center faces during hand-held calls.", isOn: $autoFraming)
                optionToggle("Subtle polish", subtitle: "Light skin smoothing for low bandwidth.", isOn: $subtleBeauty)

            }
        }
    }

    private var sharePanel: some View {
        panelSurface(title: "Share Securely", icon: "rectangle.on.rectangle.angled") {
            VStack(spacing: 10) {
                screenShareRow
                shareRow("Quantum browser", "Blocked on wallet, password, private, and payment pages.", icon: "globe")
                shareRow("OneWay Sites", "Share site previews without exposing builder secrets.", icon: "sparkles.rectangle.stack")
                shareRow("Documents & photos", "Picker handoff keeps files inside OneWay permissions.", icon: "doc.richtext")
            }
        }
    }

    private var chatPanel: some View {
        panelSurface(title: "In-call Chat", icon: "bubble.left.and.bubble.right.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Messages sent here should land in the same conversation history as the call.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.76))

                HStack(spacing: 10) {
                    TextField("Message during call", text: $inCallChatDraft)
                        .textInputAutocapitalization(.sentences)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.09), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))

                    Button {
                        inCallChatDraft = ""
                        Haptics.notify(.success)
                    } label: {
                        OneWayResolvedIcon(systemName: "paperplane.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(oneWayPurpleGradient, in: Circle())
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .disabled(inCallChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(inCallChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                }

            }
        }
    }

    private func participantsPanel(_ session: CallSession) -> some View {
        panelSurface(title: "Participants", icon: "person.2.fill") {
            VStack(spacing: 10) {
                ForEach(participantRows(session), id: \.id) { participant in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(participant.isVideoEnabled ? oneWayPurpleGradient : LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 36, height: 36)
                            .overlay {
                                Text(initials(for: participant.displayName))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(participant.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(participant.subtitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.64))
                        }

                        Spacer()

                        OneWayResolvedIcon(systemName: participant.isMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(participant.isMuted ? Color(red: 1.0, green: 0.42, blue: 0.38) : Color.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private var morePanel: some View {
        panelSurface(title: "Call Quality", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Adaptive quality")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                    ForEach(VideoQualityMode.allCases, id: \.self) { mode in
                        optionChip(mode.label, selected: selectedQuality == mode) {
                            selectedQuality = mode
                            Haptics.impact()
                        }
                    }
                }

                optionToggle("Quality monitor", subtitle: "Debug overlay with latency, packet loss, bitrate, FPS, codec, TURN, and ICE state.", isOn: $showDebugMetrics)
                optionToggle("Prioritize motion", subtitle: "Favor smooth frame pacing when the network dips.", isOn: .constant(true))
                    .disabled(true)

            }
        }
    }

    private var reactionStrip: some View {
        HStack(spacing: 10) {
            ForEach(VideoReaction.presets) { reaction in
                Button {
                    sendReaction(reaction)
                } label: {
                    Text(reaction.symbol)
                        .font(.system(size: 20))
                        .frame(width: 40, height: 38)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(PressScaleButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.24), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
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

    private var externalCallControls: some View {
        VStack(spacing: 22) {
            HStack(spacing: 24) {
                externalControl(
                    title: "Speaker",
                    icon: externalSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                    selected: externalSpeakerEnabled
                ) {
                    let next = !externalSpeakerEnabled
                    externalSpeakerEnabled = next
                    Task {
                        do { try await onSpeakerRequest?(next) }
                        catch { await MainActor.run { externalSpeakerEnabled.toggle(); lastError = error.localizedDescription } }
                    }
                }
                externalControl(title: "Keypad", icon: "circle.grid.3x3.fill") {
                    showExternalKeypad = true
                }
                externalControl(
                    title: "Mute",
                    icon: externalMuted ? "mic.slash.fill" : "mic.fill",
                    selected: externalMuted
                ) {
                    let next = !externalMuted
                    externalMuted = next
                    Task {
                        do { try await onMuteRequest?(next) }
                        catch { await MainActor.run { externalMuted.toggle(); lastError = error.localizedDescription } }
                    }
                }
            }

            HStack(spacing: 24) {
                externalControl(title: "Audio", icon: "airpodsmax") {
                    externalSpeakerEnabled.toggle()
                    Task { try? await onSpeakerRequest?(externalSpeakerEnabled) }
                }
                externalControl(title: "End", icon: "phone.down.fill", destructive: true) {
                    guard !isEndingCall else { return }
                    isEndingCall = true
                    Task {
                        do {
                            try await onEndRequest?()
                            Haptics.notify(.error)
                            onEnd()
                        } catch {
                            await MainActor.run { lastError = error.localizedDescription; isEndingCall = false }
                        }
                    }
                }
                externalControl(title: "More", icon: "ellipsis") { }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    private func externalControl(
        title: String,
        icon: String,
        selected: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(
                        destructive ? Color.red : (selected ? Color(red: 0.46, green: 0.18, blue: 0.95) : Color.white.opacity(0.13)),
                        in: Circle()
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 88)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isEndingCall)
    }

    private var externalKeypad: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(enteredDigits.isEmpty ? "Enter digits" : enteredDigits)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(height: 42)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 14) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"], id: \.self) { digit in
                        Button {
                            enteredDigits.append(digit)
                            Haptics.impact()
                        } label: {
                            Text(digit)
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(Color.white.opacity(0.12), in: Circle())
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .background(Color(red: 0.04, green: 0.01, blue: 0.10).ignoresSafeArea())
            .navigationTitle("OneWay Keypad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showExternalKeypad = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var remotePlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.04, blue: 0.11),
                    Color(red: 0.08, green: 0.02, blue: 0.15),
                    .black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 16) {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 118, height: 118)
                    .overlay {
                        Text(initials(for: displayName))
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .overlay(Circle().stroke(oneWayPurpleGradient, lineWidth: 2))
                    .shadow(color: Color(red: 0.48, green: 0.18, blue: 1.0).opacity(0.36), radius: 28)

                Text(shouldShowVideoStage ? "Waiting for video..." : "Voice call in progress")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.86))

                Text("OneWay will switch to video the moment a camera stream is available.")
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.horizontal, 42)
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

    private var shouldShowVideoStage: Bool {
        if callType == .video || activeSession?.cameraOn == true {
            return true
        }
        #if canImport(LiveKit)
        return liveKitHasRemoteVideo
        #else
        return false
        #endif
    }

    private var networkIcon: String {
        switch activeSession?.state {
        case .waitingForAudioActivation, .joining, .connecting:
            return "lock.shield.fill"
        case .connected:
            return "waveform.path.ecg"
        case .reconnecting:
            return "wifi.exclamationmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return "antenna.radiowaves.left.and.right"
        }
    }

    private var networkLabel: String {
        switch activeSession?.state {
        case .waitingForAudioActivation:
            return "Connecting securely..."
        case .joining, .connecting:
            return "Connecting"
        case .connected:
            return "Live"
        case .reconnecting:
            return "Reconnecting"
        case .failed:
            return "Issue"
        default:
            return "Ready"
        }
    }

    private var networkTint: Color {
        switch activeSession?.state {
        case .waitingForAudioActivation, .joining, .connecting:
            return Color(red: 0.48, green: 0.25, blue: 0.95)
        case .connected:
            return Color.green
        case .reconnecting:
            return Color.orange
        case .failed:
            return Color(red: 1.0, green: 0.34, blue: 0.31)
        default:
            return Color(red: 0.72, green: 0.46, blue: 1.0)
        }
    }

    private var oneWayPurpleGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.72, green: 0.36, blue: 1.0), Color(red: 0.42, green: 0.14, blue: 0.96)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var effectOverlay: some View {
        ZStack {
            if lowLightBoost {
                Color.white.opacity(0.03)
            }
            if portraitEnhance {
                LinearGradient(colors: [.clear, Color.black.opacity(0.08)], startPoint: .center, endPoint: .bottom)
            }
            if backgroundReplacement {
                RadialGradient(colors: [Color(red: 0.48, green: 0.22, blue: 1.0).opacity(0.16), .clear], center: .topTrailing, startRadius: 20, endRadius: 360)
            }
        }
        .allowsHitTesting(false)
    }

    #if DEBUG
    private var qualityDebugOverlay: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Call monitor")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
            Text("State: \(activeSession?.state.rawValue ?? "preparing")")
            Text("Participants: \(participantRows(activeSession).count)")
            Text("Quality: \(selectedQuality.label)")
            Text("Remote video: \(debugRemoteVideoCount)")
            Text("ICE/TURN metrics: pending LiveKit stats hook")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.white.opacity(0.72))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.44), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
    #endif

    private func toolbarButton(title: String,
                               icon: String,
                               isActive: Bool = true,
                               isDestructive: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(
                        Circle()
                            .fill(isDestructive ? Color(red: 1.0, green: 0.24, blue: 0.22) : Color.white.opacity(isActive ? 0.17 : 0.08))
                    )
                    .overlay(
                        Circle()
                            .stroke(isActive ? Color(red: 0.72, green: 0.42, blue: 1.0).opacity(isDestructive ? 0 : 0.72) : Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: isDestructive ? Color.red.opacity(0.28) : Color(red: 0.45, green: 0.16, blue: 1.0).opacity(isActive ? 0.24 : 0), radius: 14, y: 8)

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(isDestructive || isActive ? 0.9 : 0.58))
                    .lineLimit(1)
            }
            .frame(width: 66)
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
                OneWayResolvedIcon(systemName: systemImage)
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

    private func statusBadge(icon: String, title: String, tint: Color = Color(red: 0.74, green: 0.48, blue: 1.0)) -> some View {
        HStack(spacing: 7) {
            OneWayResolvedIcon(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func panelSurface<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                OneWayResolvedLabel(title, systemImage: icon)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    selectedPanel = nil
                } label: {
                    OneWayResolvedIcon(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color(red: 0.42, green: 0.17, blue: 1.0).opacity(0.24), radius: 24, y: 14)
    }

    private func optionChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(selected ? AnyShapeStyle(oneWayPurpleGradient) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(selected ? 0.18 : 0.1), lineWidth: 1))
        }
        .buttonStyle(PressScaleButtonStyle())
    }

    private func optionToggle(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .tint(Color(red: 0.64, green: 0.29, blue: 1.0))
    }

    private func shareRow(_ title: String, _ subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color(red: 0.76, green: 0.49, blue: 1.0))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var screenShareRow: some View {
        HStack(spacing: 12) {
            OneWayBroadcastPicker()
                .frame(width: 36, height: 36)
                .tint(Color(red: 0.76, green: 0.49, blue: 1.0))

            VStack(alignment: .leading, spacing: 3) {
                Text("Entire screen")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text("Tap the broadcast button, then choose Start Broadcast.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func togglePanel(_ panel: VideoCallPanel) {
        Haptics.impact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            selectedPanel = selectedPanel == panel ? nil : panel
            controlsVisible = true
        }
    }

    private func sendReaction(_ reaction: VideoReaction) {
        Haptics.impact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) {
            activeReaction = reaction
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_050_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.24)) {
                    activeReaction = nil
                }
            }
        }
        // TODO: broadcast reactions over the call signaling channel so every participant sees them.
    }

    private func runCallAction(_ action: () async throws -> Void) async {
        do {
            try await action()
            lastError = nil
            Haptics.impact()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func participantRows(_ session: CallSession?) -> [VideoParticipantRow] {
        var rows: [VideoParticipantRow] = [
            VideoParticipantRow(
                id: "local",
                displayName: "You",
                subtitle: "Local device",
                isMuted: session?.muted ?? false,
                isVideoEnabled: session?.cameraOn ?? (callType == .video)
            )
        ]
        if let session {
            rows.append(contentsOf: session.participants.map {
                VideoParticipantRow(
                    id: $0.id.uuidString,
                    displayName: $0.displayName,
                    subtitle: $0.isVideoEnabled ? "Video connected" : "Audio connected",
                    isMuted: $0.isMuted,
                    isVideoEnabled: $0.isVideoEnabled
                )
            })
        }
        if rows.count == 1, activeSession?.state == .connected {
            rows.append(VideoParticipantRow(id: "remote-placeholder", displayName: displayName, subtitle: "Waiting for media stats", isMuted: false, isVideoEnabled: shouldShowVideoStage))
        }
        return rows
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

    private var liveKitHasRemoteVideo: Bool {
        guard let room = activeLiveKitRoom else { return false }
        return firstRemoteVideoTrack(in: room) != nil
    }

    private var debugRemoteVideoCount: Int {
        activeLiveKitRoom?.remoteParticipants.values.reduce(0) { count, participant in
            count + ((participant.firstCameraVideoTrack ?? participant.firstScreenShareVideoTrack) == nil ? 0 : 1)
        } ?? 0
    }

    private func firstRemoteVideoTrack(in room: Room) -> VideoTrack? {
        room.remoteParticipants.values
            .compactMap { $0.firstCameraVideoTrack ?? $0.firstScreenShareVideoTrack }
            .first
    }
    #else
    private var debugRemoteVideoCount: Int { 0 }
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
            dismissFromAuthoritativeSessionState()
        default:
            break
        }
    }

    private func dismissFromAuthoritativeSessionState() {
        guard !didRequestDismissal else { return }
        didRequestDismissal = true
        print(
            "UNIFIED_END_UI_DISMISSED",
            "callId=\(PrivacyLog.shortID(callID?.uuidString))",
            "source=session_state",
            "lifecycleState=\(activeSession?.state.rawValue ?? "nil")",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            onEnd()
        }
    }
}

private enum VideoCallPanel {
    case effects
    case share
    case chat
    case participants
    case more
}

private enum VideoQualityMode: String, CaseIterable {
    case auto
    case p240
    case p360
    case p480
    case p720
    case p1080

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .p240: return "240p"
        case .p360: return "360p"
        case .p480: return "480p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        }
    }
}

private enum VideoEffectStrength: String, CaseIterable {
    case off
    case low
    case medium
    case high

    var label: String {
        switch self {
        case .off: return "Blur off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

private struct VideoReaction: Identifiable, Equatable {
    let id = UUID()
    let symbol: String

    static let presets = [
        VideoReaction(symbol: "👍"),
        VideoReaction(symbol: "❤️"),
        VideoReaction(symbol: "😂"),
        VideoReaction(symbol: "🎉"),
        VideoReaction(symbol: "👏")
    ]
}

private struct VideoParticipantRow: Identifiable {
    let id: String
    let displayName: String
    let subtitle: String
    let isMuted: Bool
    let isVideoEnabled: Bool
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

    static func impact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
    }
}
