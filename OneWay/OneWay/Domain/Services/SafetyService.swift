import Foundation

protocol SafetyService {
    func block(handle: String) async throws
    func report(handle: String, reason: String) async throws
    func applyPrivacyPreset(_ preset: PrivacyPreset) async throws
    func runSessionKillSwitch() async throws
    func fetchBlockedHandles() async throws -> [String]
    func setStoryAudienceScope(_ scope: StoryAudienceScope) async throws
    func fetchStoryAudienceScope() async throws -> StoryAudienceScope
}
