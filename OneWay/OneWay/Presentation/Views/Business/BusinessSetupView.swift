import SwiftUI

private struct LegacyBusinessSetupView: View {
    @StateObject private var viewModel = BusinessSetupViewModel()
    @State private var openNumberSearch = false
    @State private var numberClaimNotice: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case businessName
        case industry
        case businessHours
        case greeting
        case missedCallAutoReply
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard

                if viewModel.isLoading {
                    ProgressView("Checking your business setup...")
                        .tint(Theme.accentGold)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }

                if let errorMessage = viewModel.errorMessage {
                    statusNotice(title: "Setup could not refresh", message: errorMessage, color: .orange)
                }

                if let numberClaimNotice {
                    statusNotice(title: "Business number updated", message: numberClaimNotice, color: Theme.accentGold)
                }

                planSelectionCard
                identityCard
                reachabilityCard
                aiReceptionistCard

                if let action = viewModel.setupStatus?.nextRecommendedAction {
                    nextActionCard(action)
                }
            }
            .padding(18)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Business Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(viewModel.isSaving ? "Saving" : "Save") {
                    Task { await viewModel.save() }
                }
                .disabled(viewModel.isSaving)
            }
        }
        .task {
            await viewModel.load()
        }
        .navigationDestination(isPresented: $openNumberSearch) {
            BusinessNumberSearchView(
                selectedPlanId: viewModel.profile.planId,
                onAssigned: { notice in
                    numberClaimNotice = notice
                    Task { await viewModel.refreshAfterNumberClaim() }
                }
            )
        }
    }

    private var heroCard: some View {
        return VStack(alignment: .leading, spacing: 12) {
            Text("BUSINESS PRESENCE")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(Theme.accentGold)

            Text("GoDaddy gets your business online. OneWay gets your business reachable.")
                .font(.title2.weight(.heavy))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Set up the number, greetings, texting readiness, and AI help customers use when they need you.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            ProgressView(value: viewModel.progress)
                .tint(Theme.accentGold)
                .padding(.top, 4)

            Text("\(Int(viewModel.progress * 100))% ready")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(18)
        .businessSetupCardStyle()
    }

    private var identityCard: some View {
        sectionCard(title: "Business identity", subtitle: "How customers recognize your business.") {
            setupTextField("Business name", text: $viewModel.profile.businessName, field: .businessName)
            setupTextField("Industry", text: $viewModel.profile.industry, field: .industry)
            setupTextField("Business hours", text: $viewModel.profile.businessHours, field: .businessHours)
            setupTextEditor("Greeting", text: $viewModel.profile.greeting, field: .greeting)
            setupTextEditor("Missed call auto-reply", text: $viewModel.profile.missedCallAutoReply, field: .missedCallAutoReply)
        }
    }

    private var planSelectionCard: some View {
        sectionCard(title: "Plan", subtitle: "Choose the reachability package for this business.") {
            if viewModel.plans.isEmpty {
                Text("Plans will appear here once OneWay can refresh setup.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.plans) { plan in
                        Button {
                            viewModel.selectPlan(plan)
                        } label: {
                            planRow(plan)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var reachabilityCard: some View {
        sectionCard(title: "Reachability", subtitle: "Your customer-facing number and service readiness.") {
            HStack(spacing: 10) {
                businessNumberDisplay

                Button {
                    openNumberSearch = true
                } label: {
                    Text(viewModel.profile.publicPhoneNumber.isEmpty ? "Choose" : "Change")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .padding(.top, 24)
            }

            VStack(spacing: 10) {
                statusRow(
                    icon: "phone.fill",
                    title: "Business number",
                    status: (viewModel.setupStatus?.numberConfigured ?? false) ? "ready" : "needsSetup",
                    detail: (viewModel.setupStatus?.numberConfigured ?? false) ? "Customers have a number to call." : "Choose the number customers will see."
                )
                statusRow(
                    icon: "phone.connection.fill",
                    title: "Calling",
                    status: viewModel.setupStatus?.pstnPreflightStatus.status ?? viewModel.profile.voiceStatus,
                    detail: "Customers can reach your business by phone."
                )
                statusRow(
                    icon: "message.fill",
                    title: "Texting",
                    status: viewModel.setupStatus?.smsStatus.status ?? viewModel.profile.smsStatus,
                    detail: smsDetailText
                )
                statusRow(
                    icon: "recordingtape",
                    title: "Voicemail",
                    status: (viewModel.setupStatus?.voicemailConfigured ?? false) ? "ready" : "needsSetup",
                    detail: (viewModel.setupStatus?.voicemailConfigured ?? false) ? "Your greeting is ready." : "Add a greeting so missed calls still feel personal."
                )
            }
        }
    }

    private var businessNumberDisplay: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Business phone number")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Text(viewModel.profile.publicPhoneNumber.nilIfBlank ?? "No business number selected yet")
                    .foregroundStyle(viewModel.profile.publicPhoneNumber.isEmpty ? Theme.textMuted : Theme.textPrimary)
                Spacer()
                OneWayResolvedIcon(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(12)
            .background(Theme.appBackground.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func planRow(_ plan: BusinessPlan) -> some View {
        let isSelected = viewModel.profile.planId == plan.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(plan.name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if plan.recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.accentGold.opacity(0.16), in: Capsule())
                                .foregroundStyle(Theme.accentGold)
                        }
                    }
                    Text(plan.tagline)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text("$\(Int(plan.monthlyPrice))/mo")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isSelected ? Theme.accentGold : Theme.textPrimary)
            }

            Text(plan.features.joined(separator: " • "))
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .background(isSelected ? Theme.accentGold.opacity(0.12) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Theme.accentGold.opacity(0.55) : Theme.divider, lineWidth: 1)
        )
    }

    private var aiReceptionistCard: some View {
        sectionCard(title: "AI receptionist", subtitle: "Let OneWay help answer, capture details, and follow up while you are busy.") {
            Toggle(isOn: Binding(
                get: { viewModel.profile.aiReceptionistEnabled },
                set: { viewModel.setAIReceptionistEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI receptionist")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(viewModel.profile.aiReceptionistEnabled ? "Enabled for this business." : "Off until you are ready.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accentGold)
        }
    }

    private var smsDetailText: String {
        switch viewModel.setupStatus?.smsStatus.status ?? viewModel.profile.smsStatus {
        case "ready":
            return "Customer texting is ready."
        case "pending":
            return "Texting is waiting for approval."
        case "demo":
            return "Texting is in demo mode for local testing."
        default:
            return "Finish registration before customer texts can deliver."
        }
    }

    private func nextActionCard(_ action: BusinessSetupNextAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            OneWayResolvedLabel("Next recommended action", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accentGold)
            Text(action.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(action.message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Button(action.actionLabel) {
                handleNextAction(action.step)
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.accentGold.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.accentGold.opacity(0.22), lineWidth: 1)
        )
    }

    private func sectionCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            content()
        }
        .padding(16)
        .businessSetupCardStyle()
    }

    private func setupTextField(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField(title, text: text)
                .focused($focusedField, equals: field)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .padding(12)
                .background(Theme.appBackground.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func setupTextEditor(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            TextEditor(text: text)
                .focused($focusedField, equals: field)
                .frame(minHeight: 88)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.appBackground.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func statusRow(icon: String, title: String, status: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OneWayResolvedIcon(systemName: icon)
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(viewModel.statusTint(status).opacity(0.16), in: Circle())
                .foregroundStyle(viewModel.statusTint(status))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(viewModel.friendlyStatus(status))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(viewModel.statusTint(status))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusNotice(title: String, message: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .businessSetupCardStyle()
    }

    private func focusTarget(for step: String) -> Field? {
        switch step {
        case "businessIdentity": return .businessName
        case "voicemail": return .greeting
        default: return nil
        }
    }

    private func handleNextAction(_ step: String) {
        switch step {
        case "phoneNumber", "calling", "texting":
            openNumberSearch = true
        default:
            focusedField = focusTarget(for: step)
        }
    }
}

struct BusinessNumberSearchView: View {
    let selectedPlanId: String
    let onAssigned: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var areaCode = ""
    @State private var contains = ""
    @State private var results: [BusinessPhoneNumberSearchResult] = []
    @State private var isSearching = false
    @State private var claimingNumber: String?
    @State private var message: String?
    @State private var pendingClaim: BusinessPhoneNumberSearchResult?
    @State private var showClaimConfirmation = false

    private let service: BusinessPresenceServicing = NetworkBusinessPresenceService()
    private static let quoteDateFormatterWithFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let quoteDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose a business number")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Search for a number customers can call and text from your OneWay business presence.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 8)

                if selectedPlanId.nilIfBlank == nil {
                    inlineNotice(
                        title: "Choose a plan first",
                        message: "You can browse numbers now, but claiming stays locked until a business plan is selected.",
                        color: .orange
                    )
                }

                searchCard

                if let message {
                    inlineNotice(title: "Number claim", message: message, color: .orange)
                }

                if isSearching {
                    ProgressView("Searching numbers...")
                        .tint(Theme.accentGold)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }

                VStack(spacing: 10) {
                    ForEach(results) { result in
                        numberRow(result)
                    }
                }
            }
            .padding(18)
        }
        .background { SideMenuBackground() }
        .navigationTitle("Phone Number")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Claim this number?", isPresented: $showClaimConfirmation, presenting: pendingClaim) { result in
            Button("Confirm Claim") {
                Task { await claim(result) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { result in
            Text(claimConfirmationMessage(for: result))
        }
        .task {
            await search()
        }
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                setupSearchField("Area code", text: $areaCode)
                    .keyboardType(.numberPad)
                setupSearchField("Contains", text: $contains)
                    .keyboardType(.numberPad)
            }

            Button {
                Task { await search() }
            } label: {
                OneWayResolvedLabel("Search Numbers", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())

            Text("Availability is held briefly for each search. If a number expires, search again before claiming.")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(16)
        .businessSetupCardStyle()
    }

    private func setupSearchField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(12)
                .background(Theme.appBackground.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func numberRow(_ result: BusinessPhoneNumberSearchResult) -> some View {
        let quoteExpired = isQuoteExpired(result)
        let planSelected = selectedPlanId.nilIfBlank != nil

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.displayName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(locationText(for: result))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(quoteStatusText(for: result))
                        .font(.caption2)
                        .foregroundStyle(quoteExpired ? .orange : Theme.textMuted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("$\(Int(result.monthlyPrice))/mo")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accentGold)
                    Text("Calls + texts")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }
            }

            Button {
                if !planSelected {
                    message = "Choose a plan before claiming a business number."
                } else if quoteExpired {
                    message = "This search result expired. Search again to refresh number availability."
                    Task { await search() }
                } else {
                    pendingClaim = result
                    showClaimConfirmation = true
                }
            } label: {
                if claimingNumber == result.phoneNumber {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                } else if !planSelected {
                    Text("Choose Plan First")
                        .frame(maxWidth: .infinity)
                } else if quoteExpired {
                    Text("Search Again")
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Review and Claim")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(claimingNumber != nil)
        }
        .padding(15)
        .businessSetupCardStyle()
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await service.searchNumbers(
                areaCode: areaCode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                contains: contains.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            )
            message = results.isEmpty ? "No numbers matched. Try a nearby area code." : nil
        } catch {
            message = friendlyNumberError(error)
        }
    }

    private func claim(_ result: BusinessPhoneNumberSearchResult) async {
        guard selectedPlanId.nilIfBlank != nil else {
            message = "Choose a plan before claiming a business number."
            return
        }

        guard !isQuoteExpired(result) else {
            message = "This search result expired. Search again to refresh number availability."
            await search()
            return
        }

        claimingNumber = result.phoneNumber
        defer { claimingNumber = nil }
        do {
            message = nil
            let purchase = try await service.purchaseNumber(
                phoneNumber: result.phoneNumber,
                planId: selectedPlanId.nilIfBlank,
                purchaseToken: result.purchaseToken,
                confirmationAccepted: true
            )
            _ = try await service.assignNumber(
                numberId: purchase.number.id,
                phoneNumber: purchase.number.number
            )
            onAssigned(successNotice(for: purchase))
            dismiss()
        } catch {
            message = friendlyNumberError(error)
        }
    }

    private func inlineNotice(title: String, message: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.glassSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func locationText(for result: BusinessPhoneNumberSearchResult) -> String {
        [result.locality, result.region]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: ", ")
            .nilIfBlank ?? "Available business number"
    }

    private func claimConfirmationMessage(for result: BusinessPhoneNumberSearchResult) -> String {
        let setupText = result.setupPrice > 0 ? " plus a one-time $\(Int(result.setupPrice)) setup cost" : ""
        return "Confirm you want \(result.displayName) as your OneWay business number for $\(Int(result.monthlyPrice))/mo\(setupText). This can reserve the number immediately. Calls can use it after setup refreshes; customer texting may still need approval before it delivers. By providing your phone number, you agree to receive OneWay SMS messages for verification, account alerts, service notifications, support, and user-initiated communications. Message frequency varies. Message and data rates may apply. Reply STOP to opt out or HELP for help."
    }

    private func quoteStatusText(for result: BusinessPhoneNumberSearchResult) -> String {
        isQuoteExpired(result) ? "Search again to refresh availability." : "Available from this search for a limited time."
    }

    private func isQuoteExpired(_ result: BusinessPhoneNumberSearchResult) -> Bool {
        guard let expiration = quoteExpirationDate(for: result) else {
            return false
        }
        return expiration <= Date().addingTimeInterval(15)
    }

    private func quoteExpirationDate(for result: BusinessPhoneNumberSearchResult) -> Date? {
        Self.quoteDateFormatterWithFractions.date(from: result.purchaseTokenExpiresAt)
            ?? Self.quoteDateFormatter.date(from: result.purchaseTokenExpiresAt)
    }

    private func successNotice(for purchase: BusinessNumberPurchaseResponse) -> String {
        if purchase.messagingAttachment?.status == "attached" {
            return "Your business number is claimed and added. Calls and customer texting are ready after setup refreshes."
        }

        return "Your business number is claimed and added. Calls can use it now; customer texting will turn on after business texting approval."
    }

    private func friendlyNumberError(_ error: Error) -> String {
        let rawMessage: String
        if let apiError = error as? APIClientError {
            rawMessage = apiError.errorDescription ?? apiError.localizedDescription
        } else {
            rawMessage = error.localizedDescription
        }

        let normalized = rawMessage.lowercased()
        if normalized.contains("purchase_token_expired")
            || normalized.contains("purchase token expired")
            || normalized.contains("expired") {
            return "This number search expired. Search again to refresh availability before claiming."
        }

        if normalized.contains("purchase_token_invalid")
            || normalized.contains("invalid purchase")
            || normalized.contains("token") {
            return "This number hold is no longer valid. Search again and choose the number from the fresh results."
        }

        if normalized.contains("already_owned") || normalized.contains("already owned") {
            return "That number is already on your OneWay account. Refresh Business Setup to use it."
        }

        if normalized.contains("number_unavailable")
            || normalized.contains("not available")
            || normalized.contains("unavailable") {
            return "That number is no longer available. Search again or choose a different number."
        }

        if normalized.contains("twilio") || normalized.contains("provider") {
            return "The phone network could not claim that number yet. Search again or try a different number."
        }

        return rawMessage
    }
}

private extension View {
    func businessSetupCardStyle() -> some View {
        self
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
