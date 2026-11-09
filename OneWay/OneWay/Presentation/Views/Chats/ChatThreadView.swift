import SwiftUI
import Combine
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation

struct ChatThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ChatThreadViewModel
    @State private var selectedMediaItem: PhotosPickerItem?
    @State private var isShowingCameraCapture = false
    @State private var isShowingGroupTools = false
    @State private var isShowingPrivacySettings = false
    @State private var groupInviteLink: URL?
    @State private var showReplyBar = false
    @State private var isShowingAttachmentTray = false
    @StateObject private var voiceRecorder = VoicemailRecorder(maxDuration: 60)

    private let groupService: GroupService
    private let callService: CallService

    @EnvironmentObject private var tabVisibilityManager: TabVisibilityManager

    init(chat: ChatSummary, messagingService: MessagingService, groupService: GroupService, friendService: FriendService, callService: CallService) {
        self.groupService = groupService
        self.callService = callService
        _viewModel = StateObject(wrappedValue: ChatThreadViewModel(chat: chat, messagingService: messagingService, friendService: friendService, callService: callService))
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeaderView(
                chat: viewModel.chat,
                isTyping: viewModel.isPeerTyping,
                onBack: { dismiss() },
                onAudio: { Task { await viewModel.startCall(.voice) } },
                onVideo: { Task { await viewModel.startCall(.video) } },
                onMore: {
                    if viewModel.chat.isGroup { isShowingGroupTools = true }
                    else if !viewModel.chat.isExternal { isShowingPrivacySettings = true }
                }
            )

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.filteredMessages) { message in
                            MessageBubbleView(
                                message: message,
                                onRetry: { Task { await viewModel.retry(message) } },
                                onReply: { viewModel.replyToMessage = message },
                                onReact: { emoji in Task { await viewModel.react(message, emoji: emoji) } },
                                onDelete: { everyone in Task { await viewModel.deleteMessage(message, everyone: everyone) } },
                                allowCopying: viewModel.privacySettings.allowCopying,
                                allowForwarding: viewModel.privacySettings.allowForwarding
                            )
                            .id(message.id)
                            .transition(.move(edge: message.direction == .outgoing ? .trailing : .leading).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
                .onChange(of: viewModel.filteredMessages.count) { _, _ in
                    if let lastID = viewModel.filteredMessages.last?.id {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }

            if let attachment = viewModel.pendingAttachment {
                AttachmentPreview(attachment: attachment) {
                    viewModel.pendingAttachment = nil
                }
            }
            if let replyTarget = viewModel.replyToMessage {
                ReplyPreviewBar(message: replyTarget) {
                    viewModel.replyToMessage = nil
                }
            }
            if let reason = viewModel.externalMessagingDisabledReason {
                ExternalMessagingSetupBanner(message: reason)
            }
            if let privacyMessage = viewModel.privacyStatusMessage {
                PrivacyStatusBanner(message: privacyMessage) {
                    viewModel.privacyStatusMessage = nil
                }
            }

            ComposerView(
                text: $viewModel.composerText,
                searchQuery: $viewModel.searchQuery,
                selectedMediaItem: $selectedMediaItem,
                hasPendingAttachment: viewModel.pendingAttachment != nil,
                supportsAttachments: !viewModel.chat.isExternal,
                canSend: viewModel.canSendMessages,
                disappearingOverride: $viewModel.nextMessageDisappearing,
                supportsDisappearing: !viewModel.chat.isExternal,
                isShowingAttachmentTray: $isShowingAttachmentTray,
                onOpenCamera: {
                    isShowingCameraCapture = true
                },
                isRecordingVoice: isRecordingVoice,
                onVoice: { Task { await toggleVoiceRecording() } },
                onReplyCancel: {
                    viewModel.replyToMessage = nil
                },
                onSend: {
                    Task {
                        await viewModel.sendMessage()
                    }
                }
            )
        }
        .background { OneWayLightBackground() }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingAttachmentTray) {
            AttachmentTrayView(
                selectedMediaItem: $selectedMediaItem,
                supportsMedia: !viewModel.chat.isExternal,
                onCamera: {
                    isShowingAttachmentTray = false
                    isShowingCameraCapture = true
                }
            )
            .presentationDetents([.height(360), .medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: activeCallBinding) { item in
            CallSessionSheet(callID: item.callID,
                             callType: item.type,
                             displayName: viewModel.chat.participantName,
                             callService: callService) {
                viewModel.endCallPreview()
            }
        }
        .sheet(isPresented: $isShowingGroupTools) {
            GroupToolsView(chatID: viewModel.chat.id, groupService: groupService)
        }
        .sheet(isPresented: $isShowingPrivacySettings) {
            ConversationPrivacyView(settings: viewModel.privacySettings) { settings in
                Task { await viewModel.savePrivacySettings(settings) }
            }
        }
        .fullScreenCover(isPresented: $isShowingCameraCapture) {
            CameraCaptureView { image in
                guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                let attachment = MessageAttachment(
                    id: UUID(),
                    mediaType: .photo,
                    fileName: "camera-photo.jpg",
                    byteCount: data.count,
                    payload: data
                )
                viewModel.pendingAttachment = attachment
            }
        }
        .task {
            await viewModel.prepareExternalMessaging()
            await viewModel.loadPrivacySettings()
            await viewModel.loadMessages()
            viewModel.startRealtimeMessages()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await viewModel.loadMessages(showLoading: false)
            }
            viewModel.stopRealtimeMessages()
        }
        // Full-screen thread: hide custom tab bar while this view is active.
        .onAppear {
            withAnimation(.easeInOut(duration: 0.15)) {
                tabVisibilityManager.isTabBarHidden = true
            }
        }
        .onDisappear {
            withAnimation(.easeInOut(duration: 0.15)) {
                tabVisibilityManager.isTabBarHidden = false
            }
            viewModel.stopRealtimeMessages()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            viewModel.recordScreenshotWarning()
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading thread...")
            }
        }
        .onChange(of: selectedMediaItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                    let attachment = MessageAttachment(
                        id: UUID(),
                        mediaType: isVideo ? .video : .photo,
                        fileName: isVideo ? "video.mov" : "photo.jpg",
                        byteCount: data.count,
                        payload: data
                    )
                    viewModel.pendingAttachment = attachment
                }
                selectedMediaItem = nil
            }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var isRecordingVoice: Bool {
        if case .recording = voiceRecorder.state { return true }
        return false
    }

    @MainActor
    private func toggleVoiceRecording() async {
        if isRecordingVoice {
            guard let url = voiceRecorder.stop(),
                  let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            viewModel.pendingAttachment = MessageAttachment(
                mediaType: .audio,
                fileName: "voice-message.m4a",
                byteCount: data.count,
                payload: data,
                mimeType: "audio/mp4"
            )
            try? FileManager.default.removeItem(at: url)
            return
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            viewModel.errorMessage = "Microphone access is required to record a voice message."
            return
        }
        do { try voiceRecorder.start() }
        catch { viewModel.errorMessage = error.localizedDescription }
    }

    private var activeCallBinding: Binding<ActiveCall?> {
        Binding<ActiveCall?>(
            get: {
                guard let id = viewModel.activeCallID,
                      let type = viewModel.activeCallType else { return nil }
                return ActiveCall(callID: id, type: type)
            },
            set: { updated in
                if updated == nil {
                    viewModel.endCallPreview()
                }
            }
        )
    }
}

private struct GroupToolsView: View {
    @Environment(\.dismiss) private var dismiss
    let chatID: UUID
    let groupService: GroupService

    @State private var members: [GroupMember] = []
    @State private var inviteLink: URL?
    @State private var newMemberHandle: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Members") {
                    ForEach(members) { member in
                        HStack {
                            Text(member.name)
                            Spacer()
                            Text(member.role.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                Task {
                                    try? await groupService.removeMember(chatID: chatID, memberID: member.id)
                                    members = (try? await groupService.fetchMembers(chatID: chatID)) ?? []
                                }
                            } label: {
                                OneWayResolvedIcon(systemName: "minus.circle")
                            }
                        }
                    }
                    HStack {
                        TextField("@handle", text: $newMemberHandle)
                            .textInputAutocapitalization(.never)
                        Button("Add") {
                            Task {
                                guard !newMemberHandle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                                _ = try? await groupService.addMember(chatID: chatID, handle: newMemberHandle, role: .member)
                                members = (try? await groupService.fetchMembers(chatID: chatID)) ?? []
                                newMemberHandle = ""
                            }
                        }
                    }
                }

                Section("Invite") {
                    Button("Create Invite Link") {
                        Task {
                            inviteLink = try? await groupService.createInviteLink(chatID: chatID)
                        }
                    }

                    if let inviteLink {
                        ShareLink(item: inviteLink)
                        Text(inviteLink.absoluteString)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Group Tools")
            .oneWayMenuBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
            }
            .task {
                members = (try? await groupService.fetchMembers(chatID: chatID)) ?? []
            }
        }
    }
}

private struct ActiveCall: Identifiable, Equatable {
    let callID: UUID
    let type: CallType
    var id: UUID { callID }
}

private struct PrivacyStatusBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OneWayResolvedIcon(systemName: "shield.lefthalf.filled")
                .scaleEffect(1.2)
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
            Spacer()
            Button(action: onDismiss) {
                OneWayResolvedIcon(systemName: "xmark")
                    .scaleEffect(1.2)
            }
                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
        }
        .padding(12)
        .background(OneWayDesignSystem.Colors.panelElevated)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(OneWayDesignSystem.Colors.border), alignment: .top)
    }
}

private struct ConversationPrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConversationPrivacySettings
    let onSave: (ConversationPrivacySettings) -> Void

    init(settings: ConversationPrivacySettings, onSave: @escaping (ConversationPrivacySettings) -> Void) {
        _draft = State(initialValue: settings)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Disappear After Read") {
                    Toggle("Disappearing messages", isOn: Binding(
                        get: { draft.expirationMode == .afterRead },
                        set: { enabled in
                            draft.expirationMode = enabled ? .afterRead : .off
                            draft.expirationDurationSeconds = enabled ? draft.expirationDurationSeconds ?? 0 : nil
                        }
                    ))
                    if draft.expirationMode == .afterRead {
                        Picker("Delete after everyone reads", selection: Binding(
                            get: { draft.expirationDurationSeconds ?? 0 },
                            set: { draft.expirationDurationSeconds = $0 }
                        )) {
                            Text("Immediately").tag(0)
                            Text("30 seconds").tag(30)
                            Text("5 minutes").tag(300)
                            Text("1 hour").tag(3_600)
                            Text("1 day").tag(86_400)
                            Text("7 days").tag(604_800)
                        }
                    }
                    Text("The server starts the timer only after all recipients have opened the message in the foreground. Delivery notifications alone do not start it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Sharing controls") {
                    Toggle("Allow forwarding", isOn: $draft.allowForwarding)
                    Toggle("Allow copying text", isOn: $draft.allowCopying)
                    Toggle("Allow saving attachments", isOn: $draft.allowSavingAttachments)
                    Text("These controls limit actions inside OneWay. They cannot prevent screenshots, photos of the screen, notification previews, or copies made outside OneWay.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Chat Privacy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ConversationHeaderView: View {
    let chat: ChatSummary
    let isTyping: Bool
    let onBack: () -> Void
    let onAudio: () -> Void
    let onVideo: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                OneWayResolvedIcon(systemName: "chevron.left")
                    .font(.system(size: 25.5, weight: .black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                    .frame(width: 42, height: 42)
                    .background(OneWayDesignSystem.Colors.panelElevated, in: Circle())
                    .overlay(Circle().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 5)
            }
            .accessibilityLabel("Back")

            OneWayAvatar(name: chat.participantName, size: 55, verified: !chat.isExternal, online: !chat.isExternal)

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.participantName)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(isTyping ? OneWayDesignSystem.Colors.purple : Color.green)
                        .frame(width: 7, height: 7)
                    Text(isTyping ? "Typing..." : (chat.isExternal ? "SMS" : "OneWay chat"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                }
            }

            Spacer()

            if !chat.isExternal {
                headerButton("phone.fill", action: onAudio)
                headerButton("video.fill", action: onVideo)
            }
            headerButton(chat.isGroup ? "person.3.fill" : "ellipsis", action: onMore)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(Divider().overlay(OneWayDesignSystem.Colors.border), alignment: .bottom)
    }

    private func headerButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OneWayResolvedIcon(systemName: icon)
                .font(.system(size: 22.5, weight: .black))
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                .frame(width: 38, height: 38)
                .background(OneWayDesignSystem.Colors.panelElevated, in: Circle())
                .overlay(Circle().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct MessageBubbleView: View {
    let message: ChatMessage
    let onRetry: () -> Void
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onDelete: (Bool) -> Void
    let allowCopying: Bool
    let allowForwarding: Bool

    @State private var showActions = false

    var body: some View {
        if message.isSystemNotice {
            Text(message.body)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else if message.isTombstone {
            HStack(spacing: 7) {
                OneWayResolvedIcon(systemName: "timer")
                    .scaleEffect(1.2)
                Text("Message disappeared")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
        HStack {
            if message.direction == .outgoing { Spacer(minLength: 52) }

            VStack(alignment: .leading, spacing: 4) {
                if let attachment = message.attachment {
                    if attachment.mediaType == .photo, let image = UIImage(data: attachment.payload) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 220, height: 165)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    if attachment.mediaType == .video {
                        TransientVideoPlayerView(videoData: attachment.payload)
                            .frame(width: 220, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    if attachment.mediaType == .audio {
                        VoiceMessagePlayer(data: attachment.payload)
                    }
                }

                if let replyID = message.replyToMessageID {
                    Text("Replying to \(replyID.uuidString.prefix(6))…")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(message.direction == .outgoing ? .white.opacity(0.72) : OneWayDesignSystem.Colors.secondaryText)
                        .padding(.bottom, 2)
                }

                if !message.body.isEmpty {
                    if allowCopying {
                        messageBodyText.textSelection(.enabled)
                    } else {
                        messageBodyText
                    }
                }

                if let preview = message.linkPreview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.title).font(.subheadline.weight(.semibold))
                        Text(preview.description).font(.caption).foregroundStyle(message.direction == .outgoing ? .white.opacity(0.75) : OneWayDesignSystem.Colors.secondaryText)
                        Text(preview.url.absoluteString).font(.caption2).foregroundStyle(message.direction == .outgoing ? .white.opacity(0.7) : OneWayDesignSystem.Colors.secondaryText)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(OneWayDesignSystem.Colors.panelGlass))
                }

                HStack(spacing: 8) {
                    Text(message.sentAt, style: .time)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)

                    if message.direction == .outgoing {
                        HStack(spacing: 3) {
                            OneWayResolvedIcon(systemName: statusIcon)
                                .font(.system(size: 12, weight: .black))
                            Text(statusLabel)
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(statusColor)
                        .contentTransition(.opacity)
                    }
                    if message.editedAt != nil {
                        Text("Edited").font(.caption2.weight(.semibold)).foregroundStyle(statusColor)
                    }
                }
                .padding(.top, 1)

                if message.deliveryStatus == .failed {
                    Button(action: onRetry) {
                        OneWayResolvedLabel("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.black))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.12), in: Capsule())
                    }
                    .foregroundStyle(.red)
                }

                if !message.reactions.isEmpty {
                    HStack {
                        ForEach(message.reactions) { reaction in
                            Text(reaction.emoji)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: message.direction == .outgoing ? OneWayDesignSystem.Colors.purple.opacity(0.18) : Color.black.opacity(0.05), radius: 12, x: 0, y: 6)
            .contextMenu {
                Button("Reply") { onReply() }
                Button("👍 React") { onReact("👍") }
                Button("❤️ React") { onReact("❤️") }
                if allowForwarding { Button("Forward") {} }
                Button("Edit") {}
                Button("Delete for me", role: .destructive) { onDelete(false) }
                Button("Delete for everyone", role: .destructive) { onDelete(true) }
            }

            if message.direction == .incoming { Spacer(minLength: 52) }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: message.deliveryStatus)
        }
    }

    private var bubbleBackground: AnyShapeStyle {
        if message.direction == .outgoing {
            return AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient)
        }
        return AnyShapeStyle(OneWayDesignSystem.Colors.panelElevated)
    }

    private var messageBodyText: some View {
        Text(message.body)
            .font(.system(size: 16.5, weight: .medium))
            .foregroundStyle(message.direction == .outgoing ? .white : OneWayDesignSystem.Colors.text)
            .lineSpacing(2)
    }

    private var statusColor: Color {
        if message.deliveryStatus == .failed { return .red }
        return message.direction == .outgoing ? .white.opacity(0.74) : OneWayDesignSystem.Colors.secondaryText
    }

    private var statusLabel: String {
        switch message.deliveryStatus {
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .read: return "Read"
        case .failed: return "Failed"
        }
    }

    private var statusIcon: String {
        switch message.deliveryStatus {
        case .sending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle.fill"
        case .read: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}

@MainActor
private final class VoiceMessagePlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    private var player: AVAudioPlayer?
    func toggle(data: Data) {
        if isPlaying { player?.stop(); isPlaying = false; return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            isPlaying = true
        } catch { isPlaying = false }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}

struct VoiceMessagePlayer: View {
    let data: Data
    @StateObject private var playback = VoiceMessagePlayback()
    var body: some View {
        Button { playback.toggle(data: data) } label: {
            HStack(spacing: 10) {
                OneWayResolvedIcon(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                OneWayResolvedIcon(systemName: "waveform")
                Text("Voice message").font(.caption.weight(.bold))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(OneWayDesignSystem.Colors.panelGlass, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.isPlaying ? "Pause voice message" : "Play voice message")
    }
}

private struct AttachmentPreview: View {
    let attachment: MessageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack {
            OneWayResolvedIcon(systemName: attachment.mediaType == .photo ? "photo.fill" : attachment.mediaType == .video ? "video.fill" : attachment.mediaType == .audio ? "waveform" : "doc.fill")
                .scaleEffect(1.2)
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
            Text("\(attachment.fileName) • \(attachment.byteCount / 1024) KB")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
                .lineLimit(1)

            Spacer()

            Button(action: onRemove) {
                OneWayResolvedIcon(systemName: "xmark.circle.fill")
                    .scaleEffect(1.2)
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OneWayDesignSystem.Colors.panelElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

private struct ComposerView: View {
    @Binding var text: String
    @Binding var searchQuery: String
    @Binding var selectedMediaItem: PhotosPickerItem?
    let hasPendingAttachment: Bool
    let supportsAttachments: Bool
    let canSend: Bool
    @Binding var disappearingOverride: MessageDisappearingOverride
    let supportsDisappearing: Bool
    @Binding var isShowingAttachmentTray: Bool
    let onOpenCamera: () -> Void
    let isRecordingVoice: Bool
    let onVoice: () -> Void
    let onReplyCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if supportsDisappearing {
                HStack {
                    Menu {
                        Picker("This message", selection: $disappearingOverride) {
                            Text("Use chat setting").tag(MessageDisappearingOverride.inherit)
                            Text("Keep this message").tag(MessageDisappearingOverride.keep)
                            Text("Disappear after read").tag(MessageDisappearingOverride.afterRead)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            OneWayResolvedIcon(systemName: disappearingOverride == .afterRead ? "timer" : "shield")
                                .font(.system(size: 18, weight: .bold))
                            Text(disappearingLabel)
                                .font(.caption.weight(.bold))
                        }
                    }
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                    Spacer()
                }
            }
            if !searchQuery.isEmpty {
                searchPill
            }

            HStack(alignment: .bottom, spacing: 8) {
                if supportsAttachments {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                            isShowingAttachmentTray = true
                        }
                    } label: {
                        OneWayResolvedIcon(systemName: "plus")
                            .font(.system(size: 25.5, weight: .black))
                            .foregroundStyle(OneWayDesignSystem.Colors.purple)
                            .frame(width: 44, height: 44)
                            .background(OneWayDesignSystem.Colors.panelElevated, in: Circle())
                            .overlay(Circle().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Attachments")
                    .accessibilityIdentifier("chat.attachments")
                }

                TextField(
                    "",
                    text: $text,
                    prompt: Text("Message").foregroundStyle(OneWayDesignSystem.Colors.textMuted),
                    axis: .vertical
                )
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                    .tint(OneWayDesignSystem.Colors.purple)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(OneWayDesignSystem.Colors.panelElevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                    .accessibilityLabel("Message")

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasPendingAttachment {
                    HStack(spacing: 4) {
                        Button(action: onVoice) {
                            OneWayResolvedIcon(systemName: isRecordingVoice ? "stop.fill" : "mic.fill")
                                .font(.system(size: 25.5, weight: .bold))
                                .foregroundStyle(isRecordingVoice ? .red : OneWayDesignSystem.Colors.secondaryText)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isRecordingVoice ? "Stop voice recording" : "Record voice message")
                        .accessibilityIdentifier("chat.voiceMessage")
                        Button(action: onOpenCamera) {
                            OneWayResolvedIcon(systemName: "camera.fill")
                                .font(.system(size: 25.5, weight: .bold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Camera")
                        .accessibilityIdentifier("chat.camera")
                        PhotosPicker(selection: $selectedMediaItem, matching: .any(of: [.images, .videos])) {
                            OneWayResolvedIcon(systemName: "photo.fill")
                                .font(.system(size: 25.5, weight: .bold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Photo library")
                        .accessibilityIdentifier("chat.photoLibrary")
                    }
                    .font(.headline.weight(.bold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                } else {
                    Button(action: onSend) {
                        OneWayResolvedIcon(systemName: "arrow.up")
                            .font(.system(size: 25.5, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(OneWayDesignSystem.Colors.purpleGradient, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(!canSend)
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("chat.send")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(Divider().overlay(OneWayDesignSystem.Colors.border), alignment: .top)
        .zIndex(10)
    }

    private var disappearingLabel: String {
        switch disappearingOverride {
        case .inherit: return "Chat privacy"
        case .keep: return "Keep this message"
        case .afterRead: return "Disappear after read"
        }
    }

    private var searchPill: some View {
        HStack(spacing: 8) {
            OneWayResolvedIcon(systemName: "magnifyingglass")
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
            TextField("Search messages", text: $searchQuery)
                .textInputAutocapitalization(.never)
            Button {
                searchQuery = ""
            } label: {
                OneWayResolvedIcon(systemName: "xmark.circle.fill")
            }
            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(OneWayDesignSystem.Colors.panelElevated, in: Capsule())
        .overlay(Capsule().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
    }
}

private struct AttachmentTrayView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedMediaItem: PhotosPickerItem?
    let supportsMedia: Bool
    let onCamera: () -> Void

    private let actions: [(String, String)] = [
        ("Document", "doc.fill"),
        ("Location", "location.fill"),
        ("Contact", "person.crop.circle.fill"),
        ("Voice", "waveform"),
        ("Wallet", "wallet.pass.fill"),
        ("Poll", "chart.bar.doc.horizontal.fill"),
        ("Event", "calendar.badge.plus"),
        ("AI", "sparkles"),
        ("Schedule", "clock.badge.checkmark")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to Message")
                        .font(.title2.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                    Text("Share photos, files, voice notes, plans, and more.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    OneWayResolvedIcon(systemName: "xmark")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                        .frame(width: 38, height: 38)
                        .background(OneWayDesignSystem.Colors.panelElevated, in: Circle())
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                if supportsMedia {
                    trayPhotosPicker
                    trayButton("Camera", "camera.fill", action: onCamera)
                }
                ForEach(actions, id: \.0) { action in
                    trayButton(action.0, action.1) {}
                }
            }
        }
        .padding(20)
        .background { OneWayLightBackground() }
    }

    private var trayPhotosPicker: some View {
        PhotosPicker(selection: $selectedMediaItem, matching: .any(of: [.images, .videos])) {
            trayLabel("Photo", "photo.on.rectangle.angled")
        }
        .buttonStyle(.plain)
    }

    private func trayButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            trayLabel(title, icon)
        }
        .buttonStyle(.plain)
    }

    private func trayLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 8) {
            OneWayResolvedIcon(systemName: icon)
                .font(.title3.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                .frame(width: 46, height: 46)
                .background(OneWayDesignSystem.Colors.purple.opacity(0.1), in: Circle())
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(OneWayDesignSystem.Colors.panelElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
    }
}

private struct ExternalMessagingSetupBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OneWayResolvedIcon(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
