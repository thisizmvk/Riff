# Queue system design — single playback authority

Status: **adopted 2026-08-25** · Phases A-C landed · Phase D gated on
field verification (queueAddResult/queueRemoveResult logs)

## The problem this design removes

Riff historically kept a parallel queue model (two-region `upNext`) and
imposed it on the hidden WKWebView at track boundaries (pending-URL
navigation, end-of-track fallbacks, WYSIWYG enforcement). The page,
meanwhile, keeps its own queue and autoplays it. **Two authorities over
"what plays next"** produced an entire genus of bugs, all boundary
races between them:

- displayed radio ≠ played radio (two independently-generated,
  non-deterministic radio queues)
- per-track `?list=RDAMVM<id>` navigations re-seeding a fresh page
  radio every advance (album → "49 random rows" → ends in radio)
- every forced navigation = full page reload = radio re-roll
  (non-deterministic per fetch), so imposed advances could never stay
  true to the displayed list
- enforcement snapping against a mirror of the very queue the page was
  playing (self-fighting loops)
- the page natively overriding Riff-side pause (sleep timer).

## The design

**The page is the sole playback authority. Riff is a remote control
and a lens.** (The architecture th-ch/youtube-music and ytmdesktop
converged on; neither keeps a parallel queue.)

```
                    COMMANDS (remote control)
   UI ──▶ PlayerBridge ──▶ page: next/prev/seek/pause/rate/volume
                        ──▶ page: ADD_ITEMS dispatch (play next / add to queue)
                        ──▶ page: navigation (ONLY to start a new context)

                    QUERIES (lens)
   page store ──queueSnapshot──▶ QueueManager mirror ──▶ Up Next UI
   page events ─trackChanged───▶ history / scrobble / metadata fetches
```

Invariants:
1. The Up Next list IS the page's queue (mirror), in every context.
2. Riff never navigates except to start a new context (user clicked a
   song / album / playlist / Repeat-All cycle).
3. Riff never intercepts an advance. What the page plays next is what
   the list showed, by construction.
4. User queue mutations are dispatched INTO the page queue and
   verified against the next mirror snapshot.

## Migration phases

- **Phase A (landed):** `queueAddViaPage` hardened into a real
  injection pipeline — fetches proper queue renderers via the page's
  own `music/get_queue` (networkManager, falling back to a
  same-origin `ytcfg` fetch), dispatches `ADD_ITEMS` at the right
  index, then VERIFIES presence in the store and reports a
  `queueAddResult` event. Swift Play-Next/Add-to-Queue in page-driven
  contexts runs dual-path: optimistic Swift-side user region (instant
  UI + today's guaranteed fallback) + page dispatch; on a verified
  add, the Swift copy is dropped and the page owns the item. Runtime
  self-migration — no capability cliff.
- **Phase B (landed):** verified adds drop the Swift copy per-id in
  every non-chip context (order-safe: dispatches insert at
  selected+1 in call order, reproducing playNext/addToEnd ordering);
  verified page-owned ids are recorded so enforcement treats their
  arrival as expected. Queue-row removal also dispatches into the
  page (`REMOVE_ITEM` + verification via `queueRemoveResult`), with
  the local removal as fallback.
- **Phase C (landed):** the mirror is the display truth in every
  non-chip context once the current page's first snapshot lands
  (`mirrorFresh`); `/next` refreshes become metadata-only while the
  mirror owns the queue (they still seed initial rows on a fresh
  page). Enforcement narrows to user-region/chip ownership.
  "Queue drained" triggers (Repeat All, autoplay-off stop) become
  "context exhausted" — the finishing track is a context track and
  only autoplay filler remains — since the mirror truthfully shows
  the page's automix padding at album end.
- **Phase D (pending field verification):** delete the pending-URL +
  enforcement + two-region apparatus; `QueueManager` becomes mirror +
  history. Gate: `tools/harness/fieldcheck.sh` reports PASS on every
  row against a log captured on the current build (Play Next, row-tap
  jump, remove-from-queue all verified via the page; no MISMATCH, no
  enforcement override; legacy end-of-track paths idle).

  Deletion inventory, in order (each step keeps the harness green):
  1. `PlayerBridge.syncPendingNextURL` + `pendingNextURLArmed` + all
     call sites; JS `setPendingNextURL` and the `onStateChange===0`
     navigation. `.ended` keeps only Repeat All, autoplay-off and the
     sleep-timer stop; a natural advance is always the page's.
  2. The WYSIWYG enforcement branch in `trackChanged` and
     `QueuePolicy.enforcementApplies` (+ its table rows). Play Next is
     page-owned (`pageOwnedQueuedIds`), so "arrived ≠ shown head" can
     only be mirror lag.
  3. The "fallback retained" branch of `queueAddResult` and the
     Swift-side user region for page-owned adds: `QueueManager` keeps
     the user region only as a *display* of pending page adds until
     the mirror shows them, then drops it.
  4. `AdvancePlan.navigateRadio` (unverified injections no longer
     exist); `navigateIntoContext` stays for shuffled albums.
  5. Freeze the new call-site counts in `guard.sh` and rewrite the
     contract rows 3, 5 and 9 to their page-only wording.

  Field status 2026-09-10: rows 1-2 of the gate are unverified (no
  Play Next / row tap in any capture); the Next path is verified
  (11 page-native advances, 0 reloads on the new build).

## Fallback truth

Every phase keeps the previous mechanism until the new one is
*verified in the field* via the log audit lines (`queueAddResult`,
`advance arrived=… match/MISMATCH`, `ready`-per-advance patterns) and
the offline harnesses (`tools/harness/run.sh`).

## Behavior contract (locked 2026-09-09)

These are user-facing promises. They are encoded in
`Sources/Audio/QueuePolicy.swift` (pure decision table), asserted by
`tools/harness/QueueLogicTests.swift` (section 11) and
`tools/harness/js-harness.mjs`, and fenced by `tools/harness/guard.sh`
(static guards). **Changing any of them is a product decision**: update
this list, the policy, and its table row together — never one alone.

1. **What you see is what plays.** The Up Next list is the page's own
   queue (mirror). A natural advance or Next plays the top row; the
   list shifts by exactly one; nothing else moves.
2. **No reloads in radio.** Next uses the page's next control; a
   tapped row jumps in place via an identity-matched page row; shuffle
   toggles the page's shuffle. Hard navigation happens only to START a
   context (song / album / playlist / Repeat-All cycle) or to restore
   an album context after an interlude.
3. **Never guess by index** into the page's player (`playVideoAt`) or
   click queue rows by position — identity match or refuse.
4. **A failed page action is never turned into a reload.** If the page
   doesn't jump, keep the queue intact and tell the user.
5. **Explicit intent wins.** Play-Next / Add-to-queue items are
   enforced even in radio; verified page-owned adds are expected
   arrivals, not divergence.
6. **The mirror never repaints beneath user-queued items**, and never
   touches chip-curated queues.
7. **Albums advance in their own context** (page-native), never via
   per-track radio URLs; Repeat All and autoplay-off act on "context
   exhausted", not "queue empty" (the mirror shows YT's autoplay
   padding at the end).
8. **Sign-in truth is probed, not assumed** from cookie dates.
9. **Next follows the advance verdict.** The Next button is page-native
   exactly when the natural advance would be (radio rows, an in-order
   album the page is inside, autoplay rows after an album); otherwise
   Swift drives. A shuffled album is Swift-driven (the page's order
   would be wrong).
10. **No speculative tail beneath a user-owned list.** While the user
    region holds the album/queued songs, nothing is painted under it;
    the real autoplay tail appears from the mirror once it drains.
11. **An off-context track never navigates into a deterministic list**
    (`?v=X&list=<album>` with X outside the album restarts the album).
12. **A context switch clears the stale display and arms the click
    grace** before navigating (playlist / album / artist radio). The
    new page's first track is never judged against the old page's
    rows.
13. **Queue edits go through the page's own actions, never its store.**
    Remove = the row's "⋯ → Remove from queue" (identity-matched row,
    verified against the store). On failure the row returns to the
    display and the user is told. Direct `REMOVE_ITEM` / `ADD_ITEMS`
    dispatches are off (field 2026-09-10: one REMOVE_ITEM desynced the
    page's store from its player; every later Next played an unseen
    track and row taps stopped working). Play Next keeps Riff's own
    path until a page-native add is found — the bridge logs the page's
    queue API surface once per page (`queueApi:` diagnostic) for that.

Run `./tools/harness/run.sh` before committing anything under
`Sources/Audio/`, `Resources/player-bridge.js`, or `tools/harness/`
(or enable the hook: `git config core.hooksPath .githooks`).
