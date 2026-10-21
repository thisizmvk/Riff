# Riff — Product Owner review (Draupadi)

Branch `queue-and-ux-enhancements` @ `6aeeeba` · 2026-09-10 · read-only audit of what the app **does**, not what the docs say.
Harness: `./tools/harness/run.sh` → static guards OK · Swift 97/97 · JS 41/41.

Framing: the wedge (click-anywhere-to-play, native SwiftUI, hidden WKWebView) is real and shipped. The queue core is locked and green. Home is tuned. The user pain that is left is not "missing premium features" — it is that **the surfaces a daily user lives in (Library, album/playlist/artist pages, Explore) quietly show a fraction of their data and lie about what actions exist**. Fix the lies first; then parity; then delight.

---

## A. Feature inventory (what exists today)

Maturity: **Solid** = works, tested/guarded · **Usable** = works, rough edges · **Partial** = shipped but materially incomplete · **Stub** = present in code, not reachable or not useful.

| Surface | What exists (file) | Maturity |
|---|---|---|
| **App shell** | Top tabs Home / Explore / Search / Library (`RiffApp.swift` `TopTabBar`), tap-active-tab-pops-to-root, per-tab `NavigationPath`, dark-only (`preferredColorScheme(.dark)` ×5), min 980×640 | Solid |
| **Sign-in** | WebView sheet w/ Safari UA (`SignInView`), OAuth Device Flow fallback, paste-cookies import (`SettingsView` `cookieImportBlock`), server-side liveness probe + expiry toast (`AppEnvironment.probeSessionLiveness`), Switch Account | Solid |
| **Onboarding** | 4-page sheet, once (`OnboardingSheet`) | Usable |
| **Home** | Browse-home shelves w/ continuation, mood chips, disk cache for instant cold start (`HomeFeedCache`), local personalized shelves (top artists / "You've been playing" / time-of-day, `PersonalizedShelves`), artist portraits, sign-in nudge, skeleton, arrow-key carousel nav | Solid (already tuned) |
| **Explore** | `FEmusic_explore` shelves + `FEmusic_moods_and_genres` rendered through Home's `HomeSectionRow` (`ExploreView.swift:48-69`) | **Partial** — mood/genre category tiles are dropped by `endpointToIdKind` (`InnerTubeClient.swift:1601-1630` returns nil for `FEmusic_*` browseIds; `MediaItem` has no `params`), no "See all" on any shelf (`HomeSection` has no more-endpoint, `:285-289`), no charts hub |
| **Search** | Suggestions (150 ms), kind chips (`paramsToken`), client-side year/duration refinement, per-filter sort, top-result hero card, kind-grouped list, endless scroll (kind filters only), recent searches, paste-URL-to-open, ↑/↓/↵ keyboard nav (`SearchView.swift`) | Solid; `.all` has no continuation (`:24-28`); ⌘↵ "add to queue" documented (`:14-17`) but not implemented (`:418-424`) |
| **Library** | Liked / Playlists / Albums / Artists / Podcasts / History segments, live filter, sort (A-Z, most/last played from local journal), pin-to-top, "Mixed for you" rails, "New from artists you follow" rail (`LibraryView.swift`) | **Partial** — every section is the **first page only**: `library()` does one `postRaw` and never follows continuations (`InnerTubeClient.swift:430-445`); the only continuation-walkers are Home (`:113-131`) and Search |
| **Detail page** (album / playlist / artist / podcast) | One `DetailView` for all four kinds: header w/ linkable artist/album runs, "N songs · 32 min · 2024", Play / Shuffle, edit menu (owned playlists), Follow + Don't-recommend on artists, track sort, hover heart + ⋯, now-playing row highlight, related carousels, remove-from-playlist | Usable for albums; **Partial** for long playlists (no continuation in `detail()` `:945-1108` → >100 tracks truncated) and artists (top-5 songs as "tracklist", no bio/subscriber count, no discography "See all"). **Tapping track N plays it as a single with radio, not the album from N** (`DetailView.swift:680-682` → `play(item:)` `clearQueue: true`, `PlayerBridge.swift:551-575`) |
| **Track row heart** | Optimistic, starts hollow on every non-current row (`DetailView.swift:656-666`) — no app-wide liked-id set (grep `likedIds` = 0) | Partial (hearts are wrong on liked songs) |
| **Context menu** (every row/tile) | Play · Start radio · Play next · Add to queue · Go to album / artist · Don't recommend (undo toast) · Add to playlist (+ New) · Not for me (dislike) · Watch music video (browser) · Copy share link · Edit metadata · Pin (`TrackContextMenu.swift`) | Solid |
| **Mini bar** | Progress line (click-seek), 52pt art, prev/play/next, volume slider, right-click menu, tap → full player (`MiniPlayerView.swift`) | Usable — **no like, no shuffle/repeat, no time, no queue shortcut** (spec §8 promised like) |
| **Now Playing** | Hero art + "Watch video", scrubber (←/→ nudge), like, shuffle (+Smart Shuffle), ±15/30, repeat, volume/mute, sleep timer (stop / fade / end-of-track), audio-output button (opens System Settings), rate menu (podcast tap-to-cycle), ⋯ menu, Esc closes. Side pane tabs: **Up Next** (Save / Clear / ✨Build / Tune chips, recently played, drag-reorder + Move up/down + remove, Smart-Shuffle badges, radio hint) · **Lyrics** (synced karaoke, fullscreen, translate, lyric-card PNG) · **Related** (other performances rail + related list) · **Context** (Track details card, X-Ray LLM cards) | Solid |
| **Queue core** | Single-authority mirror, `QueuePolicy` decision table, verified page-side jump/remove, Play-Next enforcement, Repeat-All/autoplay-off on context exhaustion, session snapshot + resume (`pendingResume`), episode resume positions (`PlayerBridge.swift:1395-1450`) | Solid (locked; Phase D pending field verification) |
| **Playback prefs** | Autoplay toggle, crossfade presets, in-browser normalization, per-kind playback rate memory, track-change notifications, sleep/wake reassert, background JS throttling | Solid |
| **Playlists (write)** | Create (from current / queue / any row), add / remove track, rename, description, privacy, delete (`EditPlaylistSheet`, `NewPlaylistSheet`, `InnerTubeClient:1205-1297`) | Solid |
| **Library (write)** | Like / unlike / dislike song; follow / unfollow artist | Usable — **no Save album / Save playlist / Subscribe podcast** (no endpoint in `Endpoints.swift`; Library empty state at `LibraryView.swift:326` tells users to "choose Save album from its menu" — that menu item does not exist) |
| **Podcasts** | Play, rate cycle, ±15/30, resume position, Library section, search filter | Partial — no episode descriptions/dates (`parseListItem` has no description field), no "Continue listening", no subscribe, no played markers (PLAN Phase 2 🚧) |
| **Floating mini player** | Always-on-top resizable tile, hover transport, Tune chips (`FloatingMiniPlayer`, ⌥⌘M) | Solid |
| **Menu-bar extra** | Transport, scrubber, volume, sleep, crossfade, speed, open mini, quit; toggle in Settings (`MenuBarMiniPlayer`) | Solid |
| **Dock menu** | Now-playing line + play/pause/next/prev (`RiffAppDelegate`) | Solid |
| **System** | `MPNowPlayingInfoCenter` + remote commands (play/pause/toggle/next/prev/seek) (`NowPlayingCenter`), App Intents ×15 + Siri phrases (`RiffIntents`), widget snapshot writer (widget **target disabled** — free dev account, `project.yml:104-118`) | Solid / Stub (widget) |
| **Command palette** | ⌘K fuzzy launcher: tabs, sheets, transport, shuffle/smart-shuffle/repeat, like, save queue, sleep presets, crossfade, normalization (`CommandPalette.swift`) | Solid |
| **Shortcuts** | Space, ⌘←/→, ⌥⌘←/→, ⌘↑/↓, ⌘L, ⇧⌘S/R, ⌘1-4, ⌘K, ⌘F, ⌥⌘M, ⇧⌘Y, ⇧⌘L, ⌘,, ⇧⌘O (open link from clipboard) — listed in Settings | Solid; not customizable, no global hotkeys |
| **Stats / Recap** | 7/30/90-day/all-time windows, top artists/tracks, runtime, avg year from 500-entry local journal (`RecapView`) | Solid |
| **AI (opt-in)** | Anthropic / Groq / Ollama backends, Queue Builder ("vibe → queue"), lyrics translation, X-Ray cards; Keychain keys, test connection | Solid |
| **Scrobbling** | last.fm + ListenBrainz, half-or-4-min rule (`Scrobbler.swift`) | Usable (last.fm session-key onboarding is manual) |
| **Local personalization** | Blocked artists (filters Home/Search/queue), pinned library items, per-track metadata overrides (`TrackOverrideStore`) | Solid |
| **Links** | Paste URL in Search, ⇧⌘O clipboard, `openYouTubeMusicLink` (watch/playlist/browse/channel) | Usable — **no URL scheme / no `CFBundleURLTypes`** (`Info.plist`), no system Share sheet (`NSSharingService` = 0) |
| **Diagnostics** | MetricKit local reporter, export-diagnostics folder, `queueApi:` probes | Solid |
| **Quality** | 209 XCTest funcs across 14 files, queue harness (97+41), static guards, CI on macos-15, pre-commit hook | Solid |

Not present anywhere (confirmed by grep): AirPlay route picker (button just opens System Settings — correct on macOS), EQ/`AVAudioEngine`, Discord presence, localization (`NSLocalizedString` = 0), light theme, global hotkeys, drag from browse rows into the queue (`draggable` only on queue rows), podcast subscribe, save-to-library, artist bio.

---

## B. Top 12 proposals, ranked by user value

Effort: **S** ≤ 1 day · **M** 2–4 days · **L** > 1 week. "Lock" = impact on the queue behavior contract (`docs/QUEUE-DESIGN.md`, `QueuePolicy`, `guard.sh`).

### 1. Load the whole Library and whole playlists (continuations)
- **Pain / JTBD**: "I have 1,400 liked songs and Riff shows me the first page." Every Library section and every playlist/album detail is a single `/browse` response; long playlists are silently truncated, and **Play / Shuffle on a truncated page queues only what loaded**. This is the single most common way a daily user discovers the app is "not real".
- **Evidence**: `InnerTubeClient.swift:430-445` (`library()` — one `postRaw`, no loop); `:945-1108` (`detail()` — no continuation); the continuation walker already exists for Home at `:113-131` / `findContinuationToken` `:311-326`; PRODUCT_SPEC §9 "Library tab shows the signed-in user's liked songs, playlists…".
- **MVP cut**: (a) `library(section:)` follows `continuationContents.*Continuation` until exhausted or a 2,000-row cap, streaming pages into `items` so the grid fills progressively; (b) `detail()` follows `musicPlaylistShelfRenderer.continuations`; (c) header count uses the real total; (d) Library shows "Loading N more…" footer instead of freezing. Fixture-test both shapes (`InnerTubeParserTests`).
- **Effort**: M.
- **Deps / risks**: Lock — none. `playTracks` receives a longer array; `contextTracksIds` grows accordingly; `QueuePolicy` unchanged. Watch `scanForMediaItems` dedupe across pages (search already dedupes by id, `SearchView.swift:800-802`). Memory: 2k `MediaItem`s is trivial.

### 2. "Play from here" on album / playlist track rows
- **Pain / JTBD**: Clicking track 5 of an album should play the album from track 5 with 6…N queued (Spotify, Apple Music, YT Music all do this). Today it plays track 5 **as a single with auto-radio** and drops the album context; users then hit Next and get a random radio song. This breaks the very promise of the click-to-play wedge on the one surface where order matters.
- **Evidence**: `DetailView.swift:680-682` (`TrackRow` → `env.player.play(item:)`), `PlayerBridge.swift:551-575` (`clearQueue: true` → `contextTracksIds = [item.id]`, `contextPlaylistId = nil`); contrast the header Play path `DetailView.swift:487-512` which correctly calls `playTracks(_, playlistId:)`.
- **MVP cut**: `TrackRow` gets an `onPlayFromHere: (Int) async -> Void`; DetailView calls `playTracks(Array(sorted[index...]), playlistId: page.playablePlaylistId)` for album/playlist/podcast kinds (artist top-songs keep single-play). Keep the context menu "Play" as single-play (that is what "Play" means on a row elsewhere). Optional: retain the full album in `contextTracksIds` so Previous walks back past the start row — defer.
- **Effort**: S.
- **Deps / risks**: Lock — **compliant by construction**: reuses the existing `playTracks` UI call site; adds no `await navigate(` / `play(item:)` site inside `PlayerBridge`, so `guard.sh` counts are untouched; contract rows 7 and 11 are honored (the navigated `v=` is inside the list). Run `run.sh`; no table row needed. Benefits from #1 (a truncated list would still be a truncated "from here").

### 3. Save to Library: albums, playlists, podcasts (+ fix the copy that promises it)
- **Pain / JTBD**: "I found an album, I want it in my Library." There is no way to save an album, save someone else's playlist, or subscribe to a podcast. The Library → Albums empty state literally instructs users to use a menu item that does not exist.
- **Evidence**: `LibraryView.swift:326` ("Open an album, then choose "Save album" from its menu"); `Endpoints.swift:4-21` has `like/like`, `subscription/subscribe`, `browse/edit_playlist` but nothing is wired for `target.playlistId`; `ThumbnailButton.swift:75-92` container context menu has Play / Start radio / Play next / Add to queue only. PLAN Phase 2 "Library write operations … still pending".
- **MVP cut**: `InnerTubeClient.setLibrary(playlistId:, saved:)` = `like/like` / `like/removelike` with `{"target":{"playlistId": id}}` (ytmusicapi `rate_playlist`) — works for albums (use `playablePlaylistId`), playlists, and podcast shows (`MPSPPL…`); "Save to Library / Remove from Library" in the container context menu and as a header button on DetailView; optimistic + toast + undo; refresh `library(.albums)` on success; local `savedIds` set (persisted) so the button state is right before the round-trip. **Day-0 fix (S)**: correct the empty-state copy until the feature lands.
- **Effort**: S–M.
- **Deps / risks**: Lock — none. Unverified endpoint shape for albums (album browseId ≠ playlistId — must use `playablePlaylistId` from `detail()`); verify against a signed-in capture. Podcast subscribe may instead need `subscription/subscribe` on the show channel — try `like/like` first.

### 4. Make Explore navigable: moods & genres, "See all", charts
- **Pain / JTBD**: Explore is Riff's discovery surface after Home; today its Moods & Genres tiles vanish (unparseable) and no shelf can be expanded, so the tab is a thin re-skin of Home. YT Music iOS' Explore has New releases / Charts / Moods & genres hubs, each a full page.
- **Evidence**: `ExploreView.swift:48-69`; `InnerTubeClient.swift:202-210` (`browseMoodsAndGenres` → `parseHomeShelf`), `:1601-1630` (`endpointToIdKind` returns nil for `FEmusic_moods_and_genres_category` + `params`), `MediaItem.swift` has no `params`; `parseHomeShelf` `:1311-1362` ignores `header…moreContentButton` / title `navigationEndpoint`; `HomeSection` `HomeView.swift:285-289` has no more-endpoint.
- **MVP cut**: (a) `MediaItem.browseParams: String?` + `Kind.category`; parse `musicNavigationButtonRenderer` (colored mood buttons) in `browseMoodsAndGenres`; (b) `HomeSection.moreEndpoint` (browseId + params) → "See all ›" chevron on `HomeSectionRow` headers (Home, Explore, Detail related rails) pushing a `BrowseGridView` (grid of tiles reusing `ThumbnailButton`); (c) `InnerTubeClient.browse(browseId:params:)` generic + fixture; (d) charts: `FEmusic_charts` page through the same grid view with its country picker deferred.
- **Effort**: M.
- **Deps / risks**: Lock — none (pure browse). `DetailView` routing switch needs a `.category` branch (`DetailView.swift:467-485`). Keep `HomeSection` Codable-compatible for `HomeFeedCache` (optional field).

### 5. Truthful hearts: app-wide liked-song state
- **Pain / JTBD**: On any album/playlist page every heart is hollow, including songs the user liked yesterday; tapping toggles blindly, so users unlike songs by accident. Trust in the like button is trust in the app.
- **Evidence**: `DetailView.swift:656-666` ("starts hollow and flips optimistically"), no liked-id store (`grep likedIds` = 0); `PlayerBridge.toggleLike` `:1013` syncs only the current track via `/next`.
- **MVP cut**: `LikedSongsStore` (persisted `Set<videoId>`), seeded from `library(.liked)` (after #1 it is complete) on sign-in and refreshed every 30 min / after any like call; `env.isLiked(videoId)` drives `TrackRow`, `SearchResultRow`, queue rows, Now Playing; `toggleLike` writes through. Show filled hearts at rest only for liked rows (hover-reveal for the rest stays).
- **Effort**: S–M.
- **Deps / risks**: Lock — none. Depends on #1 for completeness (otherwise only the first page of likes is known — still better than nothing).

### 6. Mini bar parity: like, time, shuffle/repeat, queue
- **Pain / JTBD**: The mini bar is the one control users see 90% of the time; it lacks Like (⌘L exists but is invisible), elapsed/remaining, and any way to reach the queue without opening the full player. Spec §8 promised Like.
- **Evidence**: `MiniPlayerView.swift:65-105` (prev/play/next/volume only); PRODUCT_SPEC In-scope #8.
- **MVP cut**: heart (uses `player.liked`/`toggleLike`), "elapsed / -remaining" monospaced text next to the progress line on hover, shuffle + repeat glyphs (tint red when active; route through `toggleShuffle` / `toggleRepeat`), a `list.bullet` button that opens Now Playing with the Up Next tab pre-selected (`NowPlayingView.BottomTab` needs an `initialTab` env value). Respect the existing 980-pt min width — collapse volume first on narrow windows.
- **Effort**: S.
- **Deps / risks**: Lock — none (shuffle/repeat go through existing policy-aware entry points).

### 7. Artist page parity (bio, discography "See all", radio)
- **Pain / JTBD**: "Show me everything by this artist." Today the artist page is the album template: 5 top songs styled as a tracklist, then carousels; no bio/subscribers, no way to see all albums/singles, and the Play button plays the 5-song list rather than the artist's radio.
- **Evidence**: `DetailView.swift:3-7` ("One view because all four use the same shape"), `:487-512` (`playAll` on `page.tracks`), `InnerTubeClient.swift:945-960` (immersive header parsed only for title/subtitle/thumbnail; `description` and `subscriptionButton` ignored); `SearchResultRow.swift:214` uses `playArtistRadio` for artist rows — inconsistent with the page.
- **MVP cut**: `ArtistPage` model (description, subscriber text, top songs, shelves with more-endpoints from #4); artist header buttons become Radio / Shuffle (via `playArtistRadio`) / Follow / Don't recommend; "Top songs — See all"; discography grids via #4's grid view; expandable bio.
- **Effort**: M.
- **Deps / risks**: Lock — none. Depends on #4 (b). Keep `DetailView` for album/playlist/podcast; split artist out rather than adding more `switch item.kind`.

### 8. Podcasts: show notes, dates, "Continue listening"
- **Pain / JTBD**: Podcast listeners need to know what an episode is about and pick up where they left off. Riff already persists resume positions but never shows them; episode rows have no description or date.
- **Evidence**: `PlayerBridge.swift:1395-1450` (`episodePositions` persisted, applied silently); `MediaItem.swift` has no `description`/`publishedAt`; PLAN Phase 2 "🚧 Podcasts dedicated UX — show-notes … 'Continue listening' deferred"; README claims "Podcasts as first-class".
- **MVP cut**: parse `description` + date runs from `musicMultiRowListItemRenderer` / episode rows; episode row shows date + 2-line notes + thin progress bar from `episodePositions` (+ "Played" check when cleared); Home/Library "Continue listening" shelf from `episodePositions` (needs title/thumb — store a small `MediaItem` alongside the position); Context tab shows full show notes for the playing episode.
- **Effort**: M.
- **Deps / risks**: Lock — none. Subscribe pairs with #3.

### 9. Search polish: `.all` continuation, ⌘↵ enqueue, section jump
- **Pain / JTBD**: Under "All" the list stops at YT's first shelf set with no way to load more; the documented ⌘↵ "add to queue" does nothing; the "Songs / Albums" group headers are not tappable to switch the filter.
- **Evidence**: `SearchView.swift:24-28` (nil token under `.all`), `:14-17` vs `:418-424` (⌘↵ documented, only ↵ handled), `:471-479` (headers are plain `Text`).
- **MVP cut**: per-shelf "Show all songs ›" on `.all` group headers (sets `filter`), ⌘↵ → `addToQueueEnd` with toast, ⇧↵ → `playNext`; hover Play on artist/album rows (`SearchResultRow`); when `.all` returns a `musicShelfRenderer` with its own `bottomEndpoint`, use it as the "See all" target. Low-hanging.
- **Effort**: S.
- **Deps / risks**: Lock — none (existing `playNext` / `addToQueueEnd` UI call sites).

### 10. Drag songs into the queue + queue meta line
- **Pain / JTBD**: Power users build queues by dragging (Spotify/Apple Music). Riff has drag only for reordering inside Up Next; there is no "N songs · 42 min left" on the queue.
- **Evidence**: `QueueDragReorderModifier.swift` (queue rows only); `draggable` = 9 hits all in queue; Up Next header `NowPlayingView.swift:831-960` has Save/Clear/Build/Tune but no count/duration.
- **MVP cut**: `.draggable(item)` on `SearchResultRow`, `TrackRow`, `ThumbnailButton` (song kinds) with a `MediaItem` transferable; Up Next pane is a `dropDestination`: drop = **Add to queue** (end), ⌥-drop = **Play next**. Header line "12 songs · 41 min". Keyboard ⌫ on a focused queue row = remove.
- **Effort**: M.
- **Deps / risks**: Lock — **stay inside the contract**: drop maps only to the existing `playNext` / `addToQueueEnd` entry points (rows 5 and 13); do **not** implement "drop at index" (that is an ordering mutation the page does not expose natively — would need a table row and a page-native path). Insert-at-index is a Phase-D question.

### 11. `riff://` URL scheme + system Share sheet
- **Pain / JTBD**: A YT Music link from Messages/Slack opens the browser, not Riff; "Copy share link" is a clipboard-only share. Spotify/Apple Music both register schemes and handle universal links.
- **Evidence**: `Info.plist` has no `CFBundleURLTypes`; `NSSharingService`/`ShareLink` = 0; `openYouTubeMusicLink` already routes watch/playlist/browse/channel (`AppEnvironment.swift:696-737`).
- **MVP cut**: register `riff://` (and `x-riff://open?url=…`) in `project.yml` info properties, `.onOpenURL` on `RootView` → `openYouTubeMusicLink`; "Share…" (`ShareLink`/`NSSharingServicePicker`) in `TrackContextMenu` and Now Playing ⋯; Intents get an `OpenURL`-style entry so Shortcuts can deep-link. Universal links to `music.youtube.com` require an associated-domain entitlement Riff cannot get — document as out of reach.
- **Effort**: S.
- **Deps / risks**: Lock — none (link → existing `play(videoId:)` / `playPlaylist`).

### 12. Find-in-page for long tracklists + "scroll to now playing"
- **Pain / JTBD**: Once #1 lands, an 800-track playlist needs a filter (Library has one; Detail has none) and a way to jump to the playing row. ⌘F today yanks the user to the Search tab.
- **Evidence**: `LibraryView.swift:151-201` (filter capsule), `DetailView.swift:101-116` (sort menu only); `AppEnvironment.focusSearchField` `:311-314`.
- **MVP cut**: filter capsule above the tracklist (title/artist contains), ⌘F while a DetailView is on top focuses it (fall back to Search tab otherwise), "Now playing ↓" chip appears when the current track is off-screen (`ScrollViewReader.scrollTo`).
- **Effort**: S.
- **Deps / risks**: Lock — none. Filtered Play should play the filtered list (mirror the existing "Play honors sort" rule at `DetailView.swift:495-505`).

**Suggested sequencing**: #1 → #2 → #3 (day-0 copy fix first) → #5 → #6 → #9 → #12 · then #4 → #7 → #8 · then #10 → #11. The first block is ~2 weeks and turns Library/Detail from "demo" into "daily driver"; the second makes Explore/Artists real; the third is delight.

---

## C. Three things NOT to build (and why)

1. **Drop-at-index queue insertion / free-form queue editing in the page's store.** Field evidence on 2026-09-10 (`docs/QUEUE-DESIGN.md` row 13) shows a single direct `REMOVE_ITEM` dispatch desynced the page's store from its player and broke every later Next. Until Phase D's gate passes (`tools/harness/fieldcheck.sh` PASS on Play Next / row tap / remove), queue edits stay on the page's own actions. Any "drag to position" feature would need a new page-native path **and** a `QueuePolicy` table row — high risk, and the user-visible win over "Play next / Add to queue" is marginal.

2. **Native EQ / audio normalization via `AVAudioEngine` taps, or any audio-path feature (AirPlay picker, gapless, true crossfade).** The audio path is WebKit's Widevine pipeline by design (ARCHITECTURE.md ADR-001). Tapping it means capturing the WebView's audio output — a stream-extraction cousin that breaks the "no extraction" line, and macOS has no `AVRoutePickerView` anyway (`NowPlayingView.swift:620-628` already explains why the button opens System Settings). The in-browser normalization + volume-only crossfade are the honest ceiling; say so in Settings copy (it already does).

3. **Light theme / theme switcher and Windows/Linux ports.** The product wedge is "feels like YouTube Music iOS on a Mac" (PRODUCT_SPEC anti-criteria: "the sidebar reads as Apple Music"). YT Music iOS is dark-only; a light theme doubles the design surface (`Theme.swift`, every `.white.opacity(...)` literal — hundreds of them) for no retention story, and PLAN.md already parks it. Same for cross-platform: PLAN Phase 4 says fork, not share; do not let "Skip"/Tauri talk into the SwiftUI codebase. Spend those weeks on #1–#5 instead.

Also not now, for the record: BYO-LLM expansion (more providers / features) — three backends and three features exist; zero users are blocked on a fourth provider, while every signed-in user is blocked on Library completeness.
