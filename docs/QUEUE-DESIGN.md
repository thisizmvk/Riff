# Queue system design — single playback authority

Status: **adopted 2026-08-25** · Phase A landed · Phases B-D staged

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
- **Phase B:** once field logs show verified adds are reliable, make
  page dispatch the primary for all queue mutations in radio
  (remove/reorder via dispatch where the page supports it; drop
  affordances it doesn't).
- **Phase C:** albums/playlists display from the mirror too (the page
  queue in a deterministic context IS the album); `/next` fetches
  remain for metadata only (lyrics/related/chips/like state).
- **Phase D:** delete the pending-URL + enforcement + two-region
  apparatus; `QueueManager` becomes mirror + history.

## Fallback truth

Every phase keeps the previous mechanism until the new one is
*verified in the field* via the log audit lines (`queueAddResult`,
`advance arrived=… match/MISMATCH`, `ready`-per-advance patterns) and
the offline harnesses (`tools/harness/run.sh`).
