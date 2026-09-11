import Foundation

/// OAuth client credentials for the legacy Device-Flow path. Always the
/// public YouTube TV `client_id`/`secret` pair in practice: the Settings
/// UI that let users paste a custom client (and wrote its secret to
/// cleartext UserDefaults) was removed — that path had no sign-in entry
/// point and signing out to "apply" it destroyed the working cookie
/// session. `load()` still honours values an older build stored until
/// `reset()` purges them; nothing writes them any more.
struct OAuthClientConfig: Sendable {
    let clientId: String
    let clientSecret: String

    /// True iff the user has set custom credentials (i.e. not the TV
    /// defaults). Library access via Data API v3 needs this.
    var isCustom: Bool {
        clientId != Self.tvClientId
    }

    /// **NOT a secret.** This is the publicly-known YouTube TV OAuth
    /// client pair — Google ships these IDs in the YouTube TV / Apple
    /// TV / game console apps and they're widely embedded in
    /// open-source clients (yt-dlp, NewPipe, etc.). The "secret" is
    /// only used to identify the *application*, not the user — actual
    /// authorization happens via Device Flow where the user enters a
    /// one-time code on their phone. Safe to commit.
    static let tvClientId     = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    static let tvClientSecret = "SboVhoG9s0rNafixCSGGKXAT"

    static let `default` = OAuthClientConfig(clientId: tvClientId, clientSecret: tvClientSecret)

    private static let idKey = "oauth.client.id"
    private static let secretKey = "oauth.client.secret"

    static func load() -> OAuthClientConfig {
        let id = UserDefaults.standard.string(forKey: idKey)
        let secret = UserDefaults.standard.string(forKey: secretKey)
        if let id, !id.isEmpty, let secret, !secret.isEmpty {
            return OAuthClientConfig(clientId: id, clientSecret: secret)
        }
        return .default
    }

    // No `save()`: a client secret must never be written to
    // UserDefaults (a cleartext plist). If custom credentials ever come
    // back, store them with `Keychain.set` like every other credential.

    /// Removes any custom id/secret an older build stored in
    /// UserDefaults. Safe to call on every launch (no-op when absent).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: idKey)
        UserDefaults.standard.removeObject(forKey: secretKey)
    }
}
