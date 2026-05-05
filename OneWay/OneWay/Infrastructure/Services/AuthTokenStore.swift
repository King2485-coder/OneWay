import Foundation
#if canImport(Security)
import Security
#endif

/// Tiny wrapper around Keychain. Stores a single JWT alongside the user
/// identifier it was minted for. Reads/writes are synchronous because
/// Keychain access is fast and any race between iOS app launch and the
/// first network call is dwarfed by the network itself.
///
/// If the Keychain is unavailable (Simulator with broken config, or a
/// Catalyst build without entitlements), we fall back to `UserDefaults` so
/// the app still works in dev — never silently fail to sign in.
final class AuthTokenStore {
    static let shared = AuthTokenStore()

    private let service = "OneWay.Auth"
    private let userKey = "OneWay.AuthUserID"
    private let tokenKey = "OneWay.AuthToken"

    private init() {}

    // MARK: - Public API

    func currentUserID() -> String {
        if let stored = UserDefaults.standard.string(forKey: userKey) {
            return stored
        }
        // Stable per-install identifier for the dev path. Replaced by the
        // server-issued userId after `/api/auth/login`.
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: userKey)
        return fresh
    }

    func setUserID(_ id: String) {
        UserDefaults.standard.set(id, forKey: userKey)
    }

    func token() -> String? {
        readKeychain() ?? UserDefaults.standard.string(forKey: tokenKey)
    }

    func setToken(_ token: String?) {
        if let token {
            if !writeKeychain(token) {
                UserDefaults.standard.set(token, forKey: tokenKey)
            }
        } else {
            deleteKeychain()
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }
    }

    /// `Authorization` header value — JWT in prod, dev-token in the early
    /// path before the user has signed in. Callers should send whatever
    /// this returns and let the backend decide.
    func authorizationHeader() -> String {
        if let token = token() { return "Bearer \(token)" }
        return "Bearer dev:\(currentUserID())"
    }

    // MARK: - Keychain

    #if canImport(Security)
    private func writeKeychain(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
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
        ]
        SecItemDelete(query as CFDictionary)
    }
    #else
    private func writeKeychain(_ token: String) -> Bool { false }
    private func readKeychain() -> String? { nil }
    private func deleteKeychain() {}
    #endif
}
