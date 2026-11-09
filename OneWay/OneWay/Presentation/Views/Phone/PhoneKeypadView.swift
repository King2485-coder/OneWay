import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PhoneKeypadView: View {
    @ObservedObject var manager: CallManager
    let onBackToHome: () -> Void
    let onOpenChirp: () -> Void

    @State private var showSettings = false
    @State private var showContactPicker = false
    @State private var showNumberEditor = false
    @State private var isStartingCall = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let layout = KeypadLayout(size: proxy.size)

            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: layout.spacing) {
                        accountRow(layout: layout)
                        numberStrip(layout: layout)
                        inputArea(layout: layout)
                            .id("keypad.input")
                        OneWayDialPad(
                            maxButtonSize: layout.buttonSize,
                            rowSpacing: layout.rowSpacing,
                            columnSpacing: layout.columnSpacing
                        ) { appendDigit($0) }
                        .frame(height: layout.dialPadHeight)
                        keypadCallButtons
                            .id("keypad.call")
                        chirpKeypadSwitcher(layout: layout)
                    }
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.top, 6)
                    // Leave enough scroll runway for every keypad row and the
                    // call action to move completely above the keyboard.
                    .padding(.bottom, max(18, proxy.safeAreaInsets.bottom + 12))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: isInputFocused) { _, focused in
                    guard focused else { return }
                    withAnimation(.easeInOut(duration: 0.24)) {
                        scrollProxy.scrollTo("keypad.input", anchor: .top)
                    }
                }
            }
            .background {
                OneWayCallTheme.background
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isInputFocused = false }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .oneWayKeyboardManaged()
        .accessibilityElement(children: .contain)
        .accessibilityValue(manager.dialedText.isEmpty ? "No contact entered" : "Entered \(manager.dialedText)")
        .sheet(isPresented: $showSettings) {
            settingsSheet
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showNumberEditor) {
            NavigationStack {
                MyNumbersView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close") { showNumberEditor = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerSheet { contacts in
                if let selected = contacts.first {
                    manager.updateDialedText(selected.phoneNumber)
                }
            }
        }
    }

    private func accountRow(layout: KeypadLayout) -> some View {
        HStack {
            Button(action: onBackToHome) {
                OneWayResolvedIcon(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .background { OneWayKeypadMetalFace() }
            }.buttonStyle(.plain).accessibilityLabel("Back to OneWay Home")
            Spacer()
            Text("Keypad").font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(.white)
            Spacer()
            Menu {
                if let identity = manager.myIdentity {
                    Text(identity.onewayId)
                    Text(identity.emailAlias)
                }
                Button("Manage OneWay Numbers") { showNumberEditor = true }
                Button("Call Settings") { showSettings = true }
            } label: {
                OneWayResolvedIcon(systemName: "gearshape.fill")
                    .frame(width: 44, height: 44)
                    .background { OneWayKeypadMetalFace() }
            }.accessibilityLabel("Call settings and OneWay identity")
        }.frame(minHeight: 44)
    }

    private var displayNumber: String {
        manager.primaryOneWayNumber?.number ?? "Number unavailable"
    }

    private func numberStrip(layout: KeypadLayout) -> some View {
        HStack(spacing: 8) {
            OneWayPhysicalIcon(role: .contacts, size: 28, container: .none, accessibilityLabel: "Your OneWay number")
                .accessibilityHidden(true)
            Text("Your number ·").foregroundStyle(OneWayCallTheme.muted)
            Text(displayNumber).foregroundStyle(.white).privacySensitive()
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button { showNumberEditor = true } label: {
                OneWayResolvedIcon(systemName: "pencil").frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("Edit OneWay number")
        }
        .font(.system(.subheadline, design: .rounded, weight: .semibold))
        .padding(.leading, 12).padding(.trailing, 4)
        .background { metalPanel }
    }

    private var metalPanel: some View {
        GeometryReader { geometry in
            Image("KeypadMetalPanel").resizable().scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(x: 1.05, y: 1)
                .clipped().clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }

    private func inputArea(layout: KeypadLayout) -> some View {
        VStack(spacing: 6) {
            Text("Number or OneWay ID")
                .font(.subheadline).foregroundStyle(OneWayCallTheme.muted)
            HStack(spacing: 8) {
                Button { showContactPicker = true } label: {
                    OneWayPhysicalIcon(role: .contacts, size: 34, container: .none, accessibilityLabel: "Choose contact")
                        .frame(width: 48, height: 48)
                        .background { OneWayKeypadMetalFace() }
                }.buttonStyle(.plain).accessibilityLabel("Choose contact")
                HStack(spacing: 0) {
                    TextField("", text: Binding(get: { manager.dialedText }, set: { manager.updateDialedText($0) }),
                              prompt: Text("Enter number or @ID").foregroundColor(OneWayCallTheme.muted))
                        .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                        .keyboardType(.asciiCapable).submitLabel(.done)
                        .focused($isInputFocused).onSubmit { isInputFocused = false }
                        .font(.system(size: layout.inputFontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white).privacySensitive()
                        .accessibilityLabel("OneWay ID, OneWay number, or phone number")
                    Button(action: deleteLast) {
                        Image(systemName: "delete.left").font(.title3).foregroundStyle(OneWayCallTheme.muted)
                            .frame(width: 44, height: 48)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in clearInput() })
                    .accessibilityLabel("Delete last character")
                    .accessibilityHint("Long press clears all")
                    .accessibilityAction(named: Text("Clear all")) { clearInput() }
                }
                .padding(.leading, 14)
                .frame(minHeight: 50)
                .background { metalPanel }
                .overlay(Capsule().stroke(inputBorderColor, lineWidth: 1))
            }
            if let status = inputStatus {
                Text(status.text).font(.caption).foregroundStyle(status.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            matches
        }
    }

    private var inputBorderColor: Color {
        guard !manager.dialedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return OneWayCallTheme.purple.opacity(0.42)
        }
        return manager.classifyDialTarget(manager.dialedText) == .invalid
            ? Color.red.opacity(0.72)
            : OneWayCallTheme.purple.opacity(0.66)
    }

    private var inputStatus: (text: String, color: Color)? {
        let trimmed = manager.dialedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isStartingCall || manager.isStartingExternalPSTNCall {
            return ("Starting secure connection…", OneWayCallTheme.purple)
        }
        if !manager.oneWaySearchResults.isEmpty {
            return ("OneWay user found", .green)
        }
        switch manager.classifyDialTarget(trimmed) {
        case .onewayId: return ("Valid OneWay ID", OneWayCallTheme.purple)
        case .onewayNumber: return ("Valid OneWay number", OneWayCallTheme.purple)
        case .phoneNumber: return ("External phone number • confirmation required", .orange)
        case .invalid: return ("Enter a valid @OneWayID, OW-number, or phone number", .red)
        }
    }

    private var keypadCallButtons: some View {
        HStack(spacing: 12) {
            keypadCallButton(video: false)
            keypadCallButton(video: true)
        }
    }

    private func keypadCallButton(video: Bool) -> some View {
        Button { startCall(video: video) } label: {
            HStack(spacing: 8) {
                if isStartingCall || manager.isStartingExternalPSTNCall { ProgressView().tint(.white) }
                else { Image(systemName: video ? "video.fill" : "phone.fill") }
                Text(video ? "Video" : "Call")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.system(.title2, design: .rounded, weight: .bold))
            .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 56)
            .background(OneWayCallTheme.purpleGradient, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isStartingCall || manager.isStartingExternalPSTNCall)
        .opacity(isStartingCall || manager.isStartingExternalPSTNCall ? 0.6 : 1)
        .accessibilityLabel(video ? "Start video call" : "Start audio call")
        .accessibilityHint(video ? "Call a OneWay ID or OneWay number with video" : "")
        .accessibilityIdentifier(video ? "keypad.videoCall" : "keypad.audioCall")
    }

    private func chirpKeypadSwitcher(layout: KeypadLayout) -> some View {
        HStack(spacing: 4) {
            Button(action: onOpenChirp) {
                HStack(spacing: 8) {
                    OneWayPhysicalIcon(role: .chirp, size: 26, container: .none, accessibilityLabel: "Chirp")
                    Text("Chirp")
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("Open Chirp")
            HStack(spacing: 8) {
                Image(systemName: "circle.grid.3x3.fill")
                Text("Keypad")
            }
            .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44)
            .background(OneWayCallTheme.purpleGradient, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isSelected)
        }
        .font(.system(.headline, design: .rounded, weight: .bold))
        .foregroundStyle(OneWayCallTheme.muted)
        .padding(5).background { metalPanel }
    }

    @ViewBuilder
    private var matches: some View {
        if !manager.oneWaySearchResults.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(manager.oneWaySearchResults) { result in
                        Button {
                            manager.selectSearchResult(result)
                        } label: {
                            compactMatch(title: result.displayName ?? "OneWay User")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if !manager.keypadSuggestions.isEmpty && !manager.dialedText.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(manager.keypadSuggestions) { friend in
                        Button {
                            manager.updateDialedText(friend.handle)
                        } label: {
                            compactMatch(title: friend.displayName)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func compactMatch(title: String) -> some View {
        Text(title)
            .font(.caption.weight(.black))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: 0x111224), in: Capsule())
            .overlay(Capsule().stroke(OneWayCallTheme.purple.opacity(0.38), lineWidth: 1))
    }

    private var settingsSheet: some View {
        NavigationStack {
            ZStack {
                OneWayCallTheme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Call Settings")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(.white)
                    Text("Current call, video, Chirp, contacts, recents, voicemail, favorites, privacy, and encryption behavior remains unchanged.")
                        .foregroundStyle(OneWayCallTheme.muted)
                    Spacer()
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showSettings = false }
                }
            }
        }
    }

    private func appendDigit(_ value: String) {
        manager.updateDialedText(manager.dialedText + value)
    }

    private func deleteLast() {
        var text = manager.dialedText
        _ = text.popLast()
        manager.updateDialedText(text)
    }

    private func clearInput() {
        manager.updateDialedText("")
    }

    private func startCall(video: Bool) {
        guard !isStartingCall, !manager.isStartingExternalPSTNCall else { return }
        guard manager.activeVoiceCall == nil else {
            manager.alertMessage = "A call is already active."
            return
        }
        isStartingCall = true
        Task {
            await manager.placeDialedCall(video: video)
            isStartingCall = false
        }
    }
}

private struct KeypadLayout {
    let horizontalPadding: CGFloat = 18
    let spacing: CGFloat = 12
    let rowSpacing: CGFloat = 8
    let columnSpacing: CGFloat = 10
    let inputFontSize: CGFloat
    let buttonSize: CGFloat
    var dialPadHeight: CGFloat { buttonSize * 4 + rowSpacing * 3 }

    init(size: CGSize) {
        inputFontSize = size.width < 400 ? 20 : 22
        let widthLimit = (size.width - 36 - 20) / 3
        let heightLimit = max(64, (size.height - 380) / 4)
        buttonSize = min(104, widthLimit, heightLimit)
    }
}
