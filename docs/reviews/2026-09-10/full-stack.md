# Riff — full-stack logic & performance review

Scope: Explore / Search / Library / Detail views, `AppEnvironment`, `Sources/Data/InnerTube/*`, `Sources/Data/Auth/*`, and the non-locked Audio helpers. Queue core (PlayerBridge / QueuePolicy / QueueManager / player-bridge.js) skimmed for crash/perf only. Every finding below was traced end-to-end in code; none were taken from comments alone. Baseline `./tools/harness/run.sh`: 97 Swift + 41 JS passing, static guards OK.

Ranked most severe first.

---

## 1. Tab switch destroys every tab view → full refetch + lost state each time

- **File:** `Sources/App/RiffApp.swift:422-437` (`MainTabs`), consumers `Sources/UI/Explore/ExploreView.swift:44`, `Sources/UI/Search/SearchView.swift:5-42,390`, `Sources/UI/Library/LibraryView.swift:283-297`, `Sources/UI/Home/HomeView.swift:65`
- **Category:** perf / correctness
- **Failure scenario:** `MainTabs.body` is `switch env.activeTab { case .home: HomeView() … }`. A `switch` inside a `Group` gives each branch a distinct structural identity, so switching tabs deallocates the old view and instantiates a fresh one. Consequences, reproducible every time:
  - Search "abba", read results, tap Library, tap Search → field is empty and results are gone (`query`, `results`, `nextPageToken`, `filter` are all `@State`). Only the nav path survives (it lives in env), so a DetailView can be on the stack with a blank search beneath it.
  - Explore: `.task { await load() }` re-runs on every visit → 2 `/browse` requests and the skeleton flashes (`sections` is fresh, so `loading && sections.isEmpty` is true).
  - Library: `.task(id: section)` re-runs → `library(section:)` + `browseMixedForYou()` (+ on Artists the 1+25-request fan-out, see #9) on every visit.
  - Home: `.task { await load() }` → `browseHome()` = up to 7 serial `/browse` round-trips per return to Home (cache-first paint hides it visually, network cost is still paid).
- **Proposed fix:** Keep all four tab roots mounted: render them in a `ZStack`, each with `.opacity(active ? 1 : 0)`, `.allowsHitTesting(active)`, `.accessibilityHidden(!active)` (or `.zIndex`). Alternatively lift per-tab loaded data (`results`, `sections`, `items`, `query`) into small `@Observable` stores owned by `AppEnvironment` so view recreation is cheap and state survives. Either way add an `id`/`lastLoadedAt` guard so `.task` does not refetch content younger than N minutes.
- **Effort:** M  **Confidence:** high

## 2. Task cancellation is treated as a network failure → results wiped, "Network error: cancelled" banner

- **File:** `Sources/UI/Search/SearchView.swift:708-742` (`debouncedRunSearch`), `:714-719` (empty-query branch does not clear `errorMessage`); `Sources/UI/Library/LibraryView.swift:375-455` (`load`); `Sources/UI/Components/ErrorBanner.swift:78-85`
- **Category:** concurrency / correctness
- **Failure scenario:** `.task(id:)` cancels the running task when the id changes, but `URLSession.data(for:)` honours cooperative cancellation by **throwing `URLError(.cancelled)`**, and none of the `catch` blocks check `Task.isCancelled`.
  - Search: type "abc", pause 300 ms (request in flight), type "d" → old task cancelled → `catch` runs: `results = []`, `nextPageToken = nil`, `errorMessage = "Network error: cancelled"` (NSURLErrorDomain −999 hits the `default:` branch of `LoadErrorPresenter`). The list blanks and the red banner flashes on every keystroke that lands while a request is in flight.
  - Search, sticky variant: type "abc", then clear the field while the request is in flight → cancelled catch sets the banner; the new task takes the `guard !query.isEmpty` path which resets `results/nextPageToken/loadMoreError/searching` **but not `errorMessage`** → "Something went wrong — Network error: cancelled" stays on the empty search screen until a later search succeeds.
  - Library: Liked → Albums → Liked in quick succession → the cancelled Albums task's `catch` writes `items = []` + banner, then `try? await mixedFetch` (also cancelled) writes `mixedForYou = []`, then it reads the *current* `section` for the followed-releases branch. Normally these stale writes land before the fresh response (flash), but nothing orders them; under load the stale catch can land after the fresh `items = fetched` and leave Liked empty with a "cancelled" banner.
- **Proposed fix:** In every `catch` on a `.task`-driven load: `if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }`. Re-check `Task.isCancelled` after each `await` before assigning state. In `debouncedRunSearch` clear `errorMessage = nil` in the empty-query branch. Add a `.cancelled` case to `LoadErrorPresenter` that returns nil so callers can skip.
- **Effort:** S  **Confidence:** high

## 3. Cookies are copied from the WebView exactly once (at sign-in) → rotation drift → false "session expired"

- **File:** `Sources/UI/SignInView.swift:83-96` (only `syncFromWebView` call site), `Sources/Data/Auth/CookieJar.swift:11-23`, `Sources/App/AppEnvironment.swift:103-119` (`probeSessionLiveness`), `:888-903` (didBecomeActive), `Sources/Data/InnerTube/InnerTubeClient.swift:1694-1703`
- **Category:** correctness
- **Failure scenario:** The hidden `WKWebView` is a live, signed-in YouTube tab: Google rotates `__Secure-1PSIDTS` / `__Secure-3PSIDTS` / `SIDCC` in `WKWebsiteDataStore.default()` every ~10-30 min. `HTTPCookieStorage.shared` received a snapshot at sign-in and thereafter evolves independently (InnerTube responses set their own rotated values). After hours/days the two jars diverge; YouTube answers the InnerTube jar anonymously while the WebView still plays ad-free. `sessionLiveness()` returns `false` → `deadCookieSignature` set, `isSignedIn = false`, toast "session expired", Library blanks — although the user is still signed in and a re-sync would fix it without re-login. The existence of `deadCookieSignature` suggests this "cookies present but anonymous" state has already been seen in the field.
- **Proposed fix:** Call `await CookieJar.syncFromWebView()` (a) at the top of `probeSessionLiveness`, (b) on `didBecomeActive`, (c) when any InnerTube call throws `.needsReauth` or `library()` returns empty for a signed-in user, and (d) on a ~15 min timer while the app is active. Only evaluate liveness after the sync. Keep `deadCookieSignature` but compute it over the synced set.
- **Effort:** S  **Confidence:** med

## 4. Library "Albums" uses the library *landing* browseId; section scans are not kind-filtered; "Artists" is not the subscriptions list

- **File:** `Sources/Data/InnerTube/Endpoints.swift:30-31`, `Sources/Data/InnerTube/InnerTubeClient.swift:430-473` (`library`, `scanForMediaItems`), `:243-247` (`newReleasesFromFollowedArtists`), `Sources/UI/Library/LibraryView.swift:316,327`
- **Category:** correctness
- **Failure scenario:** `BrowseID.libraryAlbums = "FEmusic_library_landing"` is the mixed Library landing page (recent playlists, albums, artists, songs). `library(section: .albums)` then deep-walks the whole body with `scanForMediaItems` and returns **every** row regardless of kind, so Library → Albums shows playlists/artists/songs from the landing page, not the saved-albums list (`FEmusic_liked_albums`, the id ytmusicapi uses for `get_library_albums`). Same mechanism means any section that returns a "suggestions" or "recent activity" shelf leaks foreign kinds into its grid. Separately, `libraryArtists = FEmusic_library_corpus_track_artists` is "artists whose songs are in your library", not subscriptions (`FEmusic_library_corpus_artists`), so tapping Follow on an artist page (`toggleFollow`) never makes them appear in Library → Artists or in "New from artists you follow", contradicting the empty-state copy ("Follow an artist and their releases show up here").
- **Proposed fix:** `libraryAlbums = "FEmusic_liked_albums"`; add `librarySubscriptions = "FEmusic_library_corpus_artists"` and use it for the Artists section + followed-releases feed. In `library(section:)` filter the scanned items to the section's expected kind (`.liked → .song`, `.albums → .album`, `.artists → .artist`, `.playlists → .playlist`, `.podcasts → .podcast`).
- **Effort:** S  **Confidence:** med-high (ids from ytmusicapi; memory notes say library is still unverified against a signed-in account)

## 5. Library sections never follow continuations → Liked Songs capped at the first page

- **File:** `Sources/Data/InnerTube/InnerTubeClient.swift:430-445`
- **Category:** correctness
- **Failure scenario:** `library()` does one `/browse` and returns `scanForMediaItems(body)`. YT pages the library shelves (`musicShelfRenderer` / `musicPlaylistShelfRenderer` carry `continuations[0].nextContinuationData`), returning roughly 25-100 rows. A user with 600 liked songs sees the first page only; the filter field reports "No matches" for a song they know is liked; "Most played" / "Last played" sort over a truncated subset; `sortTracks` on Search is unaffected but the Library promise ("treat Liked Songs as a real filterable playlist", `LibrarySorting.swift:10-12`) is not met. There is no "load more" affordance and no log line hinting at truncation.
- **Proposed fix:** Reuse the `browseHome` continuation loop: after the first body, read the shelf's `continuations[0].nextContinuationData.continuation`, POST `/browse {continuation}`, parse `continuationContents.musicShelfContinuation.contents` / `musicPlaylistShelfContinuation.contents`, and repeat up to a cap (e.g. 10 pages) or expose a `LibraryPage(items, continuation)` and page incrementally from `LibraryView` the way Search does.
- **Effort:** M  **Confidence:** med

## 6. "Owned playlist" = any playlist in the library; remove-from-playlist swallows errors and prunes optimistically

- **File:** `Sources/UI/Detail/DetailView.swift:26-29` (`isUserOwnedPlaylist`), `:514-543` (`removeFromCurrentPlaylist`), `Sources/App/AppEnvironment.swift:791-801` (`reloadUserPlaylists` ← `library(section: .playlists)` = `FEmusic_liked_playlists`)
- **Category:** correctness / robustness
- **Failure scenario:** `FEmusic_liked_playlists` is "Library → Playlists", which includes playlists the user *saved* from other channels. `isUserOwnedPlaylist` only checks id membership, so on a saved YT-curated playlist the header shows "Edit Playlist…" and every row's context/overflow menu shows "Remove from this playlist". Tapping Remove → `try? await removeFromPlaylist(...)` → server rejects (not owner) → error discarded → row pruned from `page.tracks` anyway → user believes it's gone; it reappears on the next visit. `EditPlaylistSheet` rename/delete on such a playlist fails the same way.
- **Proposed fix:** Derive ownership from the detail response (presence of `header.musicEditablePlaylistDetailHeaderRenderer`, or an "edit" `menuNavigationItemRenderer`), or filter `userPlaylists` to rows whose subtitle run names the signed-in account (from `fetchAccountInfo`). In `removeFromCurrentPlaylist` use `do/catch`: on failure leave the row, toast "Couldn't remove", and on success prune.
- **Effort:** M  **Confidence:** med-high

## 7. Duplicate `ForEach` ids: playlist tracklists (same videoId twice) and Search "All" (top-result card ∪ Songs shelf)

- **File:** `Sources/UI/Detail/DetailView.swift:333` (`ForEach(..., id: \.element.id)`), `Sources/UI/Search/SearchView.swift:471-482` + `Sources/Data/InnerTube/InnerTubeClient.swift:406-422` (`parseSearchShelves`), `:1215-1220` (comment acknowledging repeats)
- **Category:** correctness
- **Failure scenario:**
  - A playlist that contains the same song twice (YT allows it; that's why `setVideoId` exists) yields two rows with identical `id`. SwiftUI logs "ForEach … ID occurs multiple times", and diffing becomes undefined: hover/now-playing highlight applied to both, removal animates the wrong row, `TrackRow` state attaches to the first occurrence.
  - Under the `.all` filter the `musicCardShelfRenderer` (top result) is scanned with `scanForMediaItems` and the same track almost always also heads the `musicShelfRenderer` "Songs" shelf. `parseSearchShelves` does not dedupe (only the continuation path does). Result: duplicate ids in `resultList`, and `moveFocus` (`ids.firstIndex(of: current)`) snaps back to the first occurrence so ↓ gets stuck on that row.
- **Proposed fix:** DetailView: `ForEach(backfilled.indices, id: \.self)` or id = `track.setVideoId ?? "\(track.id)#\(index)"`. Search: dedupe `parseSearchShelves` output by `(kind, id)` preserving first occurrence (same `Set` pattern already used in `loadMoreIfNeeded`).
- **Effort:** S  **Confidence:** high (tracklist) / med (search)

## 8. Sign-out leaves per-account state behind; `userPlaylists` is never refetched for the new account

- **File:** `Sources/App/AppEnvironment.swift:126-140` (`signOut`), `:786-801` (`loadUserPlaylistsIfNeeded` guard `userPlaylists.isEmpty`), `Sources/Data/InnerTube/HomeFeedCache.swift:78-84` (`clear()` never called), `Sources/Audio/QueueManager.swift:296-298` (`clearPersistedHistory()` never called), `Sources/Data/Auth/UserInfoService.swift:19` (`cachedEmail` cleared only in Settings path `SettingsView.swift:230`)
- **Category:** correctness
- **Failure scenario:** "Switch Account…" → sign out → sign in as B. `userPlaylists` still holds A's playlists and, because it is non-empty, `loadUserPlaylistsIfNeeded` never refetches → every "Add to playlist" submenu and NowPlaying picker lists A's playlists; each add fails ("Couldn't add to …"); `isUserOwnedPlaylist` is computed against A's ids. Home paints A's cached personalized shelves from disk for the first ~second (cache-first render). `followedArtistIds`, pins, and the played-history journal (which `PlayedHistoryStore.clear()` documents as "used on Sign Out") all persist across accounts. Account menu (RiffApp) and menu-bar sign-out never reset `UserInfoService.cachedEmail`.
- **Proposed fix:** In `signOut()`: `userPlaylists = []; userPlaylistsLoading = false; HomeFeedCache.clear(); UserInfoService.cachedEmail = nil`, and decide explicitly on history/follows (at minimum clear `followedArtistIds`). Add `didSet` on `isSignedIn` (or in `refreshSignedInState`) that calls `reloadUserPlaylists()` on a false→true transition.
- **Effort:** S  **Confidence:** high

## 9. Followed-releases rail double-fetches the artists list and fans out 25 unbounded `/browse` calls per visit

- **File:** `Sources/UI/Library/LibraryView.swift:418,450-451,502-510`, `Sources/Data/InnerTube/InnerTubeClient.swift:243-288`
- **Category:** perf
- **Failure scenario:** Opening Library → Artists runs `library(section: .artists)` (line 418), then `loadFollowedReleases()` → `newReleasesFromFollowedArtists()` which calls `library(section: .artists)` **again** and then `withTaskGroup` with one `detail(forBrowseId:)` task per artist (25 at once, no concurrency cap). Each artist page is a 300-600 KB JSON body that is fully `JSONSerialization`-decoded and, when no tracklist shelf matches first, deep-walked by `scanForMediaItems`. Net: 27 requests and a CPU spike on every visit, and — because of #1 — on every tab switch back to Library while Artists is selected.
- **Proposed fix:** `newReleasesFromFollowedArtists(artists: [MediaItem])` taking the already-fetched list; cap fan-out (iterate in chunks of 4-6 inside the task group); memoize the result per session keyed by the sorted artist-id set with a TTL.
- **Effort:** S-M  **Confidence:** high

## 10. Every thumbnail request picks the largest rendition

- **File:** `Sources/Data/InnerTube/Parsing.swift:45-50` (`thumbs.last`), consumers `ThumbnailButton.swift:121-153` (180 pt), `SearchResultRow.swift:99-106` (48 pt), `DetailView.swift:685-692` (44 pt)
- **Category:** perf
- **Failure scenario:** YT thumbnail arrays are ascending in size; `.last` is typically 544×544 (playlists/albums) or larger for artist banners. `AsyncImage` decodes at native size and keeps the decoded `Image` alive while the row is materialized. Library grid with 200 saved albums → 200 × 544²×4 B ≈ 240 MB of bitmaps for 180 pt tiles; Search rows decode 544 px images for 48 pt squares; first-paint scroll jank in `LazyVGrid`. The 64 MB `URLCache` memory budget also fills with oversized bodies.
- **Proposed fix:** Add `Parsing.thumbnailURL(_:targetPoints:)` that returns the smallest rendition ≥ 2× the target (fallback to largest), or rewrite the googleusercontent size suffix (`=w544-h544` → `=w360-h360`) for the known display sizes; pass 180/48/44 from the three call sites.
- **Effort:** S  **Confidence:** med-high

## 11. Sorted/filtered lists are recomputed 3-4× per body evaluation on the main thread

- **File:** `Sources/UI/Search/SearchView.swift:120-130` (`displayedResults`; read at 296, 364, 419, 434, 462, 469, 546), `Sources/UI/Library/LibraryView.swift:64-108` (`displayedItems`; read at 166, 243, 256)
- **Category:** perf
- **Failure scenario:** Both are computed properties that filter + `sorted` with `localizedCaseInsensitiveCompare` (ICU collation, ~1-3 µs per compare) and, for play-count/last-played, rebuild a dictionary over up to 500 `playedEntries`. `body` reads them several times, so one render = 3-4 full sorts. Typing in the Library filter with 1,000 liked songs under A→Z (after #5 is fixed the list really is that large) or scrolling a Search list grown to a few hundred rows via continuation → ~10-40 ms per keystroke/render on main → dropped frames.
- **Proposed fix:** Compute once per render (`let displayed = displayedResults` at the top of the relevant `body`/subview and thread it through), or hold the sorted array in `@State` recomputed in `onChange(of:)` for `items/filterText/sort/pinnedLibraryIds/playedEntries.count`.
- **Effort:** S  **Confidence:** med

## 12. Empty user playlist renders YT's "Suggestions" rows as its tracklist

- **File:** `Sources/Data/InnerTube/InnerTubeClient.swift:1038-1063`
- **Category:** correctness / robustness
- **Failure scenario:** For an owned playlist with zero tracks, the page's `musicPlaylistShelfRenderer` has no `contents` (or is absent) while YT includes a "Suggestions" `musicShelfRenderer` beneath it. The tracklist search takes the first shelf matching *either* key, so Suggestions becomes `tracks`; if nothing matches, the `scanForMediaItems(body)` fallback sweeps every row on the page (suggestions, "related" carousels) and the `kind == .song` filter keeps them. DetailView then shows "N songs", Play queues the suggestions as the playlist, and the rail meant as "You might also like" is missing (it was consumed as the tracklist).
- **Proposed fix:** Prefer `musicPlaylistShelfRenderer` over `musicShelfRenderer`; for `musicShelfRenderer` accept it as the tracklist only when it has no title (or its title is not a known suggestion heading); for album/playlist browseIds drop the whole-body fallback and return `tracks = []` (DetailView already has a "No tracks" state).
- **Effort:** S  **Confidence:** med

## 13. Sign-in sheet fires on the first SAPISID sighting and then cuts the redirect chain

- **File:** `Sources/UI/SignInView.swift:83-96, 127-131, 151-162`
- **Category:** robustness / concurrency
- **Failure scenario:** `checkForSignIn` runs on every `didCommit`/`didFinish` and fires as soon as *any* `SAPISID`/`__Secure-3PAPISID` exists — that cookie is first set on `.google.com` by accounts.google.com before the `continue` redirects reach youtube.com/music.youtube.com (which set the `.youtube.com` copies). `onComplete` → `syncFromWebView()` copies whatever exists → 400 ms → `dismiss()` → `dismantleNSView` calls `stopLoading()` and loads `about:blank`, aborting the remaining redirects. If the youtube.com hop hasn't landed in that window, `HTTPCookieStorage.shared` holds google.com cookies only; `sapisidHashAuthHeader` still builds a header (it ignores domain), but the request to `music.youtube.com` carries no youtube.com session cookies → anonymous answers while `isSignedIn` reads true. The WebView itself recovers on its next load, so the symptom is "signed in, library empty" until #3 is also fixed.
- **Proposed fix:** Fire only when a SAPISID cookie with `domain.hasSuffix("youtube.com")` exists *and* the current URL host is `music.youtube.com`; run the sync before starting the dismiss delay; don't `stopLoading()` until the sync has completed.
- **Effort:** S  **Confidence:** low-med

## 14. `HomeSection.id` is the shelf title → collisions across Explore + Moods and for the "More" fallback

- **File:** `Sources/Data/InnerTube/InnerTubeClient.swift:1345-1359` (`finalize`, fallback title `"More"`), `Sources/UI/Explore/ExploreView.swift:31-36`, `Sources/UI/Library/LibraryView.swift:221`
- **Category:** correctness
- **Failure scenario:** `finalize` sets `id = title` (UUID only when the title is empty). Two unknown-shape shelves in one response both get id `"More"`; ExploreView renders `sections` and `moods` in the same `LazyVStack`, so a title shared between the Explore feed and the Moods & Genres feed also collides. Duplicate `ForEach` ids → misrendered/non-updating rows and console warnings. `detail()` and `parseRelatedSections` already dedupe by title; Explore and Library's `mixedForYou` do not.
- **Proposed fix:** Make `finalize` accept the shelf index and build `id = "\(title)#\(index)"` (or dedupe in `ExploreView.load` like `parseRelatedSections`).
- **Effort:** S  **Confidence:** med

## 15. Infinite-scroll sentinel only fires on `onAppear` → stalls when a page is shorter than the viewport

- **File:** `Sources/UI/Search/SearchView.swift:519-527`
- **Category:** correctness
- **Failure scenario:** The 1 pt `Color.clear` sentinel triggers `loadMoreIfNeeded()` in `onAppear`. After a page is appended the sentinel's identity is unchanged; if the appended rows don't push it out of the viewport (tall window, Artists/Albums filter returning ~5-10 rows), `onAppear` never fires again and paging stops even though `nextPageToken != nil`. The user must scroll the sentinel off-screen and back to resume.
- **Proposed fix:** Also trigger in `.onChange(of: results.count)` when `nextPageToken != nil && !loadingMore` and the sentinel is visible (use `GeometryReader`/`onScrollVisibilityChange`), or attach the trigger to the last visible row's `onAppear` instead of a fixed sentinel.
- **Effort:** S  **Confidence:** med

## 16. Keychain read on the main thread on every app activation

- **File:** `Sources/App/AppEnvironment.swift:37-38, 888-903`, `Sources/Data/Auth/OAuthTokens.swift:35-51`, `Sources/Data/Auth/Keychain.swift:35-47`
- **Category:** perf
- **Failure scenario:** `refreshSignedInState()` runs on `didBecomeActive` and calls `OAuthTokens.load()` → `SecItemCopyMatching` synchronously on the main thread. Normally 1-5 ms, but on ad-hoc-signed dev builds (the case the file's own comment describes) each rebuild changes the code signature and the call can block on the keychain access prompt, freezing the UI on every Cmd-Tab back into the app. `OAuthDeviceFlow.refreshIfNeeded` (also `@MainActor`) does the same plus a network refresh on main.
- **Proposed fix:** Cache the "has OAuth token" boolean in `AppEnvironment` and refresh it off-main (`Task.detached`) at launch and after sign-in/out; only re-read Keychain when those events fire. Move `OAuthDeviceFlow.refreshIfNeeded` off `@MainActor` (it touches no UI state).
- **Effort:** S  **Confidence:** med

---

### Notes / non-findings worth knowing

- `PlayerBridge.historyCap = 50` (`PlayerBridge.swift:692`) is unused — `QueueManager()` is constructed with its default `historyCap: 500` (`QueueManager.swift:63`, `PlayerBridge.swift:21`). The effective cap is 500; anyone tuning the 50 will see no effect.
- `InnerTubeClient.likedVideos / myPlaylists / mySubscriptions / dataAPIPaginated / dataAPI` (`InnerTubeClient.swift:475-613`) are unreachable from any call site; `bearerAuthHeader` (`:1686-1689`) likewise. Dead Data-API path; safe to delete or gate behind a feature flag.
- InnerTube parsing runs off the main actor as intended: `InnerTubeClient` methods are nonisolated `async` (SE-0338 hops to the generic executor) and the project builds with `SWIFT_STRICT_CONCURRENCY: complete` without default MainActor isolation (`project.yml:20-23`).
- `DominantColor.extract` is correctly off-main and bounded (cap 200). `NowPlayingCenter.artworkCache` is bounded (16). `HiddenPlayerWebView` ↔ `WKUserContentController` is a retain cycle but both are app-lifetime singletons.
- Queue core skim: `queueSnapshot` is signature-deduped on the JS side, so `replaceServerRegion` isn't churned at the 2 s poll cadence; `progress` handler sanitizes NaN/inf before publishing. No crash risks spotted in the hot path.
