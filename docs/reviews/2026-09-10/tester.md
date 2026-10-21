# Riff — Tester / QA report (vidura)

Branch: `queue-and-ux-enhancements` (34 commits over `main`, HEAD `6aeeeba`) — 2026-09-10
Scope: unit + regression coverage of the branch's enhancements against the 13-item behavior
contract in `docs/QUEUE-DESIGN.md`, within a sandbox that can run `tools/harness/run.sh`,
`swiftc -parse`, and `node`, but not `xcodebuild`/XCTest. The repo was not modified; all new
test code lives under `scratchpad/reviews/tests/`.

---

## A. Harness results

### A.1 Baseline — `./tools/harness/run.sh` (unmodified repo)

| Stage | Result |
|---|---|
| Static behavior guards (`guard.sh`, 9 guards) | **OK** — navigate sites = 5, `play(item:)` sites = 6, all 7 `QueuePolicy.*` delegations present, no `playVideoAt`, no positional row clicks, no `uniqueKeysWithValues`, no duplicate type decls, no attribute/doc-comment splits |
| Swift logic harness (`QueueLogicTests.swift`, sections 1–12) | **97 passed, 0 failed** |
| JS bridge harness (`js-harness.mjs`, cases 1–14) | **41 passed, 0 failed** |

### A.2 With tester additions — `scratchpad/reviews/tests/build-and-run.sh`

Builds a copy of the harness under `$TMPDIR` exactly the way `run.sh` does (same file set, same
`@Observable`/`@MainActor` strip), appends the addition files before the RESULT footer, runs both.

| Stage | Result |
|---|---|
| Swift harness + sections 13–17 | **202 passed, 0 failed, 5 KNOWN BUGS (strict xfail)** |
| JS harness + cases 15–21 | **97 passed, 0 failed** |

The 5 "KNOWN BUG" rows are `bug(...)` checks: they document a probable bug, do not count as a
failure while the bug exists, and **flip to a failure once the code is fixed** (so the row must
then be promoted to `check(...)`). Details in section C.

---

## B. Coverage matrix

Legend: **H** = standalone harness (runs here) · **X** = XCTest target (review only, cannot run
here) · **F** = field log only (`fieldcheck.sh` over a captured bridge log) · **U** = uncovered.
"(new)" = covered only by the tester additions in section C.

### B.1 Behavior contract items 1–13

| # | Promise | Coverage | Notes |
|---|---|---|---|
| 1 | What you see is what plays (mirror; list shifts by one) | H (JS 2–10, 15 new; Swift consumeUpTo/consumeHead; `mirrorApplies`) + F ("advance … match" audit) | **U**: the Swift `queueSnapshot` handler — stale-snapshot drop, selected-row vs currentId slicing, mapping to `MediaItem` — lives inline in `PlayerBridge` (~L2262-2300) and has no unit test |
| 2 | No reloads in radio | H (`advance` rows; new P5 "native even pre-mirror") + static guard #4 (frozen navigate count) + F (Next page-native count) | **U**: `toggleShuffle()` selector candidates in JS; `next()` execution path in Swift |
| 3 | Never guess by index | static guards #1/#2 + H (JS 14, 17 new) | Strong. JS 17 adds identity via `queueItem` / `item` / `__data.data`, throwing getters, id-less links |
| 4 | Failed page action never becomes a reload | H (JS: `queuePlayItem` returns false w/o click; remove failure leaves queue untouched, no re-emit) | **U**: Swift `skipTo` 2.5 s verify-by-arrival + `onJumpFailed` toast; `onRemoveFailed` → `requestQueueSnapshot` — `Task`-based, PlayerBridge-internal |
| 5 | Explicit intent wins | H (`enforcementApplies` rows; new P4 cube property; new "chip + Play-Next → navigateRadio") | **U**: `queueAddResult` handling (drop Swift copy on VERIFIED add, `pageOwnedQueuedIds` expected-arrival) — Swift, inline |
| 6 | Mirror never repaints beneath user items / chips | H (`mirrorApplies`; new cross-policy "mirrorApplies=false ⇒ enforcementApplies") + guard #6 | OK |
| 7 | Albums advance in own context; exhaustion ≠ empty | H (`contextExhausted` 6 rows + 6 new boundary rows; P3 "context heads never radio") | **Caution**: section 10 "Repeat All cycle" tests a *re-implementation* of the slice/dedupe, not the code in `PlayerBridge` (mirror test — drifts silently) |
| 8 | Sign-in truth probed, not assumed | **F / U** | `a6fef4b` session-invalidation detection has no unit test; `InnerTubeClientTests` only checks the version-string format |
| 9 | Next follows the advance verdict | H (new P1: `nextUsesPageNative == (advance == .native)` on all 1024 rows; shuffled-album rows) + guard #6 + F | **U**: `advanceInputs(for:)` builder correctness (which `PlayerBridge` fields feed which policy input) |
| 10 | No speculative tail beneath a user-owned list | **F / U** | `refreshNextQueueAndIds` scoping (995bd9f) is inline; `fieldcheck.sh` has no metric for it — see D.3 step 8 |
| 11 | Off-context track never navigates into a deterministic list | H (new P7; `afterAlbum` row) | **U**: the `play(item:)` "never non-RD list for off-context" branch in Swift |
| 12 | Context switch clears display + arms click grace | **F** ("context switch → list=" + "context start (no shown head)" audit labels) | **U**: `beginNavigatedContext` has no unit test; the 3 callers (`playPlaylist`, `playByResolvingBrowseId`×?) are only checked by the navigate-count guard |
| 13 | Queue edits via the page's own actions, never its store | H (JS 11a, 13, 18 new: every `removeViaRowMenu` branch; 19 new: disabled dispatch makes no fetch) + F (removeOk/removeFail, `queueApi:` probe) | **U**: Swift `removeFromQueue` → local remove + `pageOwnedQueuedIds.remove` + `syncPendingNextURL` |

### B.2 Enhancements on the branch (by commit)

| Commit(s) | Enhancement | Coverage |
|---|---|---|
| d34510b, a5280b1, fcbf2b3, f73f76b, 2b8bfc7, bf3b2f9 | Single-authority queue phases A–C (page-queue injection, mirror as display truth, page-native Next, instant re-mirror) | H (JS 2–12) for the JS half; Swift handlers **U**; Next path **F** |
| 2c235ef | `QueuePolicy` decision table + guards + contract | H (sec 11: 28 rows; new sec 13: 1024-row cube + 15 edge rows) — **strongest-covered area** |
| 995bd9f | Album queue: Next follows verdict, no off-list nav, no speculative tail, `contextIsPageOrdered` | H (policy) ; refresh scoping **U/F** |
| 03d2aa1 | Context switch clears display, arms click grace | **F** only |
| bca6d17 | Audit labels (match / jump / context start / MISMATCH) | **F** only (fieldcheck reads them); no unit test of the labelling branch |
| 67558ec | `fieldcheck.sh` + Phase D inventory | **U** — the grader itself has no fixture-log test |
| 23a5d87, 6aeeeba | Remove-from-queue via row menu; `requestQueueSnapshot`; store dispatch off | H (JS 13, 11a; new 16, 18, 19) ; Swift toast/restore **U** |
| ec35f2f, 0be4f6d | Row-tap in-page jump, identity-verified, non-destructive fallback | H (JS 14, new 17; policy `rowTapUsesPageJump` new 16-combo sweep) ; Swift 2.5 s verify **U** |
| 8c9e4b5 | Shuffle belongs to page in radio; mini-player a11y; chip wrap | H (`localShuffleAllowed`) ; JS `toggleShuffle` selectors **U**; snapshot→`shuffleEnabled` sync in Swift **U**; UI **U** |
| a6fef4b, be21e87 | Session invalidation detection; local History tab; expiry UI | **U** |
| 5faaf7b | Per-artist links (`ArtistLinkLine`) | **U** — `ArtistLinkLine.artistNames(in:)` and `segments` are pure but the file imports SwiftUI, so not standalone-compilable here; XCTest-able. Same credit-splitting limitation as `extractArtistName` (see C.3 #7) |
| 02f023d | UI batch of nine | 1 carousel chevrons **U** · 2 sign-in nudge **U** · 3 artist portraits (lazy /browse + cache) **U** · 4 History rows "Artist • 2h ago • 3×" **U** (inline in `LibraryView` L403-410) · 5 arrow-key carousel nav **U** · 6 Open YT Music link (`openYouTubeMusicLink`) **U** (not extractable; see C.3 #6) · 7 Follow/unfollow **U** · 8 Podcast resume **U** (private funcs in `PlayerBridge` L1400-1447) · 9 inline ⋯ on queue rows **U** |
| d6f830a | Premium batch: Track details card **U**; time-of-day shelf **H** (sec 12 + new 15); `Theme.Motion` **U** |
| 9c39606, ac1c20a, 1d7a009, fc25320 | Guards for duplicate decls / attribute splits + the build fixes they came from | Guards run (positive path). **U**: no negative self-test proving each guard actually fires on a violating fixture |
| 3182e94, 46a6fdd, c174202…aa880ae | Harness creation; review batches 1–4 (security, perf, quick wins, notifications) | Batches 1–4 predate the queue work; **not re-audited here** beyond what the harness already pins |
| Tests/QueueAndResolverTests.swift (+144 lines on branch) | 10 new XCTest two-region tests | **X** — reviewed: they duplicate harness sections 1–5 (good redundancy); cannot run here |

### B.3 Pure modules with zero XCTest coverage (harness-only today)

`QueuePolicy`, `PersonalizedShelves`, `CookieImporter`. If the harness is ever skipped (hooks not
enabled — `git config core.hooksPath` is **unset** in this checkout), nothing else guards them.

---

## C. New tests written

All files: `/private/tmp/claude-501/-Users-vamsi-Projects-Ideas-Riff/7f6ca28f-a043-47db-9035-8a21755a7ee5/scratchpad/reviews/tests/`

| File | What | Count | Result |
|---|---|---|---|
| `QueueLogicTests.additions.swift` (393 lines) | Sections 13–17, `check(...)` style, append before the RESULT footer of `tools/harness/QueueLogicTests.swift` | **101 `check` + 5 `bug`** (strict xfail) | 101 pass; 5 known bugs fail-as-expected |
| `js-harness.additions.mjs` (262 lines) | Cases 15–21, append before the `JS RESULT` footer of `tools/harness/js-harness.mjs` | **56 `check`** | 56 pass |
| `build-and-run.sh` | Proof harness: copies `run.sh`'s file set to `$TMPDIR`, splices the additions, builds with `swiftc`, runs both | — | swift=0 js=0 |

### C.1 Swift additions (sections 13–17)

- **13 QueuePolicy** — exhaustive 1024-row cube with 7 contract-derived properties (P1 Next≡advance,
  P2 into-context payload, P3 context heads never radio, P4 off-context user heads always radio,
  P5 radio native pre-mirror, P6 shuffled album never native, P7 no into-context while inside the
  ordered list); named edge rows (chip + Play-Next, chip inside album, empty-string context id,
  Repeat-All cycle with nil playlist, shuffled album after interlude, playTracks-seeded rows);
  cross-policy "mirrorApplies=false ⇒ enforcementApplies"; 16-combo `rowTapUsesPageJump` sweep;
  6 `contextExhausted` boundaries.
- **14 QueueManager** — 2000-drag multiset preservation; view-filtered current row keeps its slot;
  stale-id reorder (bug); positional-vs-tag semantics after drag (documented); `move(by:)`
  clamping/promotion/demotion; consumeUpTo inside the user region; playNext promotion of a server
  head; duplicate-id remove/consume; consume past the boundary; extend with empty batch; archive
  timestamps.
- **15 PersonalizedShelves** — 9 exact slot edges; same instant in UTC vs IST; DST spring/fall
  days and a non-existent local time in America/New_York; threshold boundaries 15×8 / 15×7 / 14×8;
  inclusive 90-day cutoff (±1 s); empty-items shelf (bug); limit 12; recency tiebreak; future-dated
  plays (documented); `topArtists` limit-before-filter (bug), artistId-less skip, ranking/plural
  subtitle, most-recent cover, window; 9 `extractArtistName` shapes incl. 3 documented
  limitations; `topTracks` filter-before-limit.
- **16 SmartShuffle.merge** — protectedIds, every=2 / every=1 clamp, base shorter than cadence,
  first slot at `every`, empty base; 500-input property fuzz (base is a subsequence, injected ⊆
  pool, no duplicates, bounded growth, injected ∩ base = ∅).
- **17 CookieImporter** — CRLF (bug), `Cookie:` header prefix (bug), `=` inside values, duplicate
  names, mixed separators, empty inputs, `__Secure-3PAPISID` alone, case-sensitivity, quoted
  values verbatim, tab-separated pastes (documented), empty name/value skip, spaces around `=`.

### C.2 JS additions (cases 15–21)

- **15 emitQueueSnapshot** — automix-only queue; wrapper without `primaryRenderer`; `simpleText`
  title / `shortBylineText` fallback / empty thumbnails; `shuffleEnabled` true / non-boolean→null;
  metadata-only change deduped (documented); no selected row still emits; three more resolver
  paths (`ytmusic-player-queue` nested getState/store, player-bar `.queue.store` flat); throwing
  store → one diagnostic; queue-less app state falls through.
- **16 requestQueueSnapshot** — bypasses the signature, returns true, safe with no queue.
- **17 queuePlayItem** — identity via `queueItem` / `item` / `__data.data`; link without `v=` is
  never clicked; duplicate rows → first; no play button → row click; throwing row getter skipped.
- **18 queueRemoveViaPage** — `menu:no-row`, `menu:no-button`, `menu:still-present` (no re-emit),
  case/whitespace-insensitive label + inner anchor preferred, `menu:no-remove-item` closes via
  `body.click()`, `menu:threw`, zero store dispatches across all branches, `queueApi:` probe is
  one-shot, synchronous `true` return.
- **19 queueAddViaPage disabled** — no `get_queue` fetch, no dispatch, echoes id/position, no
  mirror re-emit.
- **20 setPendingNextURL / navigate** — verbatim store, `""`/`undefined` → null, `location.href`.
- **21 fresh bridge with playerApi present** — subscribes to `onStateChange` + `videodatachange`,
  posts `ready` + forced `trackChanged`; state 0 without pending URL → `ended` only; with pending
  URL → navigates once + `riffNavigatedTo`, consumed exactly once; states 1/3; C4 dedup key
  (same id, new `list=` re-emits); empty-metadata emit then late-title re-emit exactly once.

### C.3 Probable bugs and findings

Confirmed by a failing check against current code (strict-xfail `bug(...)` rows):

| # | Severity | Where | Finding | Evidence | Suggested fix |
|---|---|---|---|---|---|
| 1 | **Medium** | `Sources/Audio/QueueManager.swift` `reorder(visibleIds:from:to:)` | A **stale id in `visibleIds` silently drops a real row**. When the visible slot's `nextId` is not in `byId`, the branch consumes the iterator and appends nothing — the row that occupied that slot is lost. `NowPlayingView.queueList` captures `visibleIds` at render time (L1895) and the drop handler (L1970) passes it later; a mirror snapshot (2 s poll, instant re-mirror on track switch) landing mid-drag makes it stale. | `[a,b,c]` + visible `["zzz",a,b,c]` move 3→0 ⇒ `[c,a]` (b lost) | Pre-filter `visibleIds` to ids present in `upNext` before `move`, or on a nil `picked` append the original `item` |
| 2 | Low-Med | `Sources/Data/Auth/CookieImporter.swift` `parse` | **CRLF pastes keep a trailing `\r` on every value** (`.whitespaces` excludes CR). `CookieJar.import` feeds these values to the cookie store; `SAPISIDHASH` would be computed over `abc\r` → silent auth failure for anyone copying from a Windows/DevTools "Cookie" panel. | `"SAPISID=abc\r\nHSID=h1\r\n"` ⇒ `["SAPISID":"abc\r","HSID":"h1\r"]` | Trim `.whitespacesAndNewlines`; normalise `\r\n`/`\r` to `;` alongside `\n` |
| 3 | Low | same | Doc comment says it "tolerates the `Cookie:` header form", but pasting the header **line** yields key `"Cookie: SAPISID"` → `hasAuthCookie` false → import rejected with "missing auth cookie". | keys `["Cookie: SAPISID","HSID"]` | Strip a leading `^cookie:\s*` (case-insensitive) or fix the doc |
| 4 | Low | `Sources/Audio/PersonalizedShelves.swift` `topArtists` | `prefix(limit)` runs **before** the name/thumbnail `compactMap`, so each skipped artist costs a tile slot; rails render short even when qualifying artists exist. (`topTracks` and `timeOfDayShelf` filter first — inconsistent.) | limit 2, 2 qualifying + 1 thumbnail-less top-ranked ⇒ 1 tile | compactMap first, then `prefix(limit)` |
| 5 | Low | same, `timeOfDayShelf` | Thresholds (`minPlays`, `minTracks`) are counted **before** the thumbnail filter, so the function returns a non-nil shelf with **zero items**, violating its own "nil until the slot has enough signal" contract. Mitigated today only because `HomeView` guards `kept.count >= 4`. | 15 plays / 8 bare tracks ⇒ `items=[]` | Filter thumbnails before the `minTracks` guard, or `guard !ranked.isEmpty else { return nil }` |

Found by code reading (no standalone test possible; pinned as DOCUMENTED rows where reachable):

| # | Severity | Where | Finding |
|---|---|---|---|
| 6 | Low (security hygiene) | `Sources/App/AppEnvironment.swift` L699 `openYouTubeMusicLink` | Host check is `site.hasSuffix("youtube.com")` — accepts `evilyoutube.com`. Impact is limited (only plays a videoId / opens a browse page from a clipboard/search paste) but it should be `site == "youtube.com" \|\| site.hasSuffix(".youtube.com")`. Also `youtu.be/<id>?list=…` ignores the list. |
| 7 | Low (UX) | `PersonalizedShelves.extractArtistName` and `ArtistLinkLine.artistNames(in:)` | Credit splitting on `,` / ` & ` / ` and ` breaks band names: "Earth, Wind & Fire" → three links "Earth", "Wind", "Fire"; "Florence and the Machine" → "Florence". Consider only splitting when the row carries multiple artist endpoints, or keep the run whole when name resolution fails. |
| 8 | Doc | `PersonalizedShelves.extractArtistName` doc | Says it splits on `" - "`; the code does not (`"Artist A - Album"` passes through whole). |
| 9 | Doc | `QueueManager.reorder` doc | Says a moved item "keeps its ORIGINAL user/server tag", but the region is a prefix: after dragging `s1` above `u1`, `isUserQueued("s1") == true` and `isUserQueued("u1") == false`. Count is preserved, membership is positional — and this differs from `move(videoId:by:)`, which promotes/demotes explicitly. Pick one semantic and document it. |
| 10 | Product question | `QueuePolicy.advance` | (a) A Repeat-All cycle (`playTracks(…, playlistId: nil)`) has an empty context id, so its heads advance via **per-track radio navigation** (a reload per track, each re-rolling the tail). (b) An in-order album head inside its list is `.native` **even with a Tune chip active** — context outranks chip. Both are pinned as DOCUMENTED rows; confirm they are intended. |
| 11 | Test-design | `QueueLogicTests.swift` section 10 | "Repeat All cycle-building" re-implements the slice/dedupe instead of calling the code in `PlayerBridge.ended`. It cannot catch drift. Extract `RepeatAllCycle.build(entries:contextStart:current:)` and test that. |

---

## D. Gaps and regression plan

### D.1 What cannot run here (and what to do about it)

1. **XCTest target** (`Tests/`, 14 files, ~230 tests incl. the 10 two-region tests added on this
   branch). Run on a dev Mac/CI: `xcodegen generate && xcodebuild test -scheme Riff`. Nothing on
   this branch changes their inputs except `QueueAndResolverTests` (+10, reviewed OK).
2. **UI** (SwiftUI views): nine UI-batch items, premium card, motion tokens, inline ⋯ menu,
   ArtistLinkLine — no automated coverage at all.
3. **PlayerBridge inline logic** (the Swift half of contract items 1, 4, 5, 8, 10, 11, 12, 13):
   only observable through the unified log. `fieldcheck.sh` is the regression tool.

### D.2 Proposed XCTest additions (new files under `Tests/`)

| File | Cases (port from the harness where noted) |
|---|---|
| `QueuePolicyTests.swift` | Port sections 11 + 13 verbatim (`XCTAssertEqual` per row; keep the 1024-row cube as one test). These are the contract; they must run in CI even when the harness is skipped. |
| `PersonalizedShelvesTests.swift` | Port sections 12 + 15; add the 5 xfail rows as `XCTExpectFailure` until fixed. |
| `CookieImporterTests.swift` | Port section 17. |
| `ArtistLinkLineTests.swift` | `artistNames(in:)`: "A, B & C" → 3; "A and B" → 2; "Earth, Wind & Fire" (document); empty; make `segments` internal (`@testable`) and assert the artist run is the first non-kind-label segment and a leading "Song" is plain. |
| `YouTubeMusicLinkTests.swift` | **Requires a small refactor**: extract `enum YTMusicLink { case song(id, list?), playlist(id), browse(id, kind), artist(id) }` + `static func parse(_ url: URL) -> YTMusicLink?` from `AppEnvironment.openYouTubeMusicLink`. Cases: watch with/without list, `RD*` list dropped, `youtu.be/<id>`, `/playlist?list=`, `/browse/MPREb…`, `/browse/UC…`, `/browse/VLPL…`, `/channel/UC…`, `www.youtube.com`, `evilyoutube.com` **rejected**, `/shorts/x` rejected, empty `v`. |
| `EpisodeResumeTests.swift` | **Requires a refactor**: extract pure `EpisodeResumePolicy.record(kind, elapsed, duration, lastSaveAt, now) -> Action(save/clear/none)` and `resumeTarget(kind, saved, duration, alreadyApplied) -> Double?` from the private funcs at `PlayerBridge` L1400-1447. Boundaries: 30 s min, `duration-20 s` finished margin, 5 s throttle, music never tracked, once-per-track. |
| `QueueMirrorTests.swift` | **Requires a refactor**: extract `QueueMirror.upcoming(items:currentId:) -> [SnapshotRow]?` (stale-snapshot drop when `currentId` absent; slice after last selected; fallback slice after currentId; filter currentId) from the `queueSnapshot` handler. |
| `RepeatAllCycleTests.swift` | Per C.3 #11 — extract and test the real code. |
| `GuardSelfTests` (shell, `tools/harness/guard-selftest.sh`) | Feed each guard a violating fixture (a file with `playVideoAt`, a duplicated `struct`, an `@ViewBuilder` followed by `///`, a PlayerBridge with 6 `await navigate(`) and assert **GUARD FAIL**. Today the guards are only ever exercised on the passing path. |
| `FieldcheckSelfTest` (shell) | A fixture log with known counts → assert the printed numbers and PASS/OPEN verdicts. |

### D.3 Manual field script (drives `tools/harness/fieldcheck.sh`)

Capture with `log stream --predicate 'subsystem == "dev.riff.app" AND category == "bridge"' --level debug --style compact | tee ~/Downloads/riff-bridge.log`, one app launch, signed in, then grade with `./tools/harness/fieldcheck.sh`.

| Step | Action | Contract | Expected in fieldcheck / log |
|---|---|---|---|
| 1 | Start a song radio from Home; press Next ×5 | 1, 2, 9 | `Next presses advanced page-natively` = 5; `match` = 5; `page reloads (ready)` = 1 (the initial) |
| 2 | Tap the 4th Up Next row | 3, 4 | `Row tap (page jump)` 1 jumped / 0 failed; audit `jump (row tap)` |
| 3 | Play Next a song from Search; let the current track end | 5, 13 | Since store dispatch is off: `queueAddResult ok=false via=store-dispatch-disabled`, Phase D "OPEN … Play Next uses Riff's own path"; the Play-Next song plays next (`.ended → JS armed via pending URL` = 1 is **expected** here, not a regression) |
| 4 | Remove a list row via ⋯ → Remove | 13 | `queueRemoveResult ok=true via=menu:removed`; row gone from Up Next and never plays |
| 5 | Play an album from a tile **while the radio is playing** | 12 | `context switch → list=OLAK…`; audit `context start (no shown head)`; **0** `overriding to head` |
| 6 | Press Next through the album | 7, 9 | page-native advances, no reloads |
| 7 | Let the album drain into autoplay; press Next once | 10, 11 | Next is page-native; the album does **not** restart (no `?v=X&list=OLAK…` navigation with X off-album); new rows beneath came from the mirror only |
| 8 | Inspect Up Next **during** step 6 | 10 | No rows are painted beneath the album's remaining tracks until it drains (screenshot; there is no fieldcheck metric — add one: count `refreshNextQueueAndIds` lines while `userQueueCount>0` in a tracklist context) |
| 9 | Remove an **autoplay-tail** row via ⋯ | 13 | `ok=true via=menu:removed` (this was the 23a5d87 regression) |
| 10 | Detail page → Shuffle an album; Next ×3 | 9 | Next is Swift-driven (`navigateIntoContext`), rows follow Riff's shuffled order |
| 11 | Repeat All on; let the album end | 7 | `.ended → Repeat All: cycling N tracks`; N = album length |
| 12 | Autoplay off; let the album end | 7 | playback stops at the album's last track (autoplay filler visible but not played) |
| 13 | Play a podcast episode 45 s, play a song, replay the episode | UI batch #8 | `episode resume: <id> → 45s of …`; music never logs a resume |
| 14 | Paste a `music.youtube.com/watch?v=…&list=PL…` URL into Search | UI batch #6 | plays inside the playlist (list preserved); `RDAMVM…` links play as plain radio |
| 15 | Toggle shuffle in radio | 2 | no `toggleShuffle: no shuffle control matched` diagnostic; Up Next order changes to the page's order |
| Gate | `fieldcheck.sh` | — | All five Phase D lines PASS except the Play-Next line (OPEN by design until a page-native add exists) |

### D.4 Process gaps

- `git config core.hooksPath` is unset in this checkout → the pre-commit harness does not run
  locally. Enable it, and run `run.sh` in CI on every PR (it needs only `swiftc` + `node`).
- The harness has no xfail mechanism; the `bug(...)` helper in the additions is a proposal — adopt
  it (or `XCTExpectFailure` in XCTest) so known bugs are tracked by a test, not a TODO.
- Coverage of contract items 8, 10 and 12 is field-only; each needs at least one extracted pure
  function + unit test (D.2) before Phase D deletes the legacy paths.
