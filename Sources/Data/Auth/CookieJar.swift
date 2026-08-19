import Foundation
import WebKit

/// Bridges cookies between the hidden WKWebView's WKWebsiteDataStore and
/// HTTPCookieStorage so the InnerTubeClient can authenticate against
/// music.youtube.com without re-prompting the user.
///
/// The user signs in once via the WebView; both surfaces then share the session.
@MainActor
enum CookieJar {
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

    /// Load a user-pasted session (from a real-browser YT Music
    /// login) into both cookie stores. Parsing lives in
    /// `CookieImporter`; this persists. Cookies are built through
    /// Foundation's URL-scoped parser against `InnerTubeClient.baseURL`
    /// so their scope matches exactly the endpoint the client uses.
    static func importPastedCookies(_ raw: String) async -> ImportResult {
        let pairs = CookieImporter.parse(raw)
        guard !pairs.isEmpty else { return .empty }
        guard CookieImporter.hasAuthCookie(pairs) else { return .missingAuthCookie }
        let url = InnerTubeClient.baseURL
        let wk = WKWebsiteDataStore.default().httpCookieStore
        var written = 0
        for (key, val) in pairs {
            let setCookieValue = key + "=" + val + "; Path=/; Secure"
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
