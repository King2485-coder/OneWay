import Foundation
#if canImport(Security)
import Security
#endif

/// Tiny wrapper around Keychain. Stores a single JWT alongside the user
/// identifier it was minted for. Reads/writes are synchronous because
/// Keychain access is fast and any race between iOS app launch and the
/// first network call is dwarfed by the network itself.
///
/// Authentication credentials are Keychain-only. A legacy UserDefaults token
/// is consumed once for migration and deleted whether migration succeeds or
/// fails, so Keychain errors cannot silently downgrade credential storage.
final class AuthTokenStore {
    static let shared = AuthTokenStore()

    static let tokenDidChangeNotification = Notification.Name("OneWay.AuthTokenStore.tokenDidChange")

    #if DEBUG
    private static let devUserOverrideKey = "OneWay.DevUserID"
    #endif

    private let service = "com.oneway.auth"
    private let legacyService = "OneWay.Auth"
    private let userKey = "OneWay.AuthUserID"
    private let tokenKey = "OneWay.AuthToken"
    private let keychainUserKey = "OneWay.AuthUserID.Keychain"
    private let sessionVersionKey = "OneWay.AuthSessionVersion"
    private let lastLoginAtKey = "OneWay.AuthLastLoginAt"

    private init() {}

    // MARK: - Public API

    func currentUserID() -> String {
        #if DEBUG
        if let devUserID = Self.devUserIDOverride() {
            return devUserID
        }
        #endif

        if let stored = storedUserID() {
            UserDefaults.standard.set(stored, forKey: userKey)
            return stored
        }
        if let stored = UserDefaults.standard.string(forKey: userKey) {
            return stored
        }
        // Stable per-install identifier for the dev path. Replaced by the
        // server-issued userId after `/api/auth/login`.
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: userKey)
        _ = writeKeychainUserID(fresh)
        return fresh
    }

    func storedUserID() -> String? {
        readKeychainUserID() ?? UserDefaults.standard.string(forKey: userKey)
    }

    func setUserID(_ id: String) {
        let previous = storedUserID()
        UserDefaults.standard.set(id, forKey: userKey)
        _ = writeKeychainUserID(id)
        if previous != id {
            NotificationCenter.default.post(name: Self.tokenDidChangeNotification, object: nil)
        }
    }

    func token() -> String? {
        if let secureToken = readKeychain() { return secureToken }
        return Self.migrateLegacyCredential(
            loadLegacy: { UserDefaults.standard.string(forKey: self.tokenKey) },
            storeSecurely: { self.writeKeychain($0) },
            eraseLegacy: { UserDefaults.standard.removeObject(forKey: self.tokenKey) }
        )
    }

    func setToken(_ token: String?) {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        if let token {
            _ = writeKeychain(token)
        } else {
            deleteKeychain()
        }
        NotificationCenter.default.post(name: Self.tokenDidChangeNotification, object: nil)
    }

    func setSession(userID: String, token: String) {
        deleteLegacyKeychainItems()
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.set(userID, forKey: userKey)
        UserDefaults.standard.set(UUID().uuidString, forKey: sessionVersionKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastLoginAtKey)
        _ = writeKeychainUserID(userID)
        _ = writeKeychain(token)
        NotificationCenter.default.post(name: Self.tokenDidChangeNotification, object: nil)
    }

    func clearSession() {
        deleteKeychain()
        deleteKeychainUserID()
        deleteLegacyKeychainItems()
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        UserDefaults.standard.removeObject(forKey: sessionVersionKey)
        UserDefaults.standard.removeObject(forKey: lastLoginAtKey)
        NotificationCenter.default.post(name: Self.tokenDidChangeNotification, object: nil)
    }

    /// `Authorization` header value — JWT in prod, dev-token in the early
    /// path before the user has signed in. Callers should send whatever
    /// this returns and let the backend decide.
    func authorizationHeader() -> String {
        if let token = token() { return "Bearer \(token)" }
        return "Bearer dev:\(currentUserID())"
    }

    /// Returns only a server-issued credential. Development bearer tokens are
    /// selected by `DevAuth` for an explicitly local backend; they must never
    /// leak into production requests.
    func authenticatedAuthorizationHeader() -> String? {
        guard let token = token()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return "Bearer \(token)"
    }

    func tokenSubject() -> String? {
        guard let token = token() else { return nil }
        return Self.subject(fromJWT: token)
    }

    var diagnosticsKeychainService: String {
        service
    }

    var diagnosticsKeychainSynchronizable: Bool {
        false
    }

    var diagnosticsCacheNamespace: String {
        guard let userID = storedUserID(), !userID.isEmpty else { return "none" }
        return "user.\(userID)"
    }

    var sessionVersion: String {
        UserDefaults.standard.string(forKey: sessionVersionKey) ?? "none"
    }

    var lastLoginAt: Date? {
        let timestamp = UserDefaults.standard.double(forKey: lastLoginAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    #if DEBUG
    func clearDebugAccountOverrides() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.devUserOverrideKey)
        defaults.removeObject(forKey: "OneWay.DebugLoginIdentifier")
        defaults.removeObject(forKey: "OneWay.DebugLoginUserID")
        defaults.removeObject(forKey: "OneWay.DebugLoginIdentifierOverride")
        defaults.removeObject(forKey: "OneWay.DebugLoginPassword")
        defaults.removeObject(forKey: "OneWay.DebugLoginForce")
        defaults.set(false, forKey: "OneWay.DebugLoginEnabled")
    }

    func resetOneWayCompletelyForTesting() {
        deleteKeychain()
        deleteKeychainUserID()
        deleteLegacyKeychainItems()
        let defaults = UserDefaults.standard
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
        }
        [
            "OneWay.AuthToken",
            "OneWay.AuthUserID",
            "OneWay.AuthSessionVersion",
            "OneWay.AuthLastLoginAt",
            "OneWay.DevUserID",
            "OneWay.DebugLoginIdentifier",
            "OneWay.DebugLoginUserID",
            "OneWay.DebugLoginIdentifierOverride",
            "OneWay.DebugLoginPassword",
            "OneWay.DebugLoginForce",
            "OneWay.DebugTestAccountPassword",
            "OneWay.LastLoginIdentifier",
            "oneway.profileCompleteHint",
            "OneWay.SessionExplicitlySignedOut"
        ].forEach { defaults.removeObject(forKey: $0) }
        defaults.set(true, forKey: "OneWay.SessionExplicitlySignedOut")
        defaults.synchronize()
        NotificationCenter.default.post(name: Self.tokenDidChangeNotification, object: nil)
    }
    #endif

    static func subject(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = json["sub"] as? String,
              !subject.isEmpty
        else {
            return nil
        }
        return subject
    }

    /// Pure migration seam used by unit tests. The credential is returned only
    /// after a successful secure write and is always erased from legacy storage.
    static func migrateLegacyCredential(
        loadLegacy: () -> String?,
        storeSecurely: (String) -> Bool,
        eraseLegacy: () -> Void
    ) -> String? {
        guard let legacy = loadLegacy(), !legacy.isEmpty else { return nil }
        let stored = storeSecurely(legacy)
        eraseLegacy()
        return stored ? legacy : nil
    }

    #if DEBUG
    private static func devUserIDOverride() -> String? {
        let environmentValue = ProcessInfo.processInfo.environment["ONEWAY_DEV_USER_ID"]
        let defaultsValue = UserDefaults.standard.string(forKey: devUserOverrideKey)
        let value = environmentValue ?? defaultsValue
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
    #endif

    // MARK: - Keychain

    #if canImport(Security)
    private func writeKeychainUserID(_ id: String) -> Bool {
        let data = Data(id.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainUserKey,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func readKeychainUserID() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainUserKey,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychainUserID() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainUserKey,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func writeKeychain(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func deleteLegacyKeychainItems() {
        for account in [tokenKey, keychainUserKey] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
    #else
    private func writeKeychainUserID(_ id: String) -> Bool { false }
    private func readKeychainUserID() -> String? { nil }
    private func deleteKeychainUserID() {}
    private func writeKeychain(_ token: String) -> Bool { false }
    private func readKeychain() -> String? { nil }
    private func deleteKeychain() {}
    private func deleteLegacyKeychainItems() {}
    #endif
}
