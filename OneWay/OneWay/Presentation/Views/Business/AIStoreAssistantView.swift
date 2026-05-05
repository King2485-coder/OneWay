import SwiftUI
import Combine
import PhotosUI

struct AIStoreAssistantView: View {
    enum Step: Int {
        case intro, details, layout, products, pages, checkout, review
    }

    @ObservedObject var viewModel: BusinessViewModel
    @State private var currentStep: Step = .intro
    @State private var selectedLayout: BusinessViewModel.LayoutOption = .grid
    @State private var pendingImageProductID: UUID?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var uploadProgress: Double = 0
    @State private var isGenerating = false

    let onPreviewDraft: () -> Void
    let onApplyDraft: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .padding(.horizontal)
                .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch currentStep {
                    case .intro: introStep
                    case .details: detailsStep
                    case .layout: layoutStep
                    case .products: productsStep
                    case .pages: pagesStep
                    case .checkout: checkoutStep
                    case .review: reviewStep
                    }

                    historySection
                    draftSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }

            Divider()
            bottomBar
        }
        .navigationTitle("AI Assistant")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { onClose() }
            }
        }
        .photosPicker(isPresented: Binding(get: { pendingImageProductID != nil }, set: { presented in
            if !presented { pendingImageProductID = nil }
        }), selection: Binding(get: { photoPickerItem }, set: { photoPickerItem = $0 }), matching: .images, preferredItemEncoding: .automatic)
        .onChange(of: photoPickerItem) { _, newItem in
            guard let id = pendingImageProductID, let item = newItem else { return }
            Task {
                uploadProgress = 0.05
                if let data = try? await item.loadTransferable(type: Data.self) {
                    uploadProgress = 0.6
                    if let idx = viewModel.builder.products.firstIndex(where: { $0.id == id }) {
                        viewModel.builder.products[idx].imageData = data
                        viewModel.builder.products[idx].imageName = item.itemIdentifier ?? "image.jpg"
                    }
                    uploadProgress = 1.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        uploadProgress = 0
                    }
                }
                pendingImageProductID = nil
                photoPickerItem = nil
            }
        }
    }

    // MARK: Steps

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome to your AI storefront builder.")
                .font(.headline)
            Text("I’ll guide you through quick steps and build a publishable store inside OneWay.")
                .foregroundStyle(.secondary)
        }
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Store basics").font(.headline)
            TextField("Store name", text: $viewModel.builder.storeName)
                .textFieldStyle(.roundedBorder)
            TextField("Tagline", text: $viewModel.builder.tagline)
                .textFieldStyle(.roundedBorder)
            TextField("Business category", text: $viewModel.builder.category)
                .textFieldStyle(.roundedBorder)
            TextField("Preferred colors (comma-separated hex or names)", text: $viewModel.builder.preferredColors)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var layoutStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a layout").font(.headline)
            Picker("Layout", selection: $selectedLayout) {
                Text("Grid").tag(BusinessViewModel.LayoutOption.grid)
                Text("List").tag(BusinessViewModel.LayoutOption.list)
                Text("Hero + grid").tag(BusinessViewModel.LayoutOption.hero)
            }
            .pickerStyle(.segmented)
            Text("You can change this later. We’ll build a neutral, Amazon-style page with sticky nav and clean cards.")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
        .onAppear {
            viewModel.builder.layout = selectedLayout
        }
        .onChange(of: selectedLayout) { _, value in
            viewModel.builder.layout = value
        }
    }

    private var productsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Products / services")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.addProductInput()
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
            }

            if viewModel.builder.products.isEmpty {
                Text("Add at least one product with name, price, description, and an image.")
                    .foregroundStyle(.secondary)
            }

            ForEach($viewModel.builder.products) { $product in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Name", text: $product.name)
                            .textFieldStyle(.roundedBorder)
                        TextField("Price", text: $product.price)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Button(role: .destructive) {
                            viewModel.removeProductInput(product.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                    TextField("Short description", text: $product.description, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            pendingImageProductID = product.id
                        } label: {
                            Label(product.imageData == nil ? "Upload image" : "Replace image", systemImage: "photo.on.rectangle")
                        }
                        if uploadProgress > 0 && pendingImageProductID == product.id {
                            ProgressView(value: uploadProgress)
                                .frame(width: 120)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
            }
        }
    }

    private var pagesStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Additional pages").font(.headline)
            Toggle("Include About page", isOn: bindingForExtraPage("About"))
            Toggle("Include Contact page", isOn: bindingForExtraPage("Contact"))
            Toggle("Include FAQ page", isOn: bindingForExtraPage("FAQ"))
        }
    }

    private var checkoutStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Catalog vs Checkout").font(.headline)
            Toggle("Enable cart & checkout", isOn: $viewModel.builder.wantsCheckout)
            Text("If off, we’ll show a catalog-only experience with messaging CTA.")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review & build").font(.headline)
            Group {
                Text("Store: \(viewModel.builder.storeName.isEmpty ? "Untitled Store" : viewModel.builder.storeName)")
                Text("Tagline: \(viewModel.builder.tagline.isEmpty ? "—" : viewModel.builder.tagline)")
                Text("Category: \(viewModel.builder.category.isEmpty ? "General" : viewModel.builder.category)")
                Text("Colors: \(viewModel.builder.preferredColors.isEmpty ? "Neutral defaults" : viewModel.builder.preferredColors)")
                Text("Layout: \(viewModel.builder.layout.rawValue.capitalized)")
                Text("Products: \(viewModel.builder.products.count)")
                Text("Pages: \(viewModel.builder.extraPages.joined(separator: ", "))")
                Text("Checkout: \(viewModel.builder.wantsCheckout ? "Enabled" : "Catalog-only")")
            }
            .foregroundStyle(.secondary)

            if isGenerating {
                ProgressView("Building your storefront…")
            } else {
                Button {
                    Task {
                        isGenerating = true
                        await viewModel.generateFromBuilder()
                        isGenerating = false
                    }
                } label: {
                    Label("Build storefront", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.aiHistory.isEmpty {
                Text("Recent AI actions").font(.headline)
                ForEach(viewModel.aiHistory.prefix(5)) { item in
                    HStack {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        if item.applied {
                            Text("Applied").font(.caption2).foregroundStyle(.green)
                        }
                        Spacer()
                        Text(item.suggestedAt, style: .time)
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private var draftSection: some View {
        Group {
            if let draft = viewModel.draft {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Draft ready").font(.headline)
                    Text("Preview or apply the AI-generated storefront.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Preview Draft") { onPreviewDraft() }
                            .buttonStyle(.bordered)
                        Button("Apply Changes") { onApplyDraft() }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("Last edited \(draft.lastEditedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("Back") {
                withAnimation {
                    currentStep = Step(rawValue: max(0, currentStep.rawValue - 1)) ?? .intro
                }
            }
            .disabled(currentStep == .intro)

            Spacer()

            Button(currentStep == .review ? "Done" : "Next") {
                withAnimation {
                    if currentStep == .review {
                        onClose()
                    } else {
                        currentStep = Step(rawValue: currentStep.rawValue + 1) ?? .review
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(nextDisabled)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var nextDisabled: Bool {
        switch currentStep {
        case .details:
            return viewModel.builder.storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .products:
            return viewModel.builder.products.isEmpty
        default:
            return false
        }
    }

    private var progressValue: Double {
        Double(currentStep.rawValue + 1) / Double(Step.review.rawValue + 1)
    }

    private func bindingForExtraPage(_ page: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { viewModel.builder.extraPages.contains(page) },
            set: { include in
                if include {
                    if !viewModel.builder.extraPages.contains(page) {
                        viewModel.builder.extraPages.append(page)
                    }
                } else {
                    viewModel.builder.extraPages.removeAll { $0 == page }
                }
            }
        )
    }
}
