import Foundation

protocol SentinelAnalyzing: Sendable {
    func analyzeMessage(_ text: String) async -> SentinelAssessment
    func analyzeURL(_ url: URL) async -> SentinelAssessment
    func analyzeFile(name: String, mimeType: String?, bytes: Data) async -> SentinelAssessment
}

actor OnDeviceSentinelService: SentinelAnalyzing {
    private let suspiciousHosts: Set<String> = [
        "bit.ly", "tinyurl.com", "t.co", "is.gd", "cutt.ly"
    ]

    private let executableExtensions: Set<String> = [
        "app", "apk", "bat", "cmd", "com", "dmg", "exe", "jar", "js", "msi", "pkg", "ps1", "scr", "sh", "vbs"
    ]

    func analyzeMessage(_ text: String) async -> SentinelAssessment {
        let normalized = text.lowercased()
        var signals: [SentinelSignal] = []

        appendIfMatched(
            normalized,
            phrases: ["send money", "wire transfer", "gift card", "crypto payment", "cash app me", "zelle me"],
            signal: .init(kind: .fakePaymentRequest, weight: 34, summary: "The message contains an unusual payment request."),
            to: &signals
        )
        appendIfMatched(
            normalized,
            phrases: ["verify your account", "reset your password", "recovery code", "security code", "one-time code"],
            signal: .init(kind: .accountRecoveryScam, weight: 30, summary: "The message requests sensitive account or recovery information."),
            to: &signals
        )
        appendIfMatched(
            normalized,
            phrases: ["act now", "immediately", "urgent", "final warning", "today only", "do not tell anyone"],
            signal: .init(kind: .urgencyPressure, weight: 20, summary: "The sender is pressuring the recipient to act quickly."),
            to: &signals
        )
        appendIfMatched(
            normalized,
            phrases: ["guaranteed return", "double your money", "investment opportunity", "risk-free profit"],
            signal: .init(kind: .investmentScam, weight: 38, summary: "The message contains a high-risk investment claim."),
            to: &signals
        )
        appendIfMatched(
            normalized,
            phrases: ["i am your boss", "this is support", "new phone", "new number", "keep this private"],
            signal: .init(kind: .impersonation, weight: 32, summary: "The sender may be impersonating a trusted person or organization."),
            to: &signals
        )

        for url in extractURLs(from: text) {
            let urlAssessment = await analyzeURL(url)
            signals.append(contentsOf: urlAssessment.signals)
        }

        return assessment(for: signals)
    }

    func analyzeURL(_ url: URL) async -> SentinelAssessment {
        var signals: [SentinelSignal] = []
        let host = url.host?.lowercased() ?? ""

        if url.scheme?.lowercased() != "https" {
            signals.append(.init(kind: .maliciousLink, weight: 32, summary: "The link does not use an encrypted HTTPS connection."))
        }
        if suspiciousHosts.contains(host) {
            signals.append(.init(kind: .maliciousLink, weight: 24, summary: "The link hides its final destination behind a shortening service."))
        }
        if host.contains("xn--") || host.filter({ $0 == "." }).count > 4 {
            signals.append(.init(kind: .impersonation, weight: 36, summary: "The domain resembles a deceptive or disguised address."))
        }
        if url.absoluteString.count > 240 {
            signals.append(.init(kind: .maliciousLink, weight: 18, summary: "The link is unusually long and should be treated carefully."))
        }

        return assessment(for: signals)
    }

    func analyzeFile(name: String, mimeType: String?, bytes: Data) async -> SentinelAssessment {
        var signals: [SentinelSignal] = []
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let normalizedMIME = mimeType?.lowercased() ?? ""

        if executableExtensions.contains(ext) {
            signals.append(.init(kind: .dangerousFile, weight: 75, summary: "This file type can execute code on a device."))
        }
        if normalizedMIME.hasPrefix("image/") && executableExtensions.contains(ext) {
            signals.append(.init(kind: .dangerousFile, weight: 85, summary: "The file extension does not match the claimed image type."))
        }
        if bytes.starts(with: [0x4D, 0x5A]) && ext != "exe" {
            signals.append(.init(kind: .dangerousFile, weight: 90, summary: "The file appears to contain a Windows executable under a different name."))
        }
        if bytes.count > 100_000_000 {
            signals.append(.init(kind: .dangerousFile, weight: 20, summary: "This unusually large file should open in isolated preview mode."))
        }

        return assessment(for: signals)
    }

    private func assessment(for signals: [SentinelSignal]) -> SentinelAssessment {
        let score = min(100, signals.reduce(0) { $0 + $1.weight })
        let action: SentinelAction
        switch score {
        case 0..<20: action = .allow
        case 20..<40: action = .warn
        case 40..<65: action = .requireTrustedDeviceApproval
        case 65..<85: action = .quarantine
        default: action = .humanReview
        }
        return SentinelAssessment(riskScore: score, signals: signals, recommendedAction: action)
    }

    private func appendIfMatched(
        _ text: String,
        phrases: [String],
        signal: SentinelSignal,
        to signals: inout [SentinelSignal]
    ) {
        guard phrases.contains(where: text.contains) else { return }
        signals.append(signal)
    }

    private func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }
}
