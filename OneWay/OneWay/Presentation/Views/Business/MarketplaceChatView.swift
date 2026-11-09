import SwiftUI

struct MarketplaceChatView: View {
    enum Mode {
        case buyer
        case seller
    }

    @ObservedObject var viewModel: MarketplaceViewModel
    let thread: ShopConversation
    var mode: Mode = .buyer
    let onBack: () -> Void
    @State private var draft = ""
    @State private var showDeleteConfirm = false
    @State private var showBlockConfirm = false
    @State private var showReport = false

    private var currentThread: ShopConversation {
        viewModel.threads.first(where: { $0.id == thread.id }) ?? thread
    }

    private var product: MarketplaceProduct? {
        currentThread.productID.flatMap { viewModel.product($0) }
    }

    private var shop: MarketplaceShop? {
        viewModel.shop(currentThread.shopID)
    }

    var body: some View {
        ZStack {
            MarketplaceTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 12) {
                        contextCard
                        ForEach(currentThread.messages) { message in
                            messageBubble(message)
                        }
                    }
                    .padding(16)
                }
                composer
            }
        }
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) {
            MarketplaceBackBar(title: headerTitle, onBack: onBack) {
                menu
            }
        }
        .confirmationDialog("Delete this conversation from your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete for Me", role: .destructive) {
                viewModel.deleteThreadForMe(currentThread, asSeller: mode == .seller)
                onBack()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will not remove it from the other person’s account.")
        }
        .confirmationDialog("Block Shop messages?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block Shop Messages", role: .destructive) {
                viewModel.blockShopMessages(currentThread, asSeller: mode == .seller)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showReport) {
            ShopReportConversationView(viewModel: viewModel, thread: currentThread, asSeller: mode == .seller)
        }
        .task {
            await viewModel.syncShopConversations()
        }
    }

    private var headerTitle: String {
        mode == .seller ? currentThread.buyerName : (shop?.name ?? currentThread.sellerName)
    }

    private var menu: some View {
        Menu {
            if product != nil {
                OneWayResolvedButton("View Product", systemImage: "shippingbox.fill") {}
            }
            OneWayResolvedButton(currentThread.isMuted ? "Unmute" : "Mute", systemImage: currentThread.isMuted ? "bell.fill" : "bell.slash.fill") {
                viewModel.toggleMute(currentThread)
            }
            OneWayResolvedButton("Archive", systemImage: "archivebox.fill") {
                viewModel.archiveThread(currentThread, asSeller: mode == .seller)
                onBack()
            }
            OneWayResolvedButton("Report", systemImage: "flag.fill") { showReport = true }
            OneWayResolvedButton("Block Shop Messages", systemImage: "hand.raised.fill", role: .destructive) { showBlockConfirm = true }
            OneWayResolvedButton("Delete Conversation", systemImage: "trash.fill", role: .destructive) { showDeleteConfirm = true }
        } label: {
            OneWayResolvedIcon(systemName: "ellipsis.circle.fill")
        }
    }

    private var contextCard: some View {
        HStack(spacing: 12) {
            if let product {
                MarketplaceProductImageView(product: product, height: 72, cornerRadius: 16)
                    .frame(width: 78)
            } else {
                MarketplaceLogo(size: 54)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(currentThread.type.rawValue)
                    .font(.caption.weight(.black))
                    .foregroundStyle(MarketplaceTheme.purple)
                Text(product?.title ?? currentThread.subject)
                    .font(.headline.weight(.black))
                    .foregroundStyle(MarketplaceTheme.text)
                Text(statusLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MarketplaceTheme.muted)
            }
            Spacer()
        }
        .padding(14)
        .marketplaceCard(cornerRadius: 22)
    }

    private var statusLine: String {
        if currentThread.isBlocked { return "Shop messaging blocked" }
        if currentThread.isMuted { return "Muted • Delivered silently" }
        return "Private Shop conversation"
    }

    private func messageBubble(_ message: ShopConversation.ShopMessage) -> some View {
        VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
            Text(message.deletedForMe ? "Message removed" : message.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(message.isMine ? .white : MarketplaceTheme.text)
                .padding(12)
                .background(message.isMine ? MarketplaceTheme.purple : MarketplaceTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(message.isMine ? Color.clear : MarketplaceTheme.border, lineWidth: 1))
            Text("\(message.date.formatted(date: .omitted, time: .shortened)) • \(message.status.capitalized)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(MarketplaceTheme.faint)
        }
        .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
    }

    @ViewBuilder
    private var composer: some View {
        if currentThread.isBlocked {
            Text(currentThread.blockedBySeller ? "You blocked this user." : "This user is unavailable for Shop messaging.")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(MarketplaceTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(16)
                .marketplaceCard(cornerRadius: 18)
                .padding(16)
        } else {
            HStack(spacing: 10) {
                TextField(
                    "Private shop message",
                    text: $draft,
                    prompt: Text("Private shop message")
                        .foregroundStyle(MarketplaceTheme.muted),
                    axis: .vertical
                )
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .foregroundStyle(MarketplaceTheme.text)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .accessibilityIdentifier("marketplace.chat.message")
                Button {
                    sendDraft()
                } label: {
                    OneWayResolvedIcon(systemName: "paperplane.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(MarketplaceTheme.purple, in: Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                .accessibilityLabel("Send shop message")
                .accessibilityHint("Sends the message entered in the text field.")
                .accessibilityIdentifier("marketplace.chat.send")
            }
            .padding(14)
            .marketplaceCard(cornerRadius: 18)
            .padding(16)
        }
    }

    private func sendDraft() {
        let message = draft
        Task {
            if await viewModel.sendShopMessage(threadID: currentThread.id, text: message, asSeller: mode == .seller) {
                draft = ""
            }
        }
    }
}

struct ShopReportConversationView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let thread: ShopConversation
    let asSeller: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var reason = "Spam"
    @State private var reportAndBlock = false
    private let reasons = ["Spam", "Harassment", "Scam or fraud", "Prohibited item", "Abusive language", "Unwanted promotional contact", "Impersonation", "Payment request outside OneWay", "Other"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Reason", selection: $reason) {
                    ForEach(reasons, id: \.self) { Text($0) }
                }
                Toggle("Report and Block", isOn: $reportAndBlock)
                Text("Reports preserve relevant message IDs without exposing encryption keys or private media contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Report Conversation")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Submit") {
                        viewModel.reportThread(thread, reason: reason, block: reportAndBlock, asSeller: asSeller)
                        dismiss()
                    }
                }
            }
        }
    }
}
