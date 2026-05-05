import SwiftUI
import Combine
import Foundation

struct BusinessHomeView: View {
    private enum Mode: Int {
        case shop = 0
        case manage = 1
    }

    @StateObject private var viewModel: BusinessViewModel

    @State private var selectedStorefront: Storefront?
    @State private var isOwner = true // TODO: derive from auth/owner relationship
    @State private var mode: Mode = .shop
    @State private var showLiveStore = false
    @State private var showDraftPreview = false

    init(businessService: BusinessService, aiStorefrontService: AIStorefrontService, searchService: BusinessSearchService) {
        _viewModel = StateObject(wrappedValue: BusinessViewModel(businessService: businessService, aiStorefrontService: aiStorefrontService, searchService: searchService))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                modeToggle
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Group {
                    switch mode {
                    case .shop:
                        marketplaceTab
                    case .manage:
                        sellerTab
                    }
                }
            }
            .background { SideMenuBackground() }
            .navigationTitle(mode == .shop ? "Business" : "Seller Studio")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await viewModel.load()
            selectedStorefront = viewModel.storefront
        }
        .alert("Business",
               isPresented: Binding(get: { viewModel.errorMessage != nil },
                                    set: { newValue in if !newValue { viewModel.errorMessage = nil } })) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $showLiveStore) {
            if let store = selectedStorefront ?? viewModel.publishedStorefront ?? viewModel.storefront {
                NavigationStack {
                    LiveStorefrontView(storefront: store, onMessageSeller: {}, onShare: {})
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showLiveStore = false }
                            }
                        }
                }
            }
        }
    }

    private var marketplaceTab: some View {
        ShopFeedView {
            mode = .manage
        }
    }

    @State private var openThemeEditor = false
    @State private var openProductManager = false
    @State private var openCollectionManager = false
    @State private var openPublish = false
    @State private var showStorefronts = false

    private func open(store: Storefront) {
        viewModel.selectStorefront(store)
        selectedStorefront = store
        if store.isPublished {
            showLiveStore = true
        } else {
            mode = .manage
        }
    }

    private var sellerTab: some View {
        SellerStudioHomeView(
            viewModel: viewModel,
            onOpenDraft: { store in
                // Draft preview should feel like a real "store" surface (buyer UI),
                // not just a state change. Keep the user un-stuck with a clear close.
                viewModel.selectStorefront(store)
                selectedStorefront = store
                showDraftPreview = true
            },
            onViewLive: {
                selectedStorefront = viewModel.publishedStorefront ?? viewModel.storefront
                showLiveStore = selectedStorefront != nil
            },
            onOpenTheme: { openThemeEditor = true },
            onOpenProducts: { openProductManager = true },
            onOpenCollections: { openCollectionManager = true },
            onOpenPublish: { openPublish = true }
        )
        .navigationDestination(isPresented: $openThemeEditor) {
            ThemeEditorView(onAskAI: { })
        }
        .navigationDestination(isPresented: $openProductManager) {
            ProductManagerView(products: viewModel.storefront?.sections.first(where: { $0.type == .products })?.items ?? [], onAskAI: { })
        }
        .navigationDestination(isPresented: $openCollectionManager) {
            CollectionManagerView(collections: [], onAskAI: { })
        }
        .navigationDestination(isPresented: $openPublish) {
            PublishSettingsView(isPublished: viewModel.storefront?.isPublished ?? false) { _ in
                Task { await viewModel.togglePublish() }
            } onAskAI: { }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("My Storefronts") {
                    showStorefronts = true
                }
            }
        }
        .sheet(isPresented: $showStorefronts) {
            NavigationStack {
                MyStorefrontsView(viewModel: viewModel) { store in
                    showStorefronts = false
                    open(store: store)
                }
            }
        }
        .sheet(isPresented: $showDraftPreview) {
            if let draft = viewModel.draft {
                NavigationStack {
                    LiveStorefrontView(storefront: draft.storefront, onMessageSeller: {}, onShare: {})
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showDraftPreview = false }
                            }
                        }
                }
            }
        }
    }

    private var modeToggle: some View {
        Picker("Mode", selection: $mode) {
            Text("Shop").tag(Mode.shop)
            Text("Manage").tag(Mode.manage)
        }
        .pickerStyle(.segmented)
    }
}
