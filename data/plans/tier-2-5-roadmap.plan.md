# Plan: Tier 2-5 Backlog Rollout

slug: tier-2-5-roadmap
created: 2026-06-13T23:15:00Z
status: executing        # draft → approved → executing → done

## Findings

- `BrowseID.explore` and `BrowseID.moodsAndGenres` constants exist in
  [Endpoints.swift](../../Sources/Data/InnerTube/Endpoints.swift) but no
  `InnerTubeClient` method consumes them yet. Explore tab is "wire it up +
  add views" not "discover endpoints."
- Uncommitted Sleep Timer + Continue-Where-You-Left-Off code from the
  interrupted prior turn lives in `PlayerBridge.swift`, `AppEnvironment.swift`,
  `NowPlayingView.swift`. Build hit a sandbox issue (DerivedData write
  blocked), never a real compile error. Step 1 verifies + commits.
- `MediaItem` has no `duration` / `year` fields — both Search filters (#4)
  AND Year-end Recap (#5) want them; a single parser pass adds them once.
- No block-list anywhere. "Don't recommend artist" is new persisted state on
  `AppEnvironment`, enforced by post-fetch filtering of `upNext` / `related`
  / Home / Search.
- `AppTab` is at `Sources/App/AppEnvironment.swift:8` with `.home / .search /
  .library`. Explore tab = 1-line enum case + `TopTabBar` entry + ⌘4 shortcut.
- CI green on `main` (last `f07c092`). Twenty-five tests passing. Each step
  must end green before the next starts.

## Steps

- [x] **1. Verify + commit Sleep Timer + Continue Where You Left Off**
      files: PlayerBridge.swift, AppEnvironment.swift, NowPlayingView.swift
      verification: CI green on the pushed commit
- [ ] **2. "Don't recommend artist" block-list**
      files: AppEnvironment.swift, PlayerBridge.swift, TrackContextMenu.swift,
             HomeView.swift, SearchView.swift, SettingsView.swift
- [ ] **3. MediaItem.duration + year (data-model precursor)**
      files: Models/MediaItem.swift, InnerTubeClient.swift, InnerTubeParserTests.swift
- [x] **4. Search filters: year + duration** (depends on #3)
      files: SearchView.swift, SearchResultRow.swift
- [x] **5. Year-end Recap** (depends on #3 for richness)
      files: new Sources/UI/Recap/RecapView.swift, AppEnvironment.swift, RiffApp.swift
      note: shipped as "Your Riff Highlights" — playedHistory cap is 50,
            so the "year in review" framing would over-promise. Pure
            stats math lives in RecapStats.compute(from:) and is covered
            by Tests/RecapStatsTests.swift (12 new tests).
- [x] **6. Mixed-for-you Library section**
      files: LibraryView.swift, InnerTubeClient.swift, Endpoints.swift
      prework: confirm `FEmusic_mixed_for_you` browseId against live YT Music
      note: signed-in users see personalized mix carousels (Supermix,
            Discover Mix, …) above the section grid; anonymous responses
            are empty and the carousels hide entirely. Fetched in parallel
            with `library(section:)` via async let; mixed-feed failure
            silently hides without an error banner. Reuses parseHomeShelf
            + HomeSectionRow — no new parser path, no new test needed.
- [x] **7. Explore tab** (largest single step)
      files: AppEnvironment.swift, RiffApp.swift, new Sources/UI/Explore/ExploreView.swift,
             InnerTubeClient.swift (new browseExplore() + browseMoodsAndGenres())
      note: response shape is identical to Home (musicCarouselShelfRenderer
            shelves), so ExploreView reuses HomeSection + HomeSectionRow.
            Two /browse calls fire in parallel via async let. Sections
            filtered through env.isBlocked() so block-list applies to
            Explore too.
- [x] **8. Volume normalization toggle (approximate)**
      files: PlayerBridge.swift, Resources/player-bridge.js, SettingsView.swift
      note: Web Audio graph (source → analyser → gain → destination)
            on the offscreen <video>. ~5s post-skip RMS sample, gain
            scaled toward -18 dBFS RMS, clamped [0.4, 2.5]. Off by
            default; toggle in Settings → Playback. <video>.volume
            still drives the user-facing volume — both attenuations
            multiply.
- [x] **9. Per-kind playback rate defaults**
      files: PlayerBridge.swift, Tests/QueueAndResolverTests.swift
      note: PlaybackKind enum (.music / .spoken). Music defaults to 1.0×,
            spoken (episodes + podcasts) to 1.25×. Rates persist per kind
            so flipping between a podcast and a song doesn't reset either
            preference. play(item:) derives kind from MediaItem.kind;
            playPodcast() forces .spoken; play{Album,Playlist,ArtistRadio}
            force .music. Legacy `player.rate` migrated into
            `player.rate.music` on first launch. NowPlayingView slider
            unchanged — it reads/writes `playbackRate` as before; the
            kind-keyed persistence is transparent. 8 new tests.
- [x] **10. Share URL + Lyric image cards**
      files: TrackContextMenu.swift, new Sources/UI/LyricCardSheet.swift,
             NowPlayingView.swift, AppEnvironment.swift, RiffApp.swift
      note: "Copy share link" added to TrackContextMenu (songs + episodes),
            copies a music.youtube.com/watch?v=… URL to NSPasteboard.
            "Create card" button on the lyrics tab in NowPlayingView raises
            LyricCardSheet — editable snippet pre-seeded from synced or
            plain lyrics, live preview, NSSavePanel-driven PNG export at
            1080×1080 via ImageRenderer. Sheet hidden when nothing playing
            or no lyrics available. No PlayerBridge changes needed.
- [x] **11. Phase 3 — App Intents (Spotlight + Siri + Shortcuts)**
      files: new Sources/Intents/RiffIntents.swift, project.yml, AppEnvironment.swift
      note: ships 5 intents — PlayTrack / PlayArtistRadio / Resume / Pause /
            SkipNext — plus a `RiffAppShortcuts` provider with 15 phrases.
            Intents reach the live PlayerBridge via a process-wide
            `AppEnvironment.current` weak ref (RiffApp owns the single
            instance; the weak ref tracks it without risking duplicate
            WKWebViews). NSSiriUsageDescription added to Info.plist for
            voice-invocation path.
- [x] **12. Phase 3 — BYO-LLM (Anthropic + queue builder)**
      files: new Sources/AI/LLMProvider.swift, AnthropicProvider.swift,
             SettingsView.swift, new Sources/UI/Player/QueueBuilderSheet.swift
      note: Initial scope is Anthropic-only (Haiku 4.5 default, Sonnet 4.6
            offered). API key + model id live in Keychain under accounts
            `riff.llm.anthropic` and `riff.llm.anthropic.model`; never
            UserDefaults, never logged. Queue Builder raised from a
            ✨ Build chip in the Up Next header; resolves suggestions
            through `/search?filter=.songs` and waits for the user to
            click Play all / Add to queue (no auto-enqueue).

## Bug backlog (track + revisit between feature steps)

These are user-reported defects, not new features. They jump priority
over later Tier 3+ items but slot below in-progress Tier 2 work.

- [x] **BUG-1. Up Next refreshes wholesale on every track change, losing
      user intent.** Fixed in e0d652e.
      Symptom: as each new track plays, the Up Next pane gets replaced
      with the new /next response. Items the user reordered, queued
      ("Play next" / "Add to queue"), or were just visually relying on
      stay-put disappear.
      Root cause: `PlayerBridge.refreshNextQueueAndIds` does
      `queue.replaceQueue(fetched)` on every trackChanged event. The
      server queue and our local queue diverge when the user has
      mutated locally, and the server view wins.
      Fix sketch: when replacing, preserve any item whose id is in
      `userQueuedIds` (or otherwise locally-modified) by splicing
      them back into the head of `fetched` after the de-dupe. Also
      consider only replacing when the previously-shown queue was
      empty OR when the new response is a fresh chip selection —
      otherwise prepend new items rather than wholesale-replace.
      Risk: if the server queue genuinely advanced (autoplay went to
      the next track and we missed it), naive prepending could show
      a stale tail. Test path: start radio, click "Play next" on a
      song, let current track end, verify the user's song plays.

- [x] **BUG-2. "Play next" lands a track in Up Next but a different
      one plays.** Fixed in e0d652e (co-fix of BUG-1).
      Symptom: clicking "Play next" inserts the song at the top of
      Up Next, but when the current track ends YT autoplays a
      different one. (Originally fixed in `93a9977` via video.ended
      interception + userQueuedIds.)
      Status: regressed by BUG-1 — when /next replaces upNext,
      the user-queued item is no longer in the array, so
      `advanceToUserQueuedIfAny()` can't find it.
      Likely fixed when BUG-1 fix lands. Verify by reproducing the
      original repro after BUG-1 ships.

## Out of scope

- Sound Search (hum-to-find)
- App Store / Sparkle / Notarization (gated on Apple Developer account)
- Repeat-all mode
- Server-sync of playNext / removeFromQueue
- Drag-and-drop Up Next reorder

## Verification (between every step)

1. Push commit → CI must go green at <https://github.com/thisizmvk/Riff/actions>.
2. Test suite stays ≥25 passing, growing as each step adds tests.
3. Smoke-test in the running app for UI-visible changes.
4. `/vajra review` on the diff before commit for steps 4 / 5 / 7 / 11 / 12.

End-of-plan exit: all steps checked, CI green on the final commit,
phase back to `explore`.
