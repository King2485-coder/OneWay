import SwiftUI
import Combine

struct SellerStudioHomeView: View {
    @ObservedObject var viewModel: BusinessViewModel
    let onOpenDraft: (Storefront) -> Void
    let onViewLive: () -> Void
    let onOpenTheme: () -> Void
    let onOpenProducts: () -> Void
    let onOpenCollections: () -> Void
    let onOpenPublish: () -> Void

    init(viewModel: BusinessViewModel,
         onOpenDraft: @escaping (Storefront) -> Void,
         onViewLive: @escaping () -> Void,
         onOpenTheme: @escaping () -> Void,
         onOpenProducts: @escaping () -> Void,
         onOpenCollections: @escaping () -> Void,
         onOpenPublish: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onOpenDraft = onOpenDraft
        self.onViewLive = onViewLive
        self.onOpenTheme = onOpenTheme
        self.onOpenProducts = onOpenProducts
        self.onOpenCollections = onOpenCollections
        self.onOpenPublish = onOpenPublish
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                overviewCard
                aiPanel
#if DEBUG
                debugInfo
#endif
                aiSuggestions
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Seller Studio")
        .task { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manage your storefront")
                .font(.title.bold())
            Text("Preview, publish, and improve with AI.")
                .foregroundStyle(.secondary)
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let draft = viewModel.draft {
                Text(draft.storefront.business.name)
                    .font(.headline)
                Text("Draft updated \(draft.lastEditedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let live = viewModel.publishedStorefront {
                Text(live.business.name).font(.headline)
                Text("Published").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No storefront yet").font(.headline)
                Text("Ask AI or start from scratch to create your store.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("View live") { onViewLive() }
                Button(draftButtonTitle) { onOpenPublish() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.glassSurface))
    }

    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Store Assistant")
                .font(.title3.weight(.semibold))
            Text("Ask the AI to build or update your storefront. Responses apply directly to your draft.")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            HStack(spacing: 8) {
                ForEach([
                    "Create my storefront",
                    "Add products",
                    "Design a theme",
                    "Write store copy"
                ], id: \.self) { chip in
                    Button {
                        viewModel.prompt = chip
                    } label: {
                        Text(chip)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Theme.glassSurface))
                    }
                    .buttonStyle(.plain)
                }
            }

            TextEditor(text: $viewModel.prompt)
                .frame(minHeight: 110)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))

            Button {
                Task { await viewModel.generate() }
            } label: {
                HStack {
                    if viewModel.mode == .generating {
                        ProgressView()
                    }
                    Text(viewModel.mode == .generating ? "Sending to AI…" : "Send to AI")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.mode == .generating || viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let draft = viewModel.draft {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Storefront ready")
                        .font(.headline)
                    Text("AI created a draft storefront. You can open or manage it now.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Open Draft") {
                            onOpenDraft(draft.storefront)
                        }
                        Button("Publish") {
                            Task { await viewModel.togglePublish() }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.glassSurface))
    }

#if DEBUG
    private var debugInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug")
                .font(.headline)
            HStack {
                Text("Base URL")
                Spacer()
                Text(APIConfig.baseURL)
                    .font(.footnote)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("AI Endpoint")
                Spacer()
                Text(viewModel.lastAIEndpoint.isEmpty ? "/api/ai/storefronts/generate" : viewModel.lastAIEndpoint)
                    .font(.footnote)
                    .multilineTextAlignment(.trailing)
            }
            if !viewModel.lastAIBody.isEmpty {
                Text("Last Body: \(viewModel.lastAIBody)")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
            }
            if !viewModel.lastAIError.isEmpty {
                Text("Last Error: \(viewModel.lastAIError)")
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.glassSurface))
    }
#endif

    private var aiSuggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI recommendations")
                .font(.title3.weight(.semibold))
            if viewModel.aiHistory.isEmpty {
                Text("No suggestions yet. Ask AI to improve your store.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.aiHistory) { suggestion in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title).font(.headline)
                        Text(suggestion.description).font(.subheadline).foregroundStyle(.secondary)
                        Text(suggestion.suggestedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
                }
            }
        }
    }

    private var draftButtonTitle: String {
        viewModel.publishedStorefront == nil ? "Publish" : "Unpublish"
    }
}
