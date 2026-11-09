import SwiftUI

enum ShopPolicyTemplate {
    static let example = ShopPolicySections(
        processingTimes: "Orders are normally prepared within 2–3 business days. Processing time may be longer during weekends, holidays, or periods of high demand.",
        shippingAndDelivery: "Estimated delivery dates are provided during checkout. Delivery times may vary based on the destination and shipping carrier. The buyer is responsible for providing a complete and accurate delivery address.",
        returnsAndExchanges: "Return or exchange requests must be submitted within 14 days after delivery. Items must be unused, in their original condition, and returned with their original packaging. Personalized, perishable, and downloaded digital items are not eligible for return unless they arrive damaged or incorrect.",
        refunds: "Approved refunds are issued to the original payment method after the returned item has been received and inspected. Original shipping costs are not refundable unless the order arrived damaged, defective, or incorrect. Bank processing times may vary.",
        cancellations: "Cancellation requests must be submitted before the order has shipped or entered production. Orders that have already shipped, been personalized, or been completed may not be eligible for cancellation.",
        digitalProducts: "Digital products are delivered electronically and are not shipped. Because access is provided immediately, digital purchases are generally nonrefundable unless the file is defective, inaccessible, or materially different from its description.",
        damagedOrIncorrectOrders: "If an order arrives damaged, defective, or incorrect, contact the seller within 7 days of delivery. Include the order number and clear photos of the item and packaging so the seller can review the issue.",
        privacyAndCustomerInformation: "Customer information is used only to process orders, provide support, prevent fraud, and meet applicable legal requirements. Sellers must not use buyer information for unrelated marketing or share it with unauthorized parties.",
        contactingTheSeller: "Use OneWay’s buyer-to-seller messaging to ask questions about an item, order, return, or refund. Include your order number when requesting help with an existing purchase.",
        customPolicy: "Add any additional terms that apply specifically to this shop or its products."
    )

    static let fields: [(String, WritableKeyPath<ShopPolicySections, String>)] = [
        ("Processing Times", \.processingTimes),
        ("Shipping and Delivery", \.shippingAndDelivery),
        ("Returns and Exchanges", \.returnsAndExchanges),
        ("Refunds", \.refunds),
        ("Cancellations", \.cancellations),
        ("Digital Products", \.digitalProducts),
        ("Damaged or Incorrect Orders", \.damagedOrIncorrectOrders),
        ("Privacy and Customer Information", \.privacyAndCustomerInformation),
        ("Contacting the Seller", \.contactingTheSeller),
        ("Custom Policy", \.customPolicy)
    ]
}

struct ShopPoliciesView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let requestedShopID: UUID?
    let onCreateShop: () -> Void
    let onBack: () -> Void

    @State private var selectedShopID: UUID?
    @State private var sections = ShopPolicyTemplate.example
    @State private var persistedSections: ShopPolicySections?
    @State private var publishedSections: ShopPolicySections?
    @State private var version = 0
    @State private var status = "Example"
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showPreview = false
    @State private var expanded = Set(ShopPolicyTemplate.fields.map(\.0))
    @FocusState private var focusedSection: String?

    private var selectedShop: MarketplaceShop? {
        guard let selectedShopID else { return nil }
        return viewModel.sellerShops.first { $0.id == selectedShopID }
    }

    private var hasUnsavedChanges: Bool { persistedSections != sections }

    var body: some View {
        ZStack {
            MarketplaceTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    shopChooser
                    if selectedShop != nil {
                        statusCard
                        legalNote
                        ForEach(ShopPolicyTemplate.fields, id: \.0) { field in
                            policyEditor(title: field.0, keyPath: field.1)
                        }
                        actionButtons
                    } else if viewModel.sellerShops.isEmpty {
                        noShopCard
                    }
                }
                .padding(18)
                .padding(.bottom, 80)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { focusedSection = nil }
        }
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) { MarketplaceBackBar(title: "Shop Policies", onBack: onBack) }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedSection = nil }
            }
        }
        .task {
            selectedShopID = requestedShopID ?? viewModel.sellerShopID ?? viewModel.sellerShops.first?.id
            if selectedShopID != nil { await load() }
        }
        .onChange(of: selectedShopID) { _, newValue in
            guard newValue != nil else { return }
            Task { await load() }
        }
        .sheet(isPresented: $showPreview) {
            ShopPoliciesPreview(shop: selectedShop, sections: sections, version: max(1, version))
        }
    }

    @ViewBuilder private var shopChooser: some View {
        if viewModel.sellerShops.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose Shop").font(.headline.weight(.black)).foregroundStyle(.white)
                Picker("Shop", selection: $selectedShopID) {
                    ForEach(viewModel.sellerShops) { shop in Text(shop.name).tag(Optional(shop.id)) }
                }
                .pickerStyle(.menu)
                .tint(MarketplaceTheme.purple)
            }
            .padding(16).marketplaceCard()
        } else if let selectedShop {
            HStack(spacing: 12) {
                OneWayPhysicalIcon(role: .shops, size: 48, container: .none, accessibilityLabel: selectedShop.name)
                VStack(alignment: .leading) {
                    Text(selectedShop.name).font(.title2.weight(.black)).foregroundStyle(.white)
                    Text("Policies are stored for this shop only.").foregroundStyle(MarketplaceTheme.muted)
                }
            }
            .padding(16).marketplaceCard()
        }
    }

    private var statusCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(hasUnsavedChanges ? "Unsaved changes" : status)
                    .font(.headline.weight(.black))
                    .foregroundStyle(hasUnsavedChanges ? .orange : MarketplaceTheme.purple)
                Text(version > 0 ? "Published policy version \(version)" : "Not published")
                    .font(.caption.weight(.bold)).foregroundStyle(MarketplaceTheme.muted)
            }
            Spacer()
            if isLoading || isSaving { ProgressView().tint(MarketplaceTheme.purple) }
        }
        .padding(16).marketplaceCard()
    }

    private var legalNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Example Policy — Customize Before Publishing").font(.headline.weight(.black)).foregroundStyle(.orange)
            Text("Shop policies must follow OneWay’s platform rules and applicable laws. This example does not guarantee legal compliance.")
                .font(.caption.weight(.semibold)).foregroundStyle(MarketplaceTheme.muted)
        }
        .padding(16).marketplaceCard()
    }

    private func policyEditor(title: String, keyPath: WritableKeyPath<ShopPolicySections, String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) }
            } label: {
                HStack {
                    Text(title).font(.headline.weight(.black)).foregroundStyle(.white)
                    Spacer()
                    OneWayResolvedIcon(systemName: expanded.contains(title) ? "chevron.up" : "chevron.down")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.contains(title) {
                TextEditor(text: Binding(
                    get: { sections[keyPath: keyPath] },
                    set: { sections[keyPath: keyPath] = $0 }
                ))
                .focused($focusedSection, equals: title)
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white)
                .frame(minHeight: 130)
                .padding(10)
                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 16))
                HStack {
                    Button("Clear") { sections[keyPath: keyPath] = "" }
                    Spacer()
                    Button("Restore Example") { sections[keyPath: keyPath] = ShopPolicyTemplate.example[keyPath: keyPath] }
                }
                .font(.caption.weight(.black)).tint(MarketplaceTheme.purple)
            }
        }
        .padding(16).marketplaceCard()
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button("Preview as Buyer") { focusedSection = nil; showPreview = true }
                .buttonStyle(PolicyOutlineButtonStyle())
            Button(isSaving ? "Saving…" : "Save Policies") { Task { await save(publish: false) } }
                .buttonStyle(PolicyPrimaryButtonStyle()).disabled(isSaving)
            Button(isSaving ? "Publishing…" : "Publish Policies") { Task { await save(publish: true) } }
                .buttonStyle(PolicyPrimaryButtonStyle()).disabled(isSaving)
            if let errorMessage { Text(errorMessage).foregroundStyle(.orange).font(.caption.weight(.bold)) }
        }
    }

    private var noShopCard: some View {
        VStack(spacing: 14) {
            Text("Create a Shop first").font(.title2.weight(.black)).foregroundStyle(.white)
            Text("Policies belong to an individual shop.").foregroundStyle(MarketplaceTheme.muted)
            Button("Create Shop", action: onCreateShop).buttonStyle(PolicyPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(20).marketplaceCard()
    }

    private func load() async {
        guard let selectedShopID else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let document = try await StorefrontService.shared.fetchShopPolicies(shopID: selectedShopID)
            let loaded = document.sections ?? ShopPolicyTemplate.example
            sections = loaded
            persistedSections = document.sections
            publishedSections = document.publishedSections
            version = document.version
            status = document.publishedSections == nil ? (document.sections == nil ? "Example" : "Draft saved") : "Published"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(publish: Bool) async {
        guard let selectedShopID else { return }
        focusedSection = nil; isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            var document = try await StorefrontService.shared.saveShopPolicies(shopID: selectedShopID, sections: sections)
            persistedSections = document.sections
            status = "Draft saved"
            if publish {
                document = try await StorefrontService.shared.publishShopPolicies(shopID: selectedShopID)
                publishedSections = document.publishedSections
                version = document.version
                status = "Published"
            }
            MarketplaceHaptics.success()
        } catch {
            errorMessage = "Your changes are still here. \(error.localizedDescription)"
        }
    }
}

struct BuyerShopPoliciesView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let shopID: UUID
    let onBack: () -> Void
    let onMessage: (UUID) -> Void
    @State private var document: PublicShopPolicyDocument?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            MarketplaceTheme.background.ignoresSafeArea()
            ScrollView {
                if let document {
                    VStack(alignment: .leading, spacing: 14) {
                        ShopPoliciesPreviewContent(shop: viewModel.shop(shopID), sections: document.sections, version: document.version)
                        Button("Message Seller") {
                            guard let shop = viewModel.shop(shopID) else { return }
                            Task { if let id = await viewModel.startShopConversation(shop: shop) { onMessage(id) } }
                        }
                        .buttonStyle(PolicyPrimaryButtonStyle())
                    }.padding(18).padding(.bottom, 80)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(MarketplaceTheme.muted).padding(24)
                } else { ProgressView().tint(MarketplaceTheme.purple) }
            }
        }
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) { MarketplaceBackBar(title: "Shop Policies", onBack: onBack) }
        .task {
            do { document = try await StorefrontService.shared.fetchPublishedShopPolicies(shopID: shopID) }
            catch { errorMessage = "This shop has not published policies yet." }
        }
    }
}

private struct ShopPoliciesPreview: View {
    let shop: MarketplaceShop?
    let sections: ShopPolicySections
    let version: Int
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack { MarketplaceTheme.background.ignoresSafeArea(); ScrollView { ShopPoliciesPreviewContent(shop: shop, sections: sections, version: version).padding(18) } }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ShopPoliciesPreviewContent: View {
    let shop: MarketplaceShop?
    let sections: ShopPolicySections
    let version: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop?.name ?? "OneWay Shop").font(.largeTitle.weight(.black)).foregroundStyle(.white)
            Text("Published Shop Policies · Version \(version)").font(.caption.weight(.bold)).foregroundStyle(MarketplaceTheme.purple)
            ForEach(ShopPolicyTemplate.fields, id: \.0) { title, keyPath in
                let value = sections[keyPath: keyPath]
                if !value.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title).font(.headline.weight(.black)).foregroundStyle(.white)
                        Text(value).foregroundStyle(MarketplaceTheme.muted)
                    }.padding(16).marketplaceCard()
                }
            }
        }
    }
}

private struct PolicyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline.weight(.black)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(MarketplaceTheme.gradient, in: Capsule()).opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct PolicyOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline.weight(.black)).foregroundStyle(MarketplaceTheme.purple)
            .frame(maxWidth: .infinity, minHeight: 50)
            .overlay(Capsule().stroke(MarketplaceTheme.purple, lineWidth: 2)).opacity(configuration.isPressed ? 0.7 : 1)
    }
}
