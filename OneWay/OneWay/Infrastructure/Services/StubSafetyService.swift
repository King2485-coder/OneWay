import Foundation

actor StubSafetyService: SafetyService {
    private var blockedHandles: Set<String> = []
    private var privacyPreset: PrivacyPreset = .contactsOnly
    private var storyAudienceScope: StoryAudienceScope = .friends

    func block(handle: String) async throws {
        blockedHandles.insert(handle.lowercased())
    }

    func report(handle: String, reason: String) async throws {
        _ = (handle, reason)
    }

    func applyPrivacyPreset(_ preset: PrivacyPreset) async throws {
        privacyPreset = preset
    }

    func runSessionKillSwitch() async throws {
        blockedHandles.removeAll()
        privacyPreset = .lockedDown
        storyAudienceScope = .friends
    }

    func fetchBlockedHandles() async throws -> [String] {
        blockedHandles.sorted()
    }

    func setStoryAudienceScope(_ scope: StoryAudienceScope) async throws {
        storyAudienceScope = scope
    }

    func fetchStoryAudienceScope() async throws -> StoryAudienceScope {
        storyAudienceScope
    }
}
