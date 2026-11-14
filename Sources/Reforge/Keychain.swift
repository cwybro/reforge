import Foundation
import Security

/// Where Model keeps the API key; tests substitute an in-memory store.
protocol KeyStore {
    func read() -> String
    func write(_ key: String) -> Bool
}

/// The login Keychain, or the `.dev` key file in dev mode.
struct SystemKeyStore: KeyStore {
    func read() -> String { Keychain.read() }
    func write(_ key: String) -> Bool { Keychain.write(key) }
}

/// Stores the CurseForge API key in the user's login Keychain.
enum Keychain {
    private static let service = "local.reforge"
    /// Service name used before the rename from "Addon Updater".
    private static let legacyService = "local.addonupdater"
    private static let account = "curseforge-api-key"

    private static var baseQuery: [String: Any] { query(service: service) }

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String {
        if let file = DevMode.keyFile {
            return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let key = read(service: service)
        if !key.isEmpty { return key }
        // One-time move from the pre-rename Keychain item.
        let legacy = read(service: legacyService)
        if !legacy.isEmpty, write(legacy) {
            SecItemDelete(query(service: legacyService) as CFDictionary)
        }
        return legacy
    }

    private static func read(service: String) -> String {
        var query = query(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Saves the key, or deletes the item when `key` is empty. Returns false on failure.
    @discardableResult
    static func write(_ key: String) -> Bool {
        if let file = DevMode.keyFile { return DevMode.writeKey(key, to: file) }
        if key.isEmpty {
            let s = SecItemDelete(baseQuery as CFDictionary)
            return s == errSecSuccess || s == errSecItemNotFound
        }
        let data = Data(key.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Reforge – CurseForge API key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
