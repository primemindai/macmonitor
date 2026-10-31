import Foundation

/// The Ed25519 check that a release zip was signed with the MacMonitor project key.
public enum ReleaseSignature {
    /// The project's public key: base64 of the raw 32-byte Ed25519 key.
    // Set by the release key step. Until then this placeholder is not base64, so it never decodes
    // and every signature check refuses. scripts/release.sh also refuses to ship while it is here.
    public static let projectPublicKeyBase64 = "PLACEHOLDER-SET-BY-THE-RELEASE-KEY-STEP"
}
