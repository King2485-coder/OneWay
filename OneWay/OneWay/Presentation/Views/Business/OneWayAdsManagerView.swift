import Foundation
import Combine
import PhotosUI
import SwiftUI
import UIKit

private let maxAdCreativeImageUploadBytes = 10 * 1024 * 1024

private func adCreativeJPEGData(from item: PhotosPickerItem) async throws -> Data? {
    guard let data = try await item.loadTransferable(type: Data.self),
          let image = UIImage(data: data) else { return nil }

    for quality in stride(from: 0.88, through: 0.48, by: -0.10) {
        if let jpeg = image.jpegData(compressionQuality: quality),
           jpeg.count <= maxAdCreativeImageUploadBytes {
            return jpeg
        }
    }
    return image.jpegData(compressionQuality: 0.38)
}

struct OneWayAdsManagerView: View {
    let onClose: () -> Void

    @StateObject private var viewModel = OneWayAdsManagerViewModel()
    @State private var selectedSegment: AdsSegment = .dashboard
    @State private var creativeImagePickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ZStack {
                OneWayLightBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        segmentedControl
                        stateBanner
                        content
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarHidden(true)
            .task { await viewModel.load() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    OneWayResolvedIcon(systemName: "chevron.left")
                        .font(.headline.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                        .frame(width: 44, height: 44)
                        .background(OneWayDesignSystem.Colors.elevatedSurface, in: Circle())
                        .overlay(Circle().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                OneWayLogoMark(size: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("OneWay Ads")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                    Text("Create advertiser profiles and campaign drafts for review.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            OneWayCard {
                HStack(alignment: .top, spacing: 12) {
                    OneWayCinematicAssetView(
                        asset: .adsHologram,
                        motion: .drift,
                        intensity: 0.9
                    )
                    .frame(width: 82, height: 82)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Controlled Launch")
                            .font(.headline.weight(.black))
                            .foregroundStyle(OneWayDesignSystem.Colors.text)
                        Text(viewModel.configSummary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var segmentedControl: some View {
        HStack(spacing: 8) {
            ForEach(AdsSegment.allCases) { segment in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selectedSegment = segment
                    }
                } label: {
                    Text(segment.title)
                        .font(.caption.weight(.black))
                        .foregroundStyle(selectedSegment == segment ? .white : OneWayDesignSystem.Colors.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(selectedSegment == segment ? AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient) : AnyShapeStyle(OneWayDesignSystem.Colors.elevatedSurface), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(OneWayDesignSystem.Colors.surface, in: Capsule())
        .overlay(Capsule().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
    }

    @ViewBuilder
    private var stateBanner: some View {
        if viewModel.isLoading {
            infoCard(icon: "arrow.triangle.2.circlepath", title: "Loading Ads", message: "Checking campaign status, feature flags, and reporting.")
        } else if let error = viewModel.errorMessage {
            infoCard(icon: "exclamationmark.triangle.fill", title: "Ads Needs Attention", message: error)
        } else if let message = viewModel.successMessage {
            infoCard(icon: "checkmark.seal.fill", title: "Ads Updated", message: message)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSegment {
        case .dashboard:
            dashboard
        case .builder:
            builder
        case .review:
            reviewAndPolicy
        case .funding:
            funding
        case .activation:
            activation
        case .reports:
            reports
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            metricGrid
            actionCard
            campaignsCard
            statusBoard
        }
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            metric("Drafts", "\(viewModel.statusCount("draft"))", "doc.badge.plus")
            metric("In Review", "\(viewModel.statusCount("underReview"))", "doc.text.magnifyingglass")
            metric("Eligible", "\(viewModel.statusCount("eligibleForDelivery"))", "checkmark.shield.fill")
            metric("Profiles", "\(viewModel.advertisers.count)", "person.crop.circle.badge.checkmark")
        }
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 12) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                    .frame(width: 38, height: 38)
                    .background(OneWayDesignSystem.Colors.lavender, in: Circle())
                Text(value)
                    .font(.title2.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionCard: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Campaign Command Center")
                    .font(.title3.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                Text("Build a real campaign draft, save each step, return later, and submit into non-delivering review.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                Button {
                    selectedSegment = .builder
                } label: {
                    OneWayResolvedLabel(viewModel.currentCampaign == nil ? "Create Campaign" : "Continue Campaign", systemImage: "plus.circle.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(OneWayDesignSystem.Colors.purpleGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var campaignsCard: some View {
        editorCard("Your Campaigns") {
            if viewModel.campaigns.isEmpty {
                emptyState("No campaigns yet", "Build your first OneWay Ads campaign from the Build tab.")
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(viewModel.campaigns.enumerated()), id: \.element.id) { _, campaign in
                        Button {
                            viewModel.selectCampaign(campaign)
                            selectedSegment = .review
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(campaign.name)
                                        .font(.subheadline.weight(.black))
                                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                                    Text("\(AdsObjective(rawValue: campaign.objective)?.displayName ?? campaign.objective) - \(campaign.status)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                                }
                                Spacer()
                                OneWayResolvedIcon(systemName: "chevron.right")
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                            }
                            .padding(12)
                            .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var statusBoard: some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Launch Gates")
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                gate("Advertiser profile", viewModel.advertisers.isEmpty ? "Create profile" : "Ready")
                gate("Creative", viewModel.currentCampaign?.creatives.isEmpty == false ? "Created" : "Needed")
                gate("Moderation", viewModel.currentCampaign?.moderationStatus ?? "Not submitted")
                gate("Funding", viewModel.config?.campaignFundingEnabled == true ? "Enabled for later phase" : "Locked for Phase 1")
                gate("Delivery", viewModel.config?.paidDeliveryEnabled == true ? "Enabled" : "No live delivery in Phase 1")
            }
        }
    }

    private func gate(_ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 10) {
            OneWayResolvedIcon(systemName: "checkmark.shield.fill")
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }
        }
    }

    private var builder: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorCard("Advertiser Profile") {
                field("Business name", text: $viewModel.businessName)
                field("Display name", text: $viewModel.displayName)
                field("Contact email", text: $viewModel.contactEmail)
                field("Website", text: $viewModel.websiteURL)
                primaryButton(viewModel.selectedAdvertiser == nil ? "Create Advertiser Profile" : "Update Advertiser Profile") {
                    Task { await viewModel.createOrUpdateAdvertiser() }
                }
            }

            editorCard("Campaign Objective") {
                pickerRow(options: AdsObjective.allCases, selection: $viewModel.selectedObjective)
                field("Campaign name", text: $viewModel.campaignName)
                primaryButton(viewModel.currentCampaign == nil ? "Create Campaign Draft" : "Save Campaign Details") {
                    Task { await viewModel.createOrUpdateCampaign() }
                }
            }

            editorCard("Destination") {
                pickerRow(options: AdsDestinationType.allCases, selection: $viewModel.destinationType)
                field("Destination URL or ID", text: $viewModel.destinationValue)
                Text("Use a published OneWay shop/site/product ID, or an HTTPS URL for website visits.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }

            editorCard("Creative") {
                field("Headline", text: $viewModel.headline)
                field("Body text", text: $viewModel.bodyText, axis: .vertical)
                creativeImagePicker
                pickerRow(options: AdsCTA.allCases, selection: $viewModel.cta)
                creativePreview
                primaryButton("Save Creative Version") {
                    Task { await viewModel.saveCreative() }
                }
            }

            editorCard("Placements") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(AdsPlacement.allCases) { placement in
                        Button {
                            viewModel.togglePlacement(placement)
                        } label: {
                            Text(placement.displayName)
                                .font(.caption.weight(.black))
                                .foregroundStyle(viewModel.selectedPlacements.contains(placement) ? .white : OneWayDesignSystem.Colors.text)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(viewModel.selectedPlacements.contains(placement) ? AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient) : AnyShapeStyle(OneWayDesignSystem.Colors.elevatedSurface), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            editorCard("Budget and Schedule") {
                field("Budget USD", text: $viewModel.budget)
                    .keyboardType(.decimalPad)
                field("City targeting", text: $viewModel.cityTarget)
                Text("Minimum budget is \(viewModel.money(viewModel.config?.minimumBudgetMinor ?? 500)).")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }

            primaryButton("Review Campaign") {
                Task {
                    await viewModel.createOrUpdateCampaign()
                    await MainActor.run { selectedSegment = .review }
                }
            }
        }
    }

    private var creativeImagePicker: some View {
        let hasImage = !viewModel.imageURL.isEmpty
        let isUploading = viewModel.isUploadingCreativeImage

        return VStack(alignment: .leading, spacing: 10) {
            PhotosPicker(selection: $creativeImagePickerItem, matching: .images) {
                HStack(spacing: 10) {
                    OneWayResolvedIcon(systemName: hasImage ? "photo.badge.checkmark" : "photo.badge.plus")
                    Text(isUploading ? "Uploading Creative…" : (hasImage ? "Replace Creative Image" : "Choose Creative Image"))
                    Spacer()
                    if isUploading {
                        ProgressView()
                            .tint(OneWayDesignSystem.Colors.purple)
                    }
                }
                .font(.subheadline.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isUploading)
            .onChange(of: creativeImagePickerItem) { _, item in
                guard let item else { return }
                Task {
                    await viewModel.uploadCreativeImage(from: item)
                    creativeImagePickerItem = nil
                }
            }

            if !viewModel.imageURL.isEmpty {
                Button("Remove image", role: .destructive) {
                    viewModel.imageURL = ""
                }
                .font(.caption.weight(.bold))
            }

            Text("JPG, PNG, or WebP. Images are compressed before upload and reviewed with the campaign.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
        }
    }

    private func editorCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        OneWayCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                content()
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        TextField(placeholder, text: text, axis: axis)
            .lineLimit(axis == .vertical ? 2...4 : 1...1)
            .textFieldStyle(.plain)
            .modifier(OneWayFieldStyle())
    }

    private func pickerRow<T: AdsPickerOption>(options: [T], selection: Binding<T>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(options) { option in
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        Text(option.displayName)
                            .font(.caption.weight(.black))
                            .foregroundStyle(selection.wrappedValue.id == option.id ? .white : OneWayDesignSystem.Colors.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(selection.wrappedValue.id == option.id ? AnyShapeStyle(OneWayDesignSystem.Colors.purpleGradient) : AnyShapeStyle(OneWayDesignSystem.Colors.elevatedSurface), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var creativePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sponsored")
                .font(.caption.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
            if let url = URL(string: viewModel.imageURL), !viewModel.imageURL.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        creativeImagePlaceholder(icon: "exclamationmark.triangle.fill", text: "Image unavailable")
                    case .empty:
                        creativeImagePlaceholder(icon: "photo", text: "Loading creative")
                    @unknown default:
                        creativeImagePlaceholder(icon: "photo", text: "Creative image")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Text(viewModel.headline)
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
            Text(viewModel.bodyText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            Text(viewModel.cta.displayName)
                .font(.caption.weight(.black))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(OneWayDesignSystem.Colors.purpleGradient, in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func creativeImagePlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            OneWayResolvedIcon(systemName: icon)
                .font(.title2.weight(.bold))
            Text(text)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OneWayDesignSystem.Colors.surface)
    }

    private var reviewAndPolicy: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorCard("Review and Submit") {
                gate("Campaign", viewModel.currentCampaign?.name ?? viewModel.campaignName)
                gate("Objective", viewModel.selectedObjective.displayName)
                gate("Placements", viewModel.selectedPlacements.map(\.displayName).sorted().joined(separator: ", "))
                gate("Budget", "\(viewModel.budget) planned")
                gate("Status", viewModel.currentCampaign?.status ?? "Draft not created")

                primaryButton("Submit for Moderation") {
                    Task { await viewModel.submitCampaign() }
                }
                secondaryButton("Duplicate Campaign") {
                    Task { await viewModel.duplicateCampaign() }
                }
                secondaryButton("Delete Draft") {
                    Task { await viewModel.deleteCampaign() }
                }
                infoCard(icon: "lock.shield.fill", title: "Activation Guardrail", message: "Funding can prepare an approved campaign, but live delivery and activation stay locked until Phase 2B.")
            }
            editorCard("Validation") {
                if let validation = viewModel.validation {
                    gate("Completion", "\(validation.completionPercentage)%")
                    if validation.blockingErrors.isEmpty {
                        gate("Ready for review", "No blocking issues found")
                    } else {
                        ForEach(validation.blockingErrors, id: \.self) { error in
                            gate("Needs work", error)
                        }
                    }
                } else {
                    emptyState("Validation not loaded", "Open a campaign draft and save it to check review readiness.")
                }
            }
            editorCard("User Controls") {
                gate("Sponsored label", "Always visible")
                gate("Hide this ad", "Available on every ad")
                gate("Report this ad", "Creates a moderation case")
                gate("Why am I seeing this?", "Privacy-safe explanations only")
            }
        }
    }

    private var reports: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorCard("Phase 1 Readiness") {
                gate("Advertiser profiles", "Create, update, list, and close safely")
                gate("Campaign drafts", "Create, save, restore, duplicate, and delete")
                gate("Submission", "Non-delivering moderation review")
                gate("Feature flags", "Server controls objectives, placements, funding, delivery, and reporting")
                gate("Reports", viewModel.config?.reportingEnabled == true ? "Enabled by server flag" : "Locked for later phase")
            }
            editorCard("Privacy Boundary") {
                gate("No private chats", "Ads do not inspect direct messages")
                gate("No calls or Chirp", "Voice/video/PTT surfaces are excluded")
                gate("Minor safety", "Contextual ads only for minors")
            }
        }
    }

    private var funding: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorCard("Funding Required") {
                gate("Campaign", viewModel.currentCampaign?.name ?? "Select a campaign")
                gate("Status", viewModel.currentCampaign?.status ?? "No campaign selected")
                gate("Campaign Balance", viewModel.money(viewModel.funding?.balance.remainingMinor ?? 0))
                gate("Ready for Activation", viewModel.funding?.balance.readyForActivation == true ? "Yes, activation still disabled" : "No")
                field("Funding amount USD", text: $viewModel.fundingAmount)
                    .keyboardType(.decimalPad)
                primaryButton("Fund Campaign") {
                    Task { await viewModel.fundCampaign() }
                }
                Text("Stripe creates the PaymentIntent. Webhooks verify payment and credit the ledger. Campaigns stop at Ready for Activation.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }

            editorCard("Funding History") {
                if let payments = viewModel.funding?.payments, !payments.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(payments) { payment in
                            fundingRow(title: payment.status.capitalized, subtitle: payment.stripePaymentIntentId ?? "PaymentIntent pending", amount: payment.amountMinor)
                        }
                    }
                } else {
                    emptyState("No funding yet", "Approved campaigns can be funded here without activating live ads.")
                }
                secondaryButton("Refresh Funding") {
                    Task { await viewModel.refreshFunding() }
                }
            }

            editorCard("Receipt History") {
                if let receipts = viewModel.funding?.receipts, !receipts.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(receipts) { receipt in
                            fundingRow(title: receipt.receiptNumber, subtitle: receipt.issuedAt ?? "Issued", amount: receipt.amountMinor)
                        }
                    }
                } else {
                    emptyState("No receipts yet", "Receipts appear after Stripe confirms payment through the verified webhook.")
                }
            }

            editorCard("Ledger Reconciliation") {
                gate("Ledger", "\(viewModel.funding?.ledger.count ?? 0) entries")
                gate("Activation", viewModel.config?.campaignActivationEnabled == true ? "Enabled" : "Disabled")
                gate("Paid Delivery", viewModel.config?.paidDeliveryEnabled == true ? "Enabled" : "Disabled")
                secondaryButton("Reconcile Balance") {
                    Task { await viewModel.reconcileFunding() }
                }
            }
        }
    }

    private var activation: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorCard("Activation Readiness") {
                gate("Campaign", viewModel.currentCampaign?.name ?? "Select a campaign")
                gate("Status", viewModel.readableStatus(viewModel.currentCampaign?.status ?? "No campaign"))
                gate("Moderation", viewModel.readableStatus(viewModel.currentCampaign?.moderationStatus ?? "Not submitted"))
                gate("Recommended State", viewModel.readableStatus(viewModel.eligibility?.resultingRecommendedState ?? "Not evaluated"))
                gate("Schedule", viewModel.readableStatus(viewModel.eligibility?.scheduleState ?? "Unknown"))
                gate("Balance", viewModel.money(viewModel.eligibility?.fundingBalanceMinor ?? 0))
                if viewModel.eligibility?.isEligible == true {
                    infoCard(icon: "checkmark.seal.fill", title: "Passed Activation Checks", message: viewModel.eligibility?.deliveryBlocked == true ? "Campaign passed activation checks. Paid delivery is still disabled for this test phase." : "Campaign is eligible for delivery.")
                } else {
                    infoCard(icon: "exclamationmark.triangle.fill", title: "Blocked", message: "Backend gates found items that must be resolved before delivery certification.")
                }
                primaryButton("Refresh Eligibility") {
                    Task { await viewModel.refreshEligibility() }
                }
                secondaryButton("Evaluate Activation") {
                    Task { await viewModel.evaluateActivation() }
                }
            }

            editorCard("Internal Test Delivery") {
                gate("Delivery Status", viewModel.config?.paidDeliveryEnabled == true ? "Paid delivery enabled" : "Public delivery locked")
                gate("Internal Delivery", viewModel.config?.internalDeliveryEnabled == true ? "Enabled for test payloads" : "Disabled by server flag")
                gate("Verification", viewModel.config?.impressionVerificationEnabled == false ? "Disabled" : "Impressions and clicks verified")
                gate("Spend Accounting", viewModel.config?.spendAccountingEnabled == false ? "Disabled" : "Server-authoritative")
                gate("Eligible Placements", viewModel.selectedPlacements.map(\.displayName).sorted().joined(separator: ", "))
                gate("Frequency Caps", "Campaign and advertiser caps are enforced before every preview.")
                if let preview = viewModel.deliveryPreview {
                    if let ad = preview.ad, let delivery = preview.delivery {
                        infoCard(icon: "paperplane.fill", title: "Signed Test Payload", message: "\(ad.headline)\nDelivery ID: \(delivery.deliveryId)\nTrace: \(delivery.traceId)\nImpression token: \(ad.impressionToken == nil ? "missing" : "ready")\nClick token: \(ad.clickToken == nil ? "missing" : "ready")")
                    } else {
                        infoCard(icon: "circle.slash", title: "No Fill", message: viewModel.humanReason(preview.reason ?? "no_eligible_campaign"))
                    }
                } else {
                    emptyState("No preview yet", "Request an internal delivery preview after a campaign passes activation.")
                }
                primaryButton("Preview Internal Delivery") {
                    Task { await viewModel.previewDelivery() }
                }
                HStack(spacing: 10) {
                    secondaryButton("Record Impression") {
                        Task { await viewModel.recordTestImpression() }
                    }
                    secondaryButton("Record Click") {
                        Task { await viewModel.recordTestClick() }
                    }
                }
                HStack(spacing: 10) {
                    secondaryButton("Refresh Spend") {
                        Task { await viewModel.refreshSpendAccounting() }
                    }
                    secondaryButton("Reconcile Spend") {
                        Task { await viewModel.reconcileSpend() }
                    }
                }
                if let result = viewModel.latestEventResult {
                    infoCard(icon: result.ok ? "checkmark.seal.fill" : "xmark.octagon.fill", title: "Latest Event \(result.verificationStatus ?? "unknown")", message: "\(result.eventType ?? "event") • cost \(result.costMinor ?? 0) \(result.currency ?? "USD")\(result.duplicate == true ? "\nDuplicate replay: idempotent" : "")\(result.failureReasonCode.map { "\nReason: \($0)" } ?? "")")
                }
                if let spend = viewModel.spendSnapshot?.spend {
                    infoCard(icon: "chart.line.uptrend.xyaxis", title: "Spend Snapshot", message: "Spent: \(viewModel.currency(spend.spentMinor, spend.currency))\nRemaining: \(viewModel.currency(spend.remainingMinor, spend.currency))\nVerified events: \(spend.verifiedEvents)\nLatest debit: \(spend.latestLedgerDebit?.entryType ?? "none")")
                }
                if let summary = viewModel.eventSummary?.summary, !summary.latest.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(summary.latest.prefix(3)) { event in
                            gate(event.eventType.capitalized, "\(event.verificationStatus) • \(event.costMinor) \(event.currency)")
                        }
                    }
                }
                if let reconciliation = viewModel.spendReconciliation?.reconciliation {
                    infoCard(icon: reconciliation.reconciled ? "equal.circle.fill" : "exclamationmark.triangle.fill", title: "Spend Reconciliation", message: "Ledger: \(reconciliation.ledgerSpendMinor)\nCached: \(reconciliation.cachedSpendMinor)\nPhase: \(reconciliation.phase)")
                }
            }

            editorCard("Activation Blockers") {
                if let blockers = viewModel.eligibility?.blockingReasons, !blockers.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(blockers) { blocker in
                            activationReasonRow(icon: "xmark.octagon.fill", title: viewModel.humanReason(blocker.code), subtitle: blocker.message)
                        }
                    }
                } else {
                    emptyState("No blockers loaded", "Refresh eligibility to ask the backend activation gate for the current result.")
                }
            }

            editorCard("Warnings") {
                if let warnings = viewModel.eligibility?.warnings, !warnings.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(warnings) { warning in
                            activationReasonRow(icon: "info.circle.fill", title: viewModel.humanReason(warning.code), subtitle: warning.message)
                        }
                    }
                } else {
                    emptyState("No warnings", "Warnings appear when a campaign can be certified but live delivery remains blocked.")
                }
            }

            editorCard("Campaign Controls") {
                HStack(spacing: 10) {
                    secondaryButton("Pause") {
                        Task { await viewModel.pauseCampaign() }
                    }
                    secondaryButton("Resume") {
                        Task { await viewModel.resumeCampaign() }
                    }
                }
                secondaryButton("Cancel Campaign") {
                    Task { await viewModel.cancelCampaign() }
                }
                Text("Pause, resume, and cancel use backend state transitions. Resume always reruns activation gates.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }
        }
    }

    private func activationReasonRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OneWayResolvedIcon(systemName: icon)
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                .frame(width: 34, height: 34)
                .background(OneWayDesignSystem.Colors.lavender, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func fundingRow(title: String, subtitle: String, amount: Int) -> some View {
        HStack(spacing: 12) {
            OneWayResolvedIcon(systemName: "creditcard.fill")
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                .frame(width: 38, height: 38)
                .background(OneWayDesignSystem.Colors.lavender, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.text)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
            }
            Spacer()
            Text(viewModel.money(amount))
                .font(.subheadline.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
        }
        .padding(12)
        .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func infoCard(icon: String, title: String, message: String) -> some View {
        OneWayCard {
            HStack(alignment: .top, spacing: 12) {
                OneWayResolvedIcon(systemName: icon)
                    .font(.headline.weight(.black))
                    .foregroundStyle(OneWayDesignSystem.Colors.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(OneWayDesignSystem.Colors.text)
                    Text(message)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func emptyState(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.text)
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OneWayDesignSystem.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(OneWayDesignSystem.Colors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(OneWayDesignSystem.Colors.purpleGradient, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isWorking)
        .opacity(viewModel.isWorking ? 0.65 : 1)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(OneWayDesignSystem.Colors.purple)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(OneWayDesignSystem.Colors.elevatedSurface, in: Capsule())
                .overlay(Capsule().stroke(OneWayDesignSystem.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isWorking)
        .opacity(viewModel.isWorking ? 0.65 : 1)
    }
}

@MainActor
final class OneWayAdsManagerViewModel: ObservableObject {
    @Published var config: AdsConfig?
    @Published var overview: AdsOverview?
    @Published var statusCounts: [String: Int] = [:]
    @Published var advertisers: [AdsAdvertiser] = []
    @Published var campaigns: [AdsCampaign] = []
    @Published var currentCampaign: AdsCampaign?
    @Published var selectedAdvertiser: AdsAdvertiser?
    @Published var report: AdsReport?
    @Published var validation: AdsCampaignValidation?
    @Published var funding: AdsFundingSnapshot?
    @Published var eligibility: AdsEligibilityResult?
    @Published var deliveryPreview: AdsDeliveryPreviewResponse?
    @Published var latestEventResult: AdsEventResponse?
    @Published var spendSnapshot: AdsSpendResponse?
    @Published var eventSummary: AdsEventSummaryResponse?
    @Published var spendReconciliation: AdsSpendReconciliationResponse?
    @Published var isLoading = false
    @Published var isWorking = false
    @Published var isUploadingCreativeImage = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    @Published var businessName = ""
    @Published var displayName = ""
    @Published var contactEmail = ""
    @Published var websiteURL = ""
    @Published var selectedObjective: AdsObjective = .promoteProduct
    @Published var campaignName = ""
    @Published var destinationType: AdsDestinationType = .externalURL
    @Published var destinationValue = ""
    @Published var headline = ""
    @Published var bodyText = ""
    @Published var imageURL = ""
    @Published var cta: AdsCTA = .shopNow
    @Published var selectedPlacements: Set<AdsPlacement> = [.shopDiscovery, .marketplaceResults]
    @Published var budget = "5.00"
    @Published var fundingAmount = "25.00"
    @Published var cityTarget = ""

    private let service = OneWayAdsService()

    var configSummary: String {
        guard let config else { return "Ads are loading from the server." }
        if !config.adsEnabled { return "Ads are disabled by server feature flag." }
        if !config.campaignCreationEnabled { return "Campaign creation is currently disabled by server flag." }
        if !config.paidDeliveryEnabled { return "Phase 3A is active: internal signed delivery previews only. No paid delivery yet." }
        return "Delivery is enabled by server flag. Campaigns still require moderation and approval."
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let configResponse = service.config()
            async let homeResponse = service.managerHome()
            async let advertiserResponse = service.advertisers()
            async let campaignResponse = service.campaigns()
            config = try await configResponse.config
            let home = try await homeResponse
            overview = home.metrics
            statusCounts = home.statusCounts
            advertisers = try await advertiserResponse.advertisers
            campaigns = try await campaignResponse.campaigns
            selectedAdvertiser = advertisers.first
            currentCampaign = campaigns.first
            if let advertiser = selectedAdvertiser {
                businessName = advertiser.businessName
                displayName = advertiser.displayName
                contactEmail = advertiser.contactEmail
                websiteURL = advertiser.websiteURL ?? websiteURL
            }
            if let campaign = currentCampaign {
                apply(campaign)
                await refreshValidation()
                await refreshFunding()
                await refreshEligibility()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createOrUpdateAdvertiser() async {
        await perform("Advertiser profile saved.") {
            if let selectedAdvertiser = self.selectedAdvertiser {
                let response = try await self.service.updateAdvertiser(id: selectedAdvertiser.id, body: self.advertiserBody())
                self.selectedAdvertiser = response.advertiser
            } else {
                let response = try await self.service.createAdvertiser(body: self.advertiserBody())
                self.selectedAdvertiser = response.advertiser
            }
            await self.load()
        }
    }

    func createOrUpdateCampaign() async {
        await perform("Campaign draft saved.") {
            guard self.selectedAdvertiser != nil || !self.advertisers.isEmpty else {
                throw AdsClientError.validation("Create an advertiser profile first.")
            }
            if self.selectedAdvertiser == nil { self.selectedAdvertiser = self.advertisers.first }
            guard let advertiser = self.selectedAdvertiser else {
                throw AdsClientError.validation("Create an advertiser profile first.")
            }
            if self.currentCampaign == nil {
                let created = try await self.service.createCampaign(body: AdsCampaignCreateBody(
                    advertiserId: advertiser.id,
                    name: self.campaignName,
                    objective: self.selectedObjective.rawValue,
                    internalNotes: "Created from iOS OneWay Ads Manager"
                ))
                self.currentCampaign = created.campaign
            }
            guard let campaign = self.currentCampaign else { return }
            let response = try await self.service.updateCampaign(id: campaign.id, body: self.campaignBody())
            self.currentCampaign = response.campaign
            await self.load()
        }
    }

    func saveCreative() async {
        await perform("Creative saved and ready for review.") {
            if self.currentCampaign == nil {
                await self.createOrUpdateCampaign()
            }
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Create a campaign draft first.")
            }
            let response = try await self.service.createCreative(campaignId: campaign.id, body: AdsCreativeBody(
                headline: self.headline,
                bodyText: self.bodyText,
                cta: self.cta.rawValue,
                logoURL: nil,
                imageURL: self.imageURL.trimmedNonEmpty,
                videoURL: nil,
                thumbnailURL: nil,
                accessibilityDescription: nil
            ))
            var updated = campaign
            updated.creatives.insert(response.creative, at: 0)
            self.currentCampaign = updated
            await self.load()
        }
    }

    func uploadCreativeImage(from item: PhotosPickerItem) async {
        isUploadingCreativeImage = true
        errorMessage = nil
        successMessage = nil
        defer { isUploadingCreativeImage = false }

        do {
            guard let data = try await adCreativeJPEGData(from: item) else {
                throw AdsClientError.validation("We couldn’t read that image. Try another photo.")
            }
            guard data.count <= maxAdCreativeImageUploadBytes else {
                throw AdsClientError.validation("Creative images must be 10 MB or smaller.")
            }
            let fileName = item.itemIdentifier.map { "\($0).jpg" } ?? "ad-creative-\(UUID().uuidString).jpg"
            let response = try await service.uploadCreativeImage(data: data, fileName: fileName)
            imageURL = response.url
            successMessage = "Creative image uploaded."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitCampaign() async {
        await perform("Campaign submitted for moderation.") {
            if self.currentCampaign == nil { await self.createOrUpdateCampaign() }
            if self.currentCampaign?.creatives.isEmpty != false { await self.saveCreative() }
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Create a campaign first.")
            }
            let response = try await self.service.submitCampaign(id: campaign.id)
            self.currentCampaign = response.campaign
            await self.refreshValidation()
            await self.load()
        }
    }

    func fundCampaign() async {
        await perform("Stripe PaymentIntent created. Complete payment, then webhook will credit the Ads ledger.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select an approved campaign first.")
            }
            guard self.config?.campaignFundingEnabled == true else {
                throw AdsClientError.validation("Campaign funding is disabled by server feature flag.")
            }
            let amount = max(self.minorUnits(from: self.fundingAmount), self.config?.minimumBudgetMinor ?? 500)
            let response = try await self.service.fundCampaign(id: campaign.id, body: AdsFundBody(amountMinor: amount, currency: "USD", idempotencyKey: "ios-ads-fund-\(campaign.id)-\(amount)"))
            self.funding = AdsFundingSnapshot(ok: true, balance: response.balance, payments: [response.payment], ledger: self.funding?.ledger ?? [], receipts: self.funding?.receipts ?? [])
            await self.refreshFunding()
            await self.refreshEligibility()
            await self.load()
        }
    }

    func deleteCampaign() async {
        await perform("Campaign draft deleted.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select a campaign first.")
            }
            try await self.service.deleteCampaign(id: campaign.id)
            self.currentCampaign = nil
            self.validation = nil
            self.funding = nil
            self.eligibility = nil
            await self.load()
        }
    }

    func duplicateCampaign() async {
        await perform("Campaign duplicated as a new draft.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select a campaign first.")
            }
            let response = try await self.service.duplicateCampaign(id: campaign.id)
            self.currentCampaign = response.campaign
            self.apply(response.campaign)
            await self.load()
        }
    }

    func refreshValidation() async {
        guard let campaign = currentCampaign else { return }
        do {
            validation = try await service.validateCampaign(id: campaign.id).validation
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshFunding() async {
        guard let campaign = currentCampaign else { return }
        do {
            funding = try await service.funding(id: campaign.id)
            errorMessage = nil
        } catch {
            if config?.campaignFundingEnabled == true {
                errorMessage = error.localizedDescription
            }
        }
    }

    func reconcileFunding() async {
        await perform("Campaign ledger reconciled.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select a campaign first.")
            }
            _ = try await self.service.reconcileFunding(id: campaign.id)
            await self.refreshFunding()
            await self.refreshEligibility()
            await self.load()
        }
    }

    func refreshEligibility() async {
        guard let campaign = currentCampaign else { return }
        do {
            eligibility = try await service.eligibility(id: campaign.id).eligibility
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func evaluateActivation() async {
        await perform("Activation gates evaluated.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select a campaign first.")
            }
            let response = try await self.service.evaluateActivation(id: campaign.id)
            self.currentCampaign = response.campaign ?? self.currentCampaign
            self.eligibility = response.eligibility
            await self.refreshFunding()
            await self.load()
        }
    }

    func previewDelivery() async {
        await perform("Internal delivery preview generated.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select a campaign first.")
            }
            let placement = self.selectedPlacements.first ?? .contentFeed
            self.deliveryPreview = try await self.service.previewDelivery(id: campaign.id, body: AdsDeliveryPreviewBody(
                placement: placement.rawValue,
                contextualCategory: "business",
                deviceClass: "ios",
                country: "US",
                viewerReference: "ios-internal-preview-\(campaign.id)",
                isMinor: false
            ))
        }
    }

    func recordTestImpression() async {
        await perform("Verified test impression recorded.") {
            guard let token = self.deliveryPreview?.ad?.impressionToken else {
                throw AdsClientError.validation("Preview an internal delivery first.")
            }
            let result = try await self.service.recordImpression(body: AdsEventBody(
                token: token,
                clientEventId: "ios-imp-\(UUID().uuidString)",
                visibleAreaPercent: 95,
                durationMs: 1500,
                deviceClass: "ios",
                country: "US"
            ))
            self.latestEventResult = result
            await self.refreshSpendAccounting()
        }
    }

    func recordTestClick() async {
        await perform("Verified test click recorded.") {
            guard let token = self.deliveryPreview?.ad?.clickToken else {
                throw AdsClientError.validation("Preview an internal delivery first.")
            }
            let result = try await self.service.recordClick(body: AdsClickEventBody(
                token: token,
                clientEventId: "ios-click-\(UUID().uuidString)",
                deviceClass: "ios",
                country: "US"
            ))
            self.latestEventResult = result
            await self.refreshSpendAccounting()
        }
    }

    func refreshSpendAccounting() async {
        guard let campaign = currentCampaign else { return }
        do {
            async let spend = service.spend(id: campaign.id)
            async let summary = service.eventSummary(id: campaign.id)
            spendSnapshot = try await spend
            eventSummary = try await summary
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reconcileSpend() async {
        await perform("Ads spend reconciled.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select a campaign first.")
            }
            self.spendReconciliation = try await self.service.reconcileSpend(id: campaign.id)
            await self.refreshSpendAccounting()
        }
    }

    func pauseCampaign() async {
        await perform("Campaign paused.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select a campaign first.")
            }
            let response = try await self.service.pauseCampaign(id: campaign.id)
            self.currentCampaign = response.campaign ?? self.currentCampaign
            await self.refreshEligibility()
            await self.load()
        }
    }

    func resumeCampaign() async {
        await perform("Campaign resume requested. Activation gates reran.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select a campaign first.")
            }
            let response = try await self.service.resumeCampaign(id: campaign.id)
            self.currentCampaign = response.campaign ?? self.currentCampaign
            self.eligibility = response.eligibility
            await self.refreshFunding()
            await self.load()
        }
    }

    func cancelCampaign() async {
        await perform("Campaign canceled. Ledger and receipt history are preserved.") {
            guard let campaign = self.currentCampaign else {
                throw AdsClientError.validation("Select a campaign first.")
            }
            let response = try await self.service.cancelCampaign(id: campaign.id)
            self.currentCampaign = response.campaign ?? self.currentCampaign
            await self.refreshEligibility()
            await self.load()
        }
    }

    func selectCampaign(_ campaign: AdsCampaign) {
        currentCampaign = campaign
        apply(campaign)
        Task { await refreshValidation() }
        Task { await refreshFunding() }
        Task { await refreshEligibility() }
        Task { await refreshSpendAccounting() }
    }

    func statusCount(_ key: String) -> Int {
        statusCounts[key] ?? 0
    }

    func togglePlacement(_ placement: AdsPlacement) {
        if selectedPlacements.contains(placement) {
            selectedPlacements.remove(placement)
        } else {
            selectedPlacements.insert(placement)
        }
    }

    func money(_ amountMinor: Int) -> String {
        let amount = Double(amountMinor) / 100
        return amount.formatted(.currency(code: "USD"))
    }

    func currency(_ amountMinor: Int, _ code: String) -> String {
        let amount = Double(amountMinor) / 100
        return amount.formatted(.currency(code: code))
    }

    func readableStatus(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "eligibleForDelivery", with: "Eligible for Delivery")
            .replacingOccurrences(of: "readyForActivation", with: "Ready for Activation")
            .replacingOccurrences(of: "fundingRequired", with: "Funding Required")
            .replacingOccurrences(of: "underReview", with: "Under Review")
            .capitalized
    }

    func humanReason(_ code: String) -> String {
        switch code {
        case "funding_missing", "payment_not_verified", "ledger_credit_missing": return "Funding has not been verified."
        case "schedule_not_started": return "The campaign schedule has not started."
        case "creative_not_approved", "creative_version_mismatch": return "The selected creative is awaiting approval."
        case "destination_invalid", "destination_unpublished": return "The destination is no longer available."
        case "paid_delivery_disabled": return "Paid delivery is disabled for internal testing."
        case "activation_disabled": return "Activation is disabled by server flag."
        case "advertiser_not_active", "advertiser_verification_required": return "Advertiser verification is required."
        case "placement_disabled": return "A selected placement is disabled."
        case "objective_disabled": return "The campaign objective is disabled."
        case "balance_zero": return "Campaign balance is zero."
        case "campaign_paused": return "Campaign is paused."
        case "campaign_suspended": return "Campaign is suspended."
        case "schedule_expired": return "Campaign schedule has expired."
        default: return readableStatus(code)
        }
    }

    func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }

    private func perform(_ success: String, action: @escaping () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        successMessage = nil
        defer { isWorking = false }
        do {
            try await action()
            successMessage = success
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func advertiserBody() -> AdsAdvertiserBody {
        AdsAdvertiserBody(
            businessName: businessName,
            displayName: displayName,
            businessType: "creator",
            websiteURL: websiteURL.trimmedNonEmpty,
            oneWaySiteId: nil,
            oneWayShopId: nil,
            contactEmail: contactEmail,
            country: "US",
            state: nil,
            city: cityTarget.trimmedNonEmpty,
            associatedProfileId: nil,
            associatedCommunityId: nil
        )
    }

    private func campaignBody() -> AdsCampaignPatchBody {
        let budgetMinor = max(minorUnits(from: budget), config?.minimumBudgetMinor ?? 500)
        let destination = destinationValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationId = destinationType == .externalURL ? nil : destination
        let destinationURL = destinationType == .externalURL ? destination : nil
        let rules = cityTarget.trimmedNonEmpty.map { [AdsAudienceRule(ruleType: "city", ruleValue: $0)] } ?? []
        return AdsCampaignPatchBody(
            name: campaignName,
            internalNotes: "iOS guided builder draft",
            destinationType: destinationType.rawValue,
            destinationId: destinationId,
            destinationURL: destinationURL,
            dailyBudgetMinor: nil,
            lifetimeBudgetMinor: budgetMinor,
            maxSpendMinor: budgetMinor,
            currency: "USD",
            startAt: nil,
            endAt: nil,
            scheduleTimezone: TimeZone.current.identifier,
            currentBuilderStep: "review",
            placements: selectedPlacements.map(\.rawValue),
            audienceRules: rules
        )
    }

    private func apply(_ campaign: AdsCampaign) {
        campaignName = campaign.name
        if let objective = AdsObjective(rawValue: campaign.objective) {
            selectedObjective = objective
        }
        if let type = campaign.destinationType.flatMap(AdsDestinationType.init(rawValue:)) {
            destinationType = type
        }
        destinationValue = campaign.destinationURL ?? campaign.destinationId ?? destinationValue
        if let budget = campaign.lifetimeBudgetMinor {
            self.budget = String(format: "%.2f", Double(budget) / 100)
        }
        selectedPlacements = Set(campaign.placements.compactMap(AdsPlacement.init(rawValue:)))
        if let creative = campaign.creatives.first {
            headline = creative.headline
            bodyText = creative.bodyText
            imageURL = creative.imageURL ?? imageURL
            if let cta = AdsCTA(rawValue: creative.cta) {
                self.cta = cta
            }
        }
    }

    private func minorUnits(from value: String) -> Int {
        let cleaned = value.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Int((Double(cleaned) ?? 0) * 100)
    }
}

private struct OneWayAdsService {
    private let client = APIClient.shared

    func config() async throws -> AdsConfigResponse {
        try await client.get("api/ads/config", requiresAuth: false)
    }

    func managerHome() async throws -> AdsManagerHomeResponse {
        try await client.get("api/ads/manager/home")
    }

    func advertisers() async throws -> AdsAdvertisersResponse {
        try await client.get("api/ads/advertisers")
    }

    func createAdvertiser(body: AdsAdvertiserBody) async throws -> AdsAdvertiserResponse {
        try await client.post("api/ads/advertisers", body: body)
    }

    func updateAdvertiser(id: String, body: AdsAdvertiserBody) async throws -> AdsAdvertiserResponse {
        try await client.patch("api/ads/advertisers/\(id)", body: body)
    }

    func campaigns() async throws -> AdsCampaignsResponse {
        try await client.get("api/ads/campaigns")
    }

    func createCampaign(body: AdsCampaignCreateBody) async throws -> AdsCampaignResponse {
        try await client.post("api/ads/campaigns", body: body)
    }

    func updateCampaign(id: String, body: AdsCampaignPatchBody) async throws -> AdsCampaignResponse {
        try await client.patch("api/ads/campaigns/\(id)", body: body)
    }

    func createCreative(campaignId: String, body: AdsCreativeBody) async throws -> AdsCreativeResponse {
        try await client.post("api/ads/campaigns/\(campaignId)/creatives", body: body)
    }

    func uploadCreativeImage(data: Data, fileName: String) async throws -> AdsImageUploadResponse {
        try await client.uploadMultipart(
            "api/uploads/image?purpose=ad_creative",
            fileName: fileName,
            mimeType: "image/jpeg",
            data: data
        )
    }

    func submitCampaign(id: String) async throws -> AdsCampaignResponse {
        try await client.post("api/ads/campaigns/\(id)/submit", body: AdsSubmitBody(clientSubmissionId: UUID().uuidString))
    }

    func duplicateCampaign(id: String) async throws -> AdsCampaignResponse {
        try await client.post("api/ads/campaigns/\(id)/duplicate", body: EmptyAdsBody())
    }

    func fundCampaign(id: String, body: AdsFundBody) async throws -> AdsFundResponse {
        try await client.post("api/ads/campaigns/\(id)/fund", body: body)
    }

    func funding(id: String) async throws -> AdsFundingSnapshot {
        try await client.get("api/ads/campaigns/\(id)/funding")
    }

    func reconcileFunding(id: String) async throws -> AdsReconciliationResponse {
        try await client.post("api/ads/campaigns/\(id)/reconcile-ledger", body: EmptyAdsBody())
    }

    func eligibility(id: String) async throws -> AdsEligibilityResponse {
        try await client.get("api/ads/campaigns/\(id)/eligibility")
    }

    func evaluateActivation(id: String) async throws -> AdsActivationResponse {
        try await client.post("api/ads/campaigns/\(id)/evaluate-activation", body: EmptyAdsBody())
    }

    func pauseCampaign(id: String) async throws -> AdsActivationResponse {
        try await client.post("api/ads/campaigns/\(id)/pause", body: EmptyAdsBody())
    }

    func resumeCampaign(id: String) async throws -> AdsActivationResponse {
        try await client.post("api/ads/campaigns/\(id)/resume", body: EmptyAdsBody())
    }

    func cancelCampaign(id: String) async throws -> AdsActivationResponse {
        try await client.post("api/ads/campaigns/\(id)/cancel", body: EmptyAdsBody())
    }

    func deleteCampaign(id: String) async throws {
        let _: EmptyAdsResponse = try await client.delete("api/ads/campaigns/\(id)")
    }

    func validateCampaign(id: String) async throws -> AdsValidationResponse {
        try await client.get("api/ads/campaigns/\(id)/validation")
    }

    func previewDelivery(id: String, body: AdsDeliveryPreviewBody) async throws -> AdsDeliveryPreviewResponse {
        try await client.post("api/ads/campaigns/\(id)/delivery-preview", body: body)
    }

    func recordImpression(body: AdsEventBody) async throws -> AdsEventResponse {
        try await client.post("api/ads/events/impression", body: body)
    }

    func recordClick(body: AdsClickEventBody) async throws -> AdsEventResponse {
        try await client.post("api/ads/events/click", body: body)
    }

    func spend(id: String) async throws -> AdsSpendResponse {
        try await client.get("api/ads/campaigns/\(id)/spend")
    }

    func eventSummary(id: String) async throws -> AdsEventSummaryResponse {
        try await client.get("api/ads/campaigns/\(id)/events/summary")
    }

    func reconcileSpend(id: String) async throws -> AdsSpendReconciliationResponse {
        try await client.post("api/ads/campaigns/\(id)/reconcile-spend", body: EmptyAdsBody())
    }
}

private enum AdsClientError: LocalizedError {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message): return message
        }
    }
}

protocol AdsPickerOption: CaseIterable, Identifiable, Hashable {
    var displayName: String { get }
}

private enum AdsSegment: String, CaseIterable, Identifiable {
    case dashboard
    case builder
    case review
    case funding
    case activation
    case reports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Home"
        case .builder: return "Build"
        case .review: return "Review"
        case .funding: return "Fund"
        case .activation: return "Ready"
        case .reports: return "Rules"
        }
    }
}

enum AdsObjective: String, AdsPickerOption {
    case promoteShop = "promote_shop"
    case promoteProduct = "promote_product"
    case promoteSite = "promote_site"
    case promoteCommunity = "promote_community"
    case websiteVisits = "website_visits"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .promoteShop: return "Promote Shop"
        case .promoteProduct: return "Promote Product"
        case .promoteSite: return "Promote Site"
        case .promoteCommunity: return "Promote Community"
        case .websiteVisits: return "Website Visits"
        }
    }
}

enum AdsDestinationType: String, AdsPickerOption {
    case shop
    case product
    case site
    case community
    case externalURL = "external_url"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shop: return "Shop"
        case .product: return "Product"
        case .site: return "Site"
        case .community: return "Community"
        case .externalURL: return "Website URL"
        }
    }
}

enum AdsPlacement: String, AdsPickerOption {
    case shopDiscovery = "shop_discovery"
    case marketplaceResults = "marketplace_results"
    case siteDiscovery = "site_discovery"
    case communityDiscovery = "community_discovery"
    case contentFeed = "content_feed"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shopDiscovery: return "Shop Discovery"
        case .marketplaceResults: return "Marketplace Results"
        case .siteDiscovery: return "Site Discovery"
        case .communityDiscovery: return "Community Discovery"
        case .contentFeed: return "Content Feed"
        }
    }
}

enum AdsCTA: String, AdsPickerOption {
    case shopNow = "Shop Now"
    case viewProduct = "View Product"
    case learnMore = "Learn More"
    case visitSite = "Visit Site"
    case joinCommunity = "Join Community"
    case contactBusiness = "Contact Business"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

private struct EmptyAdsBody: Encodable {}
private struct EmptyAdsResponse: Decodable { let ok: Bool }
private struct AdsSubmitBody: Encodable { let clientSubmissionId: String }

struct AdsConfigResponse: Decodable { let ok: Bool; let config: AdsConfig }
private struct AdsManagerHomeResponse: Decodable { let ok: Bool; let config: AdsConfig; let statusCounts: [String: Int]; let metrics: AdsOverview }
struct AdsAdvertisersResponse: Decodable { let ok: Bool; let advertisers: [AdsAdvertiser] }
struct AdsAdvertiserResponse: Decodable { let ok: Bool; let advertiser: AdsAdvertiser }
struct AdsCampaignsResponse: Decodable { let ok: Bool; let campaigns: [AdsCampaign] }
struct AdsCampaignResponse: Decodable { let ok: Bool; let campaign: AdsCampaign }
struct AdsCreativeResponse: Decodable { let ok: Bool; let creative: AdsCreative }
private struct AdsImageUploadResponse: Decodable { let url: String }
struct AdsReportResponse: Decodable { let ok: Bool; let report: AdsReport }
struct AdsOverviewResponse: Decodable { let ok: Bool; let overview: AdsOverview }
private struct AdsValidationResponse: Decodable { let ok: Bool; let validation: AdsCampaignValidation }
private struct AdsEligibilityResponse: Decodable { let ok: Bool; let eligibility: AdsEligibilityResult }
private struct AdsActivationResponse: Decodable {
    let ok: Bool
    let transition: AdsTransitionSummary?
    let eligibility: AdsEligibilityResult?
    let campaign: AdsCampaign?
    let error: String?
}

struct AdsTransitionSummary: Decodable {
    let ok: Bool
    let previousState: String
    let newState: String
    let error: String?
}

struct AdsConfig: Decodable {
    let adsEnabled: Bool
    let advertiserCreationEnabled: Bool
    let campaignCreationEnabled: Bool
    let campaignSubmissionEnabled: Bool
    let moderationEnabled: Bool
    let campaignFundingEnabled: Bool
    let campaignActivationEnabled: Bool
    let paidDeliveryEnabled: Bool
    let internalDeliveryEnabled: Bool
    let impressionVerificationEnabled: Bool?
    let clickVerificationEnabled: Bool?
    let spendAccountingEnabled: Bool?
    let impressionBillingEnabled: Bool?
    let clickBillingEnabled: Bool?
    let conversionTrackingEnabled: Bool?
    let reportingEnabled: Bool
    let minimumBudgetMinor: Int
    let cpmPriceMinor: Int
    let cpcPriceMinor: Int?
    let stripeConfigured: Bool
}

struct AdsDeliveryPreviewBody: Encodable {
    let placement: String
    let contextualCategory: String?
    let deviceClass: String?
    let country: String?
    let viewerReference: String?
    let isMinor: Bool?
}

struct AdsDeliveryPreviewResponse: Decodable {
    let ok: Bool
    let ad: AdsDeliveredAd?
    let reason: String?
    let delivery: AdsDeliveryPayload?
    let deliveryStatus: AdsDeliveryStatus?
}

struct AdsDeliveredAd: Decodable {
    let id: String
    let campaignId: String
    let advertiserId: String
    let headline: String
    let bodyText: String
    let cta: String
    let placement: String
    let sponsoredLabel: String
    let impressionToken: String?
    let clickToken: String?
    let deliveryId: String?
    let traceId: String?
}

struct AdsDeliveryPayload: Decodable {
    let deliveryId: String
    let traceId: String
    let token: String
    let expiresAt: String
    let internalTest: Bool
    let paidDeliveryEnabled: Bool
}

struct AdsDeliveryStatus: Decodable {
    let paidDeliveryEnabled: Bool
    let internalDeliveryEnabled: Bool
    let publicDeliveryBlocked: Bool
}

struct AdsFundingSnapshot: Decodable {
    let ok: Bool?
    let balance: AdsCampaignBalance
    let payments: [AdsPayment]
    let ledger: [AdsLedgerEntry]
    let receipts: [AdsReceipt]
}

struct AdsEligibilityResult: Decodable {
    let isEligible: Bool
    let deliveryBlocked: Bool
    let resultingRecommendedState: String
    let blockingReasons: [AdsEligibilityReason]
    let warnings: [AdsEligibilityReason]
    let evaluatedAt: String
    let campaignId: String
    let advertiserId: String?
    let campaignRevision: Int
    let creativeVersion: Int?
    let fundingBalanceMinor: Int
    let currency: String
    let scheduleState: String
    let enabledPlacements: [String]
    let disabledPlacements: [String]
    let correlationId: String
}

struct AdsEligibilityReason: Decodable, Identifiable {
    var id: String { "\(code)-\(message)" }
    let code: String
    let message: String
    let severity: String
}

struct AdsCampaignBalance: Decodable {
    let campaignId: String
    let currency: String
    let fundedMinor: Int
    let spentMinor: Int
    let remainingMinor: Int
    let status: String
    let readyForActivation: Bool
    let activationEnabled: Bool
}

struct AdsLedgerEntry: Decodable, Identifiable {
    let id: String
    let campaignId: String
    let entryType: String
    let amountMinor: Int
    let currency: String
    let status: String?
    let stripePaymentIntentId: String?
    let createdAt: String?
}

struct AdsReceipt: Decodable, Identifiable {
    let id: String
    let receiptNumber: String
    let campaignId: String
    let amountMinor: Int
    let currency: String
    let status: String
    let issuedAt: String?
    let stripePaymentIntentId: String?
}

struct AdsCampaignValidation: Decodable {
    let ok: Bool
    let missing: [String]
    let blockingErrors: [String]
    let warnings: [String]
    let completionPercentage: Int
    let nextIncompleteStep: String?
    let riskLevel: String
}

struct AdsOverview: Decodable {
    let amountSpentMinor: Int
    let remainingCampaignBudgetMinor: Int
    let impressions: Int
    let clicks: Int
    let conversions: Int
    let salesAttributedMinor: Int
    let averageCostPerClickMinor: Int
    let clickThroughRate: Double
    let returnOnAdSpend: Double?
}

struct AdsAdvertiser: Decodable, Identifiable {
    let id: String
    let businessName: String
    let displayName: String
    let businessType: String
    let websiteURL: String?
    let contactEmail: String
    let status: String
}

struct AdsCampaign: Decodable, Identifiable {
    let id: String
    let advertiserId: String
    let name: String
    let objective: String
    let status: String
    let moderationStatus: String
    let destinationType: String?
    let destinationId: String?
    let destinationURL: String?
    let lifetimeBudgetMinor: Int?
    let fundedMinor: Int?
    let spentMinor: Int?
    let placements: [String]
    let audienceRules: [AdsAudienceRule]
    var creatives: [AdsCreative]
}

struct AdsCreative: Decodable, Identifiable {
    let id: String
    let campaignId: String
    let version: Int
    let status: String
    let moderationStatus: String
    let headline: String
    let bodyText: String
    let cta: String
    let imageURL: String?
    let videoURL: String?
}

struct AdsAudienceRule: Codable, Identifiable {
    var id: String { "\(ruleType)-\(ruleValue)" }
    let ruleType: String
    let ruleValue: String
}

struct AdsReport: Decodable {
    let impressions: Int
    let clicks: Int
    let conversions: Int
    let spendMinor: Int
    let remainingBudgetMinor: Int
    let clickThroughRate: Double
}

struct AdsPayment: Decodable, Identifiable {
    let id: String
    let campaignId: String
    let amountMinor: Int
    let currency: String
    let status: String
    let stripePaymentIntentId: String?
}

struct AdsStripePayment: Decodable {
    let configured: Bool
    let paymentIntentId: String?
    let clientSecret: String?
    let publishableKey: String?
}

struct AdsAdvertiserBody: Codable {
    let businessName: String
    let displayName: String
    let businessType: String
    let websiteURL: String?
    let oneWaySiteId: String?
    let oneWayShopId: String?
    let contactEmail: String
    let country: String
    let state: String?
    let city: String?
    let associatedProfileId: String?
    let associatedCommunityId: String?
}

struct AdsCampaignCreateBody: Encodable {
    let advertiserId: String
    let name: String
    let objective: String
    let internalNotes: String?
}

struct AdsCampaignPatchBody: Encodable {
    let name: String
    let internalNotes: String?
    let destinationType: String
    let destinationId: String?
    let destinationURL: String?
    let dailyBudgetMinor: Int?
    let lifetimeBudgetMinor: Int
    let maxSpendMinor: Int
    let currency: String
    let startAt: String?
    let endAt: String?
    let scheduleTimezone: String?
    let currentBuilderStep: String?
    let placements: [String]
    let audienceRules: [AdsAudienceRule]
}

struct AdsCreativeBody: Encodable {
    let headline: String
    let bodyText: String
    let cta: String
    let logoURL: String?
    let imageURL: String?
    let videoURL: String?
    let thumbnailURL: String?
    let accessibilityDescription: String?
}

private struct AdsFundBody: Encodable {
    let amountMinor: Int
    let currency: String
    let idempotencyKey: String
}

private struct AdsFundResponse: Decodable {
    let ok: Bool
    let payment: AdsPayment
    let balance: AdsCampaignBalance
    let stripe: AdsStripePayment?
}

private struct AdsReconciliationResponse: Decodable {
    let ok: Bool
    let balance: AdsCampaignBalance
}

private struct AdsEventBody: Encodable {
    let token: String
    let clientEventId: String
    let visibleAreaPercent: Double
    let durationMs: Int
    let deviceClass: String?
    let country: String?
}

private struct AdsClickEventBody: Encodable {
    let token: String
    let clientEventId: String
    let deviceClass: String?
    let country: String?
}

struct AdsEventResponse: Decodable {
    let ok: Bool
    let counted: Bool?
    let eventId: String?
    let eventType: String?
    let verificationStatus: String?
    let failureReasonCode: String?
    let costMinor: Int?
    let currency: String?
    let ledgerEntryId: String?
    let duplicate: Bool?
}

struct AdsSpendResponse: Decodable {
    let ok: Bool
    let spend: AdsSpendSnapshot
}

struct AdsSpendSnapshot: Decodable {
    let campaignId: String
    let status: String
    let currency: String
    let fundedMinor: Int
    let spentMinor: Int
    let remainingMinor: Int
    let eventCostMinor: Int
    let verifiedEvents: Int
    let latestLedgerDebit: AdsLedgerEntry?
}

struct AdsEventSummaryResponse: Decodable {
    let ok: Bool
    let summary: AdsEventSummary
}

struct AdsEventSummary: Decodable {
    let campaignId: String
    let latest: [AdsEventHistoryRow]
}

struct AdsEventHistoryRow: Decodable, Identifiable {
    let id: String
    let eventType: String
    let verificationStatus: String
    let failureReasonCode: String?
    let costMinor: Int
    let currency: String
    let createdAt: String
}

struct AdsSpendReconciliationResponse: Decodable {
    let ok: Bool
    let reconciliation: AdsSpendReconciliation
}

struct AdsSpendReconciliation: Decodable {
    let campaignId: String
    let ledgerSpendMinor: Int
    let cachedSpendMinor: Int
    let reconciled: Bool
    let phase: String
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
