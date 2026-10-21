import Foundation
import WebKit

/// Bridges cookies between the hidden WKWebView's WKWebsiteDataStore and
/// HTTPCookieStorage so the InnerTubeClient can authenticate against
/// music.youtube.com without re-prompting the user.
///
/// The user signs in once via the WebView; both surfaces then share the session.
/// Watches the WebView's cookie store and re-bridges on change.
/// Google rotates `__Secure-*PSIDTS` / `SIDCC` in the signed-in page
/// every 10–30 minutes; a one-time copy at sign-in let the two jars
/// drift until InnerTube answered anonymously while the page still
/// played ("session expired" for a live session). Changes come in
/// bursts, so the sync is coalesced.
@MainActor
private final class CookieChangeObserver: NSObject, WKHTTPCookieStoreObserver {
    private var pending: Task<Void, Never>? = nil

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.schedule() }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await CookieJar.syncFromWebView()
        }
    }
}

@MainActor
enum CookieJar {
    private static var observer: CookieChangeObserver? = nil

    /// Start mirroring WebView cookie changes into `HTTPCookieStorage`
    /// for the life of the process. Idempotent.
    static func startObserving() {
        guard observer == nil else { return }
        let o = CookieChangeObserver()
        observer = o
        WKWebsiteDataStore.default().httpCookieStore.add(o)
    }

    static func syncFromWebView() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        var bridged = 0
        for cookie in cookies {
            let domain = cookie.domain
            if domain.hasSuffix("youtube.com") || domain.hasSuffix("google.com") || domain.hasSuffix("googleusercontent.com") {
                HTTPCookieStorage.shared.setCookie(cookie)
                bridged += 1
            }
        }
        Log.innertube.debug("CookieJar bridged \(bridged) cookies from WebView → HTTPCookieStorage")
    }

    enum ImportResult { case success(count: Int); case missingAuthCookie; case empty }

    /// Lifetime (seconds) stamped on imported cookies. `document.cookie`
    /// carries no expiry, and a Set-Cookie without Expires/Max-Age
    /// builds a SESSION cookie (`isSessionOnly`) that neither jar
    /// persists — the import vanished on relaunch and then read as
    /// "session expired". An explicit Max-Age makes both jars save it.
    /// 400 days is CFNetwork's / Chrome's cap (longer is clamped);
    /// Google re-sets its own expiry when it rotates cookies, and
    /// sign-out deletes these like any other youtube.com cookie.
    private static let importedCookieMaxAge: Int = 400 * 24 * 60 * 60

    /// Load a user-pasted session (from a real-browser YT Music
    /// login) into both cookie stores. Parsing lives in
    /// `CookieImporter`; this persists. Cookies are built through
    /// Foundation's URL-scoped parser against `InnerTubeClient.baseURL`
    /// so their scope matches exactly the endpoint the client uses,
    /// with an explicit Max-Age so they survive relaunch.
    static func importPastedCookies(_ raw: String) async -> ImportResult {
        let pairs = CookieImporter.parse(raw)
        guard !pairs.isEmpty else { return .empty }
        guard CookieImporter.hasAuthCookie(pairs) else { return .missingAuthCookie }
        let url = InnerTubeClient.baseURL
        let wk = WKWebsiteDataStore.default().httpCookieStore
        var written = 0
        for (key, val) in pairs {
            let setCookieValue = key + "=" + val + "; Path=/; Secure; Max-Age=" + String(importedCookieMaxAge)
            let built = HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": setCookieValue],
                for: url
            )
            for c in built {
                HTTPCookieStorage.shared.setCookie(c)
                await wk.setCookie(c)
                written += 1
            }
        }
        return written > 0 ? .success(count: pairs.count) : .empty
    }

    /// Purge the WKWebView's own cookie + website-data store for
    /// Google / YouTube domains. Sign-out only clears
    /// `HTTPCookieStorage.shared`; without this the hidden player's
    /// WKWebsiteDataStore keeps the session, so a subsequent
    /// re-sign-in silently reuses the OLD Google account (the login
    /// page never appears) and switching accounts is impossible.
    static func purgeWebViewSession() async {
        let store = WKWebsiteDataStore.default()
        // 1. Delete matching cookies from the WK cookie store.
        let cookieStore = store.httpCookieStore
        let cookies = await cookieStore.allCookies()
        for cookie in cookies {
            let domain = cookie.domain
            if domain.hasSuffix("youtube.com") || domain.hasSuffix("google.com") || domain.hasSuffix("googleusercontent.com") {
                await cookieStore.deleteCookie(cookie)
            }
        }
        // 2. Nuke the broader website data (localStorage, IndexedDB,
        //    service workers) for those hosts too — YT Music caches
        //    session state outside cookies. Scoped to the exact
        //    hosts so we don't wipe unrelated data.
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let targets = records.filter { rec in
            rec.displayName.contains("youtube") || rec.displayName.contains("google")
        }
        if !targets.isEmpty {
            await store.removeData(ofTypes: types, for: targets)
        }
        Log.innertube.debug("CookieJar purged WebView session for \(targets.count) records")
    }
}
