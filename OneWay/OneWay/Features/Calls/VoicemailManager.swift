import Foundation
import Combine

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Public wire shape from `/api/voicemail/:userId`. `audioUrl` is server-
/// relative — combine with the API base before fetching.
struct VoicemailEntry: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let callId: String
    let callerId: String
    let calleeId: String
    let audioUrl: String
    let durationSeconds: Int
    let createdAt: Int64
    let listened: Bool
    let mimeType: String
    let bytes: Int

    var createdAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000.0)
    }
}

/// Fetches voicemail metadata, streams audio for playback, marks listened.
/// Pairs with `VoicemailRecorder` for the upload side.
@MainActor
final class VoicemailManager: ObservableObject {
    @Published private(set) var voicemails: [VoicemailEntry] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private let baseURL: URL
    private let userID: String
    private let session: URLSession

    #if canImport(AVFoundation)
    private var player: AVAudioPlayer?
    #endif

    init(baseURL: URL, userID: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.userID = userID
        self.session = session
    }

    /// Refresh the inbox.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("voicemail")
                .appendingPathComponent(userID)
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(Envelope.self, from: data)
            self.voicemails = decoded.voicemails
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Upload a freshly-recorded audio file. Returns the server entry on
    /// success. Use the values from the original missed-call record.
    func upload(callId: String,
                callerId: String,
                calleeId: String,
                durationSeconds: Int,
                fileURL: URL,
                mimeType: String = "audio/m4a") async throws -> VoicemailEntry {
        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("voicemail")
            .appendingPathComponent("upload")
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        let boundary = "OneWay-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")

        let body = try Self.buildMultipartBody(
            boundary: boundary,
            fields: [
                "callId": callId,
                "callerId": callerId,
                "calleeId": calleeId,
                "durationSeconds": String(durationSeconds),
            ],
            file: (fieldName: "audio",
                   fileName: "voicemail.m4a",
                   mimeType: mimeType,
                   fileURL: fileURL)
        )
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(UploadEnvelope.self, from: data)
        return decoded.voicemail
    }

    /// Mark a voicemail listened on the server. Updates the local cache too.
    func markListened(_ id: String) async {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("voicemail")
            .appendingPathComponent(id)
            .appendingPathComponent("listened")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
        if let i = voicemails.firstIndex(where: { $0.id == id }) {
            var updated = voicemails[i]
            updated = VoicemailEntry(
                id: updated.id, callId: updated.callId,
                callerId: updated.callerId, calleeId: updated.calleeId,
                audioUrl: updated.audioUrl, durationSeconds: updated.durationSeconds,
                createdAt: updated.createdAt, listened: true,
                mimeType: updated.mimeType, bytes: updated.bytes
            )
            voicemails[i] = updated
        }
    }

    /// Stream + play. Auto-stops any previous playback. The server requires
    /// auth on the audio endpoint, so we download into a temporary file
    /// first (`AVAudioPlayer` needs a `URL` it can read directly).
    func play(_ entry: VoicemailEntry) async throws {
        #if canImport(AVFoundation)
        let resolved = baseURL.appendingPathComponent(entry.audioUrl.trimmingCharacters(in: ["/"]))
        var request = URLRequest(url: resolved, timeoutInterval: 30)
        request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneway-vm-\(entry.id).m4a")
        try data.write(to: tmp, options: .atomic)
        let player = try AVAudioPlayer(contentsOf: tmp)
        player.prepareToPlay()
        player.play()
        self.player = player

        // Best-effort listened flag. If the user only sampled the start we
        // still mark it; product can revisit (e.g. require >= 50% playback).
        Task { await self.markListened(entry.id) }
        #else
        _ = entry
        #endif
    }

    /// Stop any active playback.
    func stop() {
        #if canImport(AVFoundation)
        player?.stop()
        player = nil
        #endif
    }

    // MARK: - Helpers

    private static func buildMultipartBody(boundary: String,
                                           fields: [String: String],
                                           file: (fieldName: String, fileName: String, mimeType: String, fileURL: URL)) throws -> Data {
        var data = Data()
        let lineBreak = "\r\n"
        for (key, value) in fields {
            data.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(key)\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            data.append("\(value)\(lineBreak)".data(using: .utf8)!)
        }
        let fileBytes = try Data(contentsOf: file.fileURL)
        data.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.fileName)\"\(lineBreak)".data(using: .utf8)!)
        data.append("Content-Type: \(file.mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        data.append(fileBytes)
        data.append(lineBreak.data(using: .utf8)!)
        data.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return data
    }

    private struct Envelope: Decodable {
        let voicemails: [VoicemailEntry]
    }
    private struct UploadEnvelope: Decodable {
        let voicemail: VoicemailEntry
    }
}
