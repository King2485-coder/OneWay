import SwiftUI
import Combine
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct ChatThreadView: View {
    @StateObject private var viewModel: ChatThreadViewModel
    @State private var selectedMediaItem: PhotosPickerItem?
    @State private var isShowingCameraCapture = false
    @State private var isShowingGroupTools = false
    @State private var groupInviteLink: URL?
    @State private var showReplyBar = false

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
            if viewModel.isPeerTyping {
                Text("Typing...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                ForEach(viewModel.filteredMessages) { message in
                            MessageBubbleView(
                                message: message,
                                onRetry: { Task { await viewModel.retry(message) } },
                                onReply: { viewModel.replyToMessage = message },
                                onReact: { emoji in Task { await viewModel.react(message, emoji: emoji) } },
                                onDelete: { everyone in Task { await viewModel.deleteMessage(message, everyone: everyone) } }
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.filteredMessages.count) { _, _ in
                    if let lastID = viewModel.filteredMessages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

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

            ComposerView(
                text: $viewModel.composerText,
                searchQuery: $viewModel.searchQuery,
                selectedMediaItem: $selectedMediaItem,
                hasPendingAttachment: viewModel.pendingAttachment != nil,
                onOpenCamera: {
                    isShowingCameraCapture = true
                },
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
        .navigationTitle(viewModel.chat.participantName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if viewModel.chat.isGroup {
                    Button {
                        isShowingGroupTools = true
                    } label: {
                        Image(systemName: "person.3")
                    }
                }

                Button {
                    Task { await viewModel.startCall(.voice) }
                } label: {
                    Image(systemName: "phone")
                }

                Button {
                    Task { await viewModel.startCall(.video) }
                } label: {
                    Image(systemName: "video")
                }
            }
        }
        .sheet(item: activeCallBinding) { item in
            CallSessionSheet(callID: item.callID,
                             callType: item.type,
                             displayName: viewModel.chat.participantName,
                             callService: callService) {
                Task { await viewModel.endActiveCall() }
            }
        }
        .sheet(isPresented: $isShowingGroupTools) {
            GroupToolsView(chatID: viewModel.chat.id, groupService: groupService)
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
            await viewModel.loadMessages()
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
                                Image(systemName: "minus.circle")
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
                    Button("Done") { dismiss() }
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

private struct MessageBubbleView: View {
    let message: ChatMessage
    let onRetry: () -> Void
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onDelete: (Bool) -> Void

    @State private var showActions = false

    var body: some View {
        HStack {
            if message.direction == .outgoing { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 4) {
                if let attachment = message.attachment {
                    if attachment.mediaType == .photo, let image = UIImage(data: attachment.payload) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 160, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if attachment.mediaType == .video {
                        TransientVideoPlayerView(videoData: attachment.payload)
                            .frame(width: 220, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                if let replyID = message.replyToMessageID {
                    Text("Replying to \(replyID.uuidString.prefix(6))…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !message.body.isEmpty {
                    Text(message.body)
                }

                if let preview = message.linkPreview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.title).font(.subheadline.weight(.semibold))
                        Text(preview.description).font(.caption).foregroundStyle(.secondary)
                        Text(preview.url.absoluteString).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                }

                HStack(spacing: 8) {
                    Text(message.sentAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if message.direction == .outgoing {
                        Text(message.deliveryStatus.rawValue.capitalized)
                            .font(.caption2)
                            .foregroundStyle(message.deliveryStatus == .failed ? .red : .secondary)
                    }
                    if message.editedAt != nil {
                        Text("Edited").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if message.deliveryStatus == .failed {
                    Button("Retry") { onRetry() }
                        .font(.caption)
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
            .padding(10)
            .background(message.direction == .outgoing ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contextMenu {
                Button("Reply") { onReply() }
                Button("👍 React") { onReact("👍") }
                Button("❤️ React") { onReact("❤️") }
                Button("Delete for me", role: .destructive) { onDelete(false) }
                Button("Delete for everyone", role: .destructive) { onDelete(true) }
            }

            if message.direction == .incoming { Spacer(minLength: 48) }
        }
    }
}

private struct AttachmentPreview: View {
    let attachment: MessageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Text("Attached: \(attachment.fileName) (\(attachment.byteCount / 1024) KB)")
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Button("Remove") {
                onRemove()
            }
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }
}

private struct ComposerView: View {
    @Binding var text: String
    @Binding var searchQuery: String
    @Binding var selectedMediaItem: PhotosPickerItem?
    let hasPendingAttachment: Bool
    let onOpenCamera: () -> Void
    let onReplyCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search messages", text: $searchQuery)
                .textFieldStyle(.roundedBorder)

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    onOpenCamera()
                } label: {
                    Image(systemName: "camera.fill")
                }

                PhotosPicker(selection: $selectedMediaItem, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "paperclip")
                }
                Button {
                    onReplyCancel()
                } label: {
                    Image(systemName: "arrow.uturn.left")
                }

                TextField("Message", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                Button("Send") {
                    onSend()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasPendingAttachment)
            }
        }
        .padding()
        .background(.thinMaterial)
    }
}
