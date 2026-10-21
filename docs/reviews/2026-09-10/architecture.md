# Riff — Architecture Review

Reviewer: Arjuna (Principal SDE) · Date: 2026-09-10 · Branch: `queue-and-ux-enhancements` @ `9c39606`
Scope: read-only review of the audio core, data layer, auth, app shell, harness, CI. No repo changes made.
Verification run: `./tools/harness/run.sh` → static guards OK, Swift harness 97/97, JS harness 41/41.

## 0. Verdict in one paragraph

The load-bearing decisions are right and they are holding: the WKWebView is invisible, the page is the single playback authority, the decision table in `QueuePolicy` is pure and fenced, and the field methodology (log audit lines + `fieldcheck.sh`) is the reason the last two weeks of queue work converged instead of oscillating. The architecture's real debt is not in the design but in three places the design has outgrown: (1) `PlayerBridge.swift` is a 2,586-line god object carrying nine unrelated concerns plus the residue of the pre-single-authority queue model (pending-URL, enforcement, two-region), (2) the InnerTube/auth layer trusts a one-shot cookie copy and a hard-coded client version, both of which will silently rot under the user, and (3) observability is tuned for a developer with `log stream` open, not for a user's diagnostics export. Phase D is blocked on one missing capability — a page-native Play Next — and Section B.1 proposes a concrete route to it that reuses the page's own `queueAddEndpoint` action rather than its store.

Metrics that anchor the review:

| Metric | Value | Source |
|---|---|---|
| `PlayerBridge.swift` | 2,586 lines, 66 of 208 repo commits (32%), 20 in last 30 days | `wc`, `git log` |
| `NowPlayingView.swift` | 2,481 lines, 57 commits | same |
| `InnerTubeClient.swift` | 1,704 lines, 40 commits | same |
| `player-bridge.js` | 1,381 lines, 33 commits, no schema/version constant | `grep -n version` → none |
| UserDefaults call sites | 30 in PlayerBridge, 28 in AppEnvironment; ~31 distinct `player.*/auth.*/library.*` keys as string literals | `grep -rc UserDefaults` |
| Log calls | 42 `bridge.debug`, 20 `innertube.debug`, 9 `.error`, **0** `.notice`/`.info`; 0 `privacy: .private` | `grep -rhoE "Log\.[a-z]+\.(...)"` |
| Cookie sync WebView→HTTPCookieStorage | called once, `SignInView.swift:86` | `grep syncFromWebView` |
| XCTest | 14 files, ~209 tests; `PlayerBridge` is never instantiated in tests | `grep -c "func test"` |
| CI | build + `xcodebuild test`; **harness is not run in CI**; no nightly canary (ARCHITECTURE.md claims one) | `.github/workflows/ci.yml` |

---

## A. Current-state assessment per dimension

### A.1 Module boundaries and size

**Strengths**
- The one architectural rule is structurally enforced, not just documented: the only `WKWebView` outside `HiddenPlayerWebView` is the sign-in sheet's `SignInWebView` (`Sources/UI/SignInView.swift:105`), and `HiddenPlayerWebView.swift:79-88` parents the player in a 1×1, alpha-0, ordered-out window.
- Pure logic has been carved out where it hurt most: `QueuePolicy` (123 lines, zero deps), `QueueManager` (300), `SmartShuffle`, `BrowseIdResolver`, `PlayedHistoryStore`, `CookieImporter`. Each has a harness or XCTest home.
- `BrowseIdResolver` and `PlayedHistoryStore` document their own extraction ("audit §6.8") — the team already knows the pattern that works.

**Risks**
- `PlayerBridge` carries at least nine concerns in one `@Observable @MainActor` class: transport commands (`503-700`), context/queue reconciliation (`2069-2578`), `/next` metadata refresh (`780-958`), chips (`960-1011`), lyrics/related loading (`1046-1115`), session snapshot/restore (`240-306`), podcast resume positions (`1395-1450`), sleep timer + volume fade (`1808-1961`), playback prefs persistence (`159-218`, `1963-2019`), and the JS eval queue with timeout (`2021-2066`). Every one of these has a different change cadence; the file's 32% commit share is the symptom.
- Pre-single-authority residue is still live and interleaved with the new model: `syncPendingNextURL` (`1681-1706`), `pendingNextURLArmed` (`140-141`), the WYSIWYG enforcement branch (`2400-2418`), the two-region user/server split in `QueueManager`, `AdvancePlan` (`1629-1679`). `docs/QUEUE-DESIGN.md` Phase D names exactly these for deletion; until then each new feature must reason about both models.
- `AppEnvironment` (1,099 lines) is the second god object: sign-in state machine, toasts, notifications, metadata overrides, LLM provider selection, scrobbling pipeline, navigation paths, block/pin/follow lists, link opening, sleep/wake, widget commands. It also holds the `onUpdate` fan-out (`962-1050`) that is effectively a second observation system.
- `InnerTubeClient` mixes transport (`postRaw` 1633-1687), ~25 endpoint methods, and ~600 lines of renderer parsing in one `@unchecked Sendable` class. Parsing is static and pure — it could live in `Parsing`/`RendererKeys` files already present but underused.

### A.2 State management (@Observable, MainActor, ObservationIgnored)

**Strengths**
- `@MainActor` isolation is consistent across `PlayerBridge`, `QueueManager`, `HiddenPlayerWebView`, `AppEnvironment`, `NowPlayingCenter`; `SWIFT_STRICT_CONCURRENCY: complete` is on in `project.yml`. `MainActor.assumeIsolated` is used correctly at the AppKit/MediaPlayer callback edges (`NowPlayingCenter.swift:44-96`, `AppEnvironment.swift:868-960`).
- Background work is disciplined: `refreshNextQueueAndIds` cancels-and-replaces (`780-783`) and re-checks `Task.isCancelled` after every await; `nextQueueTask` is the single in-flight handle.
- `@ObservationIgnored` is applied to plumbing (closures, tasks, timestamps) so SwiftUI does not re-render on bookkeeping writes.

**Risks**
- Hot and cold state share one observable: `elapsed`/`duration` mutate at ~4 Hz (`.progress` at `2318-2346`) on the same object as `currentTrack`, `upNext` pass-throughs, `liked`, `lyrics`. Any view body touching `player.elapsed` re-evaluates 4×/s; `NowPlayingView` (2,481 lines) does. `QueueManager.playedHistory` is already stored-not-computed because of exactly this (`QueueManager.swift:50-54`) — a symptom of the split not having been made at the source.
- Context flags that views branch on are `@ObservationIgnored`: `isRadioContext`/`isPageDrivenContext` (`78-88`) read `currentPlaylistId` and `activeChip`, both ignored. The comment at `84-86` acknowledges views must pair the read with an observed property. That is a staleness hazard class, not a single bug.
- `onUpdate` (`106-107`) is a manual observer bus invoked at the end of every event (`2577`); `AppEnvironment` throttles it itself (`306`, `975-1000`). Two observation systems for the same state is duplicated policy.
- Unstructured `Task { [weak self] ... }` with sleeps used as verification timers: `skipTo` 2.5 s (`1749-1763`), `togglePlay` resume 1.5 s (`1290-1300`), pause-enforce 12 s windows (`2094`, `2180`). None are cancelled on navigation/sign-out; they are correct by luck of ordering.

### A.3 The JS bridge as an external API

**Strengths**
- The bridge is designed as an API: `window.musicBridge` (`Resources/player-bridge.js:75-443`) is the sole Swift→page surface; Swift never touches the DOM directly (`PlayerBridge.eval` builds only `window.musicBridge.*` calls).
- The dangerous seams are documented and fenced: identity-only row clicks (`403-427`), `playVideoAt` banned by `guard.sh:20`, store dispatch off by default with the field reason recorded inline (`707-709`), a one-shot `queueApi:` probe to discover the page's real API (`715-744`).
- Event ingestion is hardened: main-frame + host check (`HiddenPlayerWebView.swift:94-101`) blocks iframe spoofing; every event is decoded into a typed enum; hot events skip body logging.
- Setup is race-free (poll-with-backoff to `playerApi`, `982-1040`) with a lower-fidelity mediaSession fallback and a diagnostic when it triggers.
- The JS harness (`js-harness.mjs`, 41 checks) simulates five store shapes, dedup, caps, menu-based removal, identity clicks. This is unusual and valuable.

**Risks**
- No schema version or capability handshake. `ready` is a bare `{event:"ready"}`. Swift cannot tell whether the page it is talking to supports `queuePlayItem`, `toggleShuffle`, or the store mirror until a call silently does nothing (e.g. `toggleShuffle` returns `false` and only fires a diagnostic once, `373-390`).
- Selectors are spread rather than registered: `.next-button`/`.previous-button` (`432-433`), `ytmusic-player-queue-item` (`411`, `802`), `QUEUE_ROW_MENU_BUTTON`/`QUEUE_MENU_ITEMS` (`833-834`), five shuffle candidates (`373-379`), `ytmusic-play-button-renderer, #play-button, .play-button` (`419`), `a[href*="list="]` (`483`). The comment "Selectors are the fragile external API — kept in one place" (`832`) is aspirational; there are at least six places.
- Text-matched menu items: `removeViaRowMenu` matches `"remove from queue"` in `textContent` (`814-815`) — locale-dependent. A user with YT Music in Telugu or German gets `menu:no-remove-item` every time.
- `navigate(url)` is `location.href = url` (`79`): every play is a full document reload — re-injection, `ready` again, `stickyPlaylistId` reset, mirror reset (`PlayerBridge.navigate` `1255-1264`), and 1-3 s of latency before audio. YT Music is an SPA; the page's own router would make click-to-play an in-app navigation.
- Global mutable state on `window.__riff*` (`__riffQueueSig`, `__riffPendingNextUrl`, `__riffSafetyPollId`, `__riffStoreDispatchEnabled`, `__riffQueueApiReported`, ...) — at least ten flags. Fine for a page script, but they are the bridge's real state and they are not enumerated anywhere.
- `MutationObserver` on `document.documentElement` with `subtree: true` (`1030-1032`), debounced to 500 ms. Debounce bounds the callback cost, but the observer itself still records every mutation in a continuously-mutating SPA.

### A.4 InnerTube client resilience

**Strengths**
- Sensible transport defaults: 10 s request / 30 s resource timeouts (`InnerTubeClient.swift:60-65`); `hl`/`gl` from `Locale`; SAPISIDHASH auth computed correctly (`1691-1703`); 401/403 mapped to a typed `needsReauth` that `ErrorBanner` (`ErrorBanner.swift:56-63`) turns into a re-auth affordance.
- Parsing is defensive (`Parsing.dig`/`array`/`runs`, multiple candidate paths, `scanForMediaItems` walker) and the "thin `/next`" case has two fallbacks (`PlayerBridge.swift:805-830`).
- `HomeFeedCache` (24 h TTL, Caches dir, cache-then-network in `HomeView.swift:157-178`) is the right pattern for cold start.
- `sessionLiveness()` is tri-state (`1149-1158`) and the caller never treats transport failure as "dead" — correct.

**Risks**
- `clientVersion = "1.20260501.00.00"` is a hand-maintained constant (`32`) while the hidden page already carries the live value in `ytcfg.INNERTUBE_CLIENT_VERSION` (the JS reads `ytcfg` at `872` for another purpose). The "single rotation point" is a manual dial when it could be an automatic one.
- No retry, no backoff, no 429 handling, no single-flight: `postRaw` does one `session.data(for:)` (`1668`). A transient failure on `/next` leaves Up Next empty until the next track change; a flaky network during Home load renders an error banner rather than the cached feed.
- `X-Goog-AuthUser: 0` hard-coded (`1647`). Users signed into multiple Google accounts in the WebView get the wrong account for every InnerTube call while the page plays under the right one.
- No offline model: no `NWPathMonitor`, no `isOffline` (grep: none). Offline is indistinguishable from "YouTube broke".
- Error bodies are logged `.public` up to 400 chars (`1672-1673`). Account-related endpoints (`account_menu`, playlist edits) can echo identifiers; this leaks into the diagnostics export.
- Docs drift: `ARCHITECTURE.md` and the class doc (`InnerTubeClient.swift:13-15`) promise snapshot fixtures for every endpoint and a nightly sentinel job. Neither exists (`Tests/` has no fixtures directory; parser tests build dictionaries inline; no scheduled workflow).

### A.5 Session / auth lifecycle

**Strengths**
- Sign-in truth is probed, not inferred (contract row 8): `refreshSignedInState` requires a non-expired auth cookie (`AppEnvironment.swift:37-77`), `probeSessionLiveness` (`103-124`) throttles to 10 min, remembers the dead cookie signature so reactivation cannot flip-flop, and toasts exactly once.
- Sign-out is complete: `HTTPCookieStorage` purge + `CookieJar.purgeWebViewSession` (`CookieJar.swift:60-84`) clears cookies, localStorage, IndexedDB, service workers for Google/YouTube hosts, so account switching works.
- Secrets live in Keychain (`Keychain.swift`), never UserDefaults; the diagnostics export explicitly excludes them (`DiagnosticsExporter.swift:6-18`).

**Risks**
- **One-shot cookie copy.** `CookieJar.syncFromWebView()` runs only from the sign-in sheet (`SignInView.swift:86`). Google rotates session cookies in the WebView over days/weeks; `HTTPCookieStorage.shared` keeps the sign-in-day snapshot. Outcome: InnerTube goes anonymous (Library blank, Home generic), the liveness probe marks the session dead, the user is told "session expired" — while the hidden page is still happily signed in and playing Premium. This is the single most likely cause of a "why does it say I'm signed out?" bug report, and it is invisible in the harness.
- Two sign-in models coexist (WebView cookies + OAuth Device Flow, `OAuthDeviceFlow.swift`), and `postRaw` explicitly does not send Bearer (`1634-1638`) while `dataAPI` does. The OAuth path is documented as a dead end for the default client (`PLAN.md` Phase 2). Dead-but-live code paths cost review attention every time auth changes.
- The sign-in sheet's completion detection (`SignInView.swift:140-151`) relies on URL/cookie heuristics inside a WKWebView; Google's 2FA steps "often can't complete inside a WKWebView" (comment at `57`). Cookie paste import exists as the escape hatch, which is right, but it is buried in Settings.

### A.6 Persistence

**Strengths**
- Journals are versioned and migrated (`player.history.v2` → `v3`, `PlayedHistoryStore.swift:41-83`); tests inject a suite so fixtures do not pollute production defaults (`testArchiveDoesNotPollutePerformanceUserDefaults`).
- `HomeFeedCache` correctly uses Caches, not defaults, for a large blob.
- Rate limiting is present where writes would be hot (`snapshotSessionIfDue` 5 s, `lastEpisodePositionSaveAt`).

**Risks**
- UserDefaults is used as a database: history (500 × `MediaItem` JSON, rewritten on every `archive`), `player.lastSession` every 5 s, `player.episodePositions`, `library.trackOverrides`, blocked/followed/pinned dictionaries. Every `set` rewrites the whole defaults plist; the plist is synced by `cfprefsd`. This is not a correctness bug today; it is a latency and growth cliff (and the Recap/Stats surface wants *more* than 500 entries).
- ~31 dotted string keys scattered across 12 files with no central registry; `DiagnosticsExporter.swift:134` re-types `"player.history.v3"` by hand. A rename is a grep exercise with no compiler help.
- No "clear caches" path exists (`grep HomeFeedCache.clear|URLCache.shared.removeAll` in Settings → none) though `HomeFeedCache.clear()` documents one.

### A.7 Startup / resume path

**Strengths**
- The WebView is created and `music.youtube.com` loaded eagerly in `PlayerBridge.init` (`186-188`) so the first click does not pay the page load; commands before `ready` are queued and flushed (`2023-2039`); prefs are re-applied on every `ready` (`2073-2103`) because SPA reloads lose them.
- `restoreLastSession` (`277-306`) repopulates the mini bar without auto-playing; 7-day staleness cutoff.
- Sleep/wake reassertion (`AppEnvironment.swift:911-960`) handles the "WebKit auto-resumes on wake" quirk with cancellation of stacked tasks.

**Risks**
- `AppEnvironment.init` (`803-860`) does synchronous work on the main thread before the first frame: `URLCache` construction, Keychain read (`OAuthTokens.load()` inside `refreshSignedInState`), history JSON decode (`QueueManager.init`), `restoreLastSession` decode, `DiagnosticsCenter.start()`, and it fires a network probe (`probeSessionLiveness(force: true)`) at init. No signposts exist to measure any of it (grep: none).
- Resume seek is a fixed 1.5 s sleep then seek (`1290-1300`). On a cold WebView or slow network the seek lands at 0 silently. The right trigger already exists — the first `.progress` with `duration > 0` for the target `videoId` — and `applyEpisodeResumeIfNeeded` (`1437-1449`) already uses exactly that pattern for podcasts.
- `ready` is the only "page is up" signal; there is no "page is up and the queue store is readable" signal, so the mirror's first snapshot is a race the Swift side papers over with `mirrorFresh`.

### A.8 Energy and memory

**Strengths**
- Deliberate throttling: NowPlaying updates skip progress-only ticks unless seeked or duration arrived (`AppEnvironment.swift:986-1001`); the JS safety poll and normalization tick pause on app deactivation (`setBackgrounded`, `player-bridge.js:150-181`); `MutationObserver` debounced; `queueSnapshot` deduped by signature and capped at 80 rows.
- Artwork: `URLCache` bumped to 64 MB / 512 MB (`AppEnvironment.swift:803-817`); `NowPlayingCenter` keeps a 16-entry `MPMediaItemArtwork` cache; next-track artwork prefetched at 85 % (`713-740`).

**Risks**
- The 2 s safety poll (`623-628`) runs `emitTrackChanged` + `emitQueueSnapshot` (store walk + up to 80 renderer unwraps + JSON serialisation across the bridge) for the whole session while the app is active. A store subscription (`store.subscribe`) would make the mirror event-driven; the poll should be the fallback, not the primary.
- 4 Hz `progress` messages cross the WebKit IPC boundary and mutate an observable. Wall-clock extrapolation between 1 Hz syncs (what `MPNowPlayingInfoCenter` itself does) would cut this 4×.
- No memory measurement anywhere; the ADR's "~50-80 MB WebView" figure is unverified in-repo. `DiagnosticsCenter` (MetricKit) will report hangs/crashes but not steady-state footprint.
- `AsyncImage` in 13 view files with no decode-size control: full-resolution covers decoded for 48-pt thumbnails in carousels.

### A.9 Testability

**Strengths**
- Two-tier testing that matches the sandbox reality: XCTest (~209 tests) for parsers, sorting, stats, scrobblers, intents; the standalone harness (`tools/harness/run.sh`) for the queue core, runnable without Xcode project generation. The 5,000-op fuzz with invariants (`QueueLogicTests.swift:171`) and the decision-table enumeration (`250`) are the right shape.
- Static guards (`guard.sh`) freeze the surfaces that caused every regression: navigation and force-play call-site counts, index-guessing, positional clicks, duplicate type declarations, attribute/doc-comment splits.
- Field verification is a first-class tool (`fieldcheck.sh` grades a captured log against the Phase D gate).

**Risks**
- `PlayerBridge` cannot be constructed in a test: `init` builds a `HiddenPlayerWebView` (a real `WKWebView` + `NSWindow`) and loads the network. The entire reconciliation logic in `handle(_:)` (500 lines) — the part that has produced every user-visible queue bug — is tested only in the field. Tests referencing `PlayerBridge` use only its nested types.
- The harness compiles `QueueManager` with `@Observable`/`@MainActor` stripped by `sed` (`run.sh:36-37`). It works, but it is a fork of the source under test; any macro-dependent code added to `QueueManager` breaks it in a confusing way.
- The harness is not in CI (`ci.yml` runs only `xcodebuild build/test`); it is gated by an opt-in pre-commit hook. A PR that fails the behavior contract can merge green.
- No live canary. Parser tests use hand-built dictionaries, so a Google-side renderer rename is discovered by users.

### A.10 Release engineering

**Strengths**
- XcodeGen `project.yml` as source of truth, pinned Xcode 16 on `macos-15`, tag-driven release workflow that builds Release and attaches a zip; hardened runtime and sandbox entitlements are on.
- Honest documentation of what is blocked on a paid developer account (widget target, passkeys, notarization) with re-enable steps inline.

**Risks**
- Ad-hoc signing only; users right-click → Open. No notarization path even drafted for when the account exists.
- `CFBundleVersion` is a static `"1"` (`project.yml:38`) — every build is indistinguishable in a crash report or a diagnostics manifest.
- No update mechanism, not even an opt-in "a newer release exists" check. Combined with the InnerTube rotation risk, users will be stranded on broken builds without knowing a fix shipped.
- `release.yml` does not run tests or the harness before cutting a release.

### A.11 Observability

**Strengths**
- `os.Logger` throughout with a single subsystem and category split (`Log.swift`); the audit lines in the bridge are designed to be graded (`advance arrived=… match/MISMATCH`, `queueAddResult VERIFIED`, `ready`, `context switch → list=`), and `fieldcheck.sh` consumes them. That closed loop is the project's best engineering asset.
- `DiagnosticsExporter` has a clear privacy contract (no keys, tokens, cookies, DOM), warns about listening history, and reveals the folder in Finder.
- Iframe-spoofing defence and hot-event log suppression show that logging cost and trust were both considered.

**Risks**
- **The export and the field workflow disagree.** Every audit line is `.debug` (42 of 42 bridge calls); the exporter deliberately drops below `.notice` (`DiagnosticsExporter.swift:120-126`). A user's diagnostics dump therefore contains at most nine `.error` lines and none of the lines `fieldcheck.sh` needs. Field verification only works when a developer has `log stream --level debug` running at capture time.
- All interpolations are `.public` (0 `.private`): titles, artists, and response-body previews are unredacted. Acceptable for a local log, not for a file the user is asked to attach to a public GitHub issue.
- Category sprawl: four core loggers plus six ad-hoc `Logger(...)` instances in AI/diagnostics/oauth files; `bridge` carries queue, transport, session and sleep-timer lines alike.
- No app-side ring buffer: OSLogStore persistence of debug entries is "environment-dependent" (their own comment); there is no in-memory journal the exporter can dump regardless.

### A.12 Security posture (brief, for Bhishma's joint review)

- Good: main-frame origin check on the message handler; `isInspectable` debug-only; sandbox + hardened runtime; Keychain for secrets; no telemetry.
- Watch: JS eval strings are built by interpolation with a JSON-quoting helper (`2581-2585`) — correct today, but a typed command builder would make it impossible to forget. The `ytcfg`-fetch fallback in JS (`876-884`) posts with the page's API key from same-origin — fine, but it is a second InnerTube client that lives in JS; keep it single-purpose.

---

## B. Opportunities ranked by leverage

Effort: S ≤ 2 days, M ≤ 1.5 weeks, L > 1.5 weeks. Risk = chance of user-visible regression while landing.

| # | Opportunity | Effort | Risk | Depends on |
|---|---|---|---|---|
| 1 | Page-native Play Next / Add to queue via the page's own `queueAddEndpoint` action | L | Med | — |
| 2 | Phase D: delete pending-URL, enforcement, two-region apparatus | M | Med | 1 verified in field |
| 3 | Continuous cookie sync (WKHTTPCookieStore observer) + `SESSION_INDEX` for `X-Goog-AuthUser` | S | Low | — |
| 4 | Bridge handshake: `ready` carries `schema`, `capabilities`, and page `ytcfg` (client version, context, visitor data); `clientVersion` becomes a fallback | S-M | Low | — |
| 5 | SPA navigation instead of `location.href` (click-to-play without reload) | M | Med-High | 4 (capability flag), ideally 1 (same resolver) |
| 6 | `PlayerBridge` decomposition (collaborators + `PlaybackContext` value type + file split, guard-compatible) | M | Low-Med | non-queue slices now; queue slices after 2 |
| 7 | Harness in CI + SwiftPM `RiffCore` package (drop the `sed` strip) + nightly anonymous InnerTube canary | S-M | Low | — |
| 8 | Fake-page seam: `PageDriving` protocol so `PlayerBridge` runs in XCTest against a scripted page; replay field logs as tests | M | Low | 6 (PageCommands extraction) |
| 9 | Observability: audit lines → `.notice`, in-memory `BridgeJournal` in the export, `.private` on titles/bodies, `queue`/`session` categories, `fieldcheck.sh` reads the export | S | Low | — |
| 10 | Hot/cold observable split (`PlaybackProgress`) and observed `PlaybackContext` (kills the `isRadioContext` staleness class) | S-M | Low | overlaps 6 |
| 11 | Event-driven resume and jump verification (replace the 1.5 s / 2.5 s sleeps) | S | Low | — |
| 12 | InnerTube transport hardening: retry/backoff, 429, single-flight, stale-while-revalidate `BrowseCache`, `NWPathMonitor` offline mode | M | Low | — |
| 13 | Persistence consolidation: typed key registry; journals to Application Support files; append-only history with age cap; real "Clear caches" | M | Low | — |
| 14 | Energy: store subscription instead of 2 s poll; narrowed `MutationObserver`; 1 Hz progress + wall-clock extrapolation; signposts + memory report | S-M | Low | 4 (capability: `storeSubscribe`) |
| 15 | Release: CI version stamping (re-sign after stamp), harness + tests gating `release.yml`, notarization job drafted, opt-in update check | M | Low | 7 |

### B.1 Page-native Play Next — options, ranked

Constraint recap (field 2026-09-10): the `ytmusic-app` store is not the player's playlist. `ADD_ITEMS`/`REMOVE_ITEM` dispatches edit what the queue panel shows without telling the player; the two never resync. Removal was fixed by driving the row's own "⋯ → Remove from queue" (page action, `removeViaRowMenu`). Play Next needs the same class of solution: **an action the page itself performs**, so the store and the player are updated by the page's own controller. The `queueApi:` one-shot probe (`player-bridge.js:715-744`) already logs the function surface needed to pick between the options below; the next field capture should be read for it before implementing.

**Option A (recommended) — issue the page's own `queueAddEndpoint` command.**
Every "Play next" / "Add to queue" menu item in YT Music is a `ytmusic-menu-service-item-renderer` whose data carries
`serviceEndpoint: { queueAddEndpoint: { queueTarget: { videoId } | { playlistId }, queueInsertPosition: "INSERT_AFTER_CURRENT_VIDEO" | "INSERT_AT_END" } }`.
Clicking it makes the app resolve the endpoint through its command handler, which is what updates the queue controller (store **and** player) coherently. Two implementation flavours, try A1 first:

- **A1 — synthetic menu item.** In JS: create a `ytmusic-menu-service-item-renderer`, set `.data` to the endpoint above, append it to the existing `ytmusic-popup-container` (or `document.body`), call `.click()`, remove it. This exercises the exact component and event path the real menu uses; no internal function names involved. Works for any `videoId` and, via `queueTarget.playlistId`, adds a whole album/playlist in one action (better than N inserts, and it preserves the page's own ordering).
- **A2 — direct resolver.** Find on `ytmusic-app` (or `app.inst`) the command resolver the probe reports (names historically like `resolveCommand`, `handleServiceRequest_`, or an `onYtAction` handler) and call it with `{ queueAddEndpoint }`. Fewer moving parts, more dependent on a minified internal name. Use only if A1's click does not resolve (watch for a `yt-service-request`/`yt-action` event on the element to confirm the path).

Verification (keep the existing `queueAddResult` event, extend the `via` vocabulary to `endpoint:menu-item` / `endpoint:resolver`):
1. Store presence at the expected index (selected+1 for next, end of `items` for end) — already implemented at `297-316`.
2. **Player agreement** — new, and the one the store-dispatch path lacked: on the next advance the arrival must equal the shown head (`advance arrived=… match`, already graded by `fieldcheck.sh`). Add a JS-harness case that asserts a synthetic-item click fires the service event and that no `store.dispatch` was called.
3. Swift side: on `ok=true`, the item is already page-owned (`pageOwnedQueuedIds`), exactly the Phase B hook; on `ok=false`, the legacy path stays armed until Phase D removes it.

**Option B — call the queue controller directly.** `ytmusic-player-bar`.queue exposes functions (the probe lists them); the controller is what keeps store and player coherent, so its `addItems`/`insert`-style method is page-native one level below the UI. Second choice because the names are unstable and the argument shapes (renderers from `music/get_queue`, which `fetchQueueRenderers` already obtains) need live confirmation. Same verification as A.

**Option C — rendered-row menus.** Identity-match a `ytmusic-responsive-list-item-renderer` in the Related tab or a `ytmusic-player-queue-item`, open its ⋯ menu, click "Play next" (the removal pattern). Only covers songs the page has rendered; locale-dependent text match. Useful as a fallback for Up Next/Related rows, not a general solution.

**Option D — status quo.** Riff's pending-URL navigation. A reload per injection; the thing Phase D deletes.

Ranking rationale: A is universal (any id, any container), uses the page's own semantic, needs no internal names in its primary flavour, and is verifiable with the events and grader that already exist. B is a reasonable second only because the probe already logs it. C and D are fallbacks.

### B.2 `PlayerBridge` decomposition — target shape

Guard compatibility first. `guard.sh:29-35` counts `await navigate(` and `play(item:` in `Sources/Audio/PlayerBridge.swift` only. Rule for the split: **navigation and force-play call sites stay in `PlayerBridge.swift`**; extracted collaborators never navigate or force-play, they return decisions or effects that `PlayerBridge` executes. Add a guard row asserting `navigate(`/`play(item:` appear in no *other* file under `Sources/Audio/` — a stronger fence than today, and the counts do not change, so no allowlist bump.

Target files (approximate line budgets; today's total 2,586):

| File | Lines | Contents | Testable how |
|---|---|---|---|
| `PlayerBridge.swift` | ~550 | Public playback API (`play*`, `next`, `previous`, `seek`, `skipTo`, `playTracks`, queue ops), owns collaborators, the five `navigate` and six `play(item:)` sites | field + fake page (B.8) |
| `PlayerBridge+Events.swift` | ~350 | `handle(_:)` split per event; each feeds `QueueReconciler` and applies returned effects | fake page |
| `PlaybackContext.swift` | ~120 | Value type: `currentPlaylistId`, `contextPlaylistId`, `contextTrackIds`, `contextIsPageOrdered`, `contextStartHistoryIndex`, `mirrorFresh`, `pageOwnedQueuedIds`, `activeChipId`, `userClickedAt`; `beginContext`, `beginNavigation`, `isRadio`, `isPageDriven`, `advanceInputs(for:userQueued:)` | harness (pure) |
| `QueueReconciler.swift` | ~250 | Pure: `(event, context, queue view) → [Effect]` where `Effect` ∈ `.archive`, `.consumeUpTo(id)`, `.mirror(rows)`, `.dropStale`, `.refreshMetadata(updateQueue:)`, `.cycle(tracks)`, `.forcePause(seconds)`, `.audit(label)` | harness, replaying captured field sequences |
| `PageCommands.swift` | ~130 | `eval` queue, `ready` flush, timeout; typed builders (`.navigate(url)`, `.queueAdd(id, pos)`, `.playItem(id)`, …) behind `protocol PageDriving` | XCTest with a fake |
| `PlaybackPrefs.swift` | ~150 | volume/rate/repeat/shuffle/smart-shuffle/normalization/autoplay/crossfade with persistence and the on-`ready` re-apply list | XCTest with a suite `UserDefaults` |
| `SessionSnapshot.swift` | ~120 | `LastSession`, episode positions, resume target | XCTest |
| `SleepTimer.swift` | ~180 | `@Observable`; modes, countdown, fade, enforce window; emits `pause`/`restoreVolume` requests | XCTest with a test clock |
| `TrackExtrasLoader.swift` | ~150 | lyrics / related / chips / liked per track, cancel-on-change | XCTest with a stubbed client |

Sequencing (each step: harness green, `xcodebuild build`, one field capture graded):
1. **Now, zero behaviour change:** `PlaybackPrefs`, `SleepTimer`, `SessionSnapshot`, `TrackExtrasLoader`, `PageCommands`. These do not touch the queue core; they remove ~750 lines.
2. **After 3/4/10:** `PlaybackContext` as an observed value (fixes A.2's staleness class in the same move).
3. **After Phase D:** `QueueReconciler` — extracting it *before* deletion would mean porting the enforcement and pending-URL branches only to delete them.

### B.3 Notes on the remaining opportunities

- **#3 cookie sync.** `WKHTTPCookieStore.add(_ observer:)` fires on any cookie change; on each, copy Google/YouTube cookies into `HTTPCookieStorage.shared` (the body of `syncFromWebView`), then call `refreshSignedInState()`. Also read `ytcfg.SESSION_INDEX` via the bridge handshake (#4) and send it as `X-Goog-AuthUser`. Expected effect: the "session expired while the page still plays" report class disappears.
- **#4 handshake.** `ready` → `{event:"ready", schema: 2, capabilities: ["queueMirror","queuePlayItem","toggleShuffle","queueAdd:endpoint"], ytcfg: {clientVersion, visitorData, sessionIndex, hl, gl}}`. Swift stores capabilities and hides/greys features the page cannot do instead of silently no-op'ing; `InnerTubeClient` takes `clientVersion` from the page with the constant as fallback, and the class doc is updated to say so. Also move every selector into one `SELECTORS` object at the top of the JS and have `ready` report which resolved (`selectorHealth`), so a Google-side rename is one diagnostic line, not a bug report.
- **#5 SPA navigation.** The same resolver from #1 accepts `{ watchEndpoint: { videoId, playlistId } }`; the page then performs its own in-app navigation: no document reload, no script re-injection, no `ready`, `stickyPlaylistId` survives. Because `navigate()`'s Swift call-site count is unchanged, the guard is untouched; what changes is the bridge emitting `navigated` (URL, reason) and `PlayerBridge.navigate` resetting `mirrorFresh`/`pageOwnedQueuedIds` on that event instead of on `ready`. Gate behind the capability flag and keep `location.href` as the fallback; verify with `fieldcheck.sh` (`ready` count per session should drop to ~1).
- **#9 observability.** Promote to `.notice`: `ready`, `play(item:)`, `context switch`, `advance arrived=`, `queueAddResult`, `queueRemoveResult`, `skipTo`, `MISMATCH`/`overriding`. Mark titles/artists/body previews `.private`. Add a 2,000-line in-memory `BridgeJournal` that the exporter always writes; teach `fieldcheck.sh` to accept that file. Then a user's export is a field capture.
- **#11 event-driven waits.** Resume: store `pendingResume` and seek on the first `.progress` where `currentTrack.videoId == target && duration > 0` (the podcast path already does this). Jump: the 2.5 s task becomes a cancellable timer cancelled by `pendingJumpTarget` arrival.
- **#12 transport.** Retry only idempotent reads (`browse`, `search`, `next`, `get_search_suggestions`), 2 attempts, jittered 300–900 ms, on `URLError` timeouts/network-lost and 5xx; honour `Retry-After` on 429; coalesce identical in-flight requests; `BrowseCache` keyed by `browseId` with stale-while-revalidate for album/artist/playlist detail and Library sections; `NWPathMonitor` → `isOffline` shown once in the toolbar and used to suppress the liveness probe and error banners in favour of cached content.
- **#13 persistence.** `enum Prefs { static let volume = Key<Double>("player.volume") … }` with typed accessors; journals as JSON files under `~/Library/Application Support/Riff/` with atomic writes; history as append-only JSONL with a 12-month age cap (Stats becomes honest beyond 500 plays); Settings gains "Clear caches" wired to `HomeFeedCache.clear()` + `URLCache.shared.removeAllCachedResponses()`.
- **#14 energy.** If `store.subscribe` exists (capability), subscribe and emit on change; keep the poll at 10 s as a watchdog. Observe `ytmusic-player-bar`/`ytmusic-player` subtrees, not `documentElement`. Emit `progress` at 1 Hz plus on seek/rate change; Swift extrapolates elapsed from wall clock (as `AppEnvironment` already does for NowPlaying). Add `OSSignposter` intervals for launch phases and a `MemoryReport` (task footprint) line in the diagnostics manifest.
- **#7 / #15 CI and release.** Add a `harness` job (`tools/harness/run.sh`, no Xcode project needed) to `ci.yml` and `release.yml`; add a scheduled workflow that runs anonymous `browseHome`, `search`, `next` against live endpoints and asserts parser output is non-empty (no sentinel account needed for shape drift); stamp `CFBundleVersion` from `git rev-list --count` in CI and re-sign after (the reason it was disabled locally); write the notarization job now, gated on secrets being present.

---

## C. Suggested 3-phase roadmap

### Phase 1 — Trust the ground (≈2–3 weeks; all S/S-M, all independent, all land before the next field campaign)
Goal: make the next field capture cheaper to get and more trustworthy, and remove the two silent-rot risks.
- #3 continuous cookie sync + `SESSION_INDEX`
- #4 bridge handshake (schema, capabilities, `ytcfg` client version, selector registry + health)
- #9 observability (notice-level audit lines, `BridgeJournal` in export, `.private`, `fieldcheck.sh` reads the export)
- #7 harness in CI + `RiffCore` SwiftPM package + nightly anonymous canary
- #11 event-driven resume and jump verification
- #10 hot/cold observable split; B.2 step 1 extractions (Prefs, SleepTimer, SessionSnapshot, TrackExtras, PageCommands)
Exit criteria: CI red on any behavior-contract violation; a user's diagnostics export passes `fieldcheck.sh` unchanged; `PlayerBridge.swift` < 1,900 lines with guard counts untouched; no "session expired" while the page is signed in.

### Phase 2 — One authority, for real (≈3–5 weeks)
Goal: close Phase D.
- #1 page-native Play Next / Add to queue (Option A1, then A2/B per the probe), with player-agreement verification
- Field campaign: the `fieldcheck.sh` Phase D gate PASS on all five rows on a build with #9 landed
- #2 Phase D deletion in the documented order (pending-URL → enforcement → fallback-retained → `navigateRadio` → freeze guard counts, rewrite contract rows 3/5/9)
- B.2 steps 2–3: observed `PlaybackContext`, then `QueueReconciler`
- #8 fake-page seam; convert the field captures used for the gate into replay tests so the gate never regresses silently
Exit criteria: `QueueManager` is mirror + history only; `PlayerBridge.swift` < 900 lines; every contract row has a replay test; guard counts re-frozen with justification.

### Phase 3 — Seamless by construction (≈4–6 weeks)
Goal: latency, resilience, and shipping.
- #5 SPA navigation (click-to-play without reload), gated on capability, `ready`-per-session ≈ 1
- #12 InnerTube transport hardening + offline mode + `BrowseCache`
- #14 energy work (store subscription, narrowed observer, 1 Hz progress, signposts, memory report)
- #13 persistence consolidation
- #15 release engineering (version stamping, gated release, notarization job, opt-in update check)
Exit criteria: click-to-play < 1 s warm; Home/Library render from cache offline; steady-state memory measured and published in the README; releases carry a build number and a changelog.

---

## Appendix — evidence index (file:line)

- Architectural rule enforcement: `Sources/Audio/HiddenPlayerWebView.swift:79-88`, `Sources/UI/SignInView.swift:105-133`
- Message-handler origin check: `HiddenPlayerWebView.swift:94-101`
- Pure decision table: `Sources/Audio/QueuePolicy.swift:1-123`; delegation asserted by `tools/harness/guard.sh:38-41`
- Legacy apparatus still live: `PlayerBridge.swift:140-141, 1629-1706, 2400-2418`; `player-bridge.js:583-592`
- Store dispatch disabled + probe: `player-bridge.js:707-744`; menu-driven removal `801-830`
- Selector sites: `player-bridge.js:373-379, 411, 419, 432-433, 483, 802, 833-834`
- Full-reload navigation: `player-bridge.js:79`; Swift reset on navigate `PlayerBridge.swift:1255-1264`
- 2 s poll / MutationObserver: `player-bridge.js:623-628, 1020-1032`
- Hot state on the cold object: `PlayerBridge.swift:11-14, 2318-2346`; ignored context flags `61-66, 78-88, 317-352`
- Sleep-based verification: `PlayerBridge.swift:1290-1300, 1749-1763`
- `clientVersion` constant: `Sources/Data/InnerTube/InnerTubeClient.swift:32`; `AuthUser` `1647`; no retry `1633-1687`; public body preview `1672-1673`
- One-shot cookie sync: `Sources/UI/SignInView.swift:86`; `Sources/Data/Auth/CookieJar.swift:11-23`
- Liveness probe: `Sources/App/AppEnvironment.swift:81-124`
- Startup work in init: `AppEnvironment.swift:803-860`; `PlayerBridge.swift:159-201`
- Persistence: `PlayedHistoryStore.swift:41-99`; `PlayerBridge.swift:207-218, 240-306, 1395-1450`; `HomeFeedCache.swift`
- Export drops debug: `Sources/App/DiagnosticsExporter.swift:120-126`; loggers `Sources/App/Log.swift`
- CI without harness/canary: `.github/workflows/ci.yml`; static build number `project.yml:38`; ad-hoc signing `.github/workflows/release.yml:1-12`
- Docs drift (fixtures/nightly): `docs/ARCHITECTURE.md` "Resilience" §3; `InnerTubeClient.swift:13-15`
