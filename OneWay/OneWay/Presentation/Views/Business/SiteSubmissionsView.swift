import SwiftUI

struct SiteSubmissionsView: View {
    @ObservedObject var viewModel: OneWaySitesViewModel
    let site: OneWayBuilderSite
    @Environment(\.dismiss) private var dismiss
    @State private var inquiries: [SiteStoreInquiry] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var replyTo: String?
    @State private var reply = ""
    @State private var sending = false
    private let service = NetworkSiteStoreService()

    var body: some View {
        ZStack {
            OneWayCallTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MarketplaceBackBar(title: "Website Enquiries") { dismiss() } trailing: { Button("Refresh") { Task { await load() } } }
                    if loading { ProgressView("Loading enquiries…") }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange).font(.subheadline) }
                    if !loading && inquiries.isEmpty { ContentUnavailableView("No enquiries yet", systemImage: "tray", description: Text("Messages submitted on your published website appear here. Pull to refresh.")) }
                    ForEach(inquiries) { inquiry in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(inquiry.displayName).font(.headline)
                            Text(inquiry.customerEmail).font(.caption).foregroundStyle(OneWayCallTheme.purple)
                            Text("Unverified visitor enquiry").font(.caption2).foregroundStyle(.secondary)
                            Text(inquiry.message).font(.subheadline).textSelection(.enabled)
                            if !inquiry.ownerReply.isEmpty { Text(inquiry.ownerReply).font(.subheadline); Text("Reply status: " + (inquiry.replyStatus ?? "Pending")).font(.caption).foregroundStyle(.secondary) }
                            if replyTo == inquiry.id {
                                TextField("Write a reply", text: $reply, axis: .vertical).textFieldStyle(OneWayFormFieldStyle())
                                Text("Sends an email to " + inquiry.customerEmail).font(.caption).foregroundStyle(.secondary)
                                Button(sending ? "Sending…" : "Send reply") { Task { await sendReply(inquiry) } }.buttonStyle(.borderedProminent).disabled(sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Cancel") { replyTo = nil; reply = "" }.disabled(sending)
                            } else { Button("Reply") { replyTo = inquiry.id; reply = "" }.disabled(inquiry.customerEmail.isEmpty) }
                        }.padding(18).oneWayCallGlass(cornerRadius: 18)
                    }
                }.padding(18).padding(.bottom, 120)
            }.refreshable { await load() }
        }.navigationBarHidden(true).task { await load() }
    }
    @MainActor private func load() async {
        guard !loading else { return }; loading = true; errorMessage = nil
        defer { loading = false }
        do { inquiries = try await service.inquiries(domainSlug: site.oneWaySlug) }
        catch { errorMessage = "Enquiries could not load. Your messages are preserved on the server; try again." }
    }
    @MainActor private func sendReply(_ inquiry: SiteStoreInquiry) async {
        guard !sending else { return }; sending = true; errorMessage = nil
        defer { sending = false }
        do {
            let updated = try await service.replyToInquiry(domainSlug: site.oneWaySlug, inquiryId: inquiry.id, message: reply)
            if let index = inquiries.firstIndex(where: { $0.id == updated.id }) { inquiries[index] = updated }
            replyTo = nil; reply = ""
        } catch { errorMessage = "The reply could not be sent. Your draft is still here; try again." }
    }
}
