import Foundation
import CryptoKit

/// The Ed25519 check that a release zip was signed with the MacMonitor project key.
///
/// scripts/release-key.swift signs the exact zip bytes and writes `MacMonitor-<version>.zip.sig`:
/// one line, base64 of the 64-byte raw signature. The app checks it with the public key below.
public enum ReleaseSignature {
    /// The project's public key: base64 of the raw 32-byte Ed25519 key.
    // Set by the release key step. Until then this placeholder is not base64, so it never decodes
    // and every signature check refuses. scripts/release.sh also refuses to ship while it is here.
    public static let projectPublicKeyBase64 = "PLACEHOLDER-SET-BY-THE-RELEASE-KEY-STEP"

    /// A raw 32-byte Ed25519 public key from base64, or nil (so the check refuses) for anything else.
    static func publicKey(base64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: base64), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// The `.sig` file read strictly: trim whitespace and newlines, base64, exactly 64 bytes.
    static func signature(from file: Data) -> Data? {
        guard let text = String(data: file, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 64 else { return nil }
        return raw
    }

    /// Throws `releaseSignatureMismatch` unless `sigFile` is a valid signature of `data` by `publicKeyBase64`.
    public static func verify(_ data: Data, sigFile: Data, publicKeyBase64: String) throws {
        guard let key = publicKey(base64: publicKeyBase64), let sig = signature(from: sigFile),
              key.isValidSignature(sig, for: data) else { throw UpdateError.releaseSignatureMismatch }
    }
}
