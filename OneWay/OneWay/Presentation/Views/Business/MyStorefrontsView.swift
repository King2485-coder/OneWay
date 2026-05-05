import SwiftUI
import Combine

struct MyStorefrontsView: View {
    @ObservedObject var viewModel: BusinessViewModel
    let onOpen: (Storefront) -> Void
    @State private var showCreateSheet = false
    @State private var newName: String = ""
    @State private var newCategory: String = ""
    @State private var newTagline: String = ""
    @State private var storefrontToDelete: Storefront?
    @State private var isDeleting = false

    var body: some View {
        List {
            Section {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create storefront", systemImage: "plus.circle.fill")
                }
            }

            Section("My storefronts") {
                ForEach(viewModel.storefronts) { store in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(store.business.name)
                                .font(.headline)
                            Spacer()
                            statusPill(isPublished: store.isPublished)
                        }
                        Text(store.business.tagline)
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        HStack(spacing: 12) {
                            Button("Open") {
                                onOpen(store)
                            }
                            Button(store.isPublished ? "Unpublish" : "Publish") {
                                Task { await viewModel.togglePublish(store: store) }
                            }
                            Button("Delete", role: .destructive) {
                                storefrontToDelete = store
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("My Storefronts")
        .sheet(isPresented: $showCreateSheet) {
            NavigationStack {
                Form {
                    Section("Details") {
                        TextField("Store name", text: $newName)
                        TextField("Category", text: $newCategory)
                        TextField("Tagline", text: $newTagline)
                    }
                }
                .navigationTitle("Create storefront")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showCreateSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            Task {
                                await viewModel.createStorefront(name: newName, category: newCategory, tagline: newTagline)
                                await viewModel.load()
                                showCreateSheet = false
                                newName = ""
                                newCategory = ""
                                newTagline = ""
                            }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .alert("Delete storefront?", isPresented: Binding(get: { storefrontToDelete != nil }, set: { if !$0 { storefrontToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                guard let id = storefrontToDelete?.id else { return }
                isDeleting = true
                Task {
                    await viewModel.deleteStorefront(id)
                    storefrontToDelete = nil
                    isDeleting = false
                }
            }
            Button("Cancel", role: .cancel) {
                storefrontToDelete = nil
            }
        } message: {
            Text("This will permanently remove the storefront and its data.")
        }
    }

    private func statusPill(isPublished: Bool) -> some View {
        Text(isPublished ? "Published" : "Draft")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(isPublished ? Color.green.opacity(0.2) : Color.orange.opacity(0.2)))
    }
}
