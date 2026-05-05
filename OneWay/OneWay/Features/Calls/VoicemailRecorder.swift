import Foundation
import Combine

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Records audio for voicemail. Wraps `AVAudioRecorder` and surfaces a
/// minimal state machine that's safe to bind to a SwiftUI view.
///
/// Output: a single `m4a` (AAC) file in the app's caches directory. The
/// caller hands this URL to `VoicemailManager.upload(...)` once recording
/// stops; on success the temp file is deleted.
@MainActor
final class VoicemailRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case finished(url: URL, duration: TimeInterval)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Hard cap. Server validates against this too — keep them in sync.
    let maxDuration: TimeInterval

    #if canImport(AVFoundation)
    private var recorder: AVAudioRecorder?
    private var stopTask: Task<Void, Never>?
    #endif

    init(maxDuration: TimeInterval = 60) {
        self.maxDuration = maxDuration
    }

    /// Begin recording. Throws if mic permission is denied or the audio
    /// session can't be configured. Caller should request mic permission
    /// before invoking this (e.g. via `AVAudioApplication.requestRecordPermission`
    /// in the UI on the first tap).
    func start() throws {
        #if canImport(AVFoundation)
        if case .idle = state {
            // ok
        } else {
            // Defensive — calling start while already recording would leak
            // the previous recorder. Tear down and re-arm.
            cancel()
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: [])

        let url = Self.makeOutputURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32_000,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {
            throw RecorderError.prepareFailed
        }
        guard recorder.record(forDuration: maxDuration) else {
            throw RecorderError.recordFailed
        }
        self.recorder = recorder
        self.state = .recording(startedAt: Date())

        // Belt-and-suspenders: if AVAudioRecorder's own duration cap fails
        // to fire, force-stop after `maxDuration + 0.5`.
        stopTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64((self.maxDuration + 0.5) * 1_000_000_000))
            self.stop()
        }
        #else
        throw RecorderError.unavailable
        #endif
    }

    /// Stop recording and transition to `.finished` (or `.failed`).
    @discardableResult
    func stop() -> URL? {
        #if canImport(AVFoundation)
        stopTask?.cancel()
        stopTask = nil

        guard let recorder else { return nil }
        let url = recorder.url
        let started: Date? = {
            if case .recording(let at) = state { return at }
            return nil
        }()

        recorder.stop()
        self.recorder = nil

        // Deactivate the session so the rest of the app's audio (haptics,
        // ringtones, music player) isn't held in record mode.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        if FileManager.default.fileExists(atPath: url.path) {
            let duration = started.map { Date().timeIntervalSince($0) } ?? 0
            state = .finished(url: url, duration: max(0, duration))
            return url
        } else {
            state = .failed("Recording produced no file")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Throw away the recording and reset.
    func cancel() {
        #if canImport(AVFoundation)
        stopTask?.cancel()
        stopTask = nil
        if let recorder {
            recorder.stop()
            try? FileManager.default.removeItem(at: recorder.url)
        }
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        state = .idle
    }

    /// Average mic level in [0, 1]. Useful for a recording-level meter.
    func currentLevel() -> Float {
        #if canImport(AVFoundation)
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let dB = recorder.averagePower(forChannel: 0)
        // Map [-60, 0] dB to [0, 1] roughly linearly.
        let clamped = max(-60, min(dB, 0))
        return (clamped + 60) / 60
        #else
        return 0
        #endif
    }

    enum RecorderError: Error, LocalizedError {
        case prepareFailed
        case recordFailed
        case unavailable

        var errorDescription: String? {
            switch self {
            case .prepareFailed: return "AVAudioRecorder failed to prepare."
            case .recordFailed:  return "AVAudioRecorder refused to start."
            case .unavailable:   return "Audio recording is not available on this build."
            }
        }
    }

    private static func makeOutputURL() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = "voicemail-\(UUID().uuidString).m4a"
        return dir.appendingPathComponent(name)
    }
}
