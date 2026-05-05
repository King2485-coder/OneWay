import Foundation
import Combine

@MainActor
final class SafetyCenterViewModel: ObservableObject {
    @Published var blockHandle = ""
    @Published var reportHandle = ""
    @Published var reportReason = ""
    @Published var selectedPreset: PrivacyPreset = .contactsOnly
    @Published var selectedStoryAudience: StoryAudienceScope = .friends
    @Published private(set) var blockedHandles: [String] = []
    @Published var infoMessage: String?

    private let service: SafetyService

    init(service: SafetyService) {
        self.service = service
        Task { await load() }
    }

    func load() async {
        selectedStoryAudience = (try? await service.fetchStoryAudienceScope()) ?? .friends
        blockedHandles = (try? await service.fetchBlockedHandles()) ?? []
    }

    func blockUser() async {
        guard !blockHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? await service.block(handle: blockHandle)
        infoMessage = "Blocked \(blockHandle)."
        blockHandle = ""
        blockedHandles = (try? await service.fetchBlockedHandles()) ?? blockedHandles
    }

    func reportUser() async {
        guard !reportHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? await service.report(handle: reportHandle, reason: reportReason)
        infoMessage = "Reported \(reportHandle)."
        reportHandle = ""
        reportReason = ""
    }

    func applyPreset() async {
        try? await service.applyPrivacyPreset(selectedPreset)
        infoMessage = "Applied \(selectedPreset.rawValue) preset."
    }

    func applyStoryAudience() async {
        try? await service.setStoryAudienceScope(selectedStoryAudience)
        infoMessage = "Story audience set to \(selectedStoryAudience.rawValue). Blocked users are excluded."
    }

    func sessionKillSwitch() async {
        try? await service.runSessionKillSwitch()
        infoMessage = "Session kill-switch executed."
        blockedHandles = []
        selectedStoryAudience = (try? await service.fetchStoryAudienceScope()) ?? .friends
    }
}
