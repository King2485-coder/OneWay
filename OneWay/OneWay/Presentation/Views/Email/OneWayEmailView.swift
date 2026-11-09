import SwiftUI
import Combine

@MainActor
final class OneWayEmailViewModel: ObservableObject {
    @Published var mailbox: OneWayEmailMailbox?
    @Published var messages: [OneWayEmailMessage] = []
    @Published var folder: OneWayEmailFolder = .inbox
    @Published var search = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    private let service = OneWayEmailService.shared

    func start() async {
        isLoading = true
        defer { isLoading = false }
        do {
            mailbox = try await service.mailbox()
            if mailbox != nil { try await reload() }
        } catch { errorMessage = error.localizedDescription }
    }

    func claim() async {
        isLoading = true
        defer { isLoading = false }
        do {
            mailbox = try await service.claim()
            try await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func reload() async throws {
        messages = try await service.messages(folder: folder, query: search)
    }

    func refresh() async {
        do { try await reload() } catch { errorMessage = error.localizedDescription }
    }

    func move(_ message: OneWayEmailMessage, to destination: OneWayEmailFolder) async {
        do {
            _ = try await service.update(message, folder: destination)
            try await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleStar(_ message: OneWayEmailMessage) async {
        do {
            _ = try await service.update(message, isStarred: !message.isStarred)
            try await reload()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct OneWayEmailView: View {
    var initialThreadID: String? = nil
    var startsCompose = false
    var startsSettings = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = OneWayEmailViewModel()
    @State private var showsCompose = false
    @State private var composeDraft = OneWayEmailDraft()
    @State private var showsReadiness = false
    @State private var showsInitialThread = false

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.mailbox == nil {
                    ProgressView("Opening secure mailbox…")
                } else if let mailbox = model.mailbox {
                    mailboxContent(mailbox)
                } else {
                    claimMailbox
                }
            }
            .navigationTitle(model.folder.title)
            .searchable(text: $model.search, prompt: "Search mail")
            .onSubmit(of: .search) { Task { await model.refresh() } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                if model.mailbox != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { composeDraft = OneWayEmailDraft(); showsCompose = true } label: { OneWayResolvedIcon(systemName: "square.and.pencil") }
                            .accessibilityLabel("Compose email")
                    }
                }
            }
            .sheet(isPresented: $showsCompose) {
                OneWayEmailComposeView(draft: composeDraft) { Task { await model.refresh() } }
            }
            .sheet(isPresented: $showsReadiness) {
                if let readiness = model.mailbox?.readiness { OneWayEmailReadinessView(readiness: readiness) }
            }
            .navigationDestination(isPresented: $showsInitialThread) {
                if let initialThreadID { OneWayEmailThreadView(threadID: initialThreadID, seed: nil) }
            }
            .alert("OneWay Email", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
        .task {
            await model.start()
            if initialThreadID != nil { showsInitialThread = true }
            if startsCompose { showsCompose = true }
            if startsSettings { showsReadiness = true }
        }
    }

    @ViewBuilder
    private func mailboxContent(_ mailbox: OneWayEmailMailbox) -> some View {
        VStack(spacing: 0) {
            if !mailbox.readiness.liveDeliveryEnabled {
                Button { showsReadiness = true } label: {
                    OneWayResolvedLabel("Delivery setup is not complete. Sending is safely disabled.", systemImage: "exclamationmark.shield.fill")
                        .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .foregroundStyle(.orange)
                .background(.orange.opacity(0.1))
            }
            folderPicker
            if model.messages.isEmpty && !model.isLoading {
                ContentUnavailableView("No \(model.folder.title.lowercased()) mail", systemImage: model.folder.icon, description: Text("Messages in this folder will appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.messages) { message in
                    NavigationLink {
                        OneWayEmailThreadView(threadID: message.threadId, seed: message)
                    } label: {
                        OneWayEmailRow(message: message)
                    }
                    .swipeActions(edge: .leading) {
                        Button { Task { await model.toggleStar(message) } } label: { OneWayResolvedLabel("Star", systemImage: "star.fill") }.tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { Task { await model.move(message, to: .trash) } } label: { OneWayResolvedLabel("Trash", systemImage: "trash") }.tint(.red)
                        Button { Task { await model.move(message, to: .archive) } } label: { OneWayResolvedLabel("Archive", systemImage: "archivebox") }.tint(.blue)
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.refresh() }
            }
        }
    }

    private var folderPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OneWayEmailFolder.allCases) { folder in
                    Button {
                        model.folder = folder
                        Task { await model.refresh() }
                    } label: {
                        OneWayResolvedLabel(folder.title, systemImage: folder.icon)
                            .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(model.folder == folder ? Color.purple : Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(model.folder == folder ? .white : .primary)
                    }
                }
            }.padding(.horizontal).padding(.vertical, 10)
        }
    }

    private var claimMailbox: some View {
        ContentUnavailableView {
            OneWayResolvedLabel("Claim your OneWay Email", systemImage: "envelope.badge.shield.half.filled")
        } description: {
            Text("Activate the @oneway.app address already reserved by your OneWay identity.")
        } actions: {
            Button("Activate mailbox") { Task { await model.claim() } }.buttonStyle(.borderedProminent).tint(.purple)
        }
    }
}

private struct OneWayEmailRow: View {
    let message: OneWayEmailMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(message.isRead ? Color.secondary.opacity(0.15) : Color.purple.opacity(0.2)).frame(width: 42, height: 42)
                .overlay(Text(initial).font(.headline).foregroundStyle(.purple))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayAddress).fontWeight(message.isRead ? .regular : .bold).lineLimit(1)
                    Spacer()
                    if message.isStarred { OneWayResolvedIcon(systemName: "star.fill").foregroundStyle(.yellow) }
                }
                Text(message.subject.isEmpty ? "(No subject)" : message.subject).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack {
                    if !message.attachments.isEmpty { OneWayResolvedIcon(systemName: "paperclip") }
                    Text(message.status.capitalized).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 4)
    }
    private var displayAddress: String { (message.direction == "outbound" ? message.to.first : message.from.first) ?? "Unknown sender" }
    private var initial: String { String(displayAddress.prefix(1)).uppercased() }
}

private struct OneWayEmailThreadView: View {
    let threadID: String
    let seed: OneWayEmailMessage?
    @State private var messages: [OneWayEmailMessage] = []
    @State private var errorMessage: String?
    @State private var replyDraft: OneWayEmailDraft?

    var body: some View {
        List(messages.isEmpty ? seed.map { [$0] } ?? [] : messages) { message in
            VStack(alignment: .leading, spacing: 10) {
                Text(message.from.first ?? "Unknown sender").font(.headline)
                Text(message.subject.isEmpty ? "(No subject)" : message.subject).font(.subheadline.weight(.semibold))
                Text(message.bodyText).textSelection(.enabled)
                ForEach(message.attachments) { attachment in OneWayEmailAttachmentButton(attachment: attachment) }
                HStack {
                    Button("Reply") { replyDraft = reply(to: message, all: false) }
                    Button("Reply All") { replyDraft = reply(to: message, all: true) }
                    Button("Forward") { replyDraft = forward(message) }
                    if message.direction == "inbound", let sender = message.from.first {
                        Button("Block", role: .destructive) { Task { try? await OneWayEmailService.shared.block(sender) } }
                    }
                }.font(.caption.weight(.semibold))
            }.padding(.vertical, 8)
        }
        .navigationTitle(seed?.subject.isEmpty == false ? seed!.subject : "Message")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { messages = try await OneWayEmailService.shared.thread(threadID) }
            catch { errorMessage = error.localizedDescription }
        }
        .sheet(item: $replyDraft) { draft in OneWayEmailComposeView(draft: draft) {} }
        .alert("OneWay Email", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func reply(to message: OneWayEmailMessage, all: Bool) -> OneWayEmailDraft {
        var recipients = message.from
        if all { recipients.append(contentsOf: message.cc) }
        return OneWayEmailDraft(threadId: message.threadId, to: Array(Set(recipients)).joined(separator: ", "), subject: prefixed("Re:", message.subject), body: "\n\n— Original message —\n\(message.bodyText)")
    }
    private func forward(_ message: OneWayEmailMessage) -> OneWayEmailDraft {
        OneWayEmailDraft(threadId: nil, subject: prefixed("Fwd:", message.subject), body: "\n\n— Forwarded message —\nFrom: \(message.from.joined(separator: ", "))\n\(message.bodyText)")
    }
    private func prefixed(_ prefix: String, _ subject: String) -> String { subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)" }
}

private struct OneWayEmailAttachmentButton: View {
    let attachment: OneWayEmailAttachment
    @State private var fileURL: URL?
    @State private var loading = false
    var body: some View {
        if let fileURL { ShareLink(item: fileURL) { OneWayResolvedLabel(attachment.filename, systemImage: "square.and.arrow.up") } }
        else { Button { Task { loading = true; fileURL = try? await OneWayEmailService.shared.download(attachment); loading = false } } label: { OneWayResolvedLabel(loading ? "Downloading…" : attachment.filename, systemImage: "paperclip") } }
    }
}

private struct OneWayEmailComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: OneWayEmailDraft
    let onComplete: () -> Void
    @State private var sending = false
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("To", text: $draft.to).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                DisclosureGroup("Cc / Bcc") {
                    TextField("Cc", text: $draft.cc).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    TextField("Bcc", text: $draft.bcc).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                }
                TextField("Subject", text: $draft.subject)
                TextEditor(text: $draft.body).frame(minHeight: 260)
            }
            .navigationTitle("New Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Draft") { Task { await saveDraft() } }.disabled(sending)
                    Button("Send") { Task { await send() } }.disabled(sending || draft.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Couldn’t send", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        }
    }
    private func send() async { sending = true; defer { sending = false }; do { _ = try await OneWayEmailService.shared.send(draft); onComplete(); dismiss() } catch { errorMessage = error.localizedDescription } }
    private func saveDraft() async { sending = true; defer { sending = false }; do { _ = try await OneWayEmailService.shared.saveDraft(draft); onComplete(); dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct OneWayEmailReadinessView: View {
    @Environment(\.dismiss) private var dismiss
    let readiness: OneWayEmailReadiness
    var body: some View {
        NavigationStack {
            List {
                Section("Service") { LabeledContent("Provider", value: readiness.provider.capitalized); LabeledContent("Domain", value: readiness.domain); LabeledContent("Delivery", value: readiness.liveDeliveryEnabled ? "Live" : "Gated") }
                if !readiness.missing.isEmpty { Section("Required configuration") { ForEach(readiness.missing, id: \.self) { OneWayResolvedLabel($0, systemImage: "exclamationmark.triangle") } } }
                Section("Required DNS") { ForEach(readiness.dnsRequired, id: \.self) { OneWayResolvedLabel($0, systemImage: "network") } }
            }.navigationTitle("Email Status").toolbar { Button("Done") { dismiss() } }
        }
    }
}

extension OneWayEmailDraft: Identifiable {
    var stableID: String { id ?? "new-\(threadId ?? "message")-\(subject)" }
    var idForPresentation: String { stableID }
}
