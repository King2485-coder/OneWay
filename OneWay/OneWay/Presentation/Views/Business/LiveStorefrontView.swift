import SwiftUI

private enum OneWayBankFeature {
    static let paymentsEnabled = false
}

struct LiveStorefrontView: View {
    let storefront: Storefront
    let onMessageSeller: () -> Void
    let onShare: () -> Void
    private let analyticsService = NetworkSiteStoreService()

    @State private var activeSheet: BuyerSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sellerHeader
                contactButtons
                featuredSection
                productGrid
                sellerInfo
                about
                policySection
                reviewsPlaceholder
            }
            .padding(.bottom, 24)
        }
        .background { SideMenuBackground() }
        .navigationTitle(storefront.business.name)
        .task {
            await track(.storefrontView, product: nil)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .product(let product):
                ProductDetailSheet(
                    storefront: storefront,
                    product: product,
                    analyticsService: analyticsService,
                    onRequest: { quantity, fulfillment in
                        activeSheet = .request(product: product, quantity: quantity, fulfillment: fulfillment)
                    },
                    onClose: { activeSheet = nil }
                )
            case .request(let product, let quantity, let fulfillment):
                RequestToBuySheet(
                    storefront: storefront,
                    product: product,
                    initialQuantity: quantity,
                    initialFulfillmentPreference: fulfillment,
                    onClose: { activeSheet = nil }
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Text("Share")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        Task { await track(.shareClicked, product: nil) }
                    })
                } else {
                    Button("Share") {
                        Task { await track(.shareClicked, product: nil) }
                        onShare()
                    }
                }
                Button("Message") {
                    Task { await track(.requestToBuyStarted, product: nil) }
                    activeSheet = .request(
                        product: nil,
                        quantity: 1,
                        fulfillment: storefront.business.pickupEnabled == true ? "pickup" : "shipping"
                    )
                    onMessageSeller()
                }
            }
        }
    }

    private enum BuyerSheet: Identifiable {
        case product(ProductOrService)
        case request(product: ProductOrService?, quantity: Int, fulfillment: String)

        var id: String {
            switch self {
            case .product(let product): return "product-\(product.id.uuidString)"
            case .request(let product, let quantity, let fulfillment):
                return "request-\(product?.id.uuidString ?? "shop")-\(quantity)-\(fulfillment)"
            }
        }
    }

    private var shareURL: URL? {
        if let shopURL = storefront.shopURL {
            return URL(string: shopURL.hasPrefix("http") ? shopURL : "https://\(shopURL)")
        }
        guard !storefront.slug.isEmpty else { return nil }
        return APIConfig.storefrontPublicURL(for: storefront.slug)
    }

    private func track(_ event: SiteStoreAnalyticsEventType, product: ProductOrService?) async {
        let slug = storefront.slug.isEmpty ? (storefront.business.handle ?? storefront.business.name) : storefront.slug
        try? await analyticsService.trackEvent(
            domainSlug: slug,
            eventType: event,
            productId: product?.id.uuidString,
            metadata: ["surface": "ios_storefront"]
        )
    }

    private var sellerHeader: some View {
        ZStack(alignment: .bottomLeading) {
            bannerBackground

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 12) {
                    logoImage
                    VStack(alignment: .leading, spacing: 4) {
                        Text(storefront.business.name)
                            .font(.largeTitle.weight(.bold))
                        Text(storefront.business.tagline)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("OneWay shop")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if let announcement = storefront.business.announcement, !announcement.isEmpty {
                    Text(announcement)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.glassSurface))
                }
            }
            .padding(16)
        }
    }

    private var bannerBackground: some View {
        ZStack {
            LinearGradient(colors: [Theme.primaryBlue.opacity(0.35), Theme.glassSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url = storefront.business.coverImageURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
                .overlay(Color.black.opacity(0.42))
            }
        }
        .frame(height: 220)
        .clipped()
    }

    private var logoImage: some View {
        ZStack {
            Circle().fill(Theme.glassSurface)
            if let url = storefront.business.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        logoInitial
                    }
                }
                .clipShape(Circle())
            } else {
                logoInitial
            }
        }
        .frame(width: 76, height: 76)
        .overlay(Circle().stroke(Theme.divider, lineWidth: 1))
    }

    private var logoInitial: some View {
        Text(storefront.business.name.prefix(1))
            .font(.title.bold())
            .foregroundStyle(Theme.textPrimary)
    }

    private var contactButtons: some View {
        HStack(spacing: 10) {
            buyerAction("Chirp", icon: "waveform") { contactSeller() }
            buyerAction("Call", icon: "phone.fill") { contactSeller() }
            buyerAction("Message", icon: "bubble.left.and.bubble.right.fill") { contactSeller() }
            buyerAction("AI", icon: "sparkles") { contactSeller() }
        }
        .padding(.horizontal, 16)
    }

    private func buyerAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.headline)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.bordered)
    }

    private func contactSeller() {
        Task { await track(.requestToBuyStarted, product: nil) }
        activeSheet = .request(
            product: nil,
            quantity: 1,
            fulfillment: storefront.business.pickupEnabled == true ? "pickup" : "shipping"
        )
        onMessageSeller()
    }

    private var featuredSection: some View {
        if let hero = storefront.sections.first(where: { $0.type == .hero }) {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text(hero.title).font(.title.weight(.semibold))
                    if let body = hero.body {
                        Text(body).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.glassSurface))
                .padding(.horizontal, 16)
            )
        }
        return AnyView(EmptyView())
    }

    private var productGrid: some View {
        let items = storefront.sections.first(where: { $0.type == .products })?.items ?? storefront.business.products
        return VStack(alignment: .leading, spacing: 10) {
            Text("Products")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
            if items.isEmpty {
                Text("No products yet.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.glassSurface))
                    .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    ForEach(items) { item in
                        Button {
                            Task { await track(.productView, product: item) }
                            activeSheet = .product(item)
                        } label: {
                            StorefrontProductCard(product: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var sellerInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Seller info")
                .font(.title3.weight(.semibold))
            Text(storefront.business.sellerStory ?? "Seller story coming soon.")
                .foregroundStyle(.secondary)
            contactLines
            HStack(spacing: 12) {
                Button("Contact seller", action: contactSeller)
                    .buttonStyle(.borderedProminent)
                Button("Follow shop") { }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
        .padding(.horizontal, 16)
    }

    private var contactLines: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let email = storefront.business.contactEmail, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                OneWayResolvedLabel(email, systemImage: "envelope.fill")
            }
            if let phone = storefront.business.phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                OneWayResolvedLabel(phone, systemImage: "phone.fill")
            }
            if let website = storefront.business.website, !website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                OneWayResolvedLabel(website, systemImage: "link")
            }
            if let fulfillment = storefront.business.hours, !fulfillment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                OneWayResolvedLabel(fulfillment, systemImage: "shippingbox.fill")
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.title3.weight(.semibold))
            Text(storefront.business.description)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
        .padding(.horizontal, 16)
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Policies")
                .font(.title3.weight(.semibold))
            Text(storefront.policy?.shipping ?? "Seller-defined shipping details will appear here.")
                .foregroundStyle(.secondary)
            Text(storefront.policy?.returns ?? "Return policy coming soon.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
        .padding(.horizontal, 16)
    }

    private var reviewsPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reviews")
                .font(.title3.weight(.semibold))
            Text("No customer reviews yet.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glassSurface))
        .padding(.horizontal, 16)
    }
}

private struct StorefrontProductCard: View {
    let product: ProductOrService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            productImage
                .frame(height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(product.name)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Text(product.price)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accentGold)
            Text(availabilityText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(product.isSoldOut ? .orange : product.isLowStock ? Theme.accentGold : .green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.glassSurface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.divider, lineWidth: 1))
    }

    private var productImage: some View {
        ZStack {
            if let mediaURL = product.mediaURL {
                AsyncImage(url: mediaURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Theme.primaryBlue.opacity(0.45), Theme.accentGold.opacity(0.25)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            OneWayResolvedIcon(systemName: "shippingbox.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var isAvailable: Bool {
        !product.isSoldOut
    }

    private var availabilityText: String {
        if product.isSoldOut { return "Sold out" }
        if product.isLowStock, let inventory = product.inventory { return "Low stock: \(inventory)" }
        if product.tracksStock, let inventory = product.inventory { return "\(inventory) available" }
        return "Available"
    }
}

private struct ProductDetailSheet: View {
    @Environment(\.openURL) private var openURL

    let storefront: Storefront
    let product: ProductOrService
    let analyticsService: SiteStoreService
    let onRequest: (Int, String) -> Void
    let onClose: () -> Void
    @State private var quantity = 1
    @State private var fulfillmentPreference = "pickup"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StorefrontProductHero(product: product)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(product.name)
                            .font(.system(size: 32, weight: .heavy))
                        Text(product.price)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Theme.accentGold)
                        Text(product.description.isEmpty ? "Message the seller for details." : product.description)
                            .foregroundStyle(.secondary)
                        OneWayResolvedLabel(storefront.business.name, systemImage: "storefront.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        BuyerStatusPill(text: availabilityText, color: product.isSoldOut ? .orange : product.isLowStock ? Theme.accentGold : .green)

                        Stepper("Quantity: \(quantity)", value: $quantity, in: 1...99)
                            .font(.subheadline.weight(.semibold))

                        Picker("Fulfillment", selection: $fulfillmentPreference) {
                            ForEach(fulfillmentOptions, id: \.id) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 16)

                    Button(ctaTitle, action: handleCTA)
                        .buttonStyle(.borderedProminent)
                        .disabled(product.isSoldOut)
                        .padding(.horizontal, 16)

                    Text(footerHelpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 28)
            }
            .background { SideMenuBackground() }
            .navigationTitle("Product")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await track(.productView)
                fulfillmentPreference = fulfillmentOptions.first?.id ?? "pickup"
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }

    private var isAvailable: Bool {
        !product.isSoldOut
    }

    private var paymentLink: URL? {
        validPaymentURL(product.paymentLinkURL)
            ?? validPaymentURL(storefront.defaultPaymentLinkURL)
            ?? storefront.business.website.flatMap(URL.init(string:)).flatMap(validPaymentURL)
    }

    private var ctaTitle: String {
        if product.isSoldOut { return "Sold out" }
        if usesOneWayWallet { return "Pay with OneWay" }
        return paymentLink == nil ? "Request to buy" : "Buy now"
    }

    private var usesOneWayWallet: Bool {
        guard OneWayBankFeature.paymentsEnabled else { return false }
        if product.paymentMode == "oneway_wallet" { return true }
        if product.paymentMode == nil || product.paymentMode == "contact" {
            return storefront.defaultPaymentMode == "oneway_wallet"
        }
        return false
    }

    private var footerHelpText: String {
        if usesOneWayWallet {
            return "OneWay Wallet checkout is in test mode. You can simulate payment, and the seller will see the order as paid."
        }
        if paymentLink == nil {
            return "This seller has not enabled checkout yet. Contact seller to purchase."
        }
        return "This opens the seller's payment link. OneWay does not process the payment yet."
    }

    private var availabilityText: String {
        if product.isSoldOut { return "Sold out" }
        if product.isLowStock, let inventory = product.inventory { return "Low stock: \(inventory)" }
        if product.tracksStock, let inventory = product.inventory { return "\(inventory) available" }
        return "Available"
    }

    private var fulfillmentOptions: [FulfillmentOption] {
        let options = [
            storefront.business.pickupEnabled == true ? FulfillmentOption(id: "pickup", label: "Pickup") : nil,
            storefront.business.localDeliveryEnabled == true ? FulfillmentOption(id: "local_delivery", label: "Delivery") : nil,
            storefront.business.shippingEnabled == true ? FulfillmentOption(id: "shipping", label: "Shipping") : nil,
            storefront.business.digitalDeliveryEnabled == true ? FulfillmentOption(id: "digital", label: "Digital") : nil,
        ].compactMap { $0 }
        return options.isEmpty
            ? [
                FulfillmentOption(id: "pickup", label: "Pickup"),
                FulfillmentOption(id: "shipping", label: "Shipping"),
            ]
            : options
    }

    private func handleCTA() {
        if usesOneWayWallet {
            Task { await track(.oneWayWalletCheckoutStarted) }
            onRequest(quantity, fulfillmentPreference)
        } else if let paymentLink {
            Task { await track(.buyNowClicked) }
            openURL(paymentLink)
        } else {
            Task { await track(.requestToBuyStarted) }
            onRequest(quantity, fulfillmentPreference)
        }
    }

    private func track(_ event: SiteStoreAnalyticsEventType) async {
        let slug = storefront.slug.isEmpty ? (storefront.business.handle ?? storefront.business.name) : storefront.slug
        try? await analyticsService.trackEvent(
            domainSlug: slug,
            eventType: event,
            productId: product.id.uuidString,
            metadata: ["surface": "ios_product_detail"]
        )
    }

    private func validPaymentURL(_ url: URL?) -> URL? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

private struct BuyerStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct StorefrontProductHero: View {
    let product: ProductOrService

    var body: some View {
        ZStack {
            if let mediaURL = product.mediaURL {
                AsyncImage(url: mediaURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(height: 280)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Theme.primaryBlue.opacity(0.55), Color.purple.opacity(0.45), Theme.accentGold.opacity(0.3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            OneWayResolvedIcon(systemName: "bag.fill")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
        }
    }
}

private struct FulfillmentOption {
    let id: String
    let label: String
}

private struct RequestToBuySheet: View {
    let storefront: Storefront
    let product: ProductOrService?
    let initialQuantity: Int
    let initialFulfillmentPreference: String
    let service = StorefrontBuyerRequestService()
    let analyticsService = NetworkSiteStoreService()
    let onClose: () -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var quantity = "1"
    @State private var message = ""
    @State private var fulfillmentPreference = "pickup"
    @State private var preferredContactMethod = "oneway"
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let successMessage {
                        requestSuccess(successMessage)
                    } else {
                        formContent
                    }
                }
                .padding(16)
                .safeAreaPadding(.bottom, 40)
            }
            .background { SideMenuBackground() }
            .navigationTitle(product == nil ? "Contact seller" : "Request to buy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(successMessage == nil ? "Cancel" : "Done", action: onClose)
                }
            }
        }
        .onAppear {
            quantity = String(max(1, initialQuantity))
            let allowed = fulfillmentOptions.map(\.id)
            fulfillmentPreference = allowed.contains(initialFulfillmentPreference)
                ? initialFulfillmentPreference
                : (allowed.first ?? "pickup")
            if message.isEmpty {
                if let product {
                    message = "Hi, I’d like to buy \(product.name)."
                } else {
                    message = "Hi, I have a question about your shop."
                }
            }
            Task { await track(.requestToBuyStarted) }
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(product?.name ?? storefront.business.name)
                    .font(.title2.weight(.heavy))
                Text(product?.price ?? "The seller will reply soon.")
                    .foregroundStyle(Theme.accentGold)
            }

            Group {
                TextField("Your name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Phone or text number", text: $phone)
                    .keyboardType(.phonePad)
                TextField("Quantity", text: $quantity)
                    .keyboardType(.numberPad)
            }
            .textFieldStyle(OneWayFormFieldStyle())

            Picker("How would you like to receive it?", selection: $fulfillmentPreference) {
                ForEach(fulfillmentOptions, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .pickerStyle(.segmented)

            Picker("Preferred contact", selection: $preferredContactMethod) {
                Text("OneWay").tag("oneway")
                Text("Email").tag("email")
                Text("Phone").tag("phone")
                Text("Text").tag("text")
            }
            .pickerStyle(.segmented)

            TextField("Message", text: $message, axis: .vertical)
                .lineLimit(4...7)
                .textFieldStyle(OneWayFormFieldStyle())

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if usesOneWayWallet {
                Text("OneWay Wallet is in test mode. Do not use for real money movement.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            Button {
                Task { await submit() }
            } label: {
                HStack {
                    if isSubmitting { ProgressView() }
                    Text(isSubmitting ? "Sending..." : submitButtonTitle)
                        .fontWeight(.heavy)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || validationMessage != nil)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.glassSurface))
    }

    private func requestSuccess(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            OneWayResolvedIcon(systemName: "checkmark.seal.fill")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.green)
            Text("Request sent")
                .font(.system(size: 30, weight: .heavy))
            Text(message)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                OneWayResolvedLabel("Seller will reply soon", systemImage: "bubble.left.and.bubble.right.fill")
                OneWayResolvedLabel("Your request is saved in OneWay", systemImage: "tray.full.fill")
                OneWayResolvedLabel("You can share the shop while you wait", systemImage: "square.and.arrow.up")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)

            if let shareURL {
                ShareLink(item: shareURL) {
                    OneWayResolvedLabel("Share shop", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.glassSurface))
    }

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add your name so the seller knows who to reply to."
        }
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add an email or phone number so the seller can reply."
        }
        if Int(quantity) ?? 0 <= 0 {
            return "Quantity must be at least 1."
        }
        if let product, product.isSoldOut {
            return "This product is sold out right now."
        }
        if let product,
           product.tracksStock,
           let available = product.inventory,
           (Int(quantity) ?? 0) > available {
            return "Only \(available) available right now."
        }
        return nil
    }

    private var fulfillmentOptions: [FulfillmentOption] {
        let options = [
            storefront.business.pickupEnabled == true ? FulfillmentOption(id: "pickup", label: "Pickup") : nil,
            storefront.business.localDeliveryEnabled == true ? FulfillmentOption(id: "local_delivery", label: "Delivery") : nil,
            storefront.business.shippingEnabled == true ? FulfillmentOption(id: "shipping", label: "Shipping") : nil,
            storefront.business.digitalDeliveryEnabled == true ? FulfillmentOption(id: "digital", label: "Digital") : nil
        ].compactMap { $0 }
        return options.isEmpty
            ? [
                FulfillmentOption(id: "pickup", label: "Pickup"),
                FulfillmentOption(id: "shipping", label: "Shipping")
            ]
            : options
    }

    private var shareURL: URL? {
        if let shopURL = storefront.shopURL {
            return URL(string: shopURL.hasPrefix("http") ? shopURL : "https://\(shopURL)")
        }
        guard !storefront.slug.isEmpty else { return nil }
        return APIConfig.storefrontPublicURL(for: storefront.slug)
    }

    private var usesOneWayWallet: Bool {
        guard OneWayBankFeature.paymentsEnabled else { return false }
        if product?.paymentMode == "oneway_wallet" { return true }
        if product?.paymentMode == nil || product?.paymentMode == "contact" {
            return storefront.defaultPaymentMode == "oneway_wallet"
        }
        return false
    }

    private var submitButtonTitle: String {
        usesOneWayWallet ? "Pay with OneWay" : "Send request"
    }

    private func track(_ event: SiteStoreAnalyticsEventType, product: ProductOrService?) async {
        let slug = storefront.slug.isEmpty ? (storefront.business.handle ?? storefront.business.name) : storefront.slug
        try? await analyticsService.trackEvent(
            domainSlug: slug,
            eventType: event,
            productId: product?.id.uuidString,
            metadata: ["surface": "ios_storefront"]
        )
    }

    private func submit() async {
        if let validationMessage {
            errorMessage = validationMessage
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let response = try await service.submitRequest(
                storefront: storefront,
                product: product,
                name: name,
                email: email,
                phone: phone,
                quantity: Int(quantity) ?? 1,
                message: message,
                fulfillmentPreference: fulfillmentPreference,
                preferredContactMethod: preferredContactMethod
            )
            if usesOneWayWallet, let orderRequest = response.orderRequest {
                let wallet = try await service.startWalletCheckout(
                    storefront: storefront,
                    orderId: orderRequest.id,
                    amountCents: product?.priceCents ?? orderRequest.totalCents,
                    buyerWalletUserId: email.isEmpty ? phone : email
                )
                successMessage = wallet.message ?? "OneWay Wallet test payment complete. The seller will see your order as paid."
            } else {
                successMessage = response.message ?? "Seller will reply soon with next steps."
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func track(_ event: SiteStoreAnalyticsEventType) async {
        let slug = storefront.slug.isEmpty ? (storefront.business.handle ?? storefront.business.name) : storefront.slug
        try? await analyticsService.trackEvent(
            domainSlug: slug,
            eventType: event,
            productId: product?.id.uuidString,
            metadata: ["surface": "ios_request_sheet"]
        )
    }
}

private struct StorefrontBuyerRequestResponse: Decodable {
    let message: String?
    let orderRequest: SiteStoreOrderRequest?
}

private struct StorefrontBuyerRequestBody: Encodable {
    let productId: String
    let productName: String
    let customerName: String
    let customerEmail: String
    let customerPhone: String
    let quantity: Int
    let message: String
    let fulfillmentPreference: String
    let preferredContactMethod: String
}

private final class StorefrontBuyerRequestService {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func submitRequest(
        storefront: Storefront,
        product: ProductOrService?,
        name: String,
        email: String,
        phone: String,
        quantity: Int,
        message: String,
        fulfillmentPreference: String,
        preferredContactMethod: String
    ) async throws -> StorefrontBuyerRequestResponse {
        let slug = storefront.slug.isEmpty ? (storefront.business.handle ?? storefront.business.name) : storefront.slug
        return try await client.post(
            "api/stores/\(normalizedSlug(slug))/inquiries",
            body: StorefrontBuyerRequestBody(
                productId: product?.id.uuidString ?? "",
                productName: product?.name ?? "",
                customerName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                customerEmail: email.trimmingCharacters(in: .whitespacesAndNewlines),
                customerPhone: phone.trimmingCharacters(in: .whitespacesAndNewlines),
                quantity: max(1, quantity),
                message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                fulfillmentPreference: fulfillmentPreference,
                preferredContactMethod: preferredContactMethod
            ),
            requiresAuth: false
        )
    }

    func startWalletCheckout(
        storefront: Storefront,
        orderId: String,
        amountCents: Int?,
        buyerWalletUserId: String?
    ) async throws -> (order: SiteStoreOrderRequest, message: String?, testModeWarning: String?) {
        let slug = storefront.slug.isEmpty ? (storefront.business.handle ?? storefront.business.name) : storefront.slug
        return try await NetworkSiteStoreService(client: client).startWalletCheckout(
            domainSlug: slug,
            orderId: orderId,
            amountCents: amountCents,
            buyerWalletUserId: buyerWalletUserId
        )
    }

    private func normalizedSlug(_ value: String) -> String {
        value
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".oneway.app", with: "")
            .split(separator: "/")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? value
    }
}
