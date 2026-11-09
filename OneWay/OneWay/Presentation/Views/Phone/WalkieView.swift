import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum WalkieTheme {
    static let background = LinearGradient(
        colors: [
            Color(hex: 0x03030A),
            Color(hex: 0x080713),
            Color(hex: 0x130B24),
            Color(hex: 0x05040B)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let surface = Color(hex: 0x0B0A14)
    static let elevatedSurface = Color.white.opacity(0.075)
    static let lavenderSurface = Color(hex: 0x211436)
    static let border = Color.white.opacity(0.12)
    static let purple = Color(hex: 0x8E5CFF)
    static let deepPurple = Color(hex: 0x3E197A)
    static let violet = Color(hex: 0xB26CFF)
    static let text = Color.white
    static let muted = Color.white.opacity(0.68)
    static let faint = Color.white.opacity(0.42)
    static let green = Color(hex: 0x34D37B)
    static let cardRadius: CGFloat = 28

    static let purpleGradient = LinearGradient(
        colors: [violet, purple, Color(hex: 0x5D38FF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let glassGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.13),
            Color.white.opacity(0.055),
            Color(hex: 0x160E27).opacity(0.82)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct WalkieView: View {
    @StateObject private var viewModel = WalkieViewModel()
    @StateObject private var joinCoordinator = WalkieJoinCoordinator.shared
    @State private var isPressingTalk = false
    @GestureState private var isTouchingTalk = false
    @State private var showSettings = false
    @State private var showChannels = false
    @State private var showGroupCreator = false
    @State private var showWalkieContacts = false
    @State private var showDirectChirp = false
    @State private var showAddUser = false
    @State private var showChirpProfile = false
    @State private var showFriendRequests = false
    @State private var speakerOn = true
    @State private var voiceBoostOn = true
    @State private var pulse = false
    @AppStorage("OneWay.Walkie.ChirpSoundsOn") private var chirpSoundsOn = true
    @AppStorage("OneWay.Walkie.IncomingChirp") private var incomingChirp = true
    @AppStorage("OneWay.Walkie.TransmitChirp") private var transmitChirp = true
    @AppStorage("OneWay.Walkie.EndChirp") private var endChirp = true
    @AppStorage("OneWay.Walkie.ChirpVolume") private var chirpVolume = 0.72
    @AppStorage("OneWay.Walkie.VibrateOnChirp") private var vibrateOnChirp = true
    @AppStorage("OneWay.Walkie.RespectSilentMode") private var respectSilentMode = true
    @AppStorage("OneWay.Walkie.AudioRoute") private var audioRoute = "Speaker"
    @AppStorage("OneWay.Walkie.SoundTheme") private var soundTheme = "OneWay Classic"

    let onBack: () -> Void
    let onOpenKeypad: () -> Void

    var body: some View {
        return ZStack {
            WalkieTheme.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                    topStatusStrip
                    transmitCard
                    connectFirstCard
                    chirpKeypadSwitcher
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await viewModel.handlePageOpened()
            await viewModel.loadAssignedProfile()
            await viewModel.loadWalkieContacts()
            await viewModel.refreshChannels()
            viewModel.startAutoRefreshChannels()
            pulse = true
        }
        .onAppear {
            if let sessionId = joinCoordinator.pendingSessionId {
                Task { await viewModel.join(sessionId: sessionId) }
                joinCoordinator.clear()
            }
        }
        .onChange(of: joinCoordinator.pendingSessionId) { _, sessionId in
            guard let sessionId else { return }
            Task { await viewModel.join(sessionId: sessionId) }
            joinCoordinator.clear()
        }
        .onDisappear {
            Task { await viewModel.handlePageDismissed() }
        }
        .refreshable {
            await viewModel.loadWalkieContacts()
            await viewModel.refreshChannels()
        }
        .alert(
            "Chirp",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            stationSettings
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showChannels) {
            channelsSheet
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showGroupCreator) {
            groupCreatorSheet
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showWalkieContacts) {
            walkieContactsSheet
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDirectChirp) {
            directChirpSheet
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showFriendRequests) {
            friendRequestsSheet
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAddUser, onDismiss: {
            Task { await viewModel.loadWalkieContacts(showErrors: false) }
        }) {
            AddFriendView(friendService: NetworkFriendService())
        }
        .sheet(isPresented: $showChirpProfile) {
            chirpProfileSheet
                .presentationDetents([.medium])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button(action: onBack) {
                HStack(spacing: 8) {
                    OneWayResolvedIcon(systemName: "chevron.left")
                        .font(.title3.weight(.black))
                    Text("Back")
                        .font(.title3.weight(.black))
                }
                .foregroundStyle(WalkieTheme.purple)
                .padding(.horizontal, 18)
                .frame(minHeight: 54)
                .background(
                    LinearGradient(
                        colors: [Color.white.opacity(0.08), Color(hex: 0x111021).opacity(0.96)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(WalkieTheme.purple.opacity(0.32), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.24), radius: 12, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Chirp")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundStyle(WalkieTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text("Instant. Private. Anywhere.")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(WalkieTheme.muted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                HStack(spacing: 18) {
                    chirpToyShortcut(role: .contacts, title: "Contacts") {
                        showWalkieContacts = true
                    }

                    chirpToyShortcut(
                        role: .notifications,
                        title: "Requests",
                        badge: incomingRequestCount
                    ) {
                        showFriendRequests = true
                    }
                }
            }
        }
    }

    private var topStatusStrip: some View {
        HStack(spacing: 0) {
            Button {
                if viewModel.activeSession != nil {
                    Task { await viewModel.endSession() }
                }
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 18, height: 18)
                        .shadow(color: connectionColor.opacity(0.72), radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connectionLabel)
                            .font(.headline.weight(.black))
                            .foregroundStyle(WalkieTheme.text)
                        Text(viewModel.activeSession == nil ? "Tap to connect" : "Tap to disconnect")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WalkieTheme.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chirp status, \(connectionLabel)")

            Divider().frame(height: 48).overlay(WalkieTheme.border)

            HStack(spacing: 10) {
                OneWayResolvedIcon(systemName: "lock.shield.fill")
                    .font(.title2.weight(.black))
                    .foregroundStyle(WalkieTheme.purple)
                Text("OneWay Walkie")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(WalkieTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 48).overlay(WalkieTheme.border)

            Button {
                showChirpProfile = true
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chirp ID")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(WalkieTheme.faint)
                    Text(viewModel.assignedChirpId)
                        .font(.headline.weight(.black))
                        .foregroundStyle(WalkieTheme.purple)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chirp ID")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(minHeight: 82)
        .background(WalkieTheme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(WalkieTheme.purple.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.30), radius: 18, x: 0, y: 12)
    }

    private var connectFirstCard: some View {
        Button {
            showChannels = true
        } label: {
            HStack(spacing: 16) {
                OneWayResolvedIcon(systemName: viewModel.activeSession == nil ? "person.3.sequence.fill" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(Color.white)
                    .frame(width: 58, height: 58)
                    .background(WalkieTheme.lavenderSurface, in: Circle())
                    .overlay(Circle().stroke(WalkieTheme.purple.opacity(0.38), lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.activeSession == nil ? "Connect First" : "Connected")
                        .font(.title3.weight(.black))
                        .foregroundStyle(WalkieTheme.text)
                    if viewModel.activeSession != nil {
                        Text(channelName)
                            .font(.headline.weight(.black))
                            .foregroundStyle(WalkieTheme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    Text(viewModel.activeSession == nil ? "Choose or open a channel before you start transmitting." : "Private Chirp connection")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WalkieTheme.muted)
                        .lineLimit(2)
                }
                Spacer()
                OneWayResolvedIcon(systemName: "chevron.right")
                    .font(.title2.weight(.black))
                    .foregroundStyle(WalkieTheme.muted)
            }
            .padding(18)
            .chirpDeviceCard(cornerRadius: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.activeSession == nil ? "Open Chirp channel selection" : "Open connected Chirp channel")
    }

    private var chirpKeypadSwitcher: some View {
        HStack(spacing: 14) {
            Button { } label: {
                HStack(spacing: 12) {
                    OneWayResolvedIcon(systemName: "dot.radiowaves.left.and.right")
                    Text("Chirp")
                }
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(WalkieTheme.purple.opacity(0.72), in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                onOpenKeypad()
            } label: {
                HStack(spacing: 12) {
                    OneWayResolvedIcon(systemName: "circle.grid.3x3.fill")
                    Text("Keypad")
                }
                .font(.headline.weight(.black))
                .foregroundStyle(WalkieTheme.muted)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.white.opacity(0.04), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Keypad")
        }
        .padding(10)
        .background(Color(hex: 0x111027).opacity(0.96), in: Capsule())
        .overlay(Capsule().stroke(WalkieTheme.purple.opacity(0.34), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 10)
    }

    private var channelCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .stroke(WalkieTheme.purple.opacity(0.22), lineWidth: 8)
                            .frame(width: 82, height: 82)
                        Circle()
                            .trim(from: 0, to: viewModel.activeSession == nil ? 0.68 : 0.92)
                            .stroke(
                                WalkieTheme.purpleGradient,
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .frame(width: 82, height: 82)
                            .rotationEffect(.degrees(pulse ? 360 : 0))
                            .animation(.linear(duration: 7).repeatForever(autoreverses: false), value: pulse)
                        OneWayResolvedIcon(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(WalkieTheme.text)
                    }

                    Text("\(onlineCount)")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .frame(minWidth: 28, minHeight: 28)
                        .background(WalkieTheme.purple, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .offset(x: 7, y: -7)
                        .accessibilityLabel("\(onlineCount) members online")
                }

                VStack(alignment: .leading, spacing: 7) {
                    Button {
                        showChannels = true
                    } label: {
                        HStack(spacing: 7) {
                            Text(channelName)
                                .font(.title3.weight(.black))
                                .foregroundStyle(WalkieTheme.text)
                                .lineLimit(2)
                                .minimumScaleFactor(0.78)
                                .fixedSize(horizontal: false, vertical: true)
                            OneWayResolvedIcon(systemName: "chevron.down")
                                .font(.caption.weight(.black))
                                .foregroundStyle(WalkieTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Text("\(onlineCount) members online")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(WalkieTheme.green)

                    Text(channelStatusDetail)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(WalkieTheme.muted)
                        .lineLimit(2)
                }
                .layoutPriority(1)
            }

            OpenOrTalkControl(
                isTalkActive: viewModel.state == .talking || viewModel.pushToTalkState == .transmitting,
                isTalkDisabled: isChannelTalkDisabled,
                onOpen: {
                    showChannels = true
                },
                onTalk: {
                    guard !isChannelTalkDisabled else { return }
                    Task {
                        if viewModel.activeSession == nil {
                            await viewModel.startSession()
                        }
                    }
                }
            )

            avatarStrip
        }
        .padding(20)
        .premiumWalkieGlass(cornerRadius: WalkieTheme.cardRadius)
    }

    private var walkieContactsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                OneWayResolvedLabel("Chirp Contacts", systemImage: "person.2.wave.2.fill")
                    .font(.title3.weight(.black))
                    .foregroundStyle(WalkieTheme.text)
                Spacer()
                Button("View") { showWalkieContacts = true }
                    .font(.headline.weight(.black))
                    .foregroundStyle(WalkieTheme.purple)
            }

            walkieContactsActions

            if viewModel.walkieContacts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add people to Chirp")
                        .font(.headline.weight(.black))
                        .foregroundStyle(WalkieTheme.text)
                    Text("Find OneWay users by handle or Chirp ID.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WalkieTheme.muted)
                    HStack {
                        Button("Add OneWay User") { showAddUser = true }
                            .buttonStyle(.borderedProminent)
                            .tint(WalkieTheme.purple)
                        Button("Invite Someone") { showAddUser = true }
                            .buttonStyle(.bordered)
                            .tint(WalkieTheme.purple)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.walkieContacts.prefix(3)) { contact in
                        compactWalkieContactRow(contact)
                    }
                }
            }
        }
        .padding(18)
        .premiumWalkieGlass(cornerRadius: 26)
    }

    private var groupLaunchCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Group Chirp")
                        .font(.title3.weight(.black))
                        .foregroundStyle(WalkieTheme.text)
                    Text("Create private push-to-talk rooms.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WalkieTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                OneWayResolvedIcon(systemName: "arrow.up.right")
                    .font(.title2.weight(.black))
                    .foregroundStyle(WalkieTheme.purple.opacity(0.82))
                    .frame(width: 46, height: 46)
                    .background(WalkieTheme.elevatedSurface, in: Circle())
            }

            Button {
                showGroupCreator = true
            } label: {
                OneWayResolvedLabel("New Group Chirp", systemImage: "plus")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(WalkieTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canStartSession)
            .opacity(viewModel.canStartSession ? 1 : 0.52)
        }
        .padding(18)
        .premiumWalkieGlass(cornerRadius: 26)
    }

    private var signalCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Signal")
                        .font(.headline.weight(.black))
                        .foregroundStyle(WalkieTheme.text)
                    Text(signalLabel)
                        .font(.title2.weight(.black))
                        .foregroundStyle(WalkieTheme.green)
                    Text(signalSubtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WalkieTheme.muted)
                }

                Spacer()

                Menu {
                    ForEach(audioRoutes, id: \.self) { route in
                        Button {
                            audioRoute = route
                        } label: {
                            OneWayResolvedLabel(route, systemImage: audioRouteIcon(route))
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        OneWayResolvedIcon(systemName: audioRouteIcon(audioRoute))
                        Text(audioRoute)
                            .lineLimit(1)
                        OneWayResolvedIcon(systemName: "chevron.down")
                            .font(.caption.weight(.black))
                    }
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(WalkieTheme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(WalkieTheme.elevatedSurface, in: Capsule())
                    .overlay(Capsule().stroke(WalkieTheme.border, lineWidth: 1))
                }
                .accessibilityLabel("Audio route")
            }

            WaveformView(active: isAudioActive, alignment: .leading)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .opacity(isAudioActive ? 1 : 0.48)
        }
        .padding(20)
        .premiumWalkieGlass(cornerRadius: 26)
    }

    private var transmitCard: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, 350)

            ZStack {
                HStack {
                    ChirpSideWave(active: isAudioActive)
                        .frame(width: 70, height: 190)
                    Spacer()
                    ChirpSideWave(active: isAudioActive)
                        .scaleEffect(x: -1, y: 1)
                        .frame(width: 70, height: 190)
                }
                .opacity(0.78)

                talkButton(diameter: diameter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 390)
    }

    private var chirpSetupActions: some View {
        VStack(spacing: 10) {
            Text(chirpSetupMessage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WalkieTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    showWalkieContacts = true
                } label: {
                    OneWayResolvedLabel("Choose Contact", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(WalkieTheme.purple)

                Button {
                    showChannels = true
                } label: {
                    OneWayResolvedLabel("Choose Channel", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(WalkieTheme.purple)
            }
            .font(.caption.weight(.black))

            if viewModel.activeSession == nil,
               viewModel.canStartSession,
               !viewModel.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    Task { await viewModel.startSession() }
                } label: {
                    OneWayResolvedLabel("Connect to Chirp", systemImage: "bolt.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(WalkieTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(WalkieTheme.border, lineWidth: 1))
    }

    private func talkButton(diameter: CGFloat) -> some View {
        return ZStack {
            Image("ChirpMetalBackplate")
                .resizable()
                .scaledToFit()
                .frame(width: diameter, height: diameter)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Image("OneWaySculptedChirp")
                    .resizable()
                    .scaledToFit()
                    .frame(width: diameter * 0.34, height: diameter * 0.34)
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text(primaryTalkLabel)
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(secondaryTalkLabel)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(WalkieTheme.purple)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: diameter * 0.76)
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(isTouchingTalk ? 0.97 : 1)
        .offset(y: isTouchingTalk ? 2 : 0)
        .shadow(color: WalkieTheme.purple.opacity(isTouchingTalk ? 0.28 : 0.08), radius: isTouchingTalk ? 16 : 8)
        .animation(.easeOut(duration: 0.12), value: isTouchingTalk)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isTouchingTalk) { _, touching, _ in
                    touching = true
                }
                .onChanged { _ in
                    guard !isPressingTalk else { return }
                    guard viewModel.activeSession != nil else {
                        if !showChannels { showChannels = true }
                        return
                    }
                    isPressingTalk = true
                    Task {
                        await viewModel.handlePushToTalkDown()
                    }
                }
                .onEnded { _ in
                    guard isPressingTalk else { return }
                    isPressingTalk = false
                    Task {
                        await viewModel.handlePushToTalkUp()
                    }
                }
        )
        // Gesture state resets on release or cancellation, independently of audio startup.
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.65), trigger: isTouchingTalk) { wasTouching, isTouching in
            !wasTouching && isTouching
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.40), trigger: isTouchingTalk) { wasTouching, isTouching in
            wasTouching && !isTouching
        }
        .accessibilityLabel("Press and hold to talk")
    }

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                OneWayResolvedLabel("Recent Activity", systemImage: "clock.arrow.circlepath")
                    .font(.title3.weight(.black))
                    .foregroundStyle(WalkieTheme.text)
                Spacer()
                Button("See all") { }
                    .font(.headline.weight(.black))
                    .foregroundStyle(WalkieTheme.purple)
            }

            if viewModel.walkieContacts.isEmpty {
                    Text("No recent Chirp contacts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WalkieTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(viewModel.walkieContacts.prefix(3)) { contact in
                    HStack(spacing: 12) {
                    contactAvatar(contact)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(contact.displayName)
                            .font(.headline.weight(.black))
                            .foregroundStyle(WalkieTheme.text)
                        Text(contact.chirpId ?? contact.handle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WalkieTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(availabilityText(contact))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WalkieTheme.muted)
                    Button {
                        Task { await viewModel.startSession(with: contact) }
                    } label: {
                        OneWayResolvedIcon(systemName: "mic.fill")
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(WalkieTheme.purple.opacity(0.22), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
                    if contact.id != viewModel.walkieContacts.prefix(3).last?.id {
                    Divider().overlay(WalkieTheme.purple.opacity(0.2))
                }
                }
            }
        }
        .padding(20)
        .premiumWalkieGlass(cornerRadius: 28)
    }

    private var stationSettings: some View {
        NavigationStack {
            ZStack {
                WalkieTheme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Chirp Settings")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(WalkieTheme.text)
                    Toggle("Speaker", isOn: $speakerOn)
                    Toggle("Voice Boost", isOn: $voiceBoostOn)
                    Divider().overlay(WalkieTheme.purple.opacity(0.2))
                    Toggle("Chirp Sounds On", isOn: $chirpSoundsOn)
                    Toggle("Incoming Chirp", isOn: $incomingChirp)
                    Toggle("Transmit Chirp", isOn: $transmitChirp)
                    Toggle("End Chirp", isOn: $endChirp)
                    Toggle("Vibrate on Chirp", isOn: $vibrateOnChirp)
                    Toggle("Respect Silent Mode", isOn: $respectSilentMode)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chirp Volume")
                            .font(.headline.weight(.black))
                        Slider(value: $chirpVolume, in: 0...1)
                    }
                    Picker("Audio Route", selection: $audioRoute) {
                        Text("Speaker").tag("Speaker")
                        Text("Bluetooth").tag("Bluetooth")
                        Text("Automatic").tag("Automatic")
                    }
                    Picker("Sound Theme", selection: $soundTheme) {
                        Text("OneWay Classic").tag("OneWay Classic")
                        Text("Minimal").tag("Minimal")
                        Text("Soft").tag("Soft")
                        Text("Tactical").tag("Tactical")
                        Text("Silent").tag("Silent")
                    }
                    Spacer()
                }
                .tint(WalkieTheme.purple)
                .foregroundStyle(WalkieTheme.text)
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showSettings = false }
                }
            }
        }
    }

    private var channelsSheet: some View {
        NavigationStack {
            ZStack {
                WalkieTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Channels")
                            .font(.largeTitle.weight(.black))
                            .foregroundStyle(WalkieTheme.text)

                        targetConnectCard
                        groupCreatorCard

                        ForEach(viewModel.availableChannels) { channel in
                            HStack {
                                OneWayResolvedIcon(systemName: channel.isGroup == true ? "person.3.sequence.fill" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(WalkieTheme.purple)
                                    .frame(width: 34, height: 34)
                                VStack(alignment: .leading) {
                                    Text(channelDisplayName(channel))
                                        .font(.headline.weight(.black))
                                        .foregroundStyle(WalkieTheme.text)
                                    Text(channelSubtitle(channel))
                                        .foregroundStyle(WalkieTheme.muted)
                                }
                                Spacer()
                                Button("Join") {
                                    Task { await viewModel.join(channel: channel) }
                                    showChannels = false
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(WalkieTheme.purple)
                            }
                            .padding(14)
                            .premiumWalkieGlass(cornerRadius: 18)
                        }
                    }
                    .padding(18)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showChannels = false }
                }
            }
        }
    }

    private var groupCreatorSheet: some View {
        NavigationStack {
            ZStack {
                WalkieTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("New Group Chirp")
                            .font(.largeTitle.weight(.black))
                            .foregroundStyle(WalkieTheme.text)
                        groupCreatorCard
                    }
                    .padding(18)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showGroupCreator = false }
                }
            }
        }
    }

    private var walkieContactsSheet: some View {
        NavigationStack {
            ZStack {
                WalkieTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Chirp Contacts")
                            .font(.largeTitle.weight(.black))
                            .foregroundStyle(WalkieTheme.text)
                        walkieContactsActions
                        directChirpRequestsSection
                        walkieContactSection(title: "Favorites", contacts: viewModel.walkieContacts.filter(\.isFavorite))
                        walkieContactSection(title: "Online", contacts: viewModel.walkieContacts.filter(\.isOnline))
                        walkieContactSection(title: "All Chirp Contacts", contacts: viewModel.walkieContacts)
                        pendingRequestsSection
                        walkieContactSection(title: "Recent Chirp Contacts", contacts: Array(viewModel.walkieContacts.prefix(5)))
                    }
                    .padding(18)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showWalkieContacts = false }
                }
            }
            .task {
                await viewModel.loadWalkieContacts(showErrors: false)
            }
        }
    }

    private var friendRequestsSheet: some View {
        NavigationStack {
            ZStack {
                WalkieTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sheetHeader(
                            title: "Chirp Requests",
                            subtitle: "\(incomingRequestCount) pending incoming"
                        )

                        directChirpRequestsSection
                        pendingRequestsSection
                        walkieContactSection(title: "Accepted", contacts: viewModel.walkieContacts)
                        requestArchiveSection(title: "Declined")
                        requestArchiveSection(title: "Blocked")
                    }
                    .padding(20)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showFriendRequests = false }
                }
            }
            .task {
                await viewModel.loadWalkieContacts(showErrors: false)
            }
        }
    }

    private var chirpProfileSheet: some View {
        NavigationStack {
            ZStack {
                WalkieTheme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("OneWay Chirp ID")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(WalkieTheme.text)
                    Text(viewModel.assignedChirpId)
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(WalkieTheme.purple)
                        .textSelection(.enabled)
                    HStack {
                        ShareLink(item: viewModel.assignedChirpId) {
                            OneWayResolvedLabel("Share Chirp ID", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WalkieTheme.purple)
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = viewModel.assignedChirpId
                            #endif
                        } label: {
                            OneWayResolvedLabel("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .tint(WalkieTheme.purple)
                    }
                    Image(systemName: "qrcode")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(WalkieTheme.text)
                        .frame(maxWidth: .infinity)
                        .padding(30)
                        .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Spacer()
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showChirpProfile = false }
                }
            }
        }
    }

    private var directChirpSheet: some View {
        NavigationStack {
            ZStack {
                WalkieTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sheetHeader(
                            title: "Chirp by ID",
                            subtitle: "Request a private Chirp without becoming friends first."
                        )

                        targetConnectCard

                        if let result = viewModel.directChirpLookupResult {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Available Match")
                                    .font(.headline.weight(.black))
                                    .foregroundStyle(WalkieTheme.text)
                                HStack(spacing: 12) {
                                    Text(initials(for: result.displayName))
                                        .font(.headline.weight(.black))
                                        .foregroundStyle(WalkieTheme.text)
                                        .frame(width: 52, height: 52)
                                        .background(WalkieTheme.elevatedSurface, in: Circle())
                                        .overlay(Circle().stroke(WalkieTheme.purple.opacity(0.35), lineWidth: 1))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.displayName)
                                            .font(.headline.weight(.black))
                                            .foregroundStyle(WalkieTheme.text)
                                        Text([result.handle, result.chirpId].compactMap { $0 }.joined(separator: "  "))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(WalkieTheme.muted)
                                    }
                                    Spacer()
                                }
                                Button {
                                    Task { await viewModel.requestDirectChirp(result.chirpId ?? result.handle ?? "") }
                                } label: {
                                    OneWayResolvedLabel("Request Direct Chirp", systemImage: "paperplane.fill")
                                        .font(.headline.weight(.black))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(WalkieTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .premiumWalkieGlass(cornerRadius: 22)
                        }

                        directChirpRequestsSection
                    }
                    .padding(20)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showDirectChirp = false }
                }
            }
            .task {
                await viewModel.loadWalkieContacts(showErrors: false)
            }
        }
    }

    private var targetConnectCard: some View {
        VStack(spacing: 12) {
            TextField("Chirp name, @OneWayID, Chirp ID, or phone", text: $viewModel.target)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .foregroundStyle(WalkieTheme.text)
                .padding(13)
                .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack {
                Button {
                    Task { await viewModel.lookupDirectChirp(viewModel.target) }
                } label: {
                    if viewModel.isDirectChirpLoading {
                        ProgressView()
                    } else {
                        OneWayResolvedLabel("Lookup", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .tint(WalkieTheme.purple)
                .disabled(viewModel.isDirectChirpLoading)

                Button {
                    Task { await viewModel.startSession() }
                    showChannels = false
                } label: {
                    OneWayResolvedLabel("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(WalkieTheme.purple)
                .disabled(!viewModel.canStartSession)

                Button(role: .destructive) {
                    Task { await viewModel.endSession() }
                } label: {
                    OneWayResolvedLabel("End", systemImage: "phone.down.fill")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.activeSession == nil)
            }
        }
        .padding(16)
        .premiumWalkieGlass(cornerRadius: 22)
    }

    private var walkieContactsActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    showDirectChirp = true
                } label: {
                    OneWayResolvedLabel("Chirp by ID", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(WalkieTheme.purple)

                Button {
                    showAddUser = true
                } label: {
                    OneWayResolvedLabel("Add OneWay User", systemImage: "person.badge.plus")
                }
                .buttonStyle(.bordered)
                .tint(WalkieTheme.purple)

                Button {
                    showAddUser = true
                } label: {
                    OneWayResolvedLabel("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .tint(WalkieTheme.purple)

                Button {
                    showChirpProfile = true
                } label: {
                    OneWayResolvedLabel("Scan Chirp ID", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)
                .tint(WalkieTheme.purple)

                Button {
                    showAddUser = true
                } label: {
                    OneWayResolvedLabel("Invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .tint(WalkieTheme.purple)
            }
        }
    }

    private func walkieContactSection(title: String, contacts: [WalkieContact]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(WalkieTheme.text)
            if contacts.isEmpty {
                Text("No contacts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WalkieTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach(contacts) { contact in
                    fullWalkieContactRow(contact)
                }
            }
        }
    }

    private var pendingRequestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pending Requests")
                .font(.headline.weight(.black))
                .foregroundStyle(WalkieTheme.text)
            requestSubsection(title: "Incoming", requests: incomingPendingRequests)
            requestSubsection(title: "Outgoing", requests: outgoingPendingRequests)
        }
    }

    private var directChirpRequestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Direct Chirp")
                .font(.headline.weight(.black))
                .foregroundStyle(WalkieTheme.text)

            if viewModel.incomingDirectChirpRequests.isEmpty && viewModel.outgoingDirectChirpRequests.isEmpty {
                Text("No Direct Chirp requests yet.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WalkieTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach(viewModel.incomingDirectChirpRequests) { request in
                    directChirpRequestRow(request)
                }
                ForEach(viewModel.outgoingDirectChirpRequests) { request in
                    directChirpRequestRow(request)
                }
            }
        }
    }

    private func directChirpRequestRow(_ request: DirectChirpRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(initials(for: request.displayName))
                    .font(.headline.weight(.black))
                    .foregroundStyle(WalkieTheme.text)
                    .frame(width: 50, height: 50)
                    .background(WalkieTheme.elevatedSurface, in: Circle())
                    .overlay(Circle().stroke(WalkieTheme.purple.opacity(0.32), lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(request.direction == "incoming" ? "Incoming Chirp" : "Outgoing Chirp")
                        .font(.caption.weight(.black))
                        .foregroundStyle(request.direction == "incoming" ? WalkieTheme.green : WalkieTheme.purple)
                    Text(request.displayName)
                        .font(.headline.weight(.black))
                        .foregroundStyle(WalkieTheme.text)
                    Text([request.handle, request.chirpId].compactMap { $0 }.joined(separator: "  "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WalkieTheme.muted)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            if request.direction == "incoming" {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    requestActionButton("Accept", icon: "checkmark", tint: WalkieTheme.green) {
                        Task { await viewModel.acceptDirectChirp(request) }
                    }
                    requestActionButton("Decline", icon: "xmark", tint: WalkieTheme.purple) {
                        Task { await viewModel.declineDirectChirp(request) }
                    }
                    requestActionButton("Ignore", icon: "moon.fill", tint: WalkieTheme.muted) {
                        Task { await viewModel.ignoreDirectChirp(request) }
                    }
                    requestActionButton("Block", icon: "hand.raised.fill", tint: .red) {
                        Task { await viewModel.blockDirectChirp(request) }
                    }
                }
            } else {
                HStack {
                    OneWayResolvedLabel("Pending", systemImage: "clock.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(WalkieTheme.muted)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await viewModel.cancelDirectChirp(request) }
                    } label: {
                        OneWayResolvedLabel("Cancel", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.black))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
        .padding(14)
        .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func requestSubsection(title: String, requests: [FriendConnection]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.black))
                .foregroundStyle(WalkieTheme.muted)
            if requests.isEmpty {
                Text(title == "Incoming" ? "No incoming Chirp requests." : "No outgoing Chirp requests.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WalkieTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach(requests) { friend in
                    chirpRequestRow(friend)
                }
            }
        }
    }

    private func chirpRequestRow(_ friend: FriendConnection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(initials(for: friend.displayName))
                    .font(.headline.weight(.black))
                    .foregroundStyle(WalkieTheme.text)
                    .frame(width: 50, height: 50)
                    .background(WalkieTheme.elevatedSurface, in: Circle())
                    .overlay(Circle().stroke(WalkieTheme.purple.opacity(0.32), lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text(friend.isIncomingRequest ? "Incoming Chirp Request" : "Outgoing Chirp Request")
                        .font(.caption.weight(.black))
                        .foregroundStyle(friend.isIncomingRequest ? WalkieTheme.green : WalkieTheme.purple)
                    Text(friend.displayName)
                        .font(.headline.weight(.black))
                        .foregroundStyle(WalkieTheme.text)
                    Text([friend.handle, friend.chirpID, requestTimeText(friend.createdAt)].compactMap { $0 }.joined(separator: "  "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WalkieTheme.muted)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            if friend.isIncomingRequest {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    requestActionButton("Accept", icon: "checkmark", tint: WalkieTheme.green) {
                        Task { await viewModel.acceptPendingRequest(friend) }
                    }
                    requestActionButton("Deny", icon: "xmark", tint: WalkieTheme.purple) {
                        Task { await viewModel.declinePendingRequest(friend) }
                    }
                    requestActionButton("Ignore", icon: "moon.fill", tint: WalkieTheme.muted) {
                        Task { await viewModel.ignorePendingRequest(friend) }
                    }
                    requestActionButton("Block", icon: "hand.raised.fill", tint: .red) {
                        Task { await viewModel.blockPendingRequest(friend) }
                    }
                }
            } else {
                HStack {
                    OneWayResolvedLabel("Pending", systemImage: "clock.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(WalkieTheme.muted)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await viewModel.cancelPendingRequest(friend) }
                    } label: {
                        OneWayResolvedLabel("Cancel", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.black))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
        .padding(14)
        .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func requestActionButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedLabel(title, systemImage: icon)
                .font(.caption.weight(.black))
                .foregroundStyle(title == "Accept" ? Color(hex: 0x07120C) : WalkieTheme.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(tint.opacity(title == "Accept" ? 1 : 0.2), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(tint.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func compactWalkieContactRow(_ contact: WalkieContact) -> some View {
        HStack(spacing: 12) {
            contactAvatar(contact)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.displayName)
                    .font(.headline.weight(.black))
                    .foregroundStyle(WalkieTheme.text)
                Text([contact.handle, contact.chirpId].compactMap { $0 }.joined(separator: "  "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WalkieTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await viewModel.startSession(with: contact) }
            } label: {
                OneWayResolvedIcon(systemName: "mic.circle.fill")
                    .font(.title2.weight(.black))
                    .foregroundStyle(WalkieTheme.purple)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func fullWalkieContactRow(_ contact: WalkieContact) -> some View {
        HStack(spacing: 12) {
            contactAvatar(contact)
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .font(.headline.weight(.black))
                    .foregroundStyle(WalkieTheme.text)
                Text([contact.handle, contact.chirpId].compactMap { $0 }.joined(separator: "  "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WalkieTheme.muted)
                OneWayResolvedLabel(availabilityText(contact), systemImage: "circle.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(contact.isOnline ? .green : WalkieTheme.muted)
            }
            Spacer()
            Button {
                Task { await viewModel.toggleFavorite(contact) }
            } label: {
                OneWayResolvedIcon(systemName: contact.isFavorite ? "star.fill" : "star")
                    .font(.headline.weight(.black))
                    .foregroundStyle(contact.isFavorite ? .yellow : WalkieTheme.muted)
            }
            .buttonStyle(.plain)
            Button {
                Task { await viewModel.startSession(with: contact) }
                showWalkieContacts = false
            } label: {
                OneWayResolvedIcon(systemName: "mic.circle.fill")
                    .font(.title.weight(.black))
                    .foregroundStyle(WalkieTheme.purple)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button {
                Task { await viewModel.startSession(with: contact) }
            } label: {
                OneWayResolvedLabel("Start Chirp", systemImage: "mic.fill")
            }
            Button {
                Task { await viewModel.toggleFavorite(contact) }
            } label: {
                OneWayResolvedLabel(contact.isFavorite ? "Remove Favorite" : "Add to Favorites", systemImage: "star")
            }
            Button {
                showChirpProfile = true
            } label: {
                OneWayResolvedLabel("View Profile", systemImage: "person.crop.circle")
            }
            Button {
            } label: {
                OneWayResolvedLabel("Mute", systemImage: "speaker.slash")
            }
            Button(role: .destructive) {
            } label: {
                OneWayResolvedLabel("Remove Friend", systemImage: "person.crop.circle.badge.minus")
            }
            Button(role: .destructive) {
            } label: {
                OneWayResolvedLabel("Block", systemImage: "hand.raised.fill")
            }
        }
    }

    private var groupCreatorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite a Crew")
                .font(.headline.weight(.black))
                .foregroundStyle(WalkieTheme.text)
            TextField("Room name", text: $viewModel.groupName)
                .textInputAutocapitalization(.words)
                .foregroundStyle(WalkieTheme.text)
                .padding(13)
                .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            TextField("@king, OW-482-917, phone", text: $viewModel.groupTargetsText, axis: .vertical)
                .lineLimit(2...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .foregroundStyle(WalkieTheme.text)
                .padding(13)
                .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                Task { await viewModel.startGroupSession() }
                showGroupCreator = false
                showChannels = false
            } label: {
                OneWayResolvedLabel("Start Group Chirp", systemImage: "person.3.sequence.fill")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(WalkieTheme.purpleGradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canStartGroupSession)
            .opacity(viewModel.canStartGroupSession ? 1 : 0.55)
        }
        .padding(16)
        .premiumWalkieGlass(cornerRadius: 22)
    }

    private func memberAvatar(_ member: WalkieMember) -> some View {
        ZStack(alignment: .bottomTrailing) {
            OneWayResolvedIcon(systemName: member.symbol)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(WalkieTheme.text)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(colors: [WalkieTheme.purple, Color.green.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .overlay(Circle().stroke(member.color, lineWidth: 3))
                .scaleEffect(viewModel.state == .talking && member.name == "Rocky" ? 1.08 : 1)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: viewModel.state == .talking)
            Circle()
                .fill(member.color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(WalkieTheme.surface, lineWidth: 2))
        }
    }

    private var emptyAvatar: some View {
        OneWayResolvedIcon(systemName: "person.badge.plus")
            .font(.system(size: 28, weight: .black))
            .foregroundStyle(WalkieTheme.text)
            .frame(width: 58, height: 58)
            .background(WalkieTheme.elevatedSurface, in: Circle())
            .overlay(Circle().stroke(WalkieTheme.purple, lineWidth: 2))
    }

    private func contactAvatar(_ contact: WalkieContact) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Text(initials(for: contact.displayName))
                .font(.headline.weight(.black))
                .foregroundStyle(WalkieTheme.text)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(
                        colors: [WalkieTheme.purple.opacity(0.86), Color.green.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
                .overlay(Circle().stroke(contact.isOnline ? Color.green : WalkieTheme.muted.opacity(0.65), lineWidth: 3))
                .shadow(color: WalkieTheme.purple.opacity(0.28), radius: 10)
            if contact.isFavorite {
                OneWayResolvedIcon(systemName: "star.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.yellow)
                    .padding(4)
                    .background(WalkieTheme.surface, in: Circle())
                    .offset(x: 1, y: 1)
            } else {
                Circle()
                    .fill(contact.isOnline ? Color.green : WalkieTheme.muted)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(WalkieTheme.surface, lineWidth: 2))
            }
        }
        .accessibilityLabel(contact.displayName)
    }

    private func participantAvatar(_ participant: WalkieParticipant) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Text(initials(for: participant.displayName))
                .font(.headline.weight(.black))
                .foregroundStyle(WalkieTheme.text)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(colors: [WalkieTheme.purple.opacity(0.9), Color.green.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .overlay(Circle().stroke(Color.green, lineWidth: 3))
                .shadow(color: WalkieTheme.purple.opacity(0.35), radius: 12)
            Circle()
                .fill(Color.green)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(WalkieTheme.surface, lineWidth: 2))
        }
        .accessibilityLabel(participant.displayName)
    }

    private func activityAvatar(_ symbol: String) -> some View {
        OneWayResolvedIcon(systemName: symbol)
            .font(.title.weight(.black))
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(Color.green.opacity(0.9), in: Circle())
            .overlay(Circle().stroke(Color.green, lineWidth: 2))
    }

    private func availabilityText(_ contact: WalkieContact) -> String {
        switch contact.availability {
        case "busy":
            return "Busy"
        case "doNotDisturb":
            return "Do Not Disturb"
        case "offline":
            return "Offline"
        case "emergencyOnly":
            return "Emergency Only"
        default:
            return contact.isOnline ? "Online" : "Available"
        }
    }

    private func statusPill(title: String, value: String, icon: String, isOn: Bool) -> some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .foregroundStyle(WalkieTheme.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(WalkieTheme.text)
                Text(value)
                    .font(.caption.weight(.black))
                    .foregroundStyle(isOn ? .green : WalkieTheme.faint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(WalkieTheme.elevatedSurface, in: Capsule())
        .overlay(Capsule().stroke(WalkieTheme.purple.opacity(0.28), lineWidth: 1))
    }

    private func headerActionButton(icon: String, title: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    OneWayResolvedIcon(systemName: icon)
                        .font(.headline.weight(.black))
                        .foregroundStyle(WalkieTheme.text)
                        .frame(width: 52, height: 52)
                        .background(WalkieTheme.elevatedSurface, in: Circle())
                        .overlay(Circle().stroke(WalkieTheme.border, lineWidth: 1))
                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .padding(2)
                            .background(Color.red, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
                Text(title)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(WalkieTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var avatarStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if let participants = viewModel.activeSession?.participants, !participants.isEmpty {
                    ForEach(participants) { participant in
                        participantAvatar(participant)
                    }
                } else if !viewModel.walkieContacts.isEmpty {
                    ForEach(viewModel.walkieContacts.prefix(12)) { contact in
                        Button {
                            Task { await viewModel.startSession(with: contact) }
                        } label: {
                            contactAvatar(contact)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    emptyAvatar
                }

                Button {
                    showAddUser = true
                } label: {
                    VStack(spacing: 4) {
                        OneWayResolvedIcon(systemName: "plus")
                            .font(.title3.weight(.black))
                        Text("Add")
                            .font(.caption2.weight(.black))
                    }
                    .foregroundStyle(WalkieTheme.text)
                    .frame(width: 58, height: 58)
                    .background(WalkieTheme.elevatedSurface, in: Circle())
                    .overlay(Circle().stroke(WalkieTheme.purple.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add OneWay User")
            }
        }
    }

    private func sheetHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.black))
                .foregroundStyle(WalkieTheme.text)
            Text(subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WalkieTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requestArchiveSection(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(WalkieTheme.text)
            Text("No \(title.lowercased()) requests.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WalkieTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(WalkieTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: icon)
                .font(.title2.weight(.black))
                .foregroundStyle(WalkieTheme.text)
                .frame(width: 64, height: 64)
                .background(WalkieTheme.surface, in: Circle())
                .overlay(Circle().stroke(WalkieTheme.purple.opacity(0.68), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func chirpToyShortcut(role: OneWayIconRole, title: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    OneWayPhysicalIcon(
                        role: role,
                        size: 60,
                        container: .none,
                        accessibilityLabel: title,
                        glowIntensity: 0.06
                    )
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)

                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .frame(minWidth: 19, minHeight: 19)
                            .padding(2)
                            .background(Color.red, in: Circle())
                            .offset(x: 3, y: -3)
                    }
                }

                Text(title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(WalkieTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .frame(width: 78)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Contacts" ? "Open Chirp contacts" : "Open Chirp requests")
    }

    private func channelDisplayName(_ channel: WalkieChannel) -> String {
        if channel.isGroup == true {
            let groupName = channel.groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !groupName.isEmpty { return groupName }
        }
        return [
            channel.fromWalkieName,
            channel.fromDisplayName,
            channel.target,
            channel.fromOneWayId,
            channel.fromNumber,
        ]
        .compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        .first ?? "OneWay Chirp"
    }

    private func channelSubtitle(_ channel: WalkieChannel) -> String {
        if channel.isGroup == true {
            return "\(channel.participantCount ?? channel.participants?.count ?? 0) members - \(channel.status.capitalized)"
        }
        return channel.status.capitalized
    }

    private func initials(for value: String) -> String {
        let parts = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        let result = String(letters).uppercased()
        return result.isEmpty ? "OW" : result
    }

    private var onlineCount: Int {
        let onlineContacts = viewModel.walkieContacts.filter(\.isOnline).count
        return max(onlineContacts, viewModel.activeSession?.participants?.count ?? 0)
    }

    private var channelName: String {
        let groupName = viewModel.activeSession?.groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !groupName.isEmpty { return groupName }
        let target = viewModel.activeSession?.target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return target.isEmpty ? "Chirp Contacts" : target
    }

    private var connectionLabel: String {
        switch viewModel.state {
        case .unavailable, .error:
            return "Offline"
        case .connecting:
            return "Connecting"
        default:
            return viewModel.activeSession == nil ? "Ready" : "Connected"
        }
    }

    private var connectionColor: Color {
        switch viewModel.state {
        case .unavailable, .error:
            return .red
        case .connecting:
            return .orange
        default:
            return WalkieTheme.green
        }
    }

    private var signalLabel: String {
        switch viewModel.state {
        case .unavailable, .error:
            return "Offline"
        case .connecting:
            return "Good"
        default:
            return "Strong"
        }
    }

    private var signalSubtitle: String {
        switch viewModel.state {
        case .unavailable, .error:
            return "Connection unavailable"
        case .connecting:
            return "Establishing audio"
        default:
            return "Excellent connection"
        }
    }

    private var isAudioActive: Bool {
        viewModel.state == .talking || viewModel.state == .connecting || viewModel.pushToTalkState == .receiving
    }

    private var talkText: String {
        switch viewModel.state {
        case .connecting:
            return "Connecting"
        case .talking:
            return "Release to Send"
        case .listening:
            return "Hold to Talk"
        default:
            return viewModel.activeSession == nil ? "Connect First" : "Hold to Talk"
        }
    }

    private var talkInstruction: String {
        switch viewModel.state {
        case .talking:
            return "Release to Send"
        case .listening:
            return "Hold to Talk"
        case .connecting:
            return "Securing the channel"
        default:
            return "Open a channel to start transmitting"
        }
    }

    private var chirpSetupMessage: String {
        if viewModel.state == .unavailable {
            return "Chirp is unavailable during an active OneWay call."
        }
        if viewModel.activeSession == nil {
            return "Choose a contact or channel before pressing to talk."
        }
        return "Chirp is getting the audio channel ready."
    }

    private var pushToTalkBadge: String {
        switch viewModel.pushToTalkState {
        case .requestingChannel:
            return "REQUESTING"
        case .requestingPermission:
            return "MIC"
        case .connectingMedia:
            return "LINKING"
        case .publishing:
            return "SENDING"
        case .ready:
            return "READY"
        case .readyToTransmit:
            return "READY"
        case .transmitting:
            return "LIVE"
        case .stopping:
            return "STOPPING"
        case .receiving:
            return "INCOMING"
        case .releasing:
            return "ENDING"
        case .reconnecting:
            return "RECONNECT"
        case .unavailable:
            return "OFFLINE"
        case .failed:
            return "CHECK"
        case .idle:
            return viewModel.activeSession == nil ? "OPEN" : "READY"
        }
    }

    private var primaryTalkLabel: String {
        if viewModel.activeSession == nil { return "PRESS & HOLD" }
        switch viewModel.pushToTalkState {
        case .transmitting:
            return "TRANSMITTING"
        case .receiving:
            return "RECEIVING"
        case .requestingChannel, .requestingPermission, .connectingMedia, .publishing, .reconnecting:
            return "CONNECTING"
        case .failed, .unavailable:
            return "SELECT A CHANNEL"
        default:
            return viewModel.state == .talking ? "TRANSMITTING" : "PRESS & HOLD"
        }
    }

    private var secondaryTalkLabel: String {
        if viewModel.activeSession == nil { return "TO TALK" }
        switch viewModel.pushToTalkState {
        case .transmitting:
            return "LIVE"
        case .receiving:
            return "INCOMING"
        case .failed:
            return "TRY AGAIN"
        case .unavailable:
            return "OFFLINE"
        default:
            return "TO TALK"
        }
    }

    private var channelStatusDetail: String {
        switch viewModel.state {
        case .connecting:
            return "Connecting audio"
        case .listening:
            return "Connected - ready to transmit"
        case .talking:
            return "You are transmitting now"
        case .unavailable, .error:
            return "Channel unavailable"
        default:
            return "Last activity just now"
        }
    }

    private var isChannelTalkDisabled: Bool {
        switch viewModel.state {
        case .unavailable, .error:
            return true
        default:
            return false
        }
    }

    private var channelActionTitle: String {
        switch viewModel.state {
        case .unavailable, .error:
            return "Offline"
        case .connecting:
            return "Busy"
        case .listening, .talking:
            return "Connected"
        default:
            return "Open"
        }
    }

    private var channelActionBackground: AnyShapeStyle {
        switch viewModel.state {
        case .unavailable, .error:
            return AnyShapeStyle(Color.white.opacity(0.12))
        case .connecting:
            return AnyShapeStyle(Color.orange.opacity(0.72))
        case .listening, .talking:
            return AnyShapeStyle(WalkieTheme.green.opacity(0.82))
        default:
            return AnyShapeStyle(WalkieTheme.purpleGradient)
        }
    }

    private var incomingRequestCount: Int {
        viewModel.pendingRequests.filter(\.isIncomingRequest).count
    }

    private var incomingPendingRequests: [FriendConnection] {
        viewModel.pendingRequests.filter(\.isIncomingRequest)
    }

    private var outgoingPendingRequests: [FriendConnection] {
        viewModel.pendingRequests.filter { !$0.isIncomingRequest }
    }

    private var audioRoutes: [String] {
        ["Phone", "Speaker", "Bluetooth", "AirPods", "Vehicle"]
    }

    private func audioRouteIcon(_ route: String) -> String {
        switch route {
        case "Phone":
            return "iphone"
        case "Bluetooth":
            return "dot.radiowaves.left.and.right"
        case "AirPods":
            return "airpodspro"
        case "Vehicle":
            return "car.fill"
        default:
            return speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill"
        }
    }

    private func requestTimeText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        let date = formatter.date(from: raw) ?? fallbackFormatter.date(from: raw)
        guard let date else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return relative.localizedString(for: date, relativeTo: Date())
    }

}

private extension View {
    func premiumWalkieGlass(cornerRadius: CGFloat = WalkieTheme.cardRadius) -> some View {
        self
            .background(.ultraThinMaterial.opacity(0.18), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(WalkieTheme.glassGradient, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                WalkieTheme.purple.opacity(0.3),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.34), radius: 22, x: 0, y: 16)
            .shadow(color: WalkieTheme.deepPurple.opacity(0.20), radius: 28, x: 0, y: 10)
    }
}

private struct OpenOrTalkControl: View {
    var isTalkActive: Bool = false
    var isTalkDisabled: Bool = false
    let onOpen: () -> Void
    let onTalk: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(title: "Open", icon: "bubble.left.and.bubble.right.fill", accessibilityLabel: "Open", action: onOpen)

            Rectangle()
                .fill(WalkieTheme.purple.opacity(0.34))
                .frame(width: 1, height: 30)

            segment(
                title: "Talk",
                icon: isTalkActive ? "waveform.circle.fill" : "mic.fill",
                accessibilityLabel: "Talk",
                isActive: isTalkActive,
                isDisabled: isTalkDisabled,
                action: onTalk
            )
        }
        .frame(minHeight: 48)
        .background(Color(hex: 0x09091A).opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(WalkieTheme.purple.opacity(0.48), lineWidth: 1))
        .shadow(color: WalkieTheme.purple.opacity(0.22), radius: 16, x: 0, y: 8)
    }

    private func segment(
        title: String,
        icon: String,
        accessibilityLabel: String,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.headline.weight(.black))
                Text(title)
                    .font(.headline.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
            }
            .foregroundStyle(isActive ? WalkieTheme.green : WalkieTheme.text)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(OpenOrTalkSegmentStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.48 : 1)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ChirpSideWave: View {
    let active: Bool

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .trim(from: 0.08, to: 0.42)
                    .stroke(
                        WalkieTheme.purple.opacity(active ? 0.82 - Double(index) * 0.16 : 0.46 - Double(index) * 0.08),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .frame(width: CGFloat(56 + index * 26), height: CGFloat(170 + index * 22))
                    .offset(x: CGFloat(index * 9))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ChirpDeviceCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color(hex: 0x141124).opacity(0.95),
                        Color(hex: 0x090913).opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(WalkieTheme.purple.opacity(0.24), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.30), radius: 18, x: 0, y: 12)
    }
}

private extension View {
    func chirpDeviceCard(cornerRadius: CGFloat) -> some View {
        modifier(ChirpDeviceCardModifier(cornerRadius: cornerRadius))
    }
}

private struct OpenOrTalkSegmentStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? WalkieTheme.purple.opacity(0.18) : Color.clear)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct WalkieMember: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
    let symbol: String
}

private struct WalkieRecent: Identifiable {
    let id = UUID()
    let name: String
    let message: String
    let time: String
    let symbol: String
}

private struct WaveformView: View {
    let active: Bool
    let alignment: HorizontalAlignment
    private let bars: [CGFloat] = [0.18, 0.3, 0.5, 0.72, 0.95, 0.62, 0.44, 0.28, 0.2]

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [WalkieTheme.purple.opacity(0.25), WalkieTheme.purple, Color(hex: 0xD45CFF)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 4, height: 92 * (active ? animatedHeight(value, index: index) : value * 0.45))
                    .shadow(color: WalkieTheme.purple.opacity(0.55), radius: 8)
            }
        }
        .scaleEffect(x: alignment == .trailing ? -1 : 1, y: 1)
        .animation(.easeInOut(duration: 0.58).repeatForever(autoreverses: true), value: active)
    }

    private func animatedHeight(_ value: CGFloat, index: Int) -> CGFloat {
        value * (index.isMultiple(of: 2) ? 1.08 : 0.72)
    }
}

#Preview("Premium Chirp") {
    WalkieView(onBack: {}, onOpenKeypad: {})
}
