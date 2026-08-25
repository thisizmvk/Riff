import Foundation
import os

/// Persisted OAuth credentials for the YouTube Data scope. Access
/// tokens expire (~1h); the refresh token is the long-lived secret we
/// use to mint new access tokens.
///
/// Storage policy: **Keychain-first, UserDefaults fallback.**
///
/// Why both:
///   - On a signed release build, Keychain is the right place: per-user,
///     OS-encrypted, never written to backup files, scoped to our bundle id.
///   - On ad-hoc-signed dev builds, every Xcode rebuild produces a *new*
///     code signature so macOS treats each build as a different requestor
///     and re-prompts "Riff wants to access keychain" on every launch.
///     UserDefaults sidesteps that friction during development.
///
/// We try Keychain on every load/save. If Keychain returns an error
/// (typical for a denied prompt or the ad-hoc-signature mismatch case
/// above), we silently fall through to UserDefaults and log it. On
/// load we also opportunistically migrate from UserDefaults → Keychain
/// when both stores diverge — so the moment the build gains a stable
/// signing identity, the next launch transparently hardens.
struct OAuthTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    /// Absolute time at which the access token stops being valid.
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-30) }

    private static let storageKey = "oauth.youtube.tokens"
    private static let log = Logger(subsystem: "dev.riff.app", category: "oauth")

    static func load() -> OAuthTokens? {
        // Keychain first.
        if let json = Keychain.get(storageKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder.iso8601.decode(OAuthTokens.self, from: data) {
            return decoded
        }
        // UserDefaults fallback. If we find tokens here but Keychain
        // was empty, migrate forward — next save() lands them in
        // Keychain so future loads pick the secure path.
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder.iso8601.decode(OAuthTokens.self, from: data) else {
            return nil
        }
        log.debug("loaded tokens from UserDefaults; will attempt Keychain migration on next save")
        return decoded
    }

    func save() throws {
        let data = try JSONEncoder.iso8601.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OAuthTokens.SaveError.encoding
        }
        // Try Keychain first. On success, also clear any stale
        // UserDefaults copy so the two stores don't drift.
        do {
            try Keychain.set(json, for: Self.storageKey)
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            Self.log.debug("tokens saved to Keychain")
        } catch {
            #if DEBUG
            // Dev-build convenience only: ad-hoc-signed debug builds
            // re-prompt Keychain on every rebuild and commonly fail.
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            Self.log.error("Keychain save failed (\(String(describing: error), privacy: .public)); fell back to UserDefaults (DEBUG only)")
            #else
            // SECURITY: in release, never write a long-lived refresh
            // token to a cleartext preferences plist (readable by any
            // process running as the user; included in unencrypted
            // backups). Surface the failure instead of silently
            // downgrading storage.
            Self.log.error("Keychain save failed (\(String(describing: error), privacy: .public)); tokens NOT persisted")
            throw error
            #endif
        }
    }

    static func clear() {
        // Wipe both stores on sign-out so a downgrade from Keychain
        // → UserDefaults (or vice versa across builds) can't leave
        // a stale token behind.
        Keychain.delete(storageKey)
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    enum SaveError: Error { case encoding }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
