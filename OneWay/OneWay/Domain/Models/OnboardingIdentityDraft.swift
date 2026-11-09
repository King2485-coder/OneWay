import Foundation

struct OnboardingIdentityDraft {
    var displayName: String = ""
    var username: String = ""
    var onewayId: String = ""
    var emailAlias: String = ""
    var usernameHidden: Bool = true
    var showEmailAlias: Bool = false
    var showOneWayId: Bool = true
    var showNumbers: Bool = true
    var preferredCallerIdentity: String = "onewayId"
}

/// Name-based suggestions stop independently as soon as that field is customized.
struct OneWaySignupSuggestions {
    private(set) var displayName = ""
    private(set) var handle = ""
    private(set) var emailName = ""
    private(set) var handleEdited = false
    private(set) var emailEdited = false

    static func identifier(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return String(folded.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }.prefix(24))
    }
    mutating func setDisplayName(_ value: String) {
        displayName = value
        let suggestion = Self.identifier(value)
        if !handleEdited { handle = suggestion }
        if !emailEdited { emailName = suggestion }
    }
    mutating func setHandle(_ value: String) { handle = Self.identifier(value); handleEdited = true }
    mutating func setEmailName(_ value: String) { emailName = Self.identifier(value.replacingOccurrences(of: "@oneway.app", with: "")); emailEdited = true }
    var onewayID: String { "@" + handle }
    var emailAddress: String { emailName + "@oneway.app" }
}
