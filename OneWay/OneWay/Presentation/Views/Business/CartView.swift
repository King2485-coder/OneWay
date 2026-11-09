import SwiftUI

struct CartView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onRoute: (MarketplaceRoute) -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            MarketplaceTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Cart").font(.largeTitle.weight(.black)).foregroundStyle(.white)

                    if viewModel.cartItems.isEmpty {
                        empty
                    } else {
                        ForEach(viewModel.cartItems) { item in
                            if let product = viewModel.product(item.productID) {
                                cartRow(item, product)
                            }
                        }
                        totals
                    }
                }
                .padding(18)
                .padding(.bottom, 90)
            }
        }
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) {
            MarketplaceBackBar(title: "Cart", onBack: onBack)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            OneWayResolvedIcon(systemName: "cart").font(.system(size: 48, weight: .black)).foregroundStyle(MarketplaceTheme.purple)
            Text("Your cart is empty").font(.title3.weight(.black)).foregroundStyle(.white)
            Text("Add creator-made goods from OneWay Shops.").foregroundStyle(MarketplaceTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func cartRow(_ item: CartItem, _ product: MarketplaceProduct) -> some View {
        HStack(spacing: 12) {
            MarketplaceProductImageView(product: product, height: 82, cornerRadius: 18)
                .frame(width: 86)
            VStack(alignment: .leading) {
                Text(product.title).font(.headline.weight(.black)).foregroundStyle(.white)
                Text(product.price.currency).foregroundStyle(MarketplaceTheme.muted)
                HStack {
                    Button { viewModel.updateQuantity(productID: product.id, delta: -1) } label: { OneWayResolvedIcon(systemName: "minus.circle.fill") }
                    Text("\(item.quantity)")
                    Button { viewModel.updateQuantity(productID: product.id, delta: 1) } label: { OneWayResolvedIcon(systemName: "plus.circle.fill") }
                    Button("Remove") { viewModel.removeFromCart(productID: product.id) }.font(.caption.weight(.bold))
                }
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(12)
        .marketplaceCard()
    }

    private var totals: some View {
        VStack(spacing: 12) {
            totalLine("Subtotal", viewModel.subtotal)
            Text("Tax and shipping, if applicable, are shown before payment in secure checkout.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MarketplaceTheme.muted)
            Divider().overlay(MarketplaceTheme.border)
            totalLine("Cart subtotal", viewModel.subtotal, bold: true)
            Button {
                MarketplaceHaptics.success()
                onRoute(.checkout)
            } label: {
                OneWayResolvedLabel("Secure Checkout", systemImage: "lock.fill")
                    .font(.headline.weight(.black))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(MarketplaceTheme.gradient, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .marketplaceCard()
    }

    private func totalLine(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.currency).fontWeight(bold ? .black : .semibold)
        }
    }
}

struct MarketplaceCheckoutView: View {
    @ObservedObject var viewModel: MarketplaceViewModel
    let onBack: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var showPolicies = false

    private var breakdown: MarketplaceCheckoutBreakdown {
        viewModel.checkoutBreakdown
    }

    private var seller: MarketplaceShop? {
        viewModel.cartItems.compactMap { viewModel.product($0.productID) }.first.flatMap { viewModel.shop($0.shopID) }
    }

    var body: some View {
        ZStack {
            MarketplaceTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("OneWay Checkout")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(.white)
                    Text("Review your cart, then continue to OneWay's secure payment page.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MarketplaceTheme.muted)

                    checkoutItems
                    totals
                    paymentMethods

                    if seller != nil {
                        Button("Read Shop Policies") { showPolicies = true }
                            .font(.headline.weight(.black))
                            .foregroundStyle(MarketplaceTheme.purple)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .overlay(Capsule().stroke(MarketplaceTheme.purple, lineWidth: 2))
                    }

                    if let message = viewModel.sellerValidationMessage {
                        Text(message)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .marketplaceCard(cornerRadius: 18)
                    }

                    Button {
                        Task {
                            if let checkoutURL = await viewModel.createSecureCheckout() {
                                openURL(checkoutURL)
                            }
                        }
                    } label: {
                        OneWayResolvedLabel(viewModel.checkoutIsLoading ? "Starting Secure Checkout…" : "Continue to Secure Checkout", systemImage: "lock.fill")
                            .font(.headline.weight(.black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(MarketplaceTheme.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.checkoutIsLoading || viewModel.cartItems.isEmpty)
                }
                .padding(18)
                .padding(.bottom, 110)
            }
        }
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) {
            MarketplaceBackBar(title: "Checkout", onBack: onBack)
        }
        .alert("Purchase Complete", isPresented: Binding(
            get: { viewModel.checkoutCompletedMessage != nil },
            set: { if !$0 { viewModel.checkoutCompletedMessage = nil } }
        )) {
            Button("Done") {
                viewModel.checkoutCompletedMessage = nil
                onBack()
            }
        } message: {
            Text(viewModel.checkoutCompletedMessage ?? "")
        }
        .sheet(isPresented: $showPolicies) {
            if let seller {
                NavigationStack {
                    BuyerShopPoliciesView(
                        viewModel: viewModel,
                        shopID: seller.id,
                        onBack: { showPolicies = false },
                        onMessage: { _ in showPolicies = false }
                    )
                }
            }
        }
    }

    private var checkoutItems: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Items")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
            ForEach(viewModel.cartItems) { item in
                if let product = viewModel.product(item.productID) {
                    HStack {
                        Text("\(item.quantity)x \(product.title)")
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        Text((product.price * Double(item.quantity)).currency)
                            .font(.subheadline.weight(.black))
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }

    private var totals: some View {
        VStack(spacing: 10) {
            totalLine("Subtotal", breakdown.subtotal)
            Divider().overlay(MarketplaceTheme.border)
            Text("Your final total and any applicable tax or shipping are confirmed on the secure payment page before you pay.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MarketplaceTheme.muted)
        }
        .foregroundStyle(.white)
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }

    private var paymentMethods: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Payment")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
            OneWayResolvedLabel("Available payment methods appear in secure checkout", systemImage: "creditcard.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(MarketplaceTheme.muted)
            Text("OneWay does not mark an order paid until the payment provider confirms it.")
                .font(.caption.weight(.bold))
                .foregroundStyle(MarketplaceTheme.faint)
        }
        .padding(16)
        .marketplaceCard(cornerRadius: 24)
    }

    private func totalLine(_ label: String, _ amount: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.currency).fontWeight(bold ? .black : .semibold)
        }
    }
}
