import Foundation
import CryptoKit

// Prints the AudiumSigning.keychain-db password to stdout — nothing else.
//
// Same derivation KeychainStore.swift uses for Audium.keychain-db (HKDF-SHA256, fixed
// public pepper = the app's own bundle id, base64 output), with a distinct `info` string
// so it's a different derived value, not the same password reused across two keychains.
// The one difference from KeychainStore.swift: the salt lives in a local file owned by
// this script, not in the app's UserDefaults — build.sh needs to be able to compute this
// before the app has ever been built/run on a fresh machine, so it can't depend on
// UserDefaults state the app itself creates on first launch.
//
// Usage: swift Scripts/derive-signing-password.swift <path-to-salt-file>
// The salt file is created (32 random bytes, base64) on first run if missing.

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: derive-signing-password.swift <salt-file-path>\n".data(using: .utf8)!)
    exit(1)
}
let saltPath = args[1]

let salt: Data
if let existing = FileManager.default.contents(atPath: saltPath), !existing.isEmpty {
    guard let decoded = Data(base64Encoded: existing) else {
        FileHandle.standardError.write("salt file exists but isn't valid base64: \(saltPath)\n".data(using: .utf8)!)
        exit(1)
    }
    salt = decoded
} else {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    salt = Data(bytes)
    try FileManager.default.createDirectory(
        atPath: (saltPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try salt.base64EncodedString().write(toFile: saltPath, atomically: true, encoding: .utf8)
    // Local-only, not portable to another machine, not meant to be shared/committed.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saltPath)
}

let pepper = Data("com.postproduction.Audium".utf8)
let key = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: SymmetricKey(data: pepper),
    salt: salt,
    info: Data("Audium.signing-keychain".utf8),
    outputByteCount: 32
)
let password = key.withUnsafeBytes { Data($0).base64EncodedString() }
print(password)
