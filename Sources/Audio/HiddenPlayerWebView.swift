import AppKit
import WebKit
import Observation

/// Offscreen WKWebView that loads music.youtube.com and plays audio.
///
/// Lives in a 1x1 transparent window with a 0 alpha. Never visible after the
/// initial sign-in flow. SwiftUI controls it via `evaluateJavaScript`; the page
/// posts state changes back via `WKScriptMessageHandler`.
@MainActor
final class HiddenPlayerWebView: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow

    var onEvent: ((BridgeEvent) -> Void)?

    enum BridgeEvent {
        case ready
        case stateChanged(isPlaying: Bool)
        case progress(currentTime: Double, duration: Double)
        case trackChanged(videoId: String, playlistId: String?, title: String, artist: String, artwork: URL?)
        /// Fired when the video element reaches end-of-stream. Distinct
        /// from `stateChanged(isPlaying: false)` (which also fires on
        /// user-paused) — `ended` is an edge that lets PlayerBridge
        /// jump to a user-queued "Play next" item before YT Music's
        /// natural autoplay kicks in.
        case ended
        /// The page's OWN queue (ytmusic-app store: items + automixItems),
        /// emitted by the JS safety poll whenever it changes. This is the
        /// ground truth for radio contexts, whose queues are
        /// non-deterministic and can't be reproduced by an independent
        /// /next call. `selected == true` marks the currently-playing row.
        case queueSnapshot(items: [PageQueueItem])
    }

    /// One row of the page's real queue, as mirrored from the ytmusic-app
    /// store by player-bridge.js's emitQueueSnapshot.
    struct PageQueueItem {
        let videoId: String
        let title: String
        let byline: String
        let thumbnailURL: URL?
        let selected: Bool
    }

    override init() {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        if let scriptURL = Bundle.main.url(forResource: "player-bridge", withExtension: "js"),
           let source = try? String(contentsOf: scriptURL) {
            userContent.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController = userContent
        config.mediaTypesRequiringUserActionForPlayback = []

        self.webView = WKWebView(frame: .init(x: 0, y: 0, width: 1, height: 1), configuration: config)
        // Pose as Chrome — YT Music's web app gates Safari/WebKit.
        self.webView.customUserAgent = InnerTubeClient.userAgent
        // In debug builds, expose the WebView in Safari's Develop menu so we
        // can inspect the JS console + DOM. No-op in release.
        #if DEBUG
        self.webView.isInspectable = true
        #endif

        self.window = NSWindow(
            contentRect: .init(x: -1000, y: -1000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.window.alphaValue = 0
        self.window.isOpaque = false
        self.window.backgroundColor = .clear
        self.window.contentView = webView
        self.window.orderOut(nil)

        super.init()

        userContent.add(self, name: "bridge")
        webView.navigationDelegate = self

        if let url = URL(string: "https://music.youtube.com") {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: WKScriptMessageHandler

    /// WKScriptMessageHandler is delivered on the main thread; decode the
    /// `{event, …}` payload posted from player-bridge.js and forward to
    /// `onEvent`.
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        // SECURITY: WebKit exposes window.webkit.messageHandlers.bridge to
        // EVERY frame in the WebView — including cross-origin ad iframes
        // music.youtube.com loads — not just the main frame our script is
        // injected into. Reject anything that isn't the main frame on a
        // YouTube host so an iframe can't forge trackChanged/queueSnapshot
        // events (queue spoofing + attacker-URL artwork beacons).
        guard message.frameInfo.isMainFrame,
              let host = message.frameInfo.securityOrigin.host as String?,
              host == "music.youtube.com" || host.hasSuffix(".youtube.com")
        else { return }
        guard let body = message.body as? [String: Any],
              let name = body["event"] as? String,
              let event = Self.decode(eventName: name, body: body)
        else { return }

        // PERF: os_log interpolations are evaluated eagerly — a
        // String(describing:) of the body dictionary runs even when no
        // one is collecting debug logs, at 4Hz for progress and with an
        // 80-row payload for queueSnapshot. Log the name always; dump
        // bodies only in debug builds and never for the two hot events.
        #if DEBUG
        if name != "progress", name != "queueSnapshot" {
            Log.bridge.debug("\(name, privacy: .public) \(String(describing: body), privacy: .public)")
        } else {
            Log.bridge.debug("\(name, privacy: .public)")
        }
        #else
        Log.bridge.debug("\(name, privacy: .public)")
        #endif
        onEvent?(event)
    }

    private static func decode(eventName: String, body: [String: Any]) -> BridgeEvent? {
        switch eventName {
        case "ready":
            return .ready
        case "stateChanged":
            guard let isPlaying = body["isPlaying"] as? Bool else { return nil }
            return .stateChanged(isPlaying: isPlaying)
        case "progress":
            let currentTime = (body["currentTime"] as? Double) ?? 0
            let duration = (body["duration"] as? Double) ?? 0
            return .progress(currentTime: currentTime, duration: duration)
        case "trackChanged":
            guard let videoId = body["videoId"] as? String else { return nil }
            let playlistId = body["playlistId"] as? String
            let title = (body["title"] as? String) ?? ""
            let artist = (body["artist"] as? String) ?? ""
            let artwork = (body["artwork"] as? String).flatMap(URL.init(string:))
            return .trackChanged(videoId: videoId, playlistId: playlistId, title: title, artist: artist, artwork: artwork)
        case "ended":
            return .ended
        case "queueSnapshot":
            guard let raw = body["items"] as? [[String: Any]], !raw.isEmpty else { return nil }
            let items: [PageQueueItem] = raw.compactMap { dict in
                guard let videoId = dict["videoId"] as? String, !videoId.isEmpty else { return nil }
                return PageQueueItem(
                    videoId: videoId,
                    title: (dict["title"] as? String) ?? "",
                    byline: (dict["byline"] as? String) ?? "",
                    thumbnailURL: (dict["thumbnail"] as? String).flatMap(URL.init(string:)),
                    selected: (dict["selected"] as? Bool) ?? false
                )
            }
            guard !items.isEmpty else { return nil }
            return .queueSnapshot(items: items)
        case "riffNavigatedTo":
            // Bookkeeping-only event so Swift can log JS-driven nav.
            // Commit-1 keeps this hooked while __riffPendingNextUrl
            // is still in transition; commit 2 drops the push side and
            // this case becomes dead code (no harm leaving the handler).
            if let url = body["url"] as? String {
                let via = (body["via"] as? String) ?? "?"
                Log.bridge.debug("JS navigated to (autoplay-intercept, via=\(via, privacy: .public)): \(url, privacy: .public)")
            }
            return nil
        case "diagnostic":
            // JS-side warnings (playerApi setup failures, missing
            // selectors, etc.). Surface to the unified log so the
            // primary-vs-fallback path is observable from `log show`.
            if let msg = body["msg"] as? String {
                Log.bridge.error("JS diagnostic: \(msg, privacy: .public)")
            }
            return nil
        default:
            return nil
        }
    }
}
