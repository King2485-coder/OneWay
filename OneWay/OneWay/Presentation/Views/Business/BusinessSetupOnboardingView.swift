import SwiftUI
import UIKit

struct BusinessSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tabVisibilityManager: TabVisibilityManager
    @AppStorage("oneway.business.hasCompletedInitialBusinessSetup") private var hasCompletedInitialBusinessSetup = false
    @StateObject private var viewModel = BusinessSetupViewModel()

    let onCompleted: (() -> Void)?

    init(onCompleted: (() -> Void)? = nil) {
        self.onCompleted = onCompleted
    }

    @State private var step: BusinessSetupOnboardingStep = .welcome
    @State private var selectedCategory = "Service Business"
    @State private var businessName = ""
    @State private var handle = ""
    @State private var handleWasEdited = false
    @State private var contactMode = "OneWay number"
    @State private var areaCode = ""
    @State private var existingPhone = ""
    @State private var offering = "Services"
    @State private var locationMode = "Online"
    @State private var address = ""
    @State private var hoursMode = "Business Hours"
    @State private var selectedPayments: Set<String> = ["Cards", "Apple Pay"]
    @State private var aiEmployeeEnabled = true
    @State private var selectedCommunications: Set<String> = ["Call", "Chirp", "Message", "AI First"]
    @State private var productSetup = "Skip for now"
    @State private var teamSize = "Just me"
    @State private var selectedPlanId = "basic"
    @State private var openNumberSearch = false
    @State private var numberClaimNotice: String?
    @State private var finishError: String?
    @State private var previousTabBarHidden = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case businessName
        case handle
        case areaCode
        case existingPhone
        case address
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if viewModel.isLoading {
                        ProgressView("Loading your business setup...")
                            .tint(Theme.backgroundHighlight)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }

                    if let message = viewModel.errorMessage ?? finishError {
                        notice(title: "Setup notice", message: message, color: .orange)
                    }

                    if let numberClaimNotice {
                        notice(title: "Business number", message: numberClaimNotice, color: Theme.backgroundHighlight)
                    }

                    stepContent
                }
                .padding(18)
                .padding(.bottom, 12)
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .background { SideMenuBackground() }
        .navigationTitle("Business Setup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            previousTabBarHidden = tabVisibilityManager.isTabBarHidden
            tabVisibilityManager.isTabBarHidden = true
        }
        .onDisappear {
            tabVisibilityManager.isTabBarHidden = previousTabBarHidden
        }
        .task {
            await viewModel.load()
            hydrateFromProfile()
        }
        .onChange(of: businessName) { _, newValue in
            guard !handleWasEdited else { return }
            handle = Self.makeHandle(from: newValue)
        }
        .navigationDestination(isPresented: $openNumberSearch) {
            BusinessNumberSearchView(
                selectedPlanId: selectedPlanId,
                onAssigned: { notice in
                    numberClaimNotice = notice
                    Task { await viewModel.refreshAfterNumberClaim() }
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Step \(step.rawValue + 1) of \(BusinessSetupOnboardingStep.allCases.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.backgroundHighlight, Color(hex: 0x9B5CFF)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(12, proxy.size.width * progress))
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.black.opacity(0.18))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                goBack()
            } label: {
                OneWayResolvedLabel("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryBusinessSetupButtonStyle())
            .disabled(step == .welcome || viewModel.isSaving)
            .opacity(step == .welcome ? 0.45 : 1)

            Button {
                Task { await continueFromCurrentStep() }
            } label: {
                if viewModel.isSaving {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                } else {
                    OneWayResolvedLabel(primaryActionTitle, systemImage: step == .finish ? "checkmark.circle.fill" : "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(viewModel.isSaving || !canContinue)
        }
        .padding(18)
        .background(Color.black.opacity(0.26))
        .background(.ultraThinMaterial.opacity(0.72))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            introScreen
        case .category:
            choiceScreen(
                eyebrow: "BUSINESS TYPE",
                title: "What kind of business are you setting up?",
                subtitle: "This gives OneWay smart defaults for your storefront, messages, and customer actions.",
                choices: categoryChoices,
                selection: $selectedCategory
            )
        case .name:
            textInputScreen(
                eyebrow: "BUSINESS NAME",
                title: "What should customers see?",
                subtitle: "Use the name people already know. You can edit it later.",
                placeholder: "Business name",
                text: $businessName,
                field: .businessName
            )
        case .handle:
            handleScreen
        case .contact:
            contactScreen
        case .offering:
            choiceScreen(
                eyebrow: "SELLING",
                title: "What do you sell?",
                subtitle: "OneWay will shape your shop and customer buttons around this.",
                choices: offeringChoices,
                selection: $offering
            )
        case .location:
            locationScreen
        case .hours:
            hoursScreen
        case .payments:
            multiChoiceScreen(
                eyebrow: "PAYMENTS",
                title: "How do you want customers to pay?",
                subtitle: "No sensitive info here. Checkout connections can happen after setup.",
                choices: paymentChoices,
                selections: $selectedPayments
            )
        case .aiEmployee:
            aiEmployeeScreen
        case .communication:
            multiChoiceScreen(
                eyebrow: "CUSTOMER ACTIONS",
                title: "How should customers reach you?",
                subtitle: "These choices control the buttons customers see on your OneWay page.",
                choices: communicationChoices,
                selections: $selectedCommunications
            )
        case .store:
            storeSetupScreen
        case .team:
            choiceScreen(
                eyebrow: "TEAM",
                title: "Who will run this business?",
                subtitle: "Invites can wait. This keeps permissions simple for now.",
                choices: teamChoices,
                selection: $teamSize
            )
        case .plan:
            planScreen
        case .finish:
            finishScreen
        }
    }

    private var introScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Welcome to OneWay Business")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text("Let's build your business together. OneWay will create the private foundation first, then you can edit and launch from Shop Management.")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 12) {
                benefitRow("storefront", "Business profile and storefront", "Private until you choose to launch.")
                benefitRow("phone.bubble.left.fill", "Calls, Chirp, and messages", "Choose exactly how customers can contact you.")
                benefitRow("sparkles", "AI employee ready", "Let AI answer first, route requests, and help you stay responsive.")
            }
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private var handleScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader("PUBLIC LINK", "Choose your OneWay handle.", "Customers will be able to find you at this address.")

            VStack(alignment: .leading, spacing: 8) {
                TextField("your-business", text: $handle)
                    .focused($focusedField, equals: .handle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .onChange(of: handle) { _, newValue in
                        handleWasEdited = true
                        handle = Self.makeHandle(from: newValue)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(Theme.textPrimary)

                Text("oneway.is/@\(handle.nilIfBlank ?? "your-business")")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(handleIsAvailable ? Theme.textPrimary : .orange)

                Text(handleStatusText)
                    .font(.caption)
                    .foregroundStyle(handleIsAvailable ? Theme.textSecondary : .orange)
            }
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private var contactScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader("CUSTOMER CONTACT", "How should customers call you?", "Use a OneWay number, an existing phone, or both.")

            optionGrid(contactChoices, selection: $contactMode)

            if contactMode != "Existing phone" {
                textInputBlock("Preferred area code", placeholder: "702", text: $areaCode, field: .areaCode)
                    .keyboardType(.numberPad)

                Button {
                    openNumberSearch = true
                } label: {
                    OneWayResolvedLabel("Search available OneWay numbers", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryBusinessSetupButtonStyle())
            }

            if contactMode != "OneWay number" {
                textInputBlock("Existing phone", placeholder: "(555) 123-4567", text: $existingPhone, field: .existingPhone)
                    .keyboardType(.phonePad)
            }
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private var locationScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader("LOCATION", "Where do customers work with you?", "Add an address only if customers need it.")
            optionGrid(locationChoices, selection: $locationMode)

            if locationMode != "Online" {
                textInputBlock("Business address", placeholder: "Street, city, state", text: $address, field: .address)
                Button {
                    address = address.nilIfBlank ?? "Use current location later"
                } label: {
                    OneWayResolvedLabel("Use current location later", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryBusinessSetupButtonStyle())
            }
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private var hoursScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader("HOURS", "When should OneWay say you're available?", "Business Hours defaults to Monday through Friday, 9 AM to 5 PM.")
            optionGrid(hoursChoices, selection: $hoursMode)

            if hoursMode == "Business Hours" {
                notice(
                    title: "Default schedule",
                    message: "Monday-Friday, 9:00 AM-5:00 PM. You can tune exact hours from the dashboard.",
                    color: Theme.backgroundHighlight
                )
            }
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private var aiEmployeeScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader("AI EMPLOYEE", "Let OneWay answer first?", "Recommended for faster replies, missed calls, and simple customer questions.")

            Button {
                aiEmployeeEnabled.toggle()
            } label: {
                HStack(spacing: 14) {
                    OneWayResolvedIcon(systemName: aiEmployeeEnabled ? "sparkles" : "person.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(aiEmployeeEnabled ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 38, height: 38)
                        .background((aiEmployeeEnabled ? Theme.backgroundHighlight : Color.white.opacity(0.08)), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(aiEmployeeEnabled ? "AI employee enabled" : "AI employee off")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(aiEmployeeEnabled ? "AI can greet customers and route requests before you step in." : "Customers will reach your selected human contact buttons first.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    OneWayResolvedIcon(systemName: aiEmployeeEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(aiEmployeeEnabled ? Theme.backgroundHighlight : Theme.textMuted)
                }
            }
            .buttonStyle(.plain)
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private var storeSetupScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader("SHOP", "How do you want to start the store?", "You can add products now, import later, or skip and finish the private storefront later.")
            optionGrid(storeChoices, selection: $productSetup)

            VStack(alignment: .leading, spacing: 8) {
                Text("Import options")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                HStack {
                    ForEach(["Shopify", "Square", "CSV", "WooCommerce"], id: \.self) { source in
                        Text(source)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.06), in: Capsule())
                    }
                }
                Text("You can add these business details manually during setup.")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private var planScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader("PLAN", "Choose how OneWay should power this business.", "Phone, AI, payment, and provider fees may apply depending on what you turn on.")

            VStack(spacing: 10) {
                ForEach(displayPlans) { plan in
                    Button {
                        selectedPlanId = plan.id
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            OneWayResolvedIcon(systemName: selectedPlanId == plan.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedPlanId == plan.id ? Theme.backgroundHighlight : Theme.textMuted)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(plan.name)
                                        .font(.headline.weight(.bold))
                                    Spacer()
                                    Text(priceText(for: plan))
                                        .font(.headline.weight(.heavy))
                                }
                                Text(plan.tagline)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(14)
                        .background(Color.white.opacity(selectedPlanId == plan.id ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            notice(title: "Checkout", message: "If hosted checkout is not connected yet, you can continue now and finish billing from the dashboard.", color: Theme.backgroundHighlight)
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private var finishScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            screenHeader("READY", "\(businessName.nilIfBlank ?? "Your business") is ready.", "Now let's build your storefront in Shop Management. Nothing is public until you launch.")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                finishTile("Call", "phone.fill")
                finishTile("Chirp", "waveform")
                finishTile("Message", "message.fill")
                finishTile("Shop", "bag.fill")
                finishTile("Pay", "creditcard.fill")
                finishTile("Public page", "globe")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Shop Management checklist")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                checklistRow("Confirm business number")
                checklistRow("Add first product or service")
                checklistRow("Connect hosted checkout")
                checklistRow("Invite team members")
            }
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private func choiceScreen(eyebrow: String, title: String, subtitle: String, choices: [BusinessSetupChoice], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader(eyebrow, title, subtitle)
            optionGrid(choices, selection: selection)
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private func multiChoiceScreen(eyebrow: String, title: String, subtitle: String, choices: [BusinessSetupChoice], selections: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader(eyebrow, title, subtitle)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(choices) { choice in
                    let isSelected = selections.wrappedValue.contains(choice.title)
                    Button {
                        if isSelected {
                            selections.wrappedValue.remove(choice.title)
                        } else {
                            selections.wrappedValue.insert(choice.title)
                        }
                    } label: {
                        optionCard(choice, selected: isSelected)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private func textInputScreen(eyebrow: String, title: String, subtitle: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            screenHeader(eyebrow, title, subtitle)
            textInputBlock(placeholder, placeholder: placeholder, text: text, field: field)
        }
        .padding(18)
        .businessOnboardingPanel()
    }

    private func optionGrid(_ choices: [BusinessSetupChoice], selection: Binding<String>) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(choices) { choice in
                Button {
                    selection.wrappedValue = choice.title
                } label: {
                    optionCard(choice, selected: selection.wrappedValue == choice.title)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func optionCard(_ choice: BusinessSetupChoice, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                OneWayResolvedIcon(systemName: choice.icon)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(selected ? Theme.backgroundHighlight : Color.white.opacity(0.08), in: Circle())
                Spacer()
                OneWayResolvedIcon(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.backgroundHighlight : Theme.textMuted)
            }
            Text(choice.title)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            if let detail = choice.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .padding(14)
        .background(Color.white.opacity(selected ? 0.13 : 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? Theme.backgroundHighlight.opacity(0.85) : Theme.divider, lineWidth: 1)
        )
    }

    private func textInputBlock(_ label: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: text)
                .focused($focusedField, equals: field)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .padding(14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func screenHeader(_ eyebrow: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(eyebrow)
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(Theme.backgroundHighlight)
            Text(title)
                .font(.title.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func benefitRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.backgroundHighlight, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func notice(title: String, message: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func finishTile(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: icon)
                .foregroundStyle(Theme.backgroundHighlight)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func checklistRow(_ title: String) -> some View {
        HStack(spacing: 9) {
            OneWayResolvedIcon(systemName: "circle")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var progress: Double {
        Double(step.rawValue + 1) / Double(BusinessSetupOnboardingStep.allCases.count)
    }

    private var primaryActionTitle: String {
        switch step {
        case .welcome: return "Let's Go"
        case .finish: return "Open Shop Management"
        default: return "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .name:
            return businessName.nilIfBlank != nil
        case .handle:
            return handleIsAvailable
        case .payments:
            return !selectedPayments.isEmpty
        case .communication:
            return !selectedCommunications.isEmpty
        default:
            return true
        }
    }

    private var handleIsAvailable: Bool {
        let normalized = Self.makeHandle(from: handle)
        let reserved = ["admin", "help", "support", "oneway", "api", "test"]
        return normalized.count >= 3 && normalized == handle && !reserved.contains(normalized)
    }

    private var handleStatusText: String {
        if handle.count < 3 {
            return "Use at least 3 letters or numbers."
        }
        if handleIsAvailable {
            return "Looks available. We will verify with the server when handle APIs are connected."
        }
        return "Use lowercase letters, numbers, or hyphens. This one may be reserved."
    }

    private var displayPlans: [BusinessPlan] {
        if !viewModel.plans.isEmpty {
            return viewModel.plans
        }

        return [
            BusinessPlan(id: "basic", name: "Basic", monthlyPrice: 13, tagline: "Public page, customer messaging, and starter business tools.", features: [], recommended: true),
            BusinessPlan(id: "plus", name: "Plus", monthlyPrice: 19, tagline: "More automation for calls, messages, and shop workflows.", features: [], recommended: false),
            BusinessPlan(id: "pro", name: "Pro", monthlyPrice: 29, tagline: "Advanced AI employee and stronger storefront tools.", features: [], recommended: false),
            BusinessPlan(id: "business", name: "Business", monthlyPrice: 49, tagline: "Starts at $49 for teams, higher volume, and priority setup.", features: [], recommended: false)
        ]
    }

    private func priceText(for plan: BusinessPlan) -> String {
        if plan.id == "business" {
            return "from $\(Int(plan.monthlyPrice))"
        }
        return "$\(Int(plan.monthlyPrice))/mo"
    }

    private func hydrateFromProfile() {
        businessName = viewModel.profile.businessName.nilIfBlank ?? businessName
        selectedCategory = viewModel.profile.industry.nilIfBlank ?? selectedCategory
        aiEmployeeEnabled = viewModel.profile.aiReceptionistEnabled || viewModel.profile.id == "local"
        selectedPlanId = viewModel.profile.planId.nilIfBlank ?? selectedPlanId
        handle = handle.nilIfBlank ?? Self.makeHandle(from: businessName)

        if viewModel.profile.businessHours.localizedCaseInsensitiveContains("always") {
            hoursMode = "Always Open"
        } else if viewModel.profile.businessHours.localizedCaseInsensitiveContains("appointment") {
            hoursMode = "Appointment Only"
        }
    }

    private func goBack() {
        guard let previous = BusinessSetupOnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func continueFromCurrentStep() async {
        finishError = nil

        if step == .finish {
            await saveFinalSetup()
            if finishError == nil {
                onCompleted?()
                dismiss()
            }
            return
        }

        guard let next = BusinessSetupOnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func saveFinalSetup() async {
        viewModel.profile.businessName = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.profile.industry = selectedCategory
        viewModel.profile.businessHours = hoursSummary
        viewModel.profile.aiReceptionistEnabled = aiEmployeeEnabled
        viewModel.profile.planId = selectedPlanId
        viewModel.profile.greeting = greetingSummary
        viewModel.profile.missedCallAutoReply = missedCallReply
        viewModel.profile.setupStep = "complete"
        viewModel.profile.onboardingProgress = 100
        hasCompletedInitialBusinessSetup = true

        await viewModel.save()
        finishError = viewModel.errorMessage
    }

    private var hoursSummary: String {
        switch hoursMode {
        case "Always Open":
            return "Always open"
        case "Appointment Only":
            return "Appointment only"
        default:
            return "Monday-Friday, 9:00 AM-5:00 PM"
        }
    }

    private var greetingSummary: String {
        let name = businessName.nilIfBlank ?? "this business"
        if aiEmployeeEnabled {
            return "Thanks for reaching \(name). OneWay AI can help first, then route you to the team."
        }
        return "Thanks for reaching \(name). Send a message and the team will get back to you."
    }

    private var missedCallReply: String {
        "Thanks for contacting \(businessName.nilIfBlank ?? "us"). We received your request and will reply through \(selectedCommunications.sorted().joined(separator: ", "))."
    }

    private static func makeHandle(from value: String) -> String {
        let lowered = value.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(32))
    }

    private var categoryChoices: [BusinessSetupChoice] {
        [
            .init("Retail Store", "bag.fill"),
            .init("Restaurant", "fork.knife"),
            .init("Service Business", "wrench.and.screwdriver.fill"),
            .init("Real Estate", "house.fill"),
            .init("Automotive", "car.fill"),
            .init("Professional", "briefcase.fill"),
            .init("Creator", "camera.fill"),
            .init("Company", "building.2.fill"),
            .init("Nonprofit", "heart.fill"),
            .init("Other", "square.grid.2x2.fill")
        ]
    }

    private var contactChoices: [BusinessSetupChoice] {
        [
            .init("OneWay number", "phone.badge.plus", "Best for calls, texts, Chirp, and AI routing."),
            .init("Existing phone", "phone.fill", "Use the number customers already know."),
            .init("Both", "arrow.triangle.merge", "Keep your existing phone and add OneWay.")
        ]
    }

    private var offeringChoices: [BusinessSetupChoice] {
        [
            .init("Products", "shippingbox.fill"),
            .init("Services", "person.crop.circle.badge.checkmark"),
            .init("Both", "square.stack.3d.up.fill")
        ]
    }

    private var locationChoices: [BusinessSetupChoice] {
        [
            .init("In person", "mappin.and.ellipse"),
            .init("Online", "globe"),
            .init("Both", "point.3.connected.trianglepath.dotted")
        ]
    }

    private var hoursChoices: [BusinessSetupChoice] {
        [
            .init("Always Open", "clock.badge.checkmark"),
            .init("Business Hours", "calendar"),
            .init("Appointment Only", "calendar.badge.clock")
        ]
    }

    private var paymentChoices: [BusinessSetupChoice] {
        [
            .init("Cards", "creditcard.fill"),
            .init("Apple Pay", "apple.logo"),
            .init("Google Pay", "g.circle.fill"),
            .init("PayPal", "p.circle.fill"),
            .init("Cash", "banknote.fill"),
            .init("Cash App", "dollarsign.circle.fill"),
            .init("Venmo", "v.circle.fill"),
            .init("Crypto", "bitcoinsign.circle.fill")
        ]
    }

    private var communicationChoices: [BusinessSetupChoice] {
        [
            .init("Call", "phone.fill"),
            .init("Chirp", "waveform"),
            .init("Message", "message.fill"),
            .init("Video", "video.fill"),
            .init("AI First", "sparkles")
        ]
    }

    private var storeChoices: [BusinessSetupChoice] {
        [
            .init("Add first product", "plus.square.fill"),
            .init("Import", "square.and.arrow.down.fill"),
            .init("Skip for now", "forward.fill")
        ]
    }

    private var teamChoices: [BusinessSetupChoice] {
        [
            .init("Just me", "person.fill"),
            .init("2-5", "person.2.fill"),
            .init("6-25", "person.3.fill"),
            .init("25+", "building.2.fill")
        ]
    }
}

private enum BusinessSetupOnboardingStep: Int, CaseIterable {
    case welcome
    case category
    case name
    case handle
    case contact
    case offering
    case location
    case hours
    case payments
    case aiEmployee
    case communication
    case store
    case team
    case plan
    case finish
}

private struct BusinessSetupChoice: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let detail: String?

    init(_ title: String, _ icon: String, _ detail: String? = nil) {
        self.title = title
        self.icon = icon
        self.detail = detail
    }
}

private struct SecondaryBusinessSetupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.12), in: Capsule(style: .continuous))
            .foregroundStyle(Theme.textPrimary)
            .overlay(Capsule(style: .continuous).stroke(Theme.divider, lineWidth: 1))
    }
}

private extension View {
    func businessOnboardingPanel() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.divider, lineWidth: 1)
            )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
