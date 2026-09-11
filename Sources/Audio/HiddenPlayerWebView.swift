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
        /// Outcome of a queueAddViaPage dispatch: `ok` means the id was
        /// VERIFIED present in the page's queue store after the
        /// ADD_ITEMS dispatch. Drives Phase A's self-migration — a
        /// verified add lets Swift drop its fallback copy (the page
        /// owns the item). See docs/QUEUE-DESIGN.md.
        case queueAddResult(videoId: String, position: String, ok: Bool, via: String)
        /// Outcome of a queueRemoveViaPage dispatch (Phase B): `ok`
        /// means the id was verified GONE from the page queue.
        case queueRemoveResult(videoId: String, ok: Bool, via: String)
        /// The page's OWN queue (ytmusic-app store: items + automixItems),
        /// emitted by the JS safety poll whenever it changes. This is the
        /// ground truth for radio contexts, whose queues are
        /// non-deterministic and can't be reproduced by an independent
        /// /next call. `selected == true` marks the currently-playing row.
        case queueSnapshot(items: [PageQueueItem], shuffleEnabled: Bool?)
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

    // MARK: Page-lifetime recovery state

    /// True once a navigation has COMMITTED a document on a YouTube /
    /// Google host. Gated on the host, not merely on didCommit: a
    /// captive portal commits a non-YouTube document whose posts the
    /// message handler below drops, so `ready` would never arrive —
    /// the retry must keep going through such a commit.
    private var hasCommitted = false
    /// The single in-flight load-retry chain (nil when none). Held so
    /// a commit can cancel it and a new failure never stacks a second.
    private var retryTask: Task<Void, Never>?
    /// Next retry delay: 5s tripling to a 60s cap. Never gives up —
    /// a bounded retry that stops would recreate the dead-bridge state
    /// this recovery exists to fix; at 60s cadence looping is cheap.
    private var retryDelay: TimeInterval = 5

    private static let homeURL = URL(string: "https://music.youtube.com")!

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

        webView.load(URLRequest(url: Self.homeURL))
    }

    // MARK: WKNavigationDelegate — page-lifetime recovery
    //
    // These handlers recover the PAGE, not the queue. A launch-time
    // load that fails (offline / DNS / captive portal) or a WebContent
    // process WebKit terminates mid-session leaves the bridge
    // permanently dead otherwise: the user script never (re-)runs,
    // `ready` never posts, and PlayerBridge queues commands forever
    // with nothing logged above `.debug`. Contract item 4 ("a failed
    // page action is never turned into a reload") concerns page
    // actions on a LIVE page; reloading a page that failed to exist,
    // or whose process died, is a page-lifecycle concern and never
    // routes through PlayerBridge.navigate.

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Consent / sign-in flows redirect through google.com; both
        // families count as "the real page is loading". Anything else
        // (captive portal) keeps the retry chain alive.
        guard let host = webView.url?.host,
              host == "youtube.com" || host.hasSuffix(".youtube.com")
                || host == "google.com" || host.hasSuffix(".google.com")
        else { return }
        hasCommitted = true
        retryTask?.cancel()
        retryTask = nil
        retryDelay = 5
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.bridge.notice("page loaded: \(webView.url?.host ?? "?", privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Memory pressure / JS OOM on long sessions. `reload()` would
        // re-load the current ?v= watch URL, and with
        // mediaTypesRequiringUserActionForPlayback = [] YT Music would
        // autoplay that track from 0 — surprising if the user was
        // paused when the process died. Load the origin instead; the
        // re-run user script posts `ready` through the normal path.
        Log.bridge.error("WebContent process terminated — reloading music.youtube.com")
        hasCommitted = false
        retryTask?.cancel()
        retryTask = nil
        retryDelay = 5
        webView.load(URLRequest(url: Self.homeURL))
    }

    private func handleLoadFailure(_ error: Error) {
        let ns = error as NSError
        // NSURLErrorCancelled (-999): every location.href navigate
        // issued while a load is still pending cancels the earlier
        // load. WebKitErrorDomain 102 (frame load interrupted by
        // policy change): fires on redirects. Neither is a failure;
        // retrying on them would fight legitimate navigations.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        Log.bridge.notice("page load failed: \(ns.localizedDescription, privacy: .public) [\(ns.domain, privacy: .public) \(ns.code)]")
        // Retry only a load that never produced a real page. A
        // mid-session failure on a live page must not become a reload.
        guard !hasCommitted, retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 3, 60)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.hasCommitted else { return }
            self.retryTask = nil
            Log.bridge.notice("retrying music.youtube.com load (waited \(Int(delay))s)")
            self.webView.load(URLRequest(url: Self.homeURL))
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
        case "queueAddResult":
            guard let videoId = body["videoId"] as? String, !videoId.isEmpty else { return nil }
            return .queueAddResult(
                videoId: videoId,
                position: (body["position"] as? String) ?? "",
                ok: (body["ok"] as? Bool) ?? false,
                via: (body["via"] as? String) ?? ""
            )
        case "queueRemoveResult":
            guard let videoId = body["videoId"] as? String, !videoId.isEmpty else { return nil }
            return .queueRemoveResult(
                videoId: videoId,
                ok: (body["ok"] as? Bool) ?? false,
                via: (body["via"] as? String) ?? ""
            )
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
            return .queueSnapshot(items: items, shuffleEnabled: body["shuffleEnabled"] as? Bool)
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
