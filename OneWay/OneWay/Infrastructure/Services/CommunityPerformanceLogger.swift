import Foundation
import OSLog

enum OneWayPerformanceTarget {
    case coldLaunchUsableUI
    case chatOpenFromCache
    case messageLocalBubble
    case messageDeliveredOnline
    case communityJoinVisibleUpdate
    case walkieTransmitStart
    case callSetup
    case reconnectAfterDrop

    var milliseconds: Int {
        switch self {
        case .coldLaunchUsableUI: 1_500
        case .chatOpenFromCache: 100
        case .messageLocalBubble: 50
        case .messageDeliveredOnline: 300
        case .communityJoinVisibleUpdate: 500
        case .walkieTransmitStart: 250
        case .callSetup: 1_500
        case .reconnectAfterDrop: 2_000
        }
    }
}

struct OneWayPerformanceEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let startedAt: Date
    let endedAt: Date
    let elapsedMs: Int
    let targetMs: Int?
    let passed: Bool
    let metadata: String
    let cause: String
}

enum OneWayPerformanceLogger {
    private static let logger = Logger(subsystem: "app.oneway.ios", category: "performance")
    private static let lock = NSLock()
    private static var events: [OneWayPerformanceEvent] = []
    private static let maxEvents = 300

    @discardableResult
    static func mark(_ name: String, metadata: String = "") -> Date {
        let now = Date()
        let suffix = metadata.isEmpty ? "" : " \(metadata)"
        logger.info("\(name, privacy: .public) started\(suffix, privacy: .public)")
        print("[OneWayPerformance] \(name) started\(suffix)")
        return now
    }

    @discardableResult
    static func finish(
        _ name: String,
        startedAt: Date,
        target: OneWayPerformanceTarget? = nil,
        metadata: String = "",
        cause: String = ""
    ) -> OneWayPerformanceEvent {
        let endedAt = Date()
        let elapsed = Int(endedAt.timeIntervalSince(startedAt) * 1_000)
        let targetMs = target?.milliseconds
        let passed = targetMs.map { elapsed <= $0 } ?? true
        let event = OneWayPerformanceEvent(
            id: UUID(),
            name: name,
            startedAt: startedAt,
            endedAt: endedAt,
            elapsedMs: elapsed,
            targetMs: targetMs,
            passed: passed,
            metadata: metadata,
            cause: cause
        )

        lock.withLock {
            events.append(event)
            if events.count > maxEvents {
                events.removeFirst(events.count - maxEvents)
            }
        }

        let targetText = targetMs.map { " targetMs=\($0)" } ?? ""
        let metadataText = metadata.isEmpty ? "" : " \(metadata)"
        let causeText = cause.isEmpty ? "" : " cause=\(cause)"
        let status = passed ? "PASS" : "OVER_TARGET"
        logger.info("\(status, privacy: .public) \(name, privacy: .public) \(elapsed)ms\(targetText, privacy: .public)\(metadataText, privacy: .public)\(causeText, privacy: .public)")
        print("[OneWayPerformance] \(status) \(name) elapsedMs=\(elapsed)\(targetText)\(metadataText)\(causeText)")
        return event
    }

    static func profile(
        _ stage: String,
        clientMessageId: UUID? = nil,
        communityId: UUID? = nil,
        startedAt: Date? = nil,
        target: OneWayPerformanceTarget? = nil,
        metadata: String = ""
    ) {
        let now = Date()
        let elapsed = startedAt.map { Int(now.timeIntervalSince($0) * 1_000) }
        let line = [
            "ONEWAY_PROFILE",
            "stage=\(stage)",
            "clientMessageId=\(clientMessageId?.uuidString.lowercased() ?? "nil")",
            "communityId=\(communityId?.uuidString.lowercased() ?? "nil")",
            "tsMs=\(Int(now.timeIntervalSince1970 * 1_000))",
            elapsed.map { "elapsedMs=\($0)" },
            target.map { "targetMs=\($0.milliseconds)" },
            metadata.isEmpty ? nil : metadata,
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        logger.info("\(line, privacy: .public)")
        print(line)

        if let startedAt {
            _ = finish(stage, startedAt: startedAt, target: target, metadata: metadata)
        }
    }

    static func recentEvents(limit: Int = 50) -> [OneWayPerformanceEvent] {
        lock.withLock { Array(events.suffix(limit)) }
    }

    static func exportReport() -> String {
        let snapshot = recentEvents(limit: maxEvents)
        guard !snapshot.isEmpty else {
            return "OneWay Performance Report\nNo events recorded yet."
        }
        let lines = snapshot.map { event -> String in
            let target = event.targetMs.map { " target=\($0)ms" } ?? ""
            let cause = event.cause.isEmpty ? "" : " cause=\(event.cause)"
            let metadata = event.metadata.isEmpty ? "" : " \(event.metadata)"
            return "\(event.passed ? "PASS" : "OVER") \(event.name) elapsed=\(event.elapsedMs)ms\(target)\(metadata)\(cause)"
        }
        return (["OneWay Performance Report", "Generated: \(Date())"] + lines).joined(separator: "\n")
    }

    static func clear() {
        lock.withLock { events.removeAll() }
    }
}

enum CommunityPerformanceLogger {
    @discardableResult
    static func mark(_ name: String) -> Date {
        OneWayPerformanceLogger.mark("community.\(name)")
    }

    static func finish(_ name: String, startedAt: Date, metadata: String = "") {
        _ = OneWayPerformanceLogger.finish("community.\(name)", startedAt: startedAt, metadata: metadata)
    }

    static func profile(
        _ stage: String,
        clientMessageId: UUID?,
        communityId: UUID? = nil,
        startedAt: Date? = nil,
        metadata: String = ""
    ) {
        OneWayPerformanceLogger.profile(
            "community.\(stage)",
            clientMessageId: clientMessageId,
            communityId: communityId,
            startedAt: startedAt,
            metadata: metadata
        )
    }
}
