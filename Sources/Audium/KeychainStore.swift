import Foundation
import Security
import CryptoKit
import OSLog

/// Stores AI provider API keys in a dedicated app-owned keychain (spec §3, §5 "Keychain GUI
/// dialog" fix) rather than the user's default login keychain, whose migrated internal state
/// was confirmed corrupted (silently rejects the correct unlock password). All items live in
/// `~/Library/Keychains/Audium.keychain-db`, created and unlocked non-interactively — the user
/// never sees a password prompt for this keychain, ever.
enum KeychainStore {
    private static let service = "com.postproduction.Audium.apikeys"
    private static let keychainPath = NSHomeDirectory() + "/Library/Keychains/Audium.keychain-db"
    private static let saltDefaultsKey = "AudiumKeychainSalt"

    enum Provider: String {
        case gemini, openai
    }

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)

        // Without this, Swift's default Error->NSError bridging surfaces the enum CASE INDEX
        // as the NSError code (always 0 here — `unhandled` is the only case), not the OSStatus
        // carried in the associated value — producing the misleading "...KeychainError error 0."
        // regardless of what the real OSStatus was. `SecCopyErrorMessageString` gives Apple's
        // own human-readable text for the actual code.
        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "\(message) (OSStatus \(status))"
            }
        }
    }

    // MARK: - Dedicated keychain lifecycle

    private static var cachedKeychain: SecKeychain?

    /// Opens (or creates, on first use) the Audium keychain and ensures it's unlocked. The
    /// unlock password is never stored anywhere — it's re-derived deterministically every call
    /// from a random salt (kept in UserDefaults, not sensitive on its own) and a fixed
    /// app-identity pepper via HKDF, so there's nothing "at rest" to protect and no chicken-and-
    /// egg problem of needing a keychain to store the password to the keychain.
    private static func openAudiumKeychain() throws -> SecKeychain {
        let password = derivedPassword()

        // Re-unlock on every call, even when cached: cheap and silent (confirmed via isolated
        // testing — a programmatic SecKeychainUnlock with the correct password never prompts),
        // and it means we never depend on the keychain staying unlocked across sleep/wake for
        // the life of a long-running process. SecKeychainSetSettings' lockOnSleep flag was
        // tried instead and dropped: changing keychain settings itself triggers a SecurityAgent
        // authorization request independent of item access — exactly the kind of prompt this
        // dedicated keychain exists to avoid. Re-unlocking on access sidesteps needing it.
        if let cached = cachedKeychain {
            try unlock(cached, password: password)
            return cached
        }

        var keychainRef: SecKeychain?

        if FileManager.default.fileExists(atPath: keychainPath) {
            let status = SecKeychainOpen(keychainPath, &keychainRef)
            guard status == errSecSuccess, let kc = keychainRef else {
                AudiumLog.keychain.error("Failed to open Audium keychain: status \(status)")
                throw KeychainError.unhandled(status)
            }
            try unlock(kc, password: password)
            cachedKeychain = kc
            return kc
        }

        // Explicit self-only SecAccess (nil trusted-app list = only the creating process,
        // i.e. us): without this, a keychain the app hasn't touched before can make the
        // Security framework want to confirm access via SecurityAgent on first item write,
        // which is exactly the interactive prompt this whole dedicated-keychain move exists to
        // avoid. Passing it up front means the ACL is pre-authorized — nothing to confirm.
        let initialAccess = selfOnlyAccess(label: "Audium")
        let createStatus = password.withCString { cPassword in
            SecKeychainCreate(keychainPath, UInt32(password.utf8.count), cPassword, false, initialAccess, &keychainRef)
        }
        guard createStatus == errSecSuccess, let kc = keychainRef else {
            AudiumLog.keychain.error("Failed to create Audium keychain: status \(createStatus)")
            throw KeychainError.unhandled(createStatus)
        }
        try unlock(kc, password: password)
        cachedKeychain = kc
        AudiumLog.keychain.info("Created dedicated Audium keychain")
        return kc
    }

    /// A SecAccess with a nil trusted-app list trusts only the creating process (us) — the
    /// documented way to pre-authorize an item/keychain so the OS never needs to ask "Allow
    /// Audium to access this?" via SecurityAgent.
    private static func selfOnlyAccess(label: String) -> SecAccess? {
        var access: SecAccess?
        let status = SecAccessCreate(label as CFString, nil, &access)
        guard status == errSecSuccess else { return nil }
        return access
    }

    private static func unlock(_ keychain: SecKeychain, password: String) throws {
        let status = password.withCString { cPassword in
            SecKeychainUnlock(keychain, UInt32(password.utf8.count), cPassword, true)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    private static func derivedPassword() -> String {
        // Explicit suite name, not `.standard`: `.standard`'s domain is derived from
        // `Bundle.main.bundleIdentifier`, which is nil (falls back to a different underlying
        // preferences domain) for an unbundled binary — e.g. `swift run`/`.build/debug/Audium`
        // during dev testing — but resolves normally for the real signed `.app`. Those are two
        // different files on disk (`Audium.plist` vs `com.postproduction.Audium.plist`), so the
        // salt — and thus the derived password — silently diverged between "however the binary
        // happened to be launched" and the real app, producing a permanent errSecAuthFailed
        // (-25293) against whichever keychain file got created first. Pinning to an explicit
        // suite name makes every launch path agree on the same salt regardless of bundling.
        // Deliberately NOT the app's own bundle id: Foundation special-cases and warns against
        // that ("does not make sense and will not work") — use a distinct, dedicated name.
        let defaults = UserDefaults(suiteName: "com.postproduction.Audium.KeychainStore") ?? .standard
        let salt: Data
        if let existing = defaults.data(forKey: saltDefaultsKey) {
            salt = existing
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            salt = Data(bytes)
            defaults.set(salt, forKey: saltDefaultsKey)
        }
        // The pepper ties derivation to this specific app; the salt alone (readable from
        // UserDefaults) isn't sufficient to reproduce the password without it.
        let pepper = Data((Bundle.main.bundleIdentifier ?? "com.postproduction.Audium").utf8)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pepper),
            salt: salt,
            info: Data("Audium.keychain-db".utf8),
            outputByteCount: 32
        )
        // Base64, not raw bytes: SecKeychainCreate/Unlock take a null-terminated C string, and
        // raw random bytes can contain 0x00, which would silently truncate the password.
        return key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    // MARK: - Save / load / delete (Audium keychain only)

    static func save(key: String, for provider: Provider) throws {
        do {
            let keychain = try openAudiumKeychain()
            let data = Data(key.utf8)
            // Without this, SecItemAdd/SecItemCopyMatching/SecItemDelete ignore
            // kSecUseKeychain and silently route to the unified Data Protection Keychain
            // (tied to the login/iCloud identity) instead of the legacy file-based keychain
            // `kSecUseKeychain` points at — the actual reason the password dialog said "login"
            // keychain and Audium.keychain-db kept coming back empty regardless of what our
            // code thought had succeeded.
            let baseQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider.rawValue,
                kSecUseDataProtectionKeychain as String: false,
            ]
            var deleteQuery = baseQuery
            deleteQuery[kSecMatchSearchList as String] = [keychain]
            SecItemDelete(deleteQuery as CFDictionary)

            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            attributes[kSecUseKeychain as String] = keychain
            attributes[kSecAttrAccess as String] = selfOnlyAccess(label: "\(provider.rawValue) API key")
            let status = SecItemAdd(attributes as CFDictionary, nil)
            AudiumLog.keychain.info("SecItemAdd for \(provider.rawValue, privacy: .public) returned OSStatus \(status)")
            guard status == errSecSuccess else {
                throw KeychainError.unhandled(status)
            }
            AudiumLog.keychain.info("Saved API key for \(provider.rawValue, privacy: .public)")
        } catch {
            AudiumLog.keychain.error("Failed to save API key for \(provider.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    static func load(for provider: Provider) throws -> String? {
        do {
            let keychain = try openAudiumKeychain()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider.rawValue,
                kSecMatchSearchList as String: [keychain],
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseDataProtectionKeychain as String: false,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainError.unhandled(status)
            }
            return String(data: data, encoding: .utf8)
        } catch {
            AudiumLog.keychain.error("Failed to load API key for \(provider.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    static func delete(for provider: Provider) throws {
        do {
            let keychain = try openAudiumKeychain()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider.rawValue,
                kSecMatchSearchList as String: [keychain],
                kSecUseDataProtectionKeychain as String: false,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unhandled(status)
            }
            AudiumLog.keychain.info("Deleted API key for \(provider.rawValue, privacy: .public)")
        } catch {
            AudiumLog.keychain.error("Failed to delete API key for \(provider.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - One-time migration off the corrupted login keychain

    /// Call once at app launch (off the main thread — a read against the corrupted login
    /// keychain may hit the same broken GUI prompt this whole keychain move exists to escape,
    /// so this must never block app startup). If the Audium keychain already has a key for a
    /// provider, or the login keychain doesn't, there's nothing to do. Old items are left in
    /// place (not deleted) — this only copies forward, never touches the user's existing data.
    ///
    /// Only ever attempted once per install (spec §5): on this machine the login keychain's
    /// migrated internal state is permanently corrupted (root-caused separately), so retrying
    /// this on every launch just means popping the same doomed "Allow" prompt forever. The
    /// logic stays — genuinely fresh installs with a healthy login keychain still benefit —
    /// it just doesn't get to ask more than once.
    private static let migrationAttemptedKey = "com.postproduction.Audium.migrationAttempted"

    static func migrateFromLoginKeychainIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationAttemptedKey) else { return }
        defaults.set(true, forKey: migrationAttemptedKey)
        for provider in [Provider.gemini, .openai] {
            if let already = try? load(for: provider), !already.isEmpty { continue }
            guard let legacyValue = try? loadFromLoginKeychain(for: provider), !legacyValue.isEmpty else { continue }
            do {
                try save(key: legacyValue, for: provider)
                AudiumLog.keychain.info("Migrated \(provider.rawValue, privacy: .public) API key from legacy login keychain")
            } catch {
                AudiumLog.keychain.error("Failed to migrate \(provider.rawValue, privacy: .public) API key from legacy keychain: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func loadFromLoginKeychain(for provider: Provider) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unhandled(status)
        }
        return String(data: data, encoding: .utf8)
    }

    // DEV-ONLY TEST ESCAPE HATCH — not a feature, do not build UI around this.
    // The GUI Keychain-write dialog is broken/being investigated separately, which blocks
    // manually exercising cloud providers end-to-end. Until that's fixed, setting
    // AUDIUM_GEMINI_KEY_OVERRIDE / AUDIUM_OPENAI_KEY_OVERRIDE in the environment lets a key be
    // supplied directly, bypassing Keychain reads entirely.
    // Never set in shipped builds/CI, never written back to Keychain, and inert unless the env
    // var is explicitly present.
    static func loadForTesting(for provider: Provider, envOverride: String) throws -> String? {
        if let override = ProcessInfo.processInfo.environment[envOverride], !override.isEmpty {
            return override
        }
        return try load(for: provider)
    }
}
