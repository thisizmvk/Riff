import SwiftUI
import WebKit
import AppKit

/// WebView-based Google sign-in. Pattern lifted from Kaset (the working
/// macOS YT Music client):
///
/// - Safari 17 UA. Google's "Couldn't sign you in. This browser or app may
///   not be secure" wall is specifically triggered by Chrome UA inside a
///   WKWebView. Safari UA passes through Google's account flow.
/// - Direct navigation to
///   `accounts.google.com/ServiceLogin?service=youtube&continue=…`,
///   skipping the music.youtube.com landing page (which would serve the
///   "use Chrome" interstitial under a Safari UA).
///
/// On completion the WebView's data store contains the SAPISID cookie;
/// `CookieJar.syncFromWebView()` mirrors it into `HTTPCookieStorage.shared`
/// so `InnerTubeClient` can attach the SAPISIDHASH Authorization header
/// for personalized endpoints (Library, history, recommendations).
struct SignInView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// Safari UA string Kaset uses verbatim. Don't change without testing
    /// against Google's webview-detection — Chrome UAs are rejected.
    static let signInUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static let signInURL: URL = {
        let continueURL = "https://www.youtube.com/signin?action_handle_signin=true&app=desktop&hl=en&next=https%3A%2F%2Fmusic.youtube.com%2F"
        let escaped = continueURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? continueURL
        return URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=\(escaped)")!
    }()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign in with Google")
                            .font(.system(size: 16, weight: .semibold))
                        // Framed around the concrete benefit rather
                        // than "create an account" language — Riff
                        // has no accounts of its own; signing in is
                        // just handing Google's cookie to the WebView
                        // so its own paid tier takes over.
                        Text("With YouTube Music Premium: no ads. Also unlocks your Liked Songs, playlists, and subscriptions.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Close") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                // Escape hatch: recovery / 2FA / passkey / security-key
                // steps often can't complete inside a WKWebView (no SMS
                // autofill, no USB security keys, flaky passkey support).
                // This hands the sign-in off to real Safari where all of
                // that works. Safari's cookies can't be read back into
                // Riff (sandbox), so after signing in there the user
                // returns via Settings → "Paste browser cookies".
                Button {
                    if let url = URL(string: "https://music.youtube.com") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "safari")
                            .font(.system(size: 11))
                        Text("Trouble signing in? Open in Safari")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.red)
                }
                .buttonStyle(.plain)
                .help("Opens Google sign-in in your default browser — use this if passkey, 2FA, or account recovery won't complete here. After signing in there, return to Riff and use Settings → Account → Paste browser cookies.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            SignInWebView { didSignIn in
                if didSignIn {
                    Task {
                        await CookieJar.syncFromWebView()
                        env.refreshSignedInState()
                        // Confirm the outcome — the sheet is about to
                        // dismiss, so a toast on the main window is the
                        // only place the user sees "it worked."
                        if env.isSignedIn {
                            env.showToast("Signed in — your library is loading.")
                        }
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        dismiss()
                    }
                }
            }
            .frame(minWidth: 480, minHeight: 640)
        }
        .frame(minWidth: 480, minHeight: 700)
    }
}

private struct SignInWebView: NSViewRepresentable {
    /// Called when the webview reaches a signed-in state (SAPISID cookie set).
    let onComplete: (Bool) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = SignInView.signInUserAgent
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: SignInView.signInURL))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Stop any media playing in the sign-in webview *before* it deallocates.
    /// After Google's continue URL lands on music.youtube.com, the page
    /// autoplays curated content; if we don't pause it, dismissing the sheet
    /// leaks the audio (it keeps streaming in parallel with the hidden audio
    /// engine, producing two-track simultaneous playback).
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(el => el.pause())", completionHandler: nil)
        nsView.stopLoading()
        nsView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onComplete: (Bool) -> Void
        private var fired = false
        init(onComplete: @escaping (Bool) -> Void) { self.onComplete = onComplete }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkForSignIn(webView: webView)
        }

        // Some Google sign-in steps don't fire didFinish (XHR-driven
        // intermediate flows). Polling on every navigation gives us
        // belt-and-suspenders coverage.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            checkForSignIn(webView: webView)
        }

        private func checkForSignIn(webView: WKWebView) {
            guard !fired else { return }
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                let signedIn = cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
                if signedIn, !self.fired {
                    self.fired = true
                    self.onComplete(true)
                }
            }
        }
    }
}
