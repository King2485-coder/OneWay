import Foundation
import SwiftUI
import Combine

@MainActor
final class BusinessSetupViewModel: ObservableObject {
    @Published var profile: BusinessPresenceProfile = .empty
    @Published var setupStatus: BusinessSetupStatus?
    @Published var plans: [BusinessPlan] = []
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?

    private let service: BusinessPresenceServicing

    init(service: BusinessPresenceServicing = NetworkBusinessPresenceService()) {
        self.service = service
    }

    var progress: Double {
        Double(setupStatus?.profile.onboardingProgress ?? profile.onboardingProgress) / 100.0
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let profileRequest = service.fetchProfile()
            async let statusRequest = service.fetchSetupStatus()
            async let plansRequest = service.fetchPlans()
            let loadedProfile = try await profileRequest
            let status = try await statusRequest
            let loadedPlans = try await plansRequest
            profile = status.profile.id == "local" ? loadedProfile : status.profile
            setupStatus = status
            plans = loadedPlans
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await service.updateProfile(
                BusinessPresenceUpdate(
                    businessName: profile.businessName,
                    industry: profile.industry,
                    businessHours: profile.businessHours,
                    greeting: profile.greeting,
                    missedCallAutoReply: profile.missedCallAutoReply,
                    aiReceptionistEnabled: profile.aiReceptionistEnabled,
                    planId: profile.planId.nilIfBlank,
                    smsStatus: nil,
                    voiceStatus: nil,
                    setupStep: profile.setupStep.nilIfBlank,
                    onboardingProgress: profile.onboardingProgress
                )
            )
            profile = saved
            setupStatus = try await service.fetchSetupStatus()
            if let setupStatus {
                profile = setupStatus.profile
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAIReceptionistEnabled(_ enabled: Bool) {
        profile.aiReceptionistEnabled = enabled
        Task { await save() }
    }

    func selectPlan(_ plan: BusinessPlan) {
        profile.planId = plan.id
        Task { await save() }
    }

    func refreshAfterNumberClaim() async {
        await load()
    }

    func friendlyStatus(_ status: String) -> String {
        switch status {
        case "ready":
            return "Ready"
        case "pending":
            return "Waiting on approval"
        case "demo":
            return "Demo mode"
        case "needsSetup", "notConfigured":
            return "Needs setup"
        default:
            return status
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    func statusTint(_ status: String) -> Color {
        switch status {
        case "ready":
            return .green
        case "pending":
            return .orange
        case "demo":
            return Theme.accentGold
        default:
            return .red
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
