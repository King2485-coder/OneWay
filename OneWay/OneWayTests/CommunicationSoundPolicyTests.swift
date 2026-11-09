import XCTest
import AVFoundation
import CryptoKit
@testable import CipherChat

final class CommunicationSoundPolicyTests: XCTestCase {
    private let manualSoundCategories: [AppSoundCategory] = [
        .chirp,
        .notification,
        .manualRingtone,
        .legacyWalkie,
        .audioServices,
        .other
    ]

    func testChirpSoundsAreBlockedDuringAudioCalls() {
        for event in ChirpSoundEvent.allCases {
            XCTAssertFalse(
                CommunicationSoundPolicy.allowsChirpSound(currentMode: .audioCall, event: event),
                "\(event.rawValue) must not play during audio calls."
            )
        }
    }

    func testChirpSoundsAreBlockedDuringVideoCalls() {
        for event in ChirpSoundEvent.allCases {
            XCTAssertFalse(
                CommunicationSoundPolicy.allowsChirpSound(currentMode: .videoCall, event: event),
                "\(event.rawValue) must not play during video calls."
            )
        }
    }

    func testChirpSoundsStillPlayDuringGenuineChirpMode() {
        XCTAssertTrue(
            CommunicationSoundPolicy.allowsChirpSound(currentMode: .chirp, event: .pushToTalkPress)
        )
        XCTAssertTrue(
            CommunicationSoundPolicy.allowsChirpSound(currentMode: .chirp, event: .pushToTalkRelease)
        )
    }

    func testCallSoundsAreNotChirpSoundEvents() {
        XCTAssertNil(ChirpSoundEvent(sound: .incomingCallRingtone))
        XCTAssertNil(ChirpSoundEvent(sound: .outgoingRingback))
        XCTAssertNil(ChirpSoundEvent(sound: .callConnected))
        XCTAssertNil(ChirpSoundEvent(sound: .callEnded))
    }

    func testIncomingCallsUseOfficialOneWayPulseRingtone() {
        XCTAssertEqual(CallSoundController.ringtoneFileName, "OneWayPulse.caf")
    }

    @MainActor
    func testAudioCallBlocksEveryManualSoundCategory() {
        for category in manualSoundCategories {
            XCTAssertFalse(
                ManualSoundAuthorization.isAllowed(category: category, communicationMode: .audioCall),
                "\(category.rawValue) must not manually play during audio calls."
            )
        }
    }

    @MainActor
    func testVideoCallBlocksEveryManualSoundCategory() {
        for category in manualSoundCategories {
            XCTAssertFalse(
                ManualSoundAuthorization.isAllowed(category: category, communicationMode: .videoCall),
                "\(category.rawValue) must not manually play during video calls."
            )
        }
    }

    @MainActor
    func testChirpModePermitsOnlyChirpSounds() {
        XCTAssertTrue(ManualSoundAuthorization.isAllowed(category: .chirp, communicationMode: .chirp))
        XCTAssertTrue(ManualSoundAuthorization.isAllowed(category: .legacyWalkie, communicationMode: .chirp))
        XCTAssertFalse(ManualSoundAuthorization.isAllowed(category: .manualRingtone, communicationMode: .chirp))
        XCTAssertFalse(ManualSoundAuthorization.isAllowed(category: .notification, communicationMode: .chirp))
    }

    func testVoiceAndVideoCallPushesMustUseCallKitWithoutNotificationSound() {
        let voice = CallPushSoundPolicy.policy(eventType: "incoming_oneway_call", hasVideo: false)
        XCTAssertNil(voice.sound)
        XCTAssertTrue(voice.usesCallKit)

        let video = CallPushSoundPolicy.policy(eventType: "incoming_oneway_call", hasVideo: true)
        XCTAssertNil(video.sound)
        XCTAssertTrue(video.usesCallKit)
    }

    func testOneWayPulseRingtoneAssetIsBundledAndApproved() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "OneWayPulse", withExtension: "caf"))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 80_000)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "a4828a178981e9d58f927393167cf02f81c2f6236c2d78d6f989aa341f4fdea8")

        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        XCTAssertGreaterThan(duration, 3.0)
        XCTAssertLessThan(duration, 4.2)
    }

    @MainActor
    func testHardSuppressionBlocksChirpEvenWhenModeIsIdle() async {
        let callID = UUID()
        CallSoundSuppressionController.shared.acquire(callID: callID, reason: "unit_test_idle_gap")

        XCTAssertTrue(CallSoundSuppressionController.shared.isSuppressionActive)
        XCTAssertFalse(CallSoundSuppressionController.shared.mayPlayChirpSound())
        XCTAssertFalse(CallSoundSuppressionController.shared.mayPlayManualAppSound(.chirp))
        XCTAssertFalse(ManualSoundAuthorization.isAllowed(category: .chirp, communicationMode: .idle))

        await CallSoundSuppressionController.shared.releaseAfterTeardown(callID: callID, reason: "unit_test_cleanup")
        XCTAssertFalse(CallSoundSuppressionController.shared.isSuppressionActive)
    }

    @MainActor
    func testDuplicateCallIDsAndConcurrentCallsKeepSuppressionActiveUntilAllRelease() async {
        let first = UUID()
        let second = UUID()

        CallSoundSuppressionController.shared.acquire(callID: first, reason: "unit_test_first")
        CallSoundSuppressionController.shared.acquire(callID: first, reason: "unit_test_duplicate")
        CallSoundSuppressionController.shared.acquire(callID: second, reason: "unit_test_second")

        XCTAssertTrue(CallSoundSuppressionController.shared.isSuppressionActive)
        XCTAssertEqual(CallSoundSuppressionController.shared.activeCallIDs.count, 2)

        await CallSoundSuppressionController.shared.releaseAfterTeardown(callID: first, reason: "unit_test_release_first")
        XCTAssertTrue(CallSoundSuppressionController.shared.isSuppressionActive)
        XCTAssertEqual(CallSoundSuppressionController.shared.activeCallIDs.count, 1)

        await CallSoundSuppressionController.shared.releaseAfterTeardown(callID: second, reason: "unit_test_release_second")
        XCTAssertFalse(CallSoundSuppressionController.shared.isSuppressionActive)
    }
}
