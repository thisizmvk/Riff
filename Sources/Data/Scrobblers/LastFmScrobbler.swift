import Foundation
import CryptoKit

/// last.fm scrobbler — implements `track.scrobble` and
/// `track.updateNowPlaying` against the last.fm 2.0 web service.
///
/// Spec: https://www.last.fm/api/show/track.scrobble
///       https://www.last.fm/api/show/track.updateNowPlaying
///       https://www.last.fm/api/authspec  (auth + signature)
///
/// Auth model
/// ----------
/// last.fm uses a desktop-app three-step flow:
///   1. Get an unauth'd token via `auth.getToken`.
///   2. User opens `https://www.last.fm/api/auth/?api_key=K&token=T`
///      in their browser and clicks Approve.
///   3. App calls `auth.getSession` with the now-approved token; gets
///      a permanent session key.
///
/// Because we don't ship our own API key (last.fm key registration is
/// per-developer), we BYO-key: user pastes their own API key + secret
/// from https://www.last.fm/api/account/create into Settings, then
/// clicks "Connect" — Riff runs the three-step dance itself via
/// `fetchToken` / `authorizationURL` / `fetchSession` (the browser hop
/// happens between steps 1 and 3) and stores the resulting username +
/// session key. An advanced fallback in Settings still accepts a
/// hand-obtained session key. All four values live in Keychain.
///
/// Signature
/// ---------
/// Every authenticated POST is signed: concatenate every (key, value)
/// pair in alphabetical order by key into one string, append the
/// shared secret, hash with MD5. The five params for scrobble are
/// `api_key`, `artist`, `method`, `sk`, `track`, `timestamp` (plus
/// optional `album`, `duration`). We sort over all of them — including
/// optionals when present.
///
/// Concurrency: this type is value-stateless. `URLSession` is Sendable
/// and the cached credentials are read fresh from Keychain on every
/// call (so a user pasting a new key/secret takes effect immediately).
/// Marked `final` + nonisolated.
final class LastFmScrobbler: ScrobblerService, Sendable {
    let displayName = "last.fm"

    static let apiURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    static let authURL = "https://www.last.fm/api/auth/"

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Scrobblers.makeSession()
    }

    /// True when every required credential is populated AND the user
    /// hasn't toggled the service off in Settings.
    var isReady: Bool {
        guard UserDefaults.standard.bool(forKey: ScrobblerDefaults.lastFmEnabled) else { return false }
        return Self.storedCredentials() != nil
    }

    struct Credentials: Equatable, Sendable {
        let username: String
        let apiKey: String
        let apiSecret: String
        let sessionKey: String
    }

    static func storedCredentials() -> Credentials? {
        guard let username = Keychain.get(ScrobblerKeychain.lastFmUsername), !username.isEmpty,
              let apiKey = Keychain.get(ScrobblerKeychain.lastFmAPIKey), !apiKey.isEmpty,
              let apiSecret = Keychain.get(ScrobblerKeychain.lastFmSecret), !apiSecret.isEmpty,
              let sessionKey = Keychain.get(ScrobblerKeychain.lastFmSessionKey), !sessionKey.isEmpty
        else { return nil }
        return Credentials(username: username, apiKey: apiKey, apiSecret: apiSecret, sessionKey: sessionKey)
    }

    /// Save credentials atomically. Errors propagate so Settings can
    /// show a Keychain-denied banner.
    static func saveCredentials(
        username: String,
        apiKey: String,
        apiSecret: String,
        sessionKey: String
    ) throws {
        try Keychain.set(username, for: ScrobblerKeychain.lastFmUsername)
        try Keychain.set(apiKey, for: ScrobblerKeychain.lastFmAPIKey)
        try Keychain.set(apiSecret, for: ScrobblerKeychain.lastFmSecret)
        try Keychain.set(sessionKey, for: ScrobblerKeychain.lastFmSessionKey)
    }

    static func clearCredentials() {
        Keychain.delete(ScrobblerKeychain.lastFmUsername)
        Keychain.delete(ScrobblerKeychain.lastFmAPIKey)
        Keychain.delete(ScrobblerKeychain.lastFmSecret)
        Keychain.delete(ScrobblerKeychain.lastFmSessionKey)
    }

    // MARK: - ScrobblerService

    func updateNowPlaying(_ track: ScrobbleTrack) async {
        guard let creds = Self.storedCredentials() else { return }
        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "api_key": creds.apiKey,
            "sk": creds.sessionKey,
            "artist": track.artist,
            "track": track.title,
        ]
        if let album = track.album, !album.isEmpty { params["album"] = album }
        if let dur = track.durationSeconds, dur > 0 { params["duration"] = String(dur) }
        await post(params: params, secret: creds.apiSecret)
    }

    func scrobble(_ track: ScrobbleTrack) async {
        guard let creds = Self.storedCredentials() else { return }
        let ts = Int(track.startedAt.timeIntervalSince1970)
        var params: [String: String] = [
            "method": "track.scrobble",
            "api_key": creds.apiKey,
            "sk": creds.sessionKey,
            "artist": track.artist,
            "track": track.title,
            "timestamp": String(ts),
        ]
        if let album = track.album, !album.isEmpty { params["album"] = album }
        if let dur = track.durationSeconds, dur > 0 { params["duration"] = String(dur) }
        await post(params: params, secret: creds.apiSecret)
    }

    // MARK: - Signed POST

    /// Error envelope last.fm returns on failure — sometimes alongside
    /// a non-2xx status, sometimes with HTTP 200, so we parse the body
    /// rather than trusting the status code alone.
    /// Codes: https://www.last.fm/api/errorcodes — 9 = invalid session
    /// key (permanent, needs re-auth), 13 = invalid signature (wrong
    /// shared secret), 10 = invalid API key.
    private struct APIErrorEnvelope: Decodable {
        let error: Int
        let message: String?
    }

    /// `track.scrobble` success envelope — HTTP 200 can still mean the
    /// scrobble was *ignored* (bad timestamp, filtered artist, …).
    private struct ScrobblesEnvelope: Decodable {
        struct Attr: Decodable {
            let accepted: Int
            let ignored: Int
        }
        struct Inner: Decodable {
            let attr: Attr
            enum CodingKeys: String, CodingKey { case attr = "@attr" }
        }
        let scrobbles: Inner
    }

    /// Sign + send, then parse the JSON envelope so failures are
    /// visible: logged at `.error`/`.notice` (levels that survive into
    /// diagnostics exports) and recorded on `ScrobbleHealth` for
    /// Settings to render. Errors are still swallowed — a scrobble
    /// failure can't crash the app, and there is no retry (a stale
    /// retry racing the user's next track is worse than a dropped
    /// scrobble).
    ///
    /// Logging privacy: only the method name, HTTP status, error code
    /// and server message are logged — NEVER `params` or the request
    /// body, which carry `sk` and `api_sig`.
    private func post(params: [String: String], secret: String) async {
        let method = params["method"] ?? "?"
        var signed = params
        signed["api_sig"] = Self.signature(params: params, secret: secret)
        // Ask for a JSON response so we can parse the outcome.
        signed["format"] = "json"

        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Scrobblers.formEncode(signed)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                let message = envelope.message ?? "last.fm error \(envelope.error)"
                Log.bridge.error("last.fm \(method, privacy: .public) rejected: HTTP \(status, privacy: .public), error \(envelope.error, privacy: .public) — \(message, privacy: .public)")
                let code = envelope.error
                // Error 9 means the session key was revoked/invalid —
                // permanent; retrying is pointless until the user
                // reconnects last.fm.
                let permanent = code == 9
                await MainActor.run {
                    ScrobbleHealth.shared.recordFailure(
                        service: displayName, code: code,
                        message: message, permanent: permanent
                    )
                }
            } else if !(200...299).contains(status) {
                Log.bridge.error("last.fm \(method, privacy: .public) → HTTP \(status, privacy: .public)")
                await MainActor.run {
                    ScrobbleHealth.shared.recordFailure(
                        service: displayName, code: nil,
                        message: "HTTP \(status)", permanent: false
                    )
                }
            } else {
                // Success — but a 200 scrobble can still be ignored.
                if let scrobbles = try? JSONDecoder().decode(ScrobblesEnvelope.self, from: data),
                   scrobbles.scrobbles.attr.ignored > 0 {
                    Log.bridge.notice("last.fm \(method, privacy: .public): server ignored \(scrobbles.scrobbles.attr.ignored, privacy: .public) scrobble(s), accepted \(scrobbles.scrobbles.attr.accepted, privacy: .public)")
                }
                await MainActor.run {
                    ScrobbleHealth.shared.recordSuccess(service: displayName)
                }
            }
        } catch {
            Log.bridge.error("last.fm \(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                ScrobbleHealth.shared.recordFailure(
                    service: displayName, code: nil,
                    message: error.localizedDescription, permanent: false
                )
            }
        }
    }

    /// MD5 signature over the alphabetically-sorted concatenation of
    /// every (key + value) pair, followed by the shared secret.
    /// Exposed `internal` so unit tests can verify against the canonical
    /// example from the last.fm auth spec.
    static func signature(params: [String: String], secret: String) -> String {
        var buf = ""
        for key in params.keys.sorted() {
            buf.append(key)
            buf.append(params[key] ?? "")
        }
        buf.append(secret)
        let digest = Insecure.MD5.hash(data: Data(buf.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - One-off OAuth helpers

    /// Typed last.fm API error, thrown by the auth helpers so Settings
    /// can show the real reason a "Connect" attempt failed. Because
    /// `auth.getToken` is *signed*, a mistyped shared secret fails
    /// immediately with error 13 and a bad API key with error 10 —
    /// which makes `fetchToken` a genuine credentials test (unlike
    /// unauthenticated calls such as `user.getInfo`).
    struct APIError: LocalizedError, Equatable {
        let code: Int
        let message: String
        var errorDescription: String? { "last.fm error \(code): \(message)" }
    }

    /// User-facing status line for a failed Connect step. Pure —
    /// no network, no state — so tests can pin the mapping.
    ///
    /// Codes (https://www.last.fm/api/errorcodes) seen in this flow:
    ///   14 = token not yet authorized — the user hasn't clicked
    ///        "Allow" in the browser yet;
    ///   15 = token expired — tokens live ~60 minutes;
    ///   10 = invalid API key; 13 = invalid signature, i.e. the
    ///        shared secret is wrong (auth.getToken is signed, so a
    ///        typo'd secret fails right at step 1).
    static func connectFailureMessage(for error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError.code {
            case 14, 15:
                return "Approve Riff in the browser first, then click Done (tokens expire after 60 minutes)."
            case 10:
                return "last.fm rejected the API key — check it and try again."
            case 13:
                return "last.fm rejected the signature — check the shared secret and try again."
            default:
                return "last.fm error \(apiError.code): \(apiError.message)"
            }
        }
        return error.localizedDescription
    }

    /// If `data` is a last.fm error envelope, return it as a typed error.
    private static func decodeAPIError(_ data: Data) -> APIError? {
        struct Envelope: Decodable {
            let error: Int
            let message: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return APIError(code: envelope.error, message: envelope.message ?? "last.fm error \(envelope.error)")
    }

    /// Step 1 of the desktop-app flow. Returns the unauth'd token.
    /// Throws `APIError` when last.fm rejects the key/secret.
    static func fetchToken(apiKey: String, apiSecret: String, session: URLSession? = nil) async throws -> String {
        let s = session ?? Scrobblers.makeSession()
        let params: [String: String] = ["method": "auth.getToken", "api_key": apiKey]
        let signed: [String: String] = [
            "method": "auth.getToken",
            "api_key": apiKey,
            "api_sig": signature(params: params, secret: apiSecret),
            "format": "json",
        ]
        var url = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        url.queryItems = signed.keys.sorted().map { URLQueryItem(name: $0, value: signed[$0]) }
        var req = URLRequest(url: url.url!)
        req.httpMethod = "GET"
        let (data, _) = try await s.data(for: req)
        if let apiError = decodeAPIError(data) { throw apiError }
        struct TokenResp: Decodable { let token: String }
        return try JSONDecoder().decode(TokenResp.self, from: data).token
    }

    /// Step 3 of the desktop-app flow. Exchanges an approved token for
    /// a permanent (username, sessionKey) pair.
    static func fetchSession(token: String, apiKey: String, apiSecret: String, session: URLSession? = nil) async throws -> (username: String, sessionKey: String) {
        let s = session ?? Scrobblers.makeSession()
        let params: [String: String] = [
            "method": "auth.getSession",
            "api_key": apiKey,
            "token": token,
        ]
        var signed = params
        signed["api_sig"] = signature(params: params, secret: apiSecret)
        signed["format"] = "json"

        var url = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        url.queryItems = signed.keys.sorted().map { URLQueryItem(name: $0, value: signed[$0]) }
        var req = URLRequest(url: url.url!)
        req.httpMethod = "GET"
        let (data, _) = try await s.data(for: req)
        if let apiError = decodeAPIError(data) { throw apiError }
        struct SessionResp: Decodable {
            struct Inner: Decodable { let name: String; let key: String }
            let session: Inner
        }
        let decoded = try JSONDecoder().decode(SessionResp.self, from: data)
        return (decoded.session.name, decoded.session.key)
    }

    /// Build the URL the user opens in their browser to approve the
    /// API key (step 2 of the flow). They get redirected to last.fm,
    /// click Allow, then come back to Riff and click "Done" so we
    /// trigger step 3.
    static func authorizationURL(apiKey: String, token: String) -> URL {
        var c = URLComponents(string: authURL)!
        c.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return c.url!
    }
}
