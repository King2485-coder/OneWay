#!/usr/bin/env swift

import AVFoundation
import CoreGraphics
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    fputs("Usage: render_oneway_chirp_mp4.swift <output.mp4>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: args[1]).standardizedFileURL
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("oneway-chirp-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporaryDirectory) }

let wavURL = temporaryDirectory.appendingPathComponent("oneway-classic-chirp.wav")
let videoURL = temporaryDirectory.appendingPathComponent("oneway-chirp-slate.mov")

func appendUInt16(_ value: UInt16, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

func makeChirpWAV() -> Data {
    // These match OneWayChirpPlayer's production "OneWay Classic" ready cue.
    let sampleRate = 44_100
    let chirpDuration = 0.24
    let clipDuration = 1.20
    let chirpOffset = 0.20
    let totalSamples = Int(Double(sampleRate) * clipDuration)
    let chirpSamples = Int(Double(sampleRate) * chirpDuration)
    let offsetSamples = Int(Double(sampleRate) * chirpOffset)
    let split = chirpSamples / 2
    let attack = max(1, Int(Double(chirpSamples) * 0.08))
    let releaseStart = Int(Double(chirpSamples) * 0.76)
    var pcm = Data(capacity: totalSamples * 2)

    for sampleIndex in 0..<totalSamples {
        let chirpIndex = sampleIndex - offsetSamples
        var value = 0.0
        if chirpIndex >= 0 && chirpIndex < chirpSamples {
            let t = Double(chirpIndex) / Double(sampleRate)
            let frequency = chirpIndex < split ? 1_046.0 : 1_568.0
            let envelope: Double
            if chirpIndex < attack {
                envelope = Double(chirpIndex) / Double(attack)
            } else if chirpIndex > releaseStart {
                envelope = max(0, Double(chirpSamples - chirpIndex) / Double(chirpSamples - releaseStart))
            } else {
                envelope = 1
            }
            value = sin(2 * Double.pi * frequency * t) * envelope * 0.55
        }
        var intSample = Int16(max(-1, min(1, value)) * Double(Int16.max)).littleEndian
        withUnsafeBytes(of: &intSample) { pcm.append(contentsOf: $0) }
    }

    var wav = Data()
    wav.append(contentsOf: Array("RIFF".utf8))
    appendUInt32(UInt32(36 + pcm.count), to: &wav)
    wav.append(contentsOf: Array("WAVEfmt ".utf8))
    appendUInt32(16, to: &wav)
    appendUInt16(1, to: &wav)
    appendUInt16(1, to: &wav)
    appendUInt32(UInt32(sampleRate), to: &wav)
    appendUInt32(UInt32(sampleRate * 2), to: &wav)
    appendUInt16(2, to: &wav)
    appendUInt16(16, to: &wav)
    wav.append(contentsOf: Array("data".utf8))
    appendUInt32(UInt32(pcm.count), to: &wav)
    wav.append(pcm)
    return wav
}

func drawText(_ text: String, fontSize: CGFloat, color: CGColor, centerY: CGFloat, in context: CGContext, width: CGFloat) {
    let font = CTFontCreateWithName("SFProDisplay-Semibold" as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
    context.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: centerY - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, context)
}

func makePixelBuffer(width: Int, height: Int, frame: Int, frameRate: Int) throws -> CVPixelBuffer {
    var optionalBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attributes as CFDictionary, &optionalBuffer)
    guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
        throw NSError(domain: "OneWayChirp", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not allocate a video frame."])
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer),
          let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
        throw NSError(domain: "OneWayChirp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create the frame canvas."])
    }

    let w = CGFloat(width)
    let h = CGFloat(height)
    let colors = [CGColor(red: 0.025, green: 0.012, blue: 0.07, alpha: 1), CGColor(red: 0.16, green: 0.04, blue: 0.28, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: h), options: [])

    let time = Double(frame) / Double(frameRate)
    let pulse = CGFloat(max(0, min(1, 1 - abs(time - 0.32) / 0.30)))
    context.setStrokeColor(CGColor(red: 0.69, green: 0.38, blue: 1, alpha: 0.28 + 0.42 * pulse))
    context.setLineWidth(8)
    for index in 0..<3 {
        let radius = CGFloat(100 + index * 68) + 22 * pulse
        context.strokeEllipse(in: CGRect(x: w / 2 - radius, y: h / 2 - radius + 70, width: radius * 2, height: radius * 2))
    }

    context.setFillColor(CGColor(red: 0.55, green: 0.22, blue: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: w / 2 - 76, y: h / 2 - 6, width: 152, height: 152))
    drawText("ONEWAY", fontSize: 94, color: CGColor(gray: 1, alpha: 1), centerY: h * 0.73, in: context, width: w)
    drawText("CHIRP", fontSize: 48, color: CGColor(red: 0.79, green: 0.62, blue: 1, alpha: 1), centerY: h * 0.25, in: context, width: w)
    return buffer
}

try makeChirpWAV().write(to: wavURL, options: .atomic)

let width = 1_920
let height = 1_080
let frameRate = 30
let frameCount = 36
let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 6_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
    ]
]
let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
videoInput.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height
])
guard writer.canAdd(videoInput) else { throw NSError(domain: "OneWayChirp", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not configure H.264 output."]) }
writer.add(videoInput)
guard writer.startWriting() else { throw writer.error ?? NSError(domain: "OneWayChirp", code: 4) }
writer.startSession(atSourceTime: .zero)

for frame in 0..<frameCount {
    while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    let buffer = try makePixelBuffer(width: width, height: height, frame: frame, frameRate: frameRate)
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))) else {
        throw writer.error ?? NSError(domain: "OneWayChirp", code: 5)
    }
}
videoInput.markAsFinished()
let writerSemaphore = DispatchSemaphore(value: 0)
writer.finishWriting { writerSemaphore.signal() }
writerSemaphore.wait()
guard writer.status == .completed else { throw writer.error ?? NSError(domain: "OneWayChirp", code: 6) }

let composition = AVMutableComposition()
let videoAsset = AVURLAsset(url: videoURL)
let audioAsset = AVURLAsset(url: wavURL)
guard let sourceVideoTrack = videoAsset.tracks(withMediaType: .video).first,
      let sourceAudioTrack = audioAsset.tracks(withMediaType: .audio).first,
      let destinationVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let destinationAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
    throw NSError(domain: "OneWayChirp", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not assemble the audio and video tracks."])
}
let duration = CMTime(seconds: 1.2, preferredTimescale: 600)
try destinationVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideoTrack, at: .zero)
try destinationAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudioTrack, at: .zero)

try? fileManager.removeItem(at: outputURL)
guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
    throw NSError(domain: "OneWayChirp", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not create the MP4 exporter."])
}
exporter.outputURL = outputURL
exporter.outputFileType = .mp4
exporter.shouldOptimizeForNetworkUse = true
let exportSemaphore = DispatchSemaphore(value: 0)
exporter.exportAsynchronously { exportSemaphore.signal() }
exportSemaphore.wait()
guard exporter.status == .completed else { throw exporter.error ?? NSError(domain: "OneWayChirp", code: 9) }

print(outputURL.path)
