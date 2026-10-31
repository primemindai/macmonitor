// Ed25519 release signing for MacMonitor. Uses only CryptoKit, Foundation and Security.
//
//   swift scripts/release-key.swift new                      Make the project key. Saves the private key in the login
//                                                            Keychain and prints ONLY the public key (base64).
//   swift scripts/release-key.swift sign <file>              Write <file>.sig: one line, base64 of the 64-byte signature.
//   swift scripts/release-key.swift verify <file> <pubkey>   Exit 0 only if <file>.sig verifies with <pubkey> (base64).
//
// The private key lives in the login Keychain (generic password, service "macmonitor-release-signing",
// account "release"). If MACMONITOR_SIGNING_KEY_FILE is set, `sign` reads the key from that file instead
// (raw 32 bytes, or base64 text). The private key is never printed, logged or passed on a command line.
import CryptoKit
import Foundation
import Security

let service = "macmonitor-release-signing"
let account = "release"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("release-key: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    fail("usage: swift scripts/release-key.swift new | sign <file> | verify <file> <pubkey-base64>")
}

/// Raw 32 bytes, or base64 text of them (whitespace and newlines trimmed).
func rawKey(from data: Data) -> Data? {
    if data.count == 32 { return data }
    guard let text = String(data: data, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else { return nil }
    return raw
}

func keychainQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    let raw: Data
    if let path = ProcessInfo.processInfo.environment["MACMONITOR_SIGNING_KEY_FILE"], !path.isEmpty {
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read the key file named by MACMONITOR_SIGNING_KEY_FILE") }
        guard let r = rawKey(from: data) else { fail("the key file is not 32 raw bytes or base64 of 32 bytes") }
        raw = r
    } else {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            fail("no signing key in the login Keychain (service \(service)), status \(status). Set MACMONITOR_SIGNING_KEY_FILE or run `new`.")
        }
        guard let r = rawKey(from: data) else { fail("the Keychain item is not a 32-byte key") }
        raw = r
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("the signing key is not a valid Ed25519 key") }
    return key
}

/// Strict `.sig` read, same rule as the app: trim, base64, exactly 64 bytes.
func readSignature(_ path: String) -> Data? {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 64 else { return nil }
    return raw
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "new" where args.count == 1:
    var check = keychainQuery()
    check[kSecMatchLimit as String] = kSecMatchLimitOne
    if SecItemCopyMatching(check as CFDictionary, nil) != errSecItemNotFound {
        fail("a signing key already exists in the login Keychain (service \(service)). Refusing to replace it.")
    }
    let key = Curve25519.Signing.PrivateKey()
    var add = keychainQuery()
    add[kSecValueData as String] = key.rawRepresentation
    add[kSecAttrLabel as String] = "MacMonitor release signing key"
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail(status == errSecDuplicateItem ? "a signing key already exists. Refusing to replace it." : "could not save the key, status \(status)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign" where args.count == 2:
    let path = args[1]
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let key = loadPrivateKey()
    guard let sig = try? key.signature(for: data) else { fail("signing failed") }
    // Check our own work before writing, so a bad key can never produce a .sig.
    guard key.publicKey.isValidSignature(sig, for: data) else { fail("the new signature does not verify") }
    do { try Data((sig.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: path + ".sig"), options: .atomic) }
    catch { fail("cannot write \(path).sig: \(error.localizedDescription)") }
    print(path + ".sig")

case "verify" where args.count == 3:
    let path = args[1]
    guard let raw = Data(base64Encoded: args[2].trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32,
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { fail("the public key is not base64 of a 32-byte Ed25519 key") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    guard let sig = readSignature(path + ".sig") else { fail("\(path).sig is missing or is not one line of base64 for 64 bytes") }
    guard pub.isValidSignature(sig, for: data) else { fail("\(path).sig does NOT verify with this public key") }
    print("OK: \(path).sig verifies with \(args[2])")

default:
    usage()
}
