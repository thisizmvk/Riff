import Foundation
import CryptoKit
import os

/// Native Swift client for YouTube Music's InnerTube endpoints.
///
/// All visible UI in the app is fed by this client. The hidden WKWebView is
/// the audio engine; this client is the data engine. The two share cookies via
/// `WKWebsiteDataStore` ↔ `HTTPCookieStorage`.
///
/// Reference for request shapes:
///   - https://github.com/LuanRT/YouTube.js
///   - https://github.com/sigma67/ytmusicapi (endpoint catalogue)
///
/// Stability notes: every endpoint we depend on has a snapshot fixture in
/// tests. A nightly CI job hits live endpoints with a sentinel account to
/// surface Google-side breakage early.
/// `@unchecked Sendable`: the type itself is safe to share across actors —
/// `URLSession` is Sendable, our only mutable state is via the session, and we
/// never mutate the constants. But several internal methods accept/return
/// `[String: Any]` (raw decoded JSON) which is *not* Sendable under Swift 6
/// strict concurrency. Wrapping every InnerTube response in a typed Sendable
/// shell would balloon this file; we accept the unchecked annotation here and
/// keep the unsafe-bridge confined to method internals (no `[String: Any]`
/// crosses an actor boundary in the public API — only typed `MediaItem`,
/// `HomeSection`, etc. do).
final class InnerTubeClient: @unchecked Sendable {
    static let baseURL = URL(string: "https://music.youtube.com/youtubei/v1/")!
    static let origin = "https://music.youtube.com"

    /// Bumped together when Google changes the protocol on us.
    /// `clientVersion` is the FALLBACK: once the hidden page's
    /// `pageInfo` handshake reports a plausible live
    /// INNERTUBE_CLIENT_VERSION, requests send that instead — see
    /// `effectiveClientVersion`. The constant covers requests made
    /// before the page loads (and any page whose report fails
    /// validation), and remains the single rotation point when the
    /// page can't tell us.
    static let clientName = "WEB_REMIX"
    static let clientVersion = "1.20260501.00.00"
    static let clientNameID = "67"  // X-YouTube-Client-Name for WEB_REMIX

    /// Live client version reported by the hidden page's `pageInfo`
    /// handshake; nil before the first handshake or when the reported
    /// value failed validation. Lock-protected: written from the
    /// MainActor bridge-event path, read from arbitrary request Tasks.
    private static let pageClientVersion = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Install (or clear) the page-supplied client version. Page
    /// values are untrusted input that lands in an HTTP header: only a
    /// value matching the known WEB_REMIX shape is accepted; anything
    /// else clears the override so requests fall back to the constant
    /// (a stale previous page's value must not outlive its page).
    static func updatePageClientVersion(_ value: String?) {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String? = (!trimmed.isEmpty && isPlausibleClientVersion(trimmed)) ? trimmed : nil
        pageClientVersion.withLock { current in current = candidate }
    }

    /// The WEB_REMIX version shape (`1.20260501.00.00`-like):
    /// `major.YYYYMMDD.minor.patch` with fixed digit counts.
    static func isPlausibleClientVersion(_ value: String) -> Bool {
        return value.range(of: "^[0-9]+\\.[0-9]{8}\\.[0-9]{2}\\.[0-9]{2}$", options: .regularExpression) != nil
    }

    /// What requests actually send: the page's validated live version
    /// when the handshake has provided one, else the constant.
    static var effectiveClientVersion: String {
        return pageClientVersion.withLock { $0 } ?? clientVersion
    }

    /// When we attach a Bearer token from Device Flow, the audience of that
    /// token is the YouTube TV client (`861556708454-...`) — InnerTube
    /// rejects `WEB_REMIX + Bearer` as INVALID_ARGUMENT because the
    /// clientName doesn't match the token's origin. Switching to the TV
    /// client identifiers lets InnerTube accept the combination.
    static let tvClientName = "TVHTML5_SIMPLY_EMBEDDED_PLAYER"
    static let tvClientVersion = "2.0"
    static let tvClientNameID = "85"

    /// Pretend to be Chrome on macOS. YouTube Music gates its web app
    /// (and several InnerTube endpoints) to Chrome — Safari/WebKit gets a
    /// "not optimized for your browser" interstitial. We use the same UA
    /// across the InnerTube HTTP client, the sign-in WKWebView, and the
    /// hidden audio WKWebView so the three are indistinguishable to YT.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    private let session: URLSession

    /// Default `URLSession` for InnerTube/Data API traffic. We don't use
    /// `URLSession.shared` because its default `timeoutIntervalForRequest`
    /// is 60s, which leaves the UI hanging on a wedged connection for an
    /// unreasonably long time. 10s is enough for any healthy YT Music
    /// response (browse/search/next typically land in 200-800ms) and short
    /// enough that a hostile network surfaces as a real error before the
    /// user gives up. Tests inject their own session and bypass this.
    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession()
    }

    enum InnerTubeError: Error {
        case http(Int)
        case decoding
        case needsReauth  // 401 / Cloudflare CAPTCHA — re-present sign-in sheet.
        case dataAPINotEnabled  // Library needs custom OAuth credentials with Data API v3 enabled.
    }

    // MARK: - Public API

    /// One mood / activity chip in the chip cloud above the Home rails
    /// ("Energize", "Workout", "Focus", "Sleep", "Commute", "Romance",
    /// "Sad", "Feel good", "Party", "Relax"…). YT serves these as a
    /// `chipCloudRenderer` at the top of `FEmusic_home`; each chip
    /// carries a `browseEndpoint` whose `params` re-filter Home to that
    /// vibe when sent on a second `/browse` call.
    struct HomeChip: Sendable, Identifiable, Hashable, Codable {
        /// Display label ("Workout", "Sleep", …).
        let label: String
        /// `browseEndpoint.params` blob — opaque protobuf YT echoes back
        /// to scope the next `FEmusic_home` browse to this mood. Required;
        /// chips without params are useless and parsing drops them.
        let params: String
        var id: String { label.isEmpty ? params : label }
    }

    /// Full payload of a Home browse — chips above the rails plus the
    /// rails themselves. We return both because they come from the same
    /// `/browse` response and the chip row needs to render before users
    /// scroll past the first rail.
    struct HomeFeed: Sendable {
        let chips: [HomeChip]
        let sections: [HomeSection]
    }

    func browseHome() async throws -> HomeFeed {
        // Initial /browse — 3 shelves typically come back here.
        let body = try await postRaw(.browse, body: ["browseId": BrowseID.home])
        let chips = Self.parseHomeChips(body)
        let initialShelves = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        var sections = initialShelves.compactMap(Self.parseHomeShelf)
        var continuation = Self.findContinuationToken(in: body)

        // Pull continuations until exhausted or we hit the safety cap.
        // YT Music's iOS app streams these as you scroll; we batch them
        // up-front so the home tab feels populated on first load.
        var iterations = 0
        let maxIterations = 6
        while let token = continuation, iterations < maxIterations {
            iterations += 1
            do {
                let resp = try await postRaw(.browse, body: ["continuation": token])
                let moreShelves = Parsing.array(resp, "continuationContents",
                    "sectionListContinuation", "contents") ?? []
                let moreSections = moreShelves.compactMap(Self.parseHomeShelf)
                sections.append(contentsOf: moreSections)
                continuation = Self.findContinuationToken(in: resp)
                Log.innertube.debug("home continuation \(iterations) → +\(moreSections.count) sections (total=\(sections.count))")
            } catch {
                Log.innertube.error("home continuation \(iterations) failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
        Log.innertube.debug("home final sections=\(sections.count) chips=\(chips.count)")
        return HomeFeed(chips: chips, sections: sections)
    }

    /// Fetch the Explore feed — Charts, New releases, Moods & genres,
    /// Featured playlists, etc. Same response shape as the Home feed
    /// (musicCarouselShelfRenderer + musicShelfRenderer + gridRenderer
    /// shelves under a singleColumnBrowseResultsRenderer), so we
    /// reuse parseHomeShelf without extra parser work.
    ///
    /// We DON'T follow continuation tokens here: Explore is curated
    /// and finite by design — initial shelves are the surface YT
    /// intends users to land on. Continuations would just pull in
    /// long-tail content.
    func browseExplore() async throws -> [HomeSection] {
        let body = try await postRaw(.browse, body: ["browseId": BrowseID.explore])
        let shelves = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        let sections = shelves.compactMap(Self.parseHomeShelf)
        Log.innertube.debug("explore sections=\(sections.count) shelfKinds=\(shelves.compactMap { Array($0.keys).first }, privacy: .public)")
        return sections
    }

    /// Re-fetch Home filtered by a mood chip's params blob.
    func browseHomeFiltered(chipParams: String) async throws -> [HomeSection] {
        let body = try await postRaw(.browse, body: [
            "browseId": BrowseID.home,
            "params": chipParams,
        ])
        let shelves = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        return shelves.compactMap(Self.parseHomeShelf)
    }

    /// Extract the mood / activity chip cloud above the rails from a
    /// FEmusic_home browse response. YT serves these under
    /// sectionListRenderer.header.chipCloudRenderer.chips; each chip
    /// is a chipCloudChipRenderer carrying a text run and a
    /// browseEndpoint.params blob that re-scopes Home when echoed back.
    static func parseHomeChips(_ body: [String: Any]) -> [HomeChip] {
        let candidatePaths: [[String]] = [
            ["contents", "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
             "content", "sectionListRenderer", "header", "chipCloudRenderer", "chips"],
            ["contents", "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
             "content", "sectionListRenderer", "header", "musicChipCloudRenderer", "chips"],
            ["header", "chipCloudRenderer", "chips"],
        ]
        for path in candidatePaths {
            guard let nodes = Parsing.dig(body, path) as? [[String: Any]] else { continue }
            let chips: [HomeChip] = nodes.compactMap { node in
                guard let r = node["chipCloudChipRenderer"] as? [String: Any] else { return nil }
                let raw = Parsing.runs(r, "text") ?? ""
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let params = Parsing.dig(r, ["navigationEndpoint", "browseEndpoint", "params"]) as? String,
                      !label.isEmpty, !params.isEmpty else { return nil }
                return HomeChip(label: label, params: params)
            }
            if !chips.isEmpty { return chips }
        }
        return []
    }

    /// Fetch the Moods & Genres feed — a flat list of mood/genre
    /// "tile" items, each pointing to a curated playlist when tapped.
    /// Reuses parseHomeShelf for the same reason browseExplore does.
    func browseMoodsAndGenres() async throws -> [HomeSection] {
        let body = try await postRaw(.browse, body: ["browseId": BrowseID.moodsAndGenres])
        let shelves = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        let sections = shelves.compactMap(Self.parseHomeShelf)
        Log.innertube.debug("moodsAndGenres sections=\(sections.count)")
        return sections
    }

    /// Fetch the "Mixed for you" feed — personalized auto-generated
    /// mixes (My Supermix, Discover Mix, New Release Mix, etc.).
    /// Same shelf shape as Home / Explore, so parseHomeShelf handles
    /// the response without extra parser work.
    ///
    /// Anonymous users get an empty / shelf-less response — there's
    /// nothing personal to mix. Callers should hide the section when
    /// the result is empty rather than rendering a titled void.
    func browseMixedForYou() async throws -> [HomeSection] {
        let body = try await postRaw(.browse, body: ["browseId": BrowseID.mixedForYou])
        let shelves = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        let sections = shelves.compactMap(Self.parseHomeShelf)
        Log.innertube.debug("mixedForYou sections=\(sections.count)")
        return sections
    }

    /// D3 — chronological feed of new releases from artists the user
    /// has subscribed to via YT Music. Fans out to each subscribed
    /// artist's detail page in parallel (capped at `limit` artists so
    /// power users with hundreds of subscriptions don't trigger
    /// runaway requests), pulls albums + singles + EP shelves out of
    /// the response, and returns the union sorted release-year desc.
    ///
    /// Anonymous callers will get an empty signed-in artists list and
    /// short-circuit to `[]` — the UI gates this on `env.isSignedIn`
    /// regardless, but the defense-in-depth keeps the network path
    /// honest. The whole call is best-effort: any per-artist failure
    /// is swallowed (logged) so one unreachable artist doesn't blank
    /// the whole rail.
    func newReleasesFromFollowedArtists(limit: Int = 25) async throws -> [MediaItem] {
        let artists = try await library(section: .artists)
        let scoped = Array(artists.filter { $0.kind == .artist }.prefix(max(0, limit)))
        guard !scoped.isEmpty else { return [] }
        Log.innertube.debug("followedFeed artists=\(scoped.count)")

        // Parallel fan-out — each artist detail is its own /browse call.
        // Per-artist failures are caught inside each child task so one
        // 5xx doesn't poison the whole feed. `releasesFromArtistDetail`
        // is a pure static extractor, kept off the actor to keep the
        // closure Sendable.
        let releases: [MediaItem] = await withTaskGroup(of: [MediaItem].self, returning: [MediaItem].self) { group in
            for artist in scoped {
                let client = self
                group.addTask {
                    do {
                        // Only the release shelves are read — never page
                        // the artist's song list for this fan-out.
                        let page = try await client.detail(forBrowseId: artist.id, maxContinuationPages: 0)
                        return Self.releasesFromArtistDetail(page)
                    } catch {
                        Log.innertube.error("followedFeed artist=\(artist.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                        return []
                    }
                }
            }
            var all: [MediaItem] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }

        // Dedupe by id (an artist's collab can surface on both pages),
        // then sort by year desc with nil-year items sinking to the
        // tail. Tie-break alphabetically so SwiftUI doesn't permute on
        // every refresh.
        var seen = Set<String>()
        let unique = releases.filter { seen.insert($0.id).inserted }
        let sorted = unique.sorted { lhs, rhs in
            let ly = lhs.year ?? Int.min
            let ry = rhs.year ?? Int.min
            if ly == ry {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return ly > ry
        }
        Log.innertube.debug("followedFeed releases=\(sorted.count) (deduped from \(releases.count))")
        return sorted
    }

    /// Pull album / single / EP tiles out of an artist's detail page.
    ///
    /// Selection is structural, never by shelf title: titles are
    /// localized ("Albums" / "Álbumes" / "Alben" / "アルバム"), and
    /// the old English keyword list silently dropped whole release
    /// rails outside `en`. On an artist page only the discography
    /// rails ("Albums", "Singles & EPs") carry album-page tiles
    /// (`musicTwoRowItemRenderer`, kind == .album, with release-year
    /// runs). "Videos" / "Live performances" are watch tiles
    /// (.song), "Featured on" / "Playlists by …" are playlists and
    /// "Fans might also like" is artists — so keeping only `.album`
    /// tiles selects exactly the release rails in every locale.
    /// Song-shaped tiles inside a Singles rail drop too: release-year
    /// metadata lives on the album-shaped tile and tapping it plays
    /// the single anyway.
    static func releasesFromArtistDetail(_ page: DetailPage) -> [MediaItem] {
        page.relatedSections.flatMap { section -> [MediaItem] in
            section.items.filter { $0.kind == .album }
        }
    }

    /// Walk a /browse response (initial or continuation-chunk) and return
    /// the next continuation token, if YT included one.
    private static func findContinuationToken(in body: [String: Any]) -> String? {
        // Initial response shape: contents…sectionListRenderer.continuations[0]
        //                            .nextContinuationData.continuation
        // Continuation response shape: continuationContents.sectionListContinuation.continuations[…]
        let paths: [[String]] = [
            ["contents", "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
             "content", "sectionListRenderer", "continuations", "0",
             "nextContinuationData", "continuation"],
            ["continuationContents", "sectionListContinuation", "continuations", "0",
             "nextContinuationData", "continuation"],
            ["contents", "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
             "content", "sectionListRenderer", "continuations", "0",
             "reloadContinuationData", "continuation"],
        ]
        for path in paths {
            if let token = Parsing.dig(body, path) as? String, !token.isEmpty {
                return token
            }
        }
        return nil
    }

    /// One page of search results. `continuation` is non-nil when the
    /// server returned a fetch-more token; pass it to `searchContinue`
    /// to load the next chunk.
    struct SearchPage: Sendable {
        let items: [MediaItem]
        let continuation: String?
    }

    /// Thin wrapper preserving the legacy flat-list return shape for
    /// callers that don't need continuation tokens.
    func search(query: String, filter: SearchView.SearchFilter) async throws -> [MediaItem] {
        try await searchPaged(query: query, filter: filter).items
    }

    func searchPaged(query: String, filter: SearchView.SearchFilter) async throws -> SearchPage {
        var payload: [String: Any] = ["query": query]
        if let token = filter.paramsToken { payload["params"] = token }
        let body = try await postRaw(.search, body: payload)
        let shelves = Parsing.array(body, "contents",
            "tabbedSearchResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []

        let results = Self.parseSearchShelves(shelves)
        let nextToken = Self.findSearchContinuationToken(in: shelves)

        Log.innertube.debug("search filter=\(String(describing: filter), privacy: .public) shelves=\(shelves.count) results=\(results.count) hasMore=\(nextToken != nil)")
        if results.isEmpty, !shelves.isEmpty {
            for (i, shelf) in shelves.enumerated() {
                Log.innertube.debug("  search shelf[\(i)] keys=\(Array(shelf.keys), privacy: .public)")
            }
        }
        return SearchPage(items: results, continuation: nextToken)
    }

    /// Fetch the next page of search results. We synthesize a
    /// one-element shelf array from the continuation envelope so the
    /// same parser drives both initial and continuation paths.
    func searchContinue(token: String) async throws -> SearchPage {
        let body = try await postRaw(.search, body: ["continuation": token])
        var shelves: [[String: Any]] = []
        if let cont = Parsing.dig(body, ["continuationContents", "musicShelfContinuation"]) as? [String: Any] {
            shelves.append(["musicShelfRenderer": cont])
        } else if let cont = Parsing.dig(body, ["continuationContents", "gridContinuation"]) as? [String: Any] {
            shelves.append(["gridRenderer": cont])
        } else if let cont = Parsing.dig(body, ["continuationContents", "musicPlaylistShelfContinuation"]) as? [String: Any] {
            shelves.append(["musicShelfRenderer": cont])
        }

        let results = Self.parseSearchShelves(shelves)
        let nextToken = Self.findSearchContinuationToken(in: shelves)
        Log.innertube.debug("search continuation count=\(results.count) hasMore=\(nextToken != nil)")
        return SearchPage(items: results, continuation: nextToken)
    }

    static func findSearchContinuationToken(in shelves: [[String: Any]]) -> String? {
        let rendererKeys = ["musicShelfRenderer", "gridRenderer", "musicPlaylistShelfRenderer"]
        for shelf in shelves {
            for key in rendererKeys {
                guard let r = shelf[key] as? [String: Any] else { continue }
                if let s = Parsing.dig(r, ["continuations", "0", "nextContinuationData", "continuation"]) as? String, !s.isEmpty {
                    return s
                }
                if let s = Parsing.dig(r, ["continuations", "0", "reloadContinuationData", "continuation"]) as? String, !s.isEmpty {
                    return s
                }
            }
        }
        return nil
    }

    /// Walk a list of search shelves and flatten to a MediaItem list.
    static func parseSearchShelves(_ shelves: [[String: Any]]) -> [MediaItem] {
        let flat: [MediaItem] = shelves.flatMap { shelf -> [MediaItem] in
            if let items = Parsing.array(shelf, "musicShelfRenderer", "contents") {
                return items.compactMap(Self.parseListItem)
            }
            if let items = Parsing.array(shelf, "musicCardShelfRenderer", "contents") {
                return items.compactMap(Self.parseListItem)
            }
            if let items = Parsing.array(shelf, "gridRenderer", "items") {
                return items.compactMap(Self.parseTwoRowItem)
            }
            if let items = Parsing.array(shelf, "musicCarouselShelfRenderer", "contents") {
                return items.compactMap(Self.parseTwoRowItem)
            }
            return []
        }
        // Under "All" the top-result card repeats the Songs shelf's
        // first row: duplicate ids broke row identity and pinned
        // keyboard focus to the first occurrence.
        var seen = Set<String>()
        return flat.filter { seen.insert($0.kind.rawValue + ":" + $0.id).inserted }
    }

    /// A fully-paged Library section. `truncated` is true when the
    /// server still had rows past what this holds — a page/row cap
    /// stopped the paging or a continuation request failed — so the
    /// UI can say "Showing first N" instead of passing a partial list
    /// off as complete.
    struct LibraryPage: Sendable {
        let items: [MediaItem]
        let truncated: Bool
    }

    /// Thin wrapper preserving the flat-list return shape for callers
    /// that don't surface truncation.
    func library(section: LibraryView.Section) async throws -> [MediaItem] {
        try await libraryPage(section: section).items
    }

    /// Library contents — InnerTube `/browse` with the section-specific
    /// browseId. Auth comes from the SAPISID cookie set by the WebView
    /// sign-in (Kaset's pattern). Walks the response with a deep scanner
    /// because signed-in library responses wrap shelves in
    /// `itemSectionRenderer` while anonymous browse uses
    /// `musicShelfRenderer` / `musicCarouselShelfRenderer` directly.
    func libraryPage(section: LibraryView.Section) async throws -> LibraryPage {
        let browseId: String
        switch section {
        case .liked:     browseId = BrowseID.likedSongs
        case .playlists: browseId = BrowseID.likedPlaylists
        case .albums:    browseId = BrowseID.libraryAlbums
        case .artists:   browseId = BrowseID.librarySubscriptions
        case .podcasts:  browseId = BrowseID.libraryPodcasts
        case .history:   browseId = BrowseID.history
        }
        Log.innertube.debug("library section=\(String(describing: section), privacy: .public) browseId=\(browseId, privacy: .public)")
        let body = try await postRaw(.browse, body: ["browseId": browseId])
        var results = Self.scanForMediaItems(body)
        // Page the shelf. YT returns ~25–100 rows per page; a 600-song
        // Liked list was silently truncated to page one, and Play /
        // Shuffle queued only what had loaded.
        var token = Self.findShelfContinuation(in: body)
        var pages = 0
        var truncated = false
        while let t = token {
            if pages >= Self.libraryMaxPages || results.count >= Self.libraryRowCap {
                // Cap reached with rows still on the server — say so
                // instead of returning a short list as if complete.
                truncated = true
                Log.innertube.info("library section=\(String(describing: section), privacy: .public) paging capped at pages=\(pages + 1) rows=\(results.count); more available")
                break
            }
            pages += 1
            do {
                let resp = try await postRaw(.browse, body: ["continuation": t])
                let more = Self.scanForMediaItems(resp)
                if more.isEmpty { break }
                results.append(contentsOf: more)
                token = Self.findShelfContinuation(in: resp)
            } catch {
                Log.innertube.error("library continuation \(pages) failed: \(error.localizedDescription, privacy: .public)")
                truncated = true
                break
            }
        }
        // Section pages carry "suggestions" / "recent activity" shelves
        // of other kinds; keep only what the section is FOR.
        if let kinds = Self.expectedKinds(for: section) {
            results = results.filter { kinds.contains($0.kind) }
        }
        var seen = Set<String>()
        results = results.filter { seen.insert($0.id).inserted }
        Log.innertube.debug("library section=\(String(describing: section), privacy: .public) results=\(results.count) pages=\(pages + 1) truncated=\(truncated)")
        return LibraryPage(items: results, truncated: truncated)
    }

    private static let libraryMaxPages = 20
    private static let libraryRowCap = 2000
    private static let detailMaxPages = 10

    private static func expectedKinds(for section: LibraryView.Section) -> Set<MediaItem.Kind>? {
        switch section {
        case .liked:     return [.song]
        case .playlists: return [.playlist]
        case .albums:    return [.album]
        case .artists:   return [.artist]
        case .podcasts:  return [.podcast, .episode]
        case .history:   return nil
        }
    }

    /// First `nextContinuationData.continuation` anywhere in a browse
    /// body — the initial shelf or a `continuationContents.*Continuation`
    /// envelope. Library pages carry one paged shelf; a deep walk avoids
    /// enumerating every wrapper shape. Never a reload token.
    private static func findShelfContinuation(in body: Any?) -> String? {
        var found: String? = nil
        func walk(_ node: Any?) {
            if found != nil { return }
            if let dict = node as? [String: Any] {
                if let next = dict["nextContinuationData"] as? [String: Any],
                   let token = next["continuation"] as? String, !token.isEmpty {
                    found = token
                    return
                }
                for (_, v) in dict {
                    walk(v)
                    if found != nil { return }
                }
            } else if let arr = node as? [Any] {
                for v in arr {
                    walk(v)
                    if found != nil { return }
                }
            }
        }
        walk(body)
        return found
    }

    /// Deep-walk a response tree pulling any `musicResponsiveListItemRenderer`
    /// or `musicTwoRowItemRenderer` we encounter. Used for library responses
    /// where the shelf shape varies (itemSectionRenderer wrapping
    /// musicShelfRenderer, gridRenderer, etc.) and we don't want to enumerate
    /// every wrapper combination by hand.
    private static func scanForMediaItems(_ root: Any?) -> [MediaItem] {
        var out: [MediaItem] = []
        func walk(_ node: Any?) {
            if let dict = node as? [String: Any] {
                if dict["musicResponsiveListItemRenderer"] != nil,
                   let item = parseListItem(dict) {
                    out.append(item)
                    return  // don't recurse into a known item — its kids are columns/menus, not more items
                }
                if dict["musicTwoRowItemRenderer"] != nil,
                   let item = parseTwoRowItem(dict) {
                    out.append(item)
                    return
                }
                for (_, v) in dict { walk(v) }
            } else if let arr = node as? [Any] {
                for v in arr { walk(v) }
            }
        }
        walk(root)
        return out
    }

    // MARK: - YouTube Data API v3 (Bearer auth, googleapis.com)

    private static let dataAPIBase = URL(string: "https://www.googleapis.com/youtube/v3/")!

    /// Hard cap on Data-API pagination. 50 per page × 8 pages = 400 items —
    /// enough headroom for power users without runaway requests on accounts
    /// with thousands of subscriptions.
    private static let dataAPIMaxPages = 8

    /// Walk Data API v3 pages via `pageToken` until exhausted or until the
    /// safety cap. Each yielded page is the raw response dict.
    private func dataAPIPaginated(_ path: String, params: [String: String]) async throws -> [[String: Any]] {
        var pages: [[String: Any]] = []
        var nextPageToken: String? = nil
        var iterations = 0
        repeat {
            var perPage = params
            if let tok = nextPageToken { perPage["pageToken"] = tok }
            let resp = try await dataAPI(path, params: perPage)
            pages.append(resp)
            nextPageToken = (resp["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            iterations += 1
        } while nextPageToken != nil && iterations < Self.dataAPIMaxPages
        if nextPageToken != nil {
            Log.innertube.debug("dataAPI(\(path, privacy: .public)) hit page cap (\(Self.dataAPIMaxPages)); more available")
        }
        return pages
    }

    /// `playlistItems?playlistId=LL` — "LL" is YouTube's special ID for the
    /// signed-in user's Liked Videos playlist.
    private func likedVideos() async throws -> [MediaItem] {
        let pages = try await dataAPIPaginated("playlistItems", params: [
            "playlistId": "LL",
            "part": "snippet,contentDetails",
            "maxResults": "50",
        ])
        return pages.flatMap { resp -> [MediaItem] in
            let items = (resp["items"] as? [[String: Any]]) ?? []
            return items.compactMap { item -> MediaItem? in
                let snippet = item["snippet"] as? [String: Any]
                let videoId = (item["contentDetails"] as? [String: Any])?["videoId"] as? String
                    ?? (snippet?["resourceId"] as? [String: Any])?["videoId"] as? String
                guard let videoId else { return nil }
                let title = snippet?["title"] as? String ?? ""
                let artist = snippet?["videoOwnerChannelTitle"] as? String
                    ?? snippet?["channelTitle"] as? String ?? ""
                let thumb = Self.dataAPIThumbnail(snippet?["thumbnails"] as? [String: Any])
                return MediaItem(id: videoId, kind: .song, title: title, subtitle: artist, thumbnailURL: thumb)
            }
        }
    }

    private func myPlaylists() async throws -> [MediaItem] {
        let pages = try await dataAPIPaginated("playlists", params: [
            "mine": "true",
            "part": "snippet,contentDetails",
            "maxResults": "50",
        ])
        return pages.flatMap { resp -> [MediaItem] in
            let items = (resp["items"] as? [[String: Any]]) ?? []
            return items.compactMap { item -> MediaItem? in
                guard let id = item["id"] as? String else { return nil }
                let snippet = item["snippet"] as? [String: Any]
                let title = snippet?["title"] as? String ?? ""
                let count = (item["contentDetails"] as? [String: Any])?["itemCount"] as? Int ?? 0
                let subtitle = count > 0 ? "\(count) tracks" : (snippet?["channelTitle"] as? String ?? "")
                let thumb = Self.dataAPIThumbnail(snippet?["thumbnails"] as? [String: Any])
                return MediaItem(id: id, kind: .playlist, title: title, subtitle: subtitle, thumbnailURL: thumb)
            }
        }
    }

    private func mySubscriptions() async throws -> [MediaItem] {
        let pages = try await dataAPIPaginated("subscriptions", params: [
            "mine": "true",
            "part": "snippet",
            "maxResults": "50",
        ])
        return pages.flatMap { resp -> [MediaItem] in
            let items = (resp["items"] as? [[String: Any]]) ?? []
            return items.compactMap { item -> MediaItem? in
                let snippet = item["snippet"] as? [String: Any]
                let resourceId = snippet?["resourceId"] as? [String: Any]
                guard let channelId = resourceId?["channelId"] as? String else { return nil }
                let title = snippet?["title"] as? String ?? ""
                let thumb = Self.dataAPIThumbnail(snippet?["thumbnails"] as? [String: Any])
                return MediaItem(id: channelId, kind: .artist, title: title, subtitle: "Channel", thumbnailURL: thumb)
            }
        }
    }

    /// Pick the highest-resolution thumbnail from Data API v3's
    /// `{default, medium, high, standard, maxres}` shape.
    private static func dataAPIThumbnail(_ thumbs: [String: Any]?) -> URL? {
        guard let thumbs else { return nil }
        for key in ["maxres", "standard", "high", "medium", "default"] {
            if let t = thumbs[key] as? [String: Any], let url = t["url"] as? String, let u = URL(string: url) {
                return u
            }
        }
        return nil
    }

    /// GET against `googleapis.com/youtube/v3/<path>` with the OAuth
    /// Bearer token. Throws `needsReauth` on 401/403 so the UI can
    /// re-present the sign-in sheet.
    private func dataAPI(_ path: String, params: [String: String]) async throws -> [String: Any] {
        guard let token = await OAuthDeviceFlow.refreshIfNeeded() else {
            throw InnerTubeError.needsReauth
        }
        // Construct URL safely: both `URLComponents(url:resolvingAgainstBaseURL:)`
        // and `components.url` return optionals. A malformed `path` parameter
        // (caller bug) shouldn't crash — surface as a decoding error instead.
        guard
            var components = URLComponents(url: Self.dataAPIBase.appendingPathComponent(path),
                                           resolvingAgainstBaseURL: false)
        else { throw InnerTubeError.decoding }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw InnerTubeError.decoding }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        Log.innertube.debug("→ data/v3/\(path, privacy: .public) auth=bearer")

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            let preview = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
            Log.innertube.error("← data/v3/\(path, privacy: .public) status=\(status) body=\(preview, privacy: .private(mask: .hash))")
            if status == 401 || status == 403 { throw InnerTubeError.needsReauth }
            throw InnerTubeError.http(status)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InnerTubeError.decoding
        }
        return json
    }

    /// Resolve a browseId (album / podcast / artist) into a playable
    /// `(videoId?, playlistId?)` tuple. The page auto-plays when we
    /// navigate to `/watch` with at least one of those set.
    ///
    /// Strategy:
    ///  1. Album/podcast pages expose the audio playlist via
    ///     `microformat.microformatDataRenderer.urlCanonical` =
    ///     `https://music.youtube.com/playlist?list=<id>`. That's the
    ///     canonical "play this thing" pointer — most reliable.
    ///  2. Some artist pages instead carry a `/watch?v=&list=` canonical.
    ///  3. As a last resort, recursive watchEndpoint scan. This is fragile
    ///     because the first match might be a sidebar suggestion rather
    ///     than the page's primary content; we use it only when 1+2 fail.
    func playable(forBrowseId browseId: String) async throws -> (videoId: String?, playlistId: String?)? {
        let body = try await postRaw(.browse, body: ["browseId": browseId])

        // 1+2: microformat urlCanonical
        if let canonical = Parsing.string(body, "microformat", "microformatDataRenderer", "urlCanonical"),
           let url = URLComponents(string: canonical) {
            let v = url.queryItems?.first(where: { $0.name == "v" })?.value
            let pl = url.queryItems?.first(where: { $0.name == "list" })?.value
            if v != nil || pl != nil {
                return (v, pl)
            }
        }

        // 3: recursive fallback
        if let (vid, pid) = Self.findFirstWatchEndpoint(body) {
            return (vid, pid)
        }
        return nil
    }

    /// Strip a leading "VL" — that's the YT Music convention for a
    /// playlist *browse* ID (`VL<playlistId>`); the playable ID is the
    /// suffix.
    private static func unwrapVLPrefix(_ id: String) -> String {
        id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
    }

    private static func findFirstWatchEndpoint(_ root: Any?) -> (String, String?)? {
        if let dict = root as? [String: Any] {
            if let watch = dict["watchEndpoint"] as? [String: Any],
               let vid = watch["videoId"] as? String {
                return (vid, watch["playlistId"] as? String)
            }
            for (_, v) in dict {
                if let r = findFirstWatchEndpoint(v) { return r }
            }
        }
        if let arr = root as? [Any] {
            for v in arr {
                if let r = findFirstWatchEndpoint(v) { return r }
            }
        }
        return nil
    }

    /// Result of `/next`: queued tracks + browseIds for the lyrics and
    /// related-songs tabs (which we fetch separately on demand) + the
    /// initial like state for the playing video + the Tune chip cloud
    /// (when YT included one for this watch context).
    struct NextResponse: Sendable {
        let queue: [MediaItem]
        let lyricsBrowseId: String?
        let relatedBrowseId: String?
        let likeStatus: LikeStatus
        /// Tune chips ("All", "Familiar", "Discover", "Popular", "Party",
        /// "Telugu", "2010s", …) parsed from the queue's `subHeaderChipCloud`.
        /// Empty when YT didn't return one (some contexts — explicit
        /// playlists, podcasts — don't have a Tune affordance).
        let chips: [QueueChip]
    }

    enum LikeStatus: String, Sendable {
        case like = "LIKE"
        case dislike = "DISLIKE"
        case indifferent = "INDIFFERENT"
    }

    /// One chip in YT Music's "Tune" cloud above the Up Next list.
    /// Each chip carries the protobuf-encoded `params` and the auto-radio
    /// `playlistId` (e.g. `RDATiYv2_7JUP7bIFg` for the Familiar variant of
    /// videoId `v2_7JUP7bIFg`) needed to re-issue `/next` and pull the
    /// queue variant the chip represents.
    ///
    /// Tokens are *per-watch-context* — the params encode the source
    /// videoId — so we don't hardcode them. Riff parses them out of every
    /// `/next` response and offers whichever chips YT served us.
    struct QueueChip: Sendable, Equatable, Identifiable, Hashable {
        /// YT's `uniqueId` (e.g. `"All"`, `"Familiar"`, `"Telugu"`).
        let id: String
        /// User-facing label (`text.runs[0].text`).
        let label: String
        /// Auto-radio playlistId for this variant; pass to `/next`.
        let playlistId: String
        /// Protobuf-encoded `params` for this variant; pass to `/next`.
        let params: String
        /// True when YT marks this chip as currently active in the
        /// response — i.e. the queue we just got back is the one this
        /// chip would produce.
        let isSelected: Bool
    }

    func nextQueue(videoId: String, playlistId: String?, chip: QueueChip? = nil) async throws -> NextResponse {
        var payload: [String: Any] = ["videoId": videoId]
        // When a chip is supplied, its (playlistId, params) override the
        // caller's playlistId — the chip's playlistId is the radio
        // variant (e.g. RDATiY...) that produces the desired queue.
        if let chip {
            payload["playlistId"] = chip.playlistId
            payload["params"] = chip.params
        } else if let pid = playlistId {
            payload["playlistId"] = pid
        }
        let body = try await postRaw(.next, body: payload)

        let queueItems = Parsing.array(body, "contents",
            "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer",
            "watchNextTabbedResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "musicQueueRenderer", "content", "playlistPanelRenderer",
            "contents") ?? []
        let queue: [MediaItem] = queueItems.compactMap { item -> MediaItem? in
            guard let r = item["playlistPanelVideoRenderer"] as? [String: Any] else { return nil }
            let videoId = Parsing.string(r, "videoId") ?? ""
            guard !videoId.isEmpty else { return nil }
            let title = Parsing.runs(r, "title") ?? ""
            let subtitle = Parsing.runs(r, "longBylineText") ?? Parsing.runs(r, "shortBylineText") ?? ""
            let thumb = Parsing.thumbnailURL(r["thumbnail"] as? [String: Any])
            // Mine the byline runs for artist/album browseEndpoints.
            // longBylineText runs are usually [artist, " • ", album] with
            // both artist and album carrying their own navigationEndpoint.
            let (albumId, artistId) = Self.extractIdsFromQueueRow(r)
            return MediaItem(id: videoId, kind: .song, title: title, subtitle: subtitle,
                             thumbnailURL: thumb, albumId: albumId, artistId: artistId)
        }

        // Tabs[1].endpoint.browseEndpoint.browseId → lyrics
        // Tabs[2].endpoint.browseEndpoint.browseId → related
        // The order is conventional but not guaranteed — match by tab title.
        let tabs = Parsing.array(body, "contents",
            "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer",
            "watchNextTabbedResultsRenderer", "tabs") ?? []
        var lyricsId: String?
        var relatedId: String?
        for tab in tabs {
            guard let renderer = tab["tabRenderer"] as? [String: Any] else { continue }
            let title = (renderer["title"] as? String)?.lowercased() ?? ""
            let browseId = Parsing.string(renderer, "endpoint", "browseEndpoint", "browseId")
            if title.contains("lyric"), browseId != nil { lyricsId = browseId }
            else if title.contains("related"), browseId != nil { relatedId = browseId }
        }
        // likeStatus lives on the playerOverlays' likeButtonRenderer.
        // Path: playerOverlays.playerOverlayRenderer.actions[].likeButtonRenderer.likeStatus
        var likeStatus: LikeStatus = .indifferent
        let actions = Parsing.array(body, "playerOverlays", "playerOverlayRenderer", "actions") ?? []
        for action in actions {
            if let renderer = action["likeButtonRenderer"] as? [String: Any],
               let status = renderer["likeStatus"] as? String,
               let parsed = LikeStatus(rawValue: status) {
                likeStatus = parsed
                break
            }
        }
        // Tune chip cloud lives below the queue panel:
        //   tabs[0].tabRenderer.content.musicQueueRenderer
        //     .subHeaderChipCloud.chipCloudRenderer.chips[].chipCloudChipRenderer
        // Each chip's navigationEndpoint.queueUpdateCommand
        //   .fetchContentsCommand.watchEndpoint carries the (playlistId,
        // params) needed to re-fetch /next as the chip's variant.
        let chipNodes = Parsing.array(body, "contents",
            "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer",
            "watchNextTabbedResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "musicQueueRenderer", "subHeaderChipCloud",
            "chipCloudRenderer", "chips") ?? []
        let chips: [QueueChip] = chipNodes.compactMap { node in
            guard let r = node["chipCloudChipRenderer"] as? [String: Any] else { return nil }
            let label = Parsing.runs(r, "text") ?? ""
            let id = (r["uniqueId"] as? String) ?? label
            let watch = Parsing.dig(r, ["navigationEndpoint", "queueUpdateCommand",
                                        "fetchContentsCommand", "watchEndpoint"]) as? [String: Any]
            guard let pid = watch?["playlistId"] as? String,
                  let params = watch?["params"] as? String,
                  !pid.isEmpty, !params.isEmpty else { return nil }
            let selected = (r["isSelected"] as? Bool) ?? false
            return QueueChip(id: id, label: label, playlistId: pid, params: params, isSelected: selected)
        }
        return NextResponse(queue: queue, lyricsBrowseId: lyricsId, relatedBrowseId: relatedId, likeStatus: likeStatus, chips: chips)
    }

    struct LyricLine: Sendable, Identifiable, Hashable {
        let id: Int
        let text: String
        /// Start time of the line in milliseconds, or nil when timing
        /// data isn't available.
        let startMs: Int?
    }

    struct LyricsResult: Sendable {
        let lines: [LyricLine]
        /// True when YT returned a synced (time-tagged) lyric stream.
        let timed: Bool
    }

    /// Fetch lyrics for a track (browseId comes from `/next`'s lyrics tab).
    /// Returns the structured form when synced lyrics are available — each
    /// line carries a `startMs` so the UI can highlight + auto-scroll —
    /// otherwise plain text split by line breaks.
    func lyrics(browseId: String) async throws -> LyricsResult? {
        let body = try await postRaw(.browse, body: ["browseId": browseId])

        // 1. Synced (timed) lyrics — newer response shape.
        // contents.elementRenderer.newElement.type.componentType.model
        //   .timedLyricsModel.lyricsData.timedLyricsData[]
        if let timed = Parsing.dig(body, ["contents", "elementRenderer", "newElement", "type",
                                          "componentType", "model", "timedLyricsModel",
                                          "lyricsData", "timedLyricsData"]) as? [[String: Any]] {
            let lines: [LyricLine] = timed.enumerated().compactMap { idx, item in
                let text = (item["lyricLine"] as? String) ?? ""
                let startMs = ((item["cueRange"] as? [String: Any])?["startTimeMilliseconds"] as? String).flatMap(Int.init)
                guard !text.isEmpty else { return nil }
                return LyricLine(id: idx, text: text, startMs: startMs)
            }
            if !lines.isEmpty {
                return LyricsResult(lines: lines, timed: lines.contains { $0.startMs != nil })
            }
        }

        // 2. Plain-text lyrics — older shape.
        let shelf = Parsing.dig(body, ["contents", "sectionListRenderer", "contents", "0",
                                       "musicDescriptionShelfRenderer"]) as? [String: Any]
        let plain: String?
        if let text = Parsing.runs(shelf, "description", separator: "") {
            plain = text
        } else if let runs = Parsing.dig(shelf, ["description", "runs"]) as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            plain = joined.isEmpty ? nil : joined
        } else {
            plain = nil
        }
        guard let plain else { return nil }
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { LyricLine(id: $0.offset, text: String($0.element), startMs: nil) }
        return LyricsResult(lines: lines, timed: false)
    }

    /// Fetch related songs for a given related browseId.
    func related(browseId: String) async throws -> [MediaItem] {
        let body = try await postRaw(.browse, body: ["browseId": browseId])
        return Self.scanForMediaItems(body)
    }

    /// Related tab in ONE `/browse` round trip: the flat song list
    /// (`related(browseId:)`'s projection) and the titled shelves
    /// (`parseRelatedSections`' projection) parsed from the same
    /// body. Callers needing both should use this — issuing two
    /// separate fetches POSTs the same browseId twice. Both
    /// projections fail together, which is fine: same endpoint, same
    /// body.
    func relatedPage(browseId: String) async throws -> (items: [MediaItem], sections: [HomeSection]) {
        let body = try await postRaw(.browse, body: ["browseId": browseId])
        return (items: Self.scanForMediaItems(body), sections: Self.parseRelatedSections(body))
    }

    /// Pull `musicCarouselShelfRenderer` (and friends) shelves out of
    /// a Related-tab browse response — the titled shelves YT actually
    /// shipped: "Other versions" / "Other performances" (live,
    /// acoustic, cover variants of the current track), "Recommended
    /// tracks", "More from <Artist>", "You might also like", etc.
    /// Each shelf is a `musicCarouselShelfRenderer` at
    /// `…sectionListRenderer.contents[]`; reuses `parseHomeShelf` so
    /// the visual treatment matches Home rails. Returns an empty
    /// array when YT didn't include sectioned shelves (some watch
    /// contexts return a flat song list only). Walks both the
    /// single-column and two-column layouts so we don't silently drop
    /// shelves on the newer desktop response shape — same defense the
    /// album detail parser uses (see `detail(forBrowseId:)`).
    static func parseRelatedSections(_ body: [String: Any]) -> [HomeSection] {
        let singleCol = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        let twoCol = Parsing.array(body, "contents",
            "twoColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        // Plain `contents.sectionListRenderer.contents` — observed on some
        // related browse responses that skip the tabbed wrapper.
        let flat = Parsing.array(body, "contents",
            "sectionListRenderer", "contents") ?? []
        var seen = Set<String>()
        var sections: [HomeSection] = []
        for shelf in (singleCol + twoCol + flat) {
            guard let section = parseHomeShelf(shelf), !seen.contains(section.id) else { continue }
            seen.insert(section.id)
            sections.append(section)
        }
        return sections
    }

    /// Detail page for an album / playlist / podcast — header info plus
    /// tracklist. Same `/browse` endpoint with the corresponding browseId.
    /// `playlistId` (when known) is the playable playlist for the whole
    /// thing; the user can hit Play and we navigate /watch?list=<id>.
    struct DetailPage: Sendable {
        let title: String
        let subtitle: String
        /// Structured form of `subtitle` — preserves the per-run
        /// navigation endpoints YT Music ships, so the UI can render
        /// the artist segment as a tappable link to their page.
        /// Falls back to a single plain-text run when the response
        /// didn't carry runs (rare, but possible on legacy responses).
        let subtitleRuns: [AnnotatedRun]
        let artworkURL: URL?
        /// For albums/playlists: navigate /watch?list=<this> to play the
        /// whole thing. nil when not applicable (artist pages).
        let playablePlaylistId: String?
        let tracks: [MediaItem]
        /// Carousels shown below the tracklist — typically "Other
        /// versions", "More from <Artist>", "You might also like".
        /// Empty when YT didn't include them (some playlists, podcasts).
        /// Reuses `HomeSection` so the existing `HomeSectionRow` renderer
        /// can be dropped in unchanged.
        let relatedSections: [HomeSection]
        /// True when the tracklist continues server-side past `tracks`
        /// — the page/row cap stopped paging, the caller asked for
        /// fewer pages, or a continuation request failed. Lets the UI
        /// show "Showing first N" rather than presenting a partial
        /// list as complete. `var` with a default so the memberwise
        /// init keeps its existing shape for callers that build pages.
        var truncated: Bool = false
    }

    /// One segment of a styled-text run from InnerTube. When `browseId`
    /// is non-nil, that segment is a navigable link (currently only
    /// artist links are surfaced — album / playlist links could be
    /// added later as more places need them). Plain prose runs (e.g.
    /// the year, the " • " separators) leave `browseId` nil.
    struct AnnotatedRun: Sendable, Hashable {
        let text: String
        let browseId: String?
        let kind: MediaItem.Kind?
    }

    /// - parameter maxContinuationPages: cap on tracklist continuation
    ///   requests after the first page (nil = `detailMaxPages`). Pass 0
    ///   when only the header / related shelves / first page are needed
    ///   so the call stays a single round trip.
    func detail(forBrowseId browseId: String, maxContinuationPages: Int? = nil) async throws -> DetailPage {
        let body = try await postRaw(.browse, body: ["browseId": browseId])

        let header: [String: Any]? = Self.detailHeader(in: body)

        let title = Parsing.runs(header, "title") ?? ""
        // Album/playlist headers put the ARTIST in straplineTextOne
        // (with its own browse endpoint) and only "Album • 2024" in
        // subtitle. The old code preferred subtitle and dropped the
        // strapline whenever subtitle existed, so every album showed
        // a bare "Album" line and blank track-row artists. Combine
        // both, strapline first, so the artist run survives and
        // renders; DetailView's albumArtistFallback then backfills
        // blank track rows from the first artist run.
        let straplineRuns = (Parsing.dig(header, ["straplineTextOne", "runs"]) as? [[String: Any]]) ?? []
        let plainSubtitleRuns = (Parsing.dig(header, ["subtitle", "runs"]) as? [[String: Any]]) ?? []
        var rawRuns: [[String: Any]] = straplineRuns
        if !straplineRuns.isEmpty && !plainSubtitleRuns.isEmpty {
            rawRuns.append(["text": " • "])
        }
        rawRuns.append(contentsOf: plainSubtitleRuns)
        let subtitle = (Parsing.runs(header, "straplineTextOne").map { $0 + " • " } ?? "")
            + (Parsing.runs(header, "subtitle") ?? "")
        let subtitleRuns: [AnnotatedRun] = rawRuns.map { run in
            let text = (run["text"] as? String) ?? ""
            if let endpoint = run["navigationEndpoint"] as? [String: Any],
               let resolved = Self.endpointToIdKind(endpoint) {
                return AnnotatedRun(text: text, browseId: resolved.0, kind: resolved.1)
            }
            return AnnotatedRun(text: text, browseId: nil, kind: nil)
        }
        let headerKeysList = Array(header?.keys ?? [:].keys)
        Log.innertube.debug("detail browseId=\(browseId, privacy: .public) headerKeys=\(headerKeysList, privacy: .public) subtitle=\"\(subtitle, privacy: .public)\" rawRunCount=\(rawRuns.count) parsedRuns=\(subtitleRuns.map { "[\($0.text)|\($0.browseId ?? "nil")]" }, privacy: .public)")
        let artworkContainer: [String: Any]? =
            (Parsing.dig(header, ["thumbnail", "croppedSquareThumbnailRenderer", "thumbnail"]) as? [String: Any])
            ?? (Parsing.dig(header, ["thumbnail", "musicThumbnailRenderer", "thumbnail"]) as? [String: Any])
        let artwork = Parsing.thumbnailURL(artworkContainer)

        // urlCanonical → /playlist?list=<id> for albums, /channel/<id> for artists.
        var playablePlaylistId: String?
        if let canonical = Parsing.string(body, "microformat", "microformatDataRenderer", "urlCanonical"),
           let comps = URLComponents(string: canonical) {
            playablePlaylistId = comps.queryItems?.first(where: { $0.name == "list" })?.value
        }

        // YT Music album / playlist pages return one of two layouts:
        //
        //   - **single-column**: every shelf in
        //     `singleColumnBrowseResultsRenderer.tabs[0]…sectionListRenderer.contents`
        //     — tracklist first, then "More from …" / "You might also like"
        //     after it.
        //
        //   - **two-column** (newer desktop layout): the tracklist is in
        //     `twoColumnBrowseResultsRenderer.secondaryContents…contents`
        //     and the related carousels live in a *separate* sibling at
        //     `twoColumnBrowseResultsRenderer.tabs[0]…sectionListRenderer.contents`.
        //     The first version of this code only looked at
        //     secondaryContents, so on two-column responses the related
        //     carousels were silently dropped.
        //
        // We collect both candidate trees and try each in turn for the
        // tracklist; afterwards we union the leftover shelves from both
        // (de-duped) as the related-sections pool.
        let singleColShelves = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        let twoColSecondaryShelves = Parsing.array(body, "contents",
            "twoColumnBrowseResultsRenderer", "secondaryContents",
            "sectionListRenderer", "contents") ?? []
        let twoColPrimaryShelves = Parsing.array(body, "contents",
            "twoColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        // Order matters: we look for the tracklist in this order. On
        // two-column responses the tracklist is in secondaryContents;
        // on single-column it's in the primary tab. Whichever matches
        // first wins.
        let allShelfTrees: [[[String: Any]]] = [
            singleColShelves,
            twoColSecondaryShelves,
            twoColPrimaryShelves,
        ]
        Log.innertube.debug("detail browseId=\(browseId, privacy: .public) shelfCounts: single=\(singleColShelves.count) twoColSec=\(twoColSecondaryShelves.count) twoColPri=\(twoColPrimaryShelves.count)")

        var tracks: [MediaItem] = []
        var tracklistTreeIndex: Int? = nil
        var tracklistShelfIndex: Int? = nil
        var tracklistContinuation: String? = nil
        outer: for (treeIdx, shelves) in allShelfTrees.enumerated() {
            for (i, shelf) in shelves.enumerated() {
                if let r = shelf["musicShelfRenderer"] as? [String: Any],
                   let contents = r["contents"] as? [[String: Any]] {
                    tracks = contents.compactMap(Self.parseListItem)
                    tracklistTreeIndex = treeIdx
                    tracklistShelfIndex = i
                    tracklistContinuation = Self.tracklistContinuationToken(shelf: r)
                    break outer
                }
                if let r = shelf["musicPlaylistShelfRenderer"] as? [String: Any],
                   let contents = r["contents"] as? [[String: Any]] {
                    tracks = contents.compactMap(Self.parseListItem)
                    tracklistTreeIndex = treeIdx
                    tracklistShelfIndex = i
                    tracklistContinuation = Self.tracklistContinuationToken(shelf: r)
                    break outer
                }
            }
        }
        // Long playlists page (~100 rows each): follow the shelf's
        // continuation so the page — and Play / Shuffle — hold the
        // WHOLE list, not the first page. The current shape carries
        // the token in a trailing `continuationItemRenderer` and
        // answers with `onResponseReceivedActions`; the legacy
        // `continuations` / `continuationContents` shape is still
        // accepted (see `parseTracklistContinuation`). Rows are
        // de-duped across pages (setVideoId, else videoId) so a stale
        // or looping token can't repeat a page; a page with nothing
        // new ends paging.
        let pageCap = max(0, maxContinuationPages ?? Self.detailMaxPages)
        var seenRowKeys = Set(tracks.map(Self.tracklistRowKey))
        var detailPages = 0
        var truncated = false
        while let token = tracklistContinuation {
            if detailPages >= pageCap || tracks.count >= Self.libraryRowCap {
                truncated = true
                if pageCap > 0 {
                    Log.innertube.info("detail browseId=\(browseId, privacy: .public) paging capped at pages=\(detailPages + 1) tracks=\(tracks.count); more available")
                }
                break
            }
            detailPages += 1
            let resp: [String: Any]
            do {
                resp = try await postRaw(.browse, body: ["continuation": token])
            } catch {
                Log.innertube.error("detail continuation \(detailPages) failed: \(error.localizedDescription, privacy: .public)")
                truncated = true
                break
            }
            guard let chunk = Self.parseTracklistContinuation(resp) else {
                Log.innertube.error("detail continuation \(detailPages): unrecognised envelope keys=\(Array(resp.keys), privacy: .public)")
                truncated = true
                break
            }
            let fresh = chunk.tracks.filter { seenRowKeys.insert(Self.tracklistRowKey($0)).inserted }
            if fresh.isEmpty { break }
            tracks.append(contentsOf: fresh)
            tracklistContinuation = chunk.continuation
        }
        if tracks.isEmpty {
            tracks = Self.scanForMediaItems(body)
        }
        // Final defense-in-depth: an album/playlist tracklist contains
        // song or episode rows by definition. Anything else (bleed-in
        // from recommendation carousels) gets filtered out so the page
        // never shows "Album • Other artist" rows where tracks should be.
        tracks = tracks.filter { $0.kind == .song || $0.kind == .episode }

        // Build the candidate "related shelves" pool: every shelf from
        // every tree, minus the tracklist shelf itself. We don't dedupe
        // by tree because the trees are disjoint paths in the response.
        let trackIds = Set(tracks.map(\.id))
        var candidateShelves: [[String: Any]] = []
        for (treeIdx, shelves) in allShelfTrees.enumerated() {
            for (i, shelf) in shelves.enumerated() {
                if treeIdx == tracklistTreeIndex && i == tracklistShelfIndex { continue }
                // The two-column header shelf (primary tab contents[0])
                // is the page header, never a related rail.
                if Self.isDetailHeaderShelf(shelf) { continue }
                candidateShelves.append(shelf)
            }
        }
        // Reuse parseHomeShelf — `musicCarouselShelfRenderer` (and friends)
        // are identical between Home rails and the bottom-of-album shelves.
        var seenSectionIds = Set<String>()
        let relatedSections: [HomeSection] = candidateShelves.compactMap { shelf in
            guard let section = Self.parseHomeShelf(shelf) else { return nil }
            // De-dupe by section title — when both two-column trees
            // include "You might also like" we only want it once.
            let key = section.title.lowercased()
            if !key.isEmpty {
                if seenSectionIds.contains(key) { return nil }
                seenSectionIds.insert(key)
            }
            // Drop items that are just the album's own tracks.
            let filtered = section.items.filter { !trackIds.contains($0.id) }
            guard !filtered.isEmpty else { return nil }
            return HomeSection(id: section.id, title: section.title, items: filtered)
        }
        Log.innertube.debug("detail browseId=\(browseId, privacy: .public) tracks=\(tracks.count) related=\(relatedSections.count) titles=\(relatedSections.map(\.title), privacy: .public)")

        return DetailPage(
            title: title,
            subtitle: subtitle,
            subtitleRuns: subtitleRuns.isEmpty
                ? [AnnotatedRun(text: subtitle, browseId: nil, kind: nil)]
                : subtitleRuns,
            artworkURL: artwork,
            playablePlaylistId: playablePlaylistId,
            tracks: tracks,
            relatedSections: relatedSections,
            truncated: truncated
        )
    }

    /// Detail-page header renderer. Lives at one of:
    ///   - `header.musicDetailHeaderRenderer` (older albums / playlists)
    ///   - `header.musicResponsiveHeaderRenderer` (newer single-column)
    ///   - `header.musicImmersiveHeaderRenderer` (artist pages)
    ///   - `header.musicEditablePlaylistDetailHeaderRenderer.header.*`
    ///     (owned playlists, older shape)
    ///   - **two-column layout** (current albums / playlists — no
    ///     top-level `header` at all): the first shelf of
    ///     `twoColumnBrowseResultsRenderer.tabs[0]…sectionListRenderer
    ///     .contents` is a `musicResponsiveHeaderRenderer`, or for owned
    ///     playlists `musicEditablePlaylistDetailHeaderRenderer.header
    ///     .musicResponsiveHeaderRenderer` (ytmusicapi resolves it the
    ///     same way).
    /// Top-level locations win; the two-column shelf is the fallback.
    static func detailHeader(in body: [String: Any]) -> [String: Any]? {
        for key in [RendererKeys.detailHeader, RendererKeys.responsiveHeader, RendererKeys.immersiveHeader] {
            if let header = Parsing.dig(body, ["header", key]) as? [String: Any] {
                return header
            }
        }
        for key in [RendererKeys.detailHeader, RendererKeys.responsiveHeader] {
            if let header = Parsing.dig(body, ["header", RendererKeys.editablePlaylistDetailHeader, "header", key]) as? [String: Any] {
                return header
            }
        }
        let primaryShelves = Parsing.array(body, "contents",
            "twoColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        guard let first = primaryShelves.first else { return nil }
        if let header = first[RendererKeys.responsiveHeader] as? [String: Any] {
            return header
        }
        if let header = Parsing.dig(first, [RendererKeys.editablePlaylistDetailHeader, "header", RendererKeys.responsiveHeader]) as? [String: Any] {
            return header
        }
        return nil
    }

    /// True for a shelf that is a detail-page header (the two-column
    /// layout ships the header as primary-tab `contents[0]`), so it is
    /// never offered as a related rail.
    static func isDetailHeaderShelf(_ shelf: [String: Any]) -> Bool {
        shelf[RendererKeys.responsiveHeader] != nil
            || shelf[RendererKeys.editablePlaylistDetailHeader] != nil
            || shelf[RendererKeys.detailHeader] != nil
    }

    /// Token of a trailing `continuationItemRenderer` in a row list —
    /// how current responses page a tracklist shelf (and each appended
    /// continuation chunk).
    static func trailingContinuationToken(in items: [[String: Any]]) -> String? {
        for item in items.reversed() {
            guard let renderer = item["continuationItemRenderer"] as? [String: Any] else { continue }
            if let token = Parsing.dig(renderer, ["continuationEndpoint", "continuationCommand", "token"]) as? String,
               !token.isEmpty {
                return token
            }
        }
        return nil
    }

    /// Next-page token for a tracklist shelf (`musicShelfRenderer` /
    /// `musicPlaylistShelfRenderer`, or a legacy `*Continuation`
    /// envelope): the trailing `continuationItemRenderer` first, then
    /// the legacy `continuations[0].nextContinuationData`. Only the
    /// shelf's own token — never a deep walk, which would pick up
    /// `secondaryContents.sectionListRenderer`'s carousel token.
    static func tracklistContinuationToken(shelf: [String: Any]) -> String? {
        if let contents = shelf["contents"] as? [[String: Any]],
           let token = trailingContinuationToken(in: contents) {
            return token
        }
        if let token = Parsing.dig(shelf, ["continuations", "0", "nextContinuationData", "continuation"]) as? String,
           !token.isEmpty {
            return token
        }
        return nil
    }

    /// Rows + next token from one tracklist continuation response.
    /// Accepts the current envelope
    /// (`onResponseReceivedActions[*].appendContinuationItemsAction
    /// .continuationItems`, token in the trailing
    /// `continuationItemRenderer`) and the legacy one
    /// (`continuationContents.musicPlaylistShelfContinuation` /
    /// `musicShelfContinuation`). nil when neither is present.
    static func parseTracklistContinuation(_ resp: [String: Any]) -> (tracks: [MediaItem], continuation: String?)? {
        if let actions = resp["onResponseReceivedActions"] as? [[String: Any]] {
            var rows: [[String: Any]] = []
            var matched = false
            for action in actions {
                guard let items = Parsing.dig(action, ["appendContinuationItemsAction", "continuationItems"]) as? [[String: Any]] else { continue }
                matched = true
                rows.append(contentsOf: items)
            }
            if matched {
                return (tracks: rows.compactMap(Self.parseListItem),
                        continuation: Self.trailingContinuationToken(in: rows))
            }
        }
        let legacy = (Parsing.dig(resp, ["continuationContents", "musicPlaylistShelfContinuation"]) as? [String: Any])
            ?? (Parsing.dig(resp, ["continuationContents", "musicShelfContinuation"]) as? [String: Any])
        if let legacy, let contents = legacy["contents"] as? [[String: Any]] {
            return (tracks: contents.compactMap(Self.parseListItem),
                    continuation: Self.tracklistContinuationToken(shelf: legacy))
        }
        return nil
    }

    /// Identity of a tracklist row for cross-page de-dupe. Playlists
    /// may hold the same video twice — `setVideoId` tells those apart.
    private static func tracklistRowKey(_ item: MediaItem) -> String {
        item.setVideoId ?? item.id
    }

    /// Detail for a YT Music playlist (just delegates — playlist browseIds
    /// are typically `VL<playlistId>`; the caller should already have
    /// VL-stripped if needed).
    func playlistDetail(playlistId: String, maxContinuationPages: Int? = nil) async throws -> DetailPage {
        // Playlist browseId is "VL" + playlistId.
        try await detail(forBrowseId: "VL" + playlistId, maxContinuationPages: maxContinuationPages)
    }

    /// Signed-in account chrome for the Settings "Account" card.
    struct AccountInfo: Sendable {
        let name: String?
        let handle: String?
    }

    /// Fetch the signed-in account's display name + handle via
    /// InnerTube's account_menu — the one account source that works
    /// with SAPISIDHASH (cookie) auth. (The OAuth userinfo path only
    /// works for Device-Flow sign-ins, so cookie-import sessions had
    /// nothing to show.) Returns nil when anonymous or on parse
    /// failure; the Settings card falls back to a generic "Signed
    /// in" line.
    func fetchAccountInfo() async -> AccountInfo? {
        guard let body = try? await postRaw(.accountMenu, body: [:]) else { return nil }
        let header = Parsing.dig(body, [
            "actions", "0", "openPopupAction", "popup",
            "multiPageMenuRenderer", "header", "activeAccountHeaderRenderer",
        ]) as? [String: Any]
        guard let header else { return nil }
        let name = Parsing.runs(header, "accountName")
        let handle = Parsing.runs(header, "channelHandle")
        if name == nil && handle == nil { return nil }
        return AccountInfo(name: name, handle: handle)
    }

    /// Tri-state session liveness. YouTube can invalidate a session
    /// server-side while the cookies remain and their expiry dates sit
    /// months out — Riff then looks signed in while every call is
    /// answered anonymously (tiny generic Home, empty Library).
    ///   - true:  account_menu carries an active-account header
    ///   - false: request succeeded but came back anonymous-shaped
    ///   - nil:   transport/HTTP failure — UNKNOWN, never treat as dead
    func sessionLiveness() async -> Bool? {
        let body: [String: Any]
        do { body = try await postRaw(.accountMenu, body: [:]) } catch { return nil }
        let header = Parsing.dig(body, [
            "actions", "0", "openPopupAction", "popup",
            "multiPageMenuRenderer", "header", "activeAccountHeaderRenderer",
        ]) as? [String: Any]
        return header != nil
    }

    /// Like the given video. Requires SAPISID cookie auth — anonymous calls
    /// throw `needsReauth`.
    func like(videoId: String) async throws {
        _ = try await postRaw(.like, body: ["target": ["videoId": videoId]])
    }

    /// Thumbs-down. Unlike the local blocked-artists feature, this
    /// trains YT Music's server-side recommendations — the radio stops
    /// suggesting the track. Same endpoint family as like/removelike.
    func dislike(videoId: String) async throws {
        _ = try await postRaw(.dislike, body: ["target": ["videoId": videoId]])
    }

    /// Follow (subscribe) / unfollow an artist channel. Requires cookie
    /// auth; anonymous calls throw `needsReauth`.
    func setFollowing(channelId: String, follow: Bool) async throws {
        _ = try await postRaw(follow ? .subscribe : .unsubscribe, body: ["channelIds": [channelId]])
    }

    /// Completions for a partial search query — the strings YT Music's
    /// own search box shows as you type (includes typo corrections).
    /// Lightweight endpoint; called per keystroke (debounced by the
    /// caller). Returns plain suggestion strings in rank order.
    func searchSuggestions(query: String) async throws -> [String] {
        let body = try await postRaw(.searchSuggestions, body: ["input": query])
        let sections = Parsing.array(body, "contents") ?? []
        var out: [String] = []
        for section in sections {
            guard let renderer = section["searchSuggestionsSectionRenderer"] as? [String: Any],
                  let contents = renderer["contents"] as? [[String: Any]] else { continue }
            for entry in contents {
                // Plain text suggestions only — entries can also be
                // rich results (musicResponsiveListItemRenderer); the
                // search itself covers those.
                guard let s = entry["searchSuggestionRenderer"] as? [String: Any],
                      let runs = Parsing.dig(s, ["suggestion", "runs"]) as? [[String: Any]] else { continue }
                let text = runs.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { out.append(text) }
            }
        }
        return out
    }

    /// Add the given video to the given user-owned playlist. Requires
    /// SAPISID cookie auth (the user's session). The playlistId is the
    /// raw PL... id (no VL prefix).
    func addToPlaylist(videoId: String, playlistId: String) async throws {
        _ = try await postRaw(.editPlaylist, body: [
            "playlistId": playlistId,
            "actions": [[
                "action": "ACTION_ADD_VIDEO",
                "addedVideoId": videoId,
            ]],
        ])
    }

    /// Remove a track from a user-owned playlist. `setVideoId` is the
    /// per-playlist row identifier (different from the video's
    /// `videoId`) — captured by `parseListItem` from each track row's
    /// `playlistItemData.playlistSetVideoId` and stored on the
    /// MediaItem. The same videoId can appear multiple times in a
    /// playlist, so the setVideoId is what disambiguates.
    func removeFromPlaylist(setVideoId: String, videoId: String, playlistId: String) async throws {
        _ = try await postRaw(.editPlaylist, body: [
            "playlistId": playlistId,
            "actions": [[
                "action": "ACTION_REMOVE_VIDEO",
                "setVideoId": setVideoId,
                "removedVideoId": videoId,
            ]],
        ])
    }

    /// Rename a user-owned playlist. Requires SAPISID cookie auth.
    func renamePlaylist(playlistId: String, title: String) async throws {
        _ = try await postRaw(.editPlaylist, body: [
            "playlistId": playlistId,
            "actions": [[
                "action": "ACTION_SET_PLAYLIST_NAME",
                "playlistName": title,
            ]],
        ])
    }

    /// Update a user-owned playlist's description. Empty string
    /// clears it. Requires SAPISID cookie auth.
    func setPlaylistDescription(playlistId: String, description: String) async throws {
        _ = try await postRaw(.editPlaylist, body: [
            "playlistId": playlistId,
            "actions": [[
                "action": "ACTION_SET_PLAYLIST_DESCRIPTION",
                "playlistDescription": description,
            ]],
        ])
    }

    /// Update a user-owned playlist's privacy.
    func setPlaylistPrivacy(playlistId: String, privacy: PlaylistPrivacy) async throws {
        _ = try await postRaw(.editPlaylist, body: [
            "playlistId": playlistId,
            "actions": [[
                "action": "ACTION_SET_PLAYLIST_PRIVACY",
                "playlistPrivacy": privacy.rawValue,
            ]],
        ])
    }

    /// Delete a user-owned playlist. Irreversible — caller is
    /// responsible for any "are you sure?" confirmation. Requires
    /// SAPISID cookie auth.
    func deletePlaylist(playlistId: String) async throws {
        _ = try await postRaw(.deletePlaylist, body: [
            "playlistId": playlistId,
        ])
    }

    /// Create a new user-owned playlist. Returns the new playlist's id
    /// when YT confirms creation.
    @discardableResult
    func createPlaylist(title: String, description: String? = nil, privacy: PlaylistPrivacy = .private) async throws -> String? {
        var body: [String: Any] = [
            "title": title,
            "privacyStatus": privacy.rawValue,
        ]
        if let description, !description.isEmpty {
            body["description"] = description
        }
        let resp = try await postRaw(.createPlaylist, body: body)
        return resp["playlistId"] as? String
    }

    enum PlaylistPrivacy: String, Sendable {
        case `public` = "PUBLIC"
        case `private` = "PRIVATE"
        case unlisted = "UNLISTED"
    }

    /// Remove a previously-set like.
    func removeLike(videoId: String) async throws {
        _ = try await postRaw(.removeLike, body: ["target": ["videoId": videoId]])
    }

    // MARK: - Parse helpers (private)

    /// Handles every shelf shape we've seen on YT Music's home:
    ///   - `musicCarouselShelfRenderer`     — typical horizontal carousel
    ///   - `musicImmersiveCarouselShelfRenderer` — taller hero carousel
    ///   - `musicShelfRenderer`             — list-style rows (e.g. "Trending songs")
    ///   - `musicCardShelfRenderer`         — single hero card with featured action
    ///   - `gridRenderer`                   — grid of tiles
    /// Falls back to scanForMediaItems for anything else so we never silently
    /// drop a section.
    static func parseHomeShelf(_ shelf: [String: Any]) -> HomeSection? {
        // Carousel of two-row tiles (Listen again, Mixed for you, …)
        if let r = shelf["musicCarouselShelfRenderer"] as? [String: Any] {
            let title = Parsing.runs(r, "header", "musicCarouselShelfBasicHeaderRenderer", "title") ?? ""
            let contents = r["contents"] as? [[String: Any]] ?? []
            let items = contents.compactMap(parseTwoRowItem)
            return finalize(title: title, items: items)
        }
        // Immersive carousel (New releases hero strip, etc.)
        if let r = shelf["musicImmersiveCarouselShelfRenderer"] as? [String: Any] {
            let title = Parsing.runs(r, "header", "musicCarouselShelfBasicHeaderRenderer", "title") ?? ""
            let contents = r["contents"] as? [[String: Any]] ?? []
            let items = contents.compactMap(parseTwoRowItem)
            return finalize(title: title, items: items)
        }
        // Row-list shelf (Trending songs, etc.)
        if let r = shelf["musicShelfRenderer"] as? [String: Any] {
            let title = Parsing.runs(r, "title") ?? Parsing.string(r, "title", "runs", "0", "text") ?? ""
            let contents = r["contents"] as? [[String: Any]] ?? []
            let items = contents.compactMap(parseListItem)
            return finalize(title: title, items: items)
        }
        // Single-card hero shelf.
        if let r = shelf["musicCardShelfRenderer"] as? [String: Any] {
            let title = Parsing.runs(r, "title") ?? ""
            let items = scanForMediaItems(r)
            return finalize(title: title, items: items)
        }
        // Grid of tiles.
        if let r = shelf["gridRenderer"] as? [String: Any] {
            let title = Parsing.string(r, "header", "gridHeaderRenderer", "title", "runs", "0", "text") ?? ""
            let items = (r["items"] as? [[String: Any]] ?? []).compactMap(parseTwoRowItem)
            return finalize(title: title, items: items)
        }
        // Last-ditch: deep scan for any items inside, label by any title we
        // can find. This keeps unknown shelf types from being silently
        // dropped — better to render them with a generic header.
        let items = scanForMediaItems(shelf)
        if !items.isEmpty {
            let title = Parsing.runs(shelf, "header", "musicCarouselShelfBasicHeaderRenderer", "title") ?? "More"
            return finalize(title: title, items: items)
        }
        return nil
    }

    private static func finalize(title: String, items: [MediaItem]) -> HomeSection? {
        guard !items.isEmpty else { return nil }
        return HomeSection(id: title.isEmpty ? UUID().uuidString : title, title: title, items: items)
    }

    /// `musicResponsiveListItemRenderer` (list rows in search/liked songs).
    static func parseListItem(_ wrapper: [String: Any]) -> MediaItem? {
        guard let r = wrapper["musicResponsiveListItemRenderer"] as? [String: Any] else { return nil }
        let cols = r["flexColumns"] as? [[String: Any]] ?? []
        let title = Parsing.runs(cols.first, "musicResponsiveListItemFlexColumnRenderer", "text") ?? ""
        let subtitle = cols.count > 1
            ? (Parsing.runs(cols[1], "musicResponsiveListItemFlexColumnRenderer", "text") ?? "")
            : ""

        // Songs put the navigation on the title cell's first run
        // (watchEndpoint, "click the title to play"). Albums / artists /
        // playlists put it at the row level (browseEndpoint, "click the row
        // to open the page"). Try cell first, then row.
        let titleEndpoint = Parsing.dig(cols.first, ["musicResponsiveListItemFlexColumnRenderer", "text", "runs", "0", "navigationEndpoint"]) as? [String: Any]
        let rowEndpoint = r["navigationEndpoint"] as? [String: Any]
        guard let resolved = endpointToIdKind(titleEndpoint) ?? endpointToIdKind(rowEndpoint) else { return nil }
        let (id, kind) = resolved
        let thumb = Parsing.thumbnailURL(Parsing.dig(r, ["thumbnail", "musicThumbnailRenderer", "thumbnail"]) as? [String: Any])
        // Mine flexColumns[1+] runs and the row menu for the album /
        // artist browse references — drives the "Go to album / Go to
        // artist" context-menu actions. We accept the first match per
        // kind so a song with multiple artists still resolves to one.
        let (albumId, artistId) = extractAlbumArtistIds(from: r, cols: cols)
        // playlistSetVideoId — present only when the row is rendered
        // inside a playlist tracklist. Required to remove the row
        // from its parent playlist later (the same videoId can
        // appear multiple times so videoId alone is ambiguous).
        let setVideoId = Parsing.dig(r, ["playlistItemData", "playlistSetVideoId"]) as? String
        // Duration string — search song rows expose it as plain text
        // at fixedColumns[0].musicResponsiveListItemFixedColumnRenderer
        // .text.runs[0].text (typically "3:42"). Library liked-songs
        // use the same fixed-column path. Some shelves omit it.
        let durationText =
            Parsing.runs(Parsing.dig(r, ["fixedColumns", "0"]) as? [String: Any],
                         "musicResponsiveListItemFixedColumnRenderer", "text")
        let durationSeconds = durationText.flatMap(parseDurationString)
        // Year — scan flexColumns[1+] runs for a plain "YYYY" text run.
        // YT puts year in the byline alongside the artist + plays count.
        let year = extractYearFromFlexColumns(cols: cols)
        return MediaItem(id: id, kind: kind, title: title, subtitle: subtitle,
                         thumbnailURL: thumb, albumId: albumId, artistId: artistId,
                         setVideoId: setVideoId,
                         durationSeconds: durationSeconds, year: year)
    }

    /// Parse "mm:ss" or "h:mm:ss" into seconds. Returns nil for any
    /// non-conforming string so stray punctuation can't fake a
    /// duration. Permissive about leading zeros and surrounding
    /// whitespace; strict that the result must be greater than zero.
    static func parseDurationString(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let ints = parts.compactMap(Int.init)
        guard ints.count == parts.count else { return nil }
        let seconds: Int
        switch ints.count {
        case 2: seconds = ints[0] * 60 + ints[1]
        case 3: seconds = ints[0] * 3600 + ints[1] * 60 + ints[2]
        default: return nil
        }
        return seconds > 0 ? seconds : nil
    }

    /// Walk every run in every flex column past the title and return
    /// the first plain-text run that parses as a 4-digit year in the
    /// 1900-2099 window. Skip runs with a navigationEndpoint — those
    /// are artist / album links, never year markers.
    private static func extractYearFromFlexColumns(cols: [[String: Any]]) -> Int? {
        for col in cols.dropFirst() {
            let runs = (Parsing.dig(col, ["musicResponsiveListItemFlexColumnRenderer", "text", "runs"]) as? [[String: Any]]) ?? []
            for run in runs where run["navigationEndpoint"] == nil {
                guard let txt = run["text"] as? String else { continue }
                let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if let y = Int(trimmed), (1900...2099).contains(y) {
                    return y
                }
            }
        }
        return nil
    }

    /// Variant of `extractAlbumArtistIds` for `playlistPanelVideoRenderer`
    /// rows from `/next`. The shape is different — there are no flex
    /// columns; the artist/album endpoints live inside `longBylineText.runs`
    /// and the row's menu items.
    private static func extractIdsFromQueueRow(_ row: [String: Any]) -> (album: String?, artist: String?) {
        var album: String?
        var artist: String?
        let runs = (Parsing.dig(row, ["longBylineText", "runs"]) as? [[String: Any]]) ?? []
        for run in runs {
            guard let endpoint = run["navigationEndpoint"] as? [String: Any],
                  let resolved = endpointToIdKind(endpoint) else { continue }
            switch resolved.1 {
            case .album where album == nil:   album = resolved.0
            case .artist where artist == nil: artist = resolved.0
            default: continue
            }
        }
        if album == nil || artist == nil {
            let menuItems = (Parsing.dig(row, ["menu", "menuRenderer", "items"]) as? [[String: Any]]) ?? []
            for raw in menuItems {
                let item = (raw["menuNavigationItemRenderer"] as? [String: Any]) ?? raw
                guard let endpoint = item["navigationEndpoint"] as? [String: Any],
                      let resolved = endpointToIdKind(endpoint) else { continue }
                switch resolved.1 {
                case .album where album == nil:   album = resolved.0
                case .artist where artist == nil: artist = resolved.0
                default: continue
                }
            }
        }
        return (album, artist)
    }

    /// Walk a row's flex columns + menu items pulling out the first
    /// album browseId and the first artist browseId we find. YT Music's
    /// row layouts are inconsistent — sometimes the album is in
    /// flexColumns[2], sometimes only in the menu, sometimes absent —
    /// so we try several sources rather than committing to one path.
    private static func extractAlbumArtistIds(from row: [String: Any], cols: [[String: Any]]) -> (album: String?, artist: String?) {
        var album: String?
        var artist: String?

        // flexColumns: scan every run's navigationEndpoint. Artist runs
        // typically appear in [1], album runs in [2], but the order
        // varies (especially for podcast episode rows).
        for col in cols.dropFirst() {  // skip title column
            let runs = (Parsing.dig(col, ["musicResponsiveListItemFlexColumnRenderer", "text", "runs"]) as? [[String: Any]]) ?? []
            for run in runs {
                guard let endpoint = run["navigationEndpoint"] as? [String: Any],
                      let resolved = endpointToIdKind(endpoint) else { continue }
                switch resolved.1 {
                case .album where album == nil:   album = resolved.0
                case .artist where artist == nil: artist = resolved.0
                default: continue
                }
                if album != nil && artist != nil { return (album, artist) }
            }
        }

        // Row menu: "Go to album" / "Go to artist" entries carry their
        // own browseEndpoints. This is a fallback for rows whose flex
        // columns omit them (search song shelves often do).
        let menuItems = (Parsing.dig(row, ["menu", "menuRenderer", "items"]) as? [[String: Any]]) ?? []
        for raw in menuItems {
            let item = (raw["menuNavigationItemRenderer"] as? [String: Any]) ?? raw
            guard let endpoint = item["navigationEndpoint"] as? [String: Any],
                  let resolved = endpointToIdKind(endpoint) else { continue }
            switch resolved.1 {
            case .album where album == nil:   album = resolved.0
            case .artist where artist == nil: artist = resolved.0
            default: continue
            }
            if album != nil && artist != nil { break }
        }
        return (album, artist)
    }

    /// `musicTwoRowItemRenderer` (carousel tiles in home / library grids).
    static func parseTwoRowItem(_ wrapper: [String: Any]) -> MediaItem? {
        guard let r = wrapper["musicTwoRowItemRenderer"] as? [String: Any] else { return nil }
        let title = Parsing.runs(r, "title") ?? ""
        let subtitle = Parsing.runs(r, "subtitle") ?? ""
        let endpoint = r["navigationEndpoint"] as? [String: Any]
        guard let (id, kind) = endpointToIdKind(endpoint) else { return nil }
        let thumb = Parsing.thumbnailURL(Parsing.dig(r, ["thumbnailRenderer", "musicThumbnailRenderer", "thumbnail"]) as? [String: Any])
        // Carousel song tiles (Listen again, Quick Picks, etc.) carry
        // their album / artist refs in the subtitle runs and the
        // overflow menu — exactly like list rows do, just under
        // different keys. Without this, "Go to album / Go to artist"
        // never shows up on Home tiles.
        let (albumId, artistId) = extractIdsFromTwoRowTile(r)
        // Year — first plain-text 4-digit run in subtitle. Tiles
        // for albums often surface the year alongside the artist
        // ("Artist · 2024"); song tiles sometimes do too.
        let year = extractYearFromRuns(Parsing.dig(r, ["subtitle", "runs"]) as? [[String: Any]] ?? [])
        return MediaItem(id: id, kind: kind, title: title, subtitle: subtitle,
                         thumbnailURL: thumb, albumId: albumId, artistId: artistId,
                         year: year)
    }

    /// Shared year-from-runs extractor (used by both list and tile
    /// paths). Skips runs with a navigationEndpoint so artist /
    /// album links can't accidentally parse as a year.
    private static func extractYearFromRuns(_ runs: [[String: Any]]) -> Int? {
        for run in runs where run["navigationEndpoint"] == nil {
            guard let txt = run["text"] as? String else { continue }
            let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
            if let y = Int(trimmed), (1900...2099).contains(y) {
                return y
            }
        }
        return nil
    }

    /// Walks a `musicTwoRowItemRenderer`'s subtitle runs and overflow
    /// menu pulling out the first album browseId and the first artist
    /// browseId. The two-row tile shape diverges from list rows
    /// enough that sharing one walker would obscure the field paths.
    private static func extractIdsFromTwoRowTile(_ row: [String: Any]) -> (album: String?, artist: String?) {
        var album: String?
        var artist: String?

        // subtitle.runs is typically [artistRun, " • ", albumRun] for
        // songs. Both runs carry their own navigationEndpoint to the
        // corresponding browse page.
        let subtitleRuns = (Parsing.dig(row, ["subtitle", "runs"]) as? [[String: Any]]) ?? []
        for run in subtitleRuns {
            guard let endpoint = run["navigationEndpoint"] as? [String: Any],
                  let resolved = endpointToIdKind(endpoint) else { continue }
            switch resolved.1 {
            case .album where album == nil:   album = resolved.0
            case .artist where artist == nil: artist = resolved.0
            default: continue
            }
            if album != nil && artist != nil { return (album, artist) }
        }

        // Overflow menu: "Go to album" / "Go to artist" entries are
        // explicitly typed by YT, so this is the most reliable source
        // when subtitle runs don't carry endpoints (some Quick Picks
        // tiles render a flat unlabelled subtitle string).
        let menuItems = (Parsing.dig(row, ["menu", "menuRenderer", "items"]) as? [[String: Any]]) ?? []
        for raw in menuItems {
            let item = (raw["menuNavigationItemRenderer"] as? [String: Any]) ?? raw
            guard let endpoint = item["navigationEndpoint"] as? [String: Any],
                  let resolved = endpointToIdKind(endpoint) else { continue }
            switch resolved.1 {
            case .album where album == nil:   album = resolved.0
            case .artist where artist == nil: artist = resolved.0
            default: continue
            }
            if album != nil && artist != nil { break }
        }
        return (album, artist)
    }

    /// Map a navigationEndpoint to (id, kind). Returns nil if we don't
    /// recognise the endpoint shape.
    static func endpointToIdKind(_ endpoint: [String: Any]?) -> (String, MediaItem.Kind)? {
        guard let endpoint else { return nil }
        if let watch = endpoint["watchEndpoint"] as? [String: Any],
           let videoId = watch["videoId"] as? String {
            return (videoId, .song)
        }
        if let watchPL = endpoint["watchPlaylistEndpoint"] as? [String: Any],
           let pid = watchPL["playlistId"] as? String {
            return (pid, .playlist)
        }
        if let browse = endpoint["browseEndpoint"] as? [String: Any],
           let browseId = browse["browseId"] as? String {
            let pageType = (Parsing.dig(browse, ["browseEndpointContextSupportedConfigs",
                                                 "browseEndpointContextMusicConfig",
                                                 "pageType"]) as? String) ?? ""
            switch pageType {
            case "MUSIC_PAGE_TYPE_ALBUM":             return (browseId, .album)
            case "MUSIC_PAGE_TYPE_ARTIST":            return (browseId, .artist)
            case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE": return (browseId, .podcast)
            case "MUSIC_PAGE_TYPE_PLAYLIST":          return (Self.unwrapVLPrefix(browseId), .playlist)
            default:
                if browseId.hasPrefix("MPRE") { return (browseId, .album) }   // album browseId pattern
                if browseId.hasPrefix("UC") || browseId.hasPrefix("UCMO") { return (browseId, .artist) }
                if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") { return (Self.unwrapVLPrefix(browseId), .playlist) }
                return nil
            }
        }
        return nil
    }

    // MARK: - Request plumbing

    private func postRaw(_ endpoint: Endpoint, body: [String: Any]) async throws -> [String: Any] {
        // SAPISIDHASH cookie auth when we have a SAPISID cookie (set by
        // the WebView sign-in — Kaset's pattern). Otherwise anonymous.
        // OAuth Bearer is *not* attached: empirically InnerTube returns
        // 400 INVALID_ARGUMENT for every Bearer-authed request regardless
        // of clientName claimed.
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(endpoint.rawValue))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.origin, forHTTPHeaderField: "Origin")
        req.setValue("\(Self.origin)/", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.clientNameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(Self.effectiveClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")

        let authMode: String
        if let sapisid = Self.sapisidHashAuthHeader() {
            req.setValue(sapisid, forHTTPHeaderField: "Authorization")
            authMode = "sapisid"
        } else {
            authMode = "anonymous"
        }
        Log.innertube.debug("→ \(endpoint.rawValue, privacy: .public) auth=\(authMode, privacy: .public)")

        var payload = body
        payload["context"] = [
            "client": [
                "clientName": Self.clientName,
                "clientVersion": Self.effectiveClientVersion,
                "hl": Locale.current.language.languageCode?.identifier ?? "en",
                "gl": Locale.current.region?.identifier ?? "US",
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // One retry for idempotent reads on fast-fail signals — the
        // whole decision lives in `RetryPolicy` (pure, harness-tested).
        // `Task.sleep` throws on cancellation, and we check
        // `Task.isCancelled` before sleeping, so cancel-and-replace
        // callers (search-as-you-type, /next refresh) stop immediately
        // instead of sleeping and refiring a superseded request.
        var attempt = 1
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch let error as URLError {
                if !Task.isCancelled,
                   let backoff = RetryPolicy.delay(endpoint: endpoint, attempt: attempt,
                                                   status: nil, urlError: error.code,
                                                   retryAfter: nil) {
                    Log.innertube.notice("← \(endpoint.rawValue, privacy: .public) urlError=\(error.code.rawValue) retry in \(String(format: "%.2f", backoff), privacy: .public)s")
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }
                throw error
            }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                if !Task.isCancelled,
                   let backoff = RetryPolicy.delay(endpoint: endpoint, attempt: attempt,
                                                   status: http.statusCode, urlError: nil,
                                                   retryAfter: http.value(forHTTPHeaderField: "Retry-After")) {
                    Log.innertube.notice("← \(endpoint.rawValue, privacy: .public) status=\(http.statusCode) retry in \(String(format: "%.2f", backoff), privacy: .public)s")
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }
                let preview = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
                Log.innertube.error("← \(endpoint.rawValue, privacy: .public) status=\(http.statusCode) auth=\(authMode, privacy: .public) body=\(preview, privacy: .private(mask: .hash))")
                if http.statusCode == 401 || http.statusCode == 403 { throw InnerTubeError.needsReauth }
                throw InnerTubeError.http(http.statusCode)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InnerTubeError.decoding
            }
            return json
        }
    }

    /// `Bearer <access_token>` if we have a valid OAuth token (or can
    /// refresh the stored one). Async because refresh hits the network.
    private static func bearerAuthHeader() async -> String? {
        guard let token = await OAuthDeviceFlow.refreshIfNeeded() else { return nil }
        return "Bearer \(token)"
    }

    /// SAPISIDHASH `<ts>_<sha1(ts + " " + sapisid + " " + origin)>` per
    /// google.com auth scheme. Required for signed-in endpoints (library);
    /// returns nil if no SAPISID cookie exists yet (pre-sign-in).
    private static func sapisidHashAuthHeader() -> String? {
        guard let sapisid = currentAPISIDValue() else { return nil }
        let ts = String(Int(Date().timeIntervalSince1970))
        let raw = "\(ts) \(sapisid) \(Self.origin)"
        let hash = Insecure.SHA1.hash(data: Data(raw.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hex)"
    }

    /// The SAPISID value the hash is computed over. The jar can hold
    /// several copies (`.youtube.com` and `.google.com` from the
    /// WebView bridge, host-only `music.youtube.com` from a cookie
    /// import) and `HTTPCookieStorage.cookies` is unordered, so the
    /// old global `.first` picked an arbitrary — possibly never-sent
    /// or stale — copy. Consider only cookies URLSession will actually
    /// attach to music.youtube.com and pick deterministically; the
    /// global jar is a fallback for a jar with no host-scoped copy
    /// (previous behaviour). This only makes the choice deterministic
    /// and loud: a jar holding two live sessions must be cleaned where
    /// cookies are written (CookieJar import), not here.
    private static func currentAPISIDValue() -> String? {
        let storage = HTTPCookieStorage.shared
        let originURL = URL(string: Self.origin)
        let host = originURL?.host ?? "music.youtube.com"
        if let originURL,
           let sendable = storage.cookies(for: originURL),
           let cookie = preferredAPISIDCookie(in: sendable, host: host) {
            return cookie.value
        }
        return preferredAPISIDCookie(in: storage.cookies ?? [], host: host)?.value
    }

    /// Pick the SAPISID (else `__Secure-3PAPISID`) cookie to hash:
    /// unexpired, non-empty, then the most specific domain for `host`
    /// (host-only `music.youtube.com` > `.music.youtube.com` >
    /// `.youtube.com` > non-matching), then the latest expiry. Logs
    /// once per conflict when live copies disagree — cookie NAMES and
    /// DOMAINS only, never values.
    static func preferredAPISIDCookie(in cookies: [HTTPCookie], host: String, now: Date = Date()) -> HTTPCookie? {
        for name in ["SAPISID", "__Secure-3PAPISID"] {
            let live = cookies.filter { cookie in
                cookie.name == name && !cookie.value.isEmpty
                    && (cookie.expiresDate ?? Date.distantFuture) > now
            }
            guard !live.isEmpty else { continue }
            if Set(live.map { $0.value }).count > 1 {
                reportAPISIDConflict(name: name, cookies: live)
            }
            return live.max(by: { lhs, rhs in
                apisidPreference(lhs, host: host) < apisidPreference(rhs, host: host)
            })
        }
        return nil
    }

    /// Sort key for `preferredAPISIDCookie`: (domain matches host,
    /// domain specificity, expiry). Higher is preferred.
    private static func apisidPreference(_ cookie: HTTPCookie, host: String) -> (Int, Int, Date) {
        let domain = cookie.domain.lowercased()
        let isDomainCookie = domain.hasPrefix(".")
        let bare = isDomainCookie ? String(domain.dropFirst()) : domain
        let lowerHost = host.lowercased()
        let matches: Int = (lowerHost == bare || lowerHost.hasSuffix("." + bare)) ? 1 : 0
        // Longer domain = more specific; a host-only cookie edges out a
        // domain cookie of the same name.
        let specificity: Int = bare.count * 2 + (isDomainCookie ? 0 : 1)
        return (matches, specificity, cookie.expiresDate ?? Date.distantFuture)
    }

    /// Conflict signatures already logged — postRaw runs per request,
    /// so an unthrottled log would repeat on every call.
    private static let reportedAPISIDConflicts = OSAllocatedUnfairLock(initialState: Set<String>())

    private static func reportAPISIDConflict(name: String, cookies: [HTTPCookie]) {
        let domains = cookies.map { $0.domain }.sorted().joined(separator: ",")
        let signature = name + "|" + domains
        let isNew = reportedAPISIDConflicts.withLock { reported in
            reported.insert(signature).inserted
        }
        guard isNew else { return }
        Log.innertube.error("auth: \(cookies.count) live \(name, privacy: .public) cookies disagree (domains=\(domains, privacy: .public)); hashing the most specific. A stale session is still in the jar — sign out or re-import to clear it.")
    }
}
