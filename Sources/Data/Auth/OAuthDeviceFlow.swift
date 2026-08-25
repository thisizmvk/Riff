import Foundation
import Observation

/// Drives the OAuth 2.0 Device Authorization Flow against Google so users can
/// sign in without an embedded webview. The Google YouTube Data scope is
/// what InnerTube needs for personalized endpoints (library, history, likes).
///
/// **Why Device Flow**: Google blocks Google-account sign-in inside any
/// embedded webview as an anti-account-takeover measure. The TV-app-style
/// device flow is the only path that works end-to-end without a real
/// browser embedding — the user enters a 6-character code on
/// google.com/device in their everyday browser, and we poll Google's token
/// endpoint until they confirm.
///
/// **Client identity**: we re-use the public client_id/secret pair shipped
/// with the YouTube TV app. Same approach as `ytmusicapi`, `youtube-music`
/// (th-ch), and most other open-source YT clients. Google publishes these
/// values; they are not secret.
@MainActor
@Observable
final class OAuthDeviceFlow {
    enum State: Equatable {
        case idle
        case requesting
        case awaitingUser(userCode: String, verificationURL: URL)
        case success
        case failure(String)
    }

    private(set) var state: State = .idle

    /// Pulled from OAuthClientConfig at call time so a Settings change
    /// takes effect on the next sign-in attempt without reinstalling.
    private static var clientId: String     { OAuthClientConfig.load().clientId }
    private static var clientSecret: String { OAuthClientConfig.load().clientSecret }
    private static let scope = "https://www.googleapis.com/auth/youtube"

    private static let deviceCodeURL = URL(string: "https://oauth2.googleapis.com/device/code")!
    private static let tokenURL      = URL(string: "https://oauth2.googleapis.com/token")!

    private var pollingTask: Task<Void, Never>?

    func start() async {
        cancel()
        state = .requesting
        do {
            let resp = try await requestDeviceCode()
            guard let url = URL(string: resp.verification_url) else {
                state = .failure("Invalid verification URL")
                return
            }
            state = .awaitingUser(userCode: resp.user_code, verificationURL: url)
            pollingTask = Task { [weak self] in
                await self?.pollForToken(deviceCode: resp.device_code, interval: resp.interval, expiresIn: resp.expires_in)
            }
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
        if case .awaitingUser = state { state = .idle }
    }

    static func signOut() {
        OAuthTokens.clear()
    }

    /// Refresh an expired access token using the stored refresh token.
    /// Returns the new access token, or nil if refresh failed (caller should
    /// then prompt the user to sign in again).
    static func refreshIfNeeded() async -> String? {
        guard let current = OAuthTokens.load() else { return nil }
        if !current.isExpired { return current.accessToken }
        guard let refreshToken = current.refreshToken else { return nil }
        do {
            let resp = try await refresh(token: refreshToken)
            let new = OAuthTokens(
                accessToken: resp.access_token,
                refreshToken: refreshToken,  // Google omits this on refresh; keep the original
                expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in))
            )
            try new.save()
            return new.accessToken
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private struct DeviceCodeResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_url: String
        let expires_in: Int
        let interval: Int
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private struct ErrorResponse: Decodable {
        let error: String
        let error_description: String?
    }

    private struct RefreshResponse: Decodable {
        let access_token: String
        let expires_in: Int
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        var req = URLRequest(url: Self.deviceCodeURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "client_id": Self.clientId,
            "scope": Self.scope,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Body deliberately not logged (codes are short-lived, but the
        // token-endpoint sibling below must never log bodies — keep the
        // whole flow consistent so a future copy-paste can't regress it).
        Log.oauth.debug("device/code status=\(status)")

        if status != 200 {
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                let desc = err.error_description.map { ": \($0)" } ?? ""
                throw NSError(
                    domain: "OAuthDeviceFlow", code: status,
                    userInfo: [NSLocalizedDescriptionKey: "Google returned \(err.error)\(desc)"]
                )
            }
            throw NSError(domain: "OAuthDeviceFlow", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Google returned status \(status)"])
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    private func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        // Belt-and-suspenders cap on top of the time-based `deadline`: if the
        // network is flaky and `continue`s on every error, or Google returns
        // `slow_down` repeatedly without ever resolving, we don't want to
        // spin until `expiresIn`. Google's typical device-flow window is
        // 1800s with a 5s interval → ~360 polls. Cap at 400 to leave headroom
        // for `slow_down` backoff (which extends interval mid-flow) while
        // still guaranteeing termination.
        let maxAttempts = 400
        var attempts = 0
        while !Task.isCancelled, Date() < deadline, attempts < maxAttempts {
            attempts += 1
            do {
                try await Task.sleep(nanoseconds: UInt64(interval) * NSEC_PER_SEC)
            } catch { return }

            var req = URLRequest(url: Self.tokenURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formEncode([
                "client_id": Self.clientId,
                "client_secret": Self.clientSecret,
                "code": deviceCode,
                // Legacy grant_type that Google documents for OAuth 2.0 for
                // TVs and Limited-Input Devices. The RFC 8628 urn form is
                // rejected by this specific client_id.
                "grant_type": "http://oauth.net/grant_type/device/1.0",
            ])

            let data: Data
            let status: Int
            do {
                let (d, r) = try await URLSession.shared.data(for: req)
                data = d
                status = (r as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                Log.oauth.debug("poll network error: \(error.localizedDescription, privacy: .public) — retrying")
                continue
            }

            // SECURITY: never log the token-endpoint body — on 200 it
            // contains the access token AND the long-lived refresh token,
            // and a `privacy: .public` os_log line is readable by anyone
            // on the machine (Console.app, `log stream`, sysdiagnose) and
            // can ride along in a diagnostics dump. Status code only.
            Log.oauth.debug("poll status=\(status)")

            if status == 200 {
                do {
                    let token = try JSONDecoder().decode(TokenResponse.self, from: data)
                    let tokens = OAuthTokens(
                        accessToken: token.access_token,
                        refreshToken: token.refresh_token,
                        expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in))
                    )
                    try tokens.save()
                    state = .success
                    return
                } catch {
                    state = .failure("Couldn't decode token: \(error.localizedDescription)")
                    return
                }
            }

            // Non-200: expect an OAuth error code.
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                switch err.error {
                case "authorization_pending", "slow_down":
                    continue  // expected — keep polling
                case "access_denied":
                    state = .failure("Sign-in was denied")
                    return
                case "expired_token":
                    state = .failure("Code expired. Please try again.")
                    return
                default:
                    let desc = err.error_description.map { ": \($0)" } ?? ""
                    state = .failure("Google returned \(err.error)\(desc)")
                    return
                }
            }

            // Unrecognised response shape.
            state = .failure("Unexpected status \(status) from token endpoint")
            return
        }
        if !Task.isCancelled {
            if attempts >= maxAttempts {
                state = .failure("Sign-in took too many attempts. Please try again.")
            } else {
                state = .failure("Sign-in timed out. Please try again.")
            }
        }
    }

    private static func refresh(token: String) async throws -> RefreshResponse {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": token,
            "grant_type": "refresh_token",
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(RefreshResponse.self, from: data)
    }
}

private func formEncode(_ pairs: [String: String]) -> Data {
    // RFC 3986 unreserved set. Stricter than `.urlQueryAllowed` (which keeps
    // `:`, `/`, `@`, etc. unescaped) — those characters must be encoded in
    // form bodies. Google's device/code endpoint rejects loose encoding
    // with `invalid_request`.
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let encoded = pairs.map { k, v in
        let ke = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
        let ve = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
        return "\(ke)=\(ve)"
    }.joined(separator: "&")
    return Data(encoded.utf8)
}
