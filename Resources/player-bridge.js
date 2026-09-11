/*
 * player-bridge.js
 *
 * Injected into music.youtube.com at documentStart by the hidden WKWebView.
 * Exposes window.musicBridge.{...} so the Swift side can drive playback
 * through a stable surface, regardless of how YT Music restructures its
 * internals.
 *
 * Architecture (rewritten 2026-06 based on research into
 * th-ch/youtube-music + sozercan/kaset, both of which converged on this
 * approach):
 *
 *   1. Track-change detection — subscribe to YT's own
 *      `playerApi.addEventListener('videodatachange', …)`. This is the
 *      canonical event YT itself dispatches on MSE source-swap, the same
 *      moment the underlying audio source changes. It fires reliably
 *      where <video>.ended does NOT (YT's MSE pipeline doesn't end the
 *      stream — it just swaps the source mid-flight).
 *
 *   2. State change + end-of-track — subscribe to
 *      `playerApi.addEventListener('onStateChange', …)`. State codes:
 *        -1 unstarted, 0 ENDED, 1 PLAYING, 2 PAUSED, 3 BUFFERING, 5 CUED
 *      State 0 is the real "natural end of track" signal — fires before
 *      YT's own autoplay handler advances the source. Replaces the
 *      window-capture-phase `ended` listener and the timeupdate
 *      EOT-window heuristic that were patched in earlier rounds.
 *
 *   3. Setup gate — the playerApi + ytmusic-player-bar elements don't
 *      exist until YT's app upgrades. We poll-with-backoff until they
 *      appear before wiring listeners. Fixes the race that documentStart
 *      injection always lost.
 *
 *   4. Fallback to mediaSession polling — only if playerApi never
 *      materializes (defensive; YT has changed selector names in the
 *      past). When fallback fires it's logged so we know.
 *
 * The old `__riffPendingNextUrl` + capture-phase ended + timeupdate
 * EOT-window code is GONE from this rewrite. Commit 2 replaces it
 * entirely with Redux-store queue dispatch (the real fix).
 */

(function () {
    "use strict";

    // ---- Element finders ---------------------------------------------------

    function videoEl() { return document.querySelector("video"); }

    /**
     * Find YT Music's player API object. Two known seams, in preference order:
     *   - ytmusic-player element's .playerApi (modern, post-2023 ish)
     *   - #movie_player element directly (older; some YT Music builds still
     *     expose it). Both share the same surface: getVideoData(),
     *     addEventListener('videodatachange'|'onStateChange', fn),
     *     setVolume(0..100), playVideo(), pauseVideo(), etc.
     */
    function playerApi() {
        const ytp = document.querySelector("ytmusic-player");
        if (ytp && typeof ytp.playerApi === "object" && ytp.playerApi) {
            return ytp.playerApi;
        }
        const mp = document.getElementById("movie_player");
        if (mp && typeof mp.getVideoData === "function") {
            return mp;
        }
        return null;
    }

    function playerBar() { return document.querySelector("ytmusic-player-bar"); }

    function postEvent(payload) {
        try { window.webkit.messageHandlers.bridge.postMessage(payload); } catch (_) {}
    }

    // ---- Public API (window.musicBridge) -----------------------------------

    const api = {
        // Single navigation primitive — Swift builds the full /watch?v=&list=
        // URL and tells the page to load it. The /watch route auto-plays.
        navigate(url) { location.href = url; },

        togglePlay() {
            const v = videoEl();
            if (!v) return;
            v.paused ? v.play() : v.pause();
        },

        // Unconditional pause — no toggle semantics. Used by Swift's
        // pause-enforcement (sleep end-of-track / autoplay-off stop) so
        // a repeated enforcement call can never accidentally resume.
        pause() {
            const v = videoEl();
            if (v && !v.paused) v.pause();
        },

        setPlaybackRate(rate) {
            const v = videoEl();
            // defaultPlaybackRate too: the HTML media load algorithm
            // resets playbackRate to defaultPlaybackRate on each new
            // source, so a podcast rate set only via playbackRate
            // snapped back to 1.0 at the next episode.
            if (v) { v.playbackRate = rate; v.defaultPlaybackRate = rate; }
        },

        skipBy(seconds) {
            const v = videoEl();
            if (v && isFinite(v.duration)) {
                v.currentTime = Math.max(0, Math.min(v.duration, v.currentTime + seconds));
            }
        },

        setVolume(level) {
            const clamped = Math.max(0, Math.min(1, level));
            // Cache the user's target volume — every write to
            // `<video>.volume` from this point forward multiplies it
            // by the active crossfade factor (default 1.0), so the
            // user's setVolume calls never fight an in-flight ramp.
            // When no crossfade is in flight the factor is 1.0 and
            // this is identical to a direct write. Falls back to a
            // direct write if the crossfade module hasn't initialized
            // yet (shouldn't happen — the IIFE wires both
            // synchronously — but cheap to guard).
            if (window.__riffXfade) {
                window.__riffXfade.userVolume = clamped;
                window.__riffXfade.applyVolume();
            } else {
                const v = videoEl();
                if (v) v.volume = clamped;
            }
        },

        // Crossfade between tracks (Tier 3 B8). `seconds` ∈ {0, 2, 4, 6, 8}.
        // 0 disables the feature entirely (factor stays pinned to 1.0).
        // The JS bridge handles both halves of the fade in one place:
        //   - tail ramp: on `timeupdate`, when remaining < seconds we
        //     linearly ramp the factor from 1.0 → 0.0
        //   - head ramp: on the NEXT trackChanged after a tail ramp
        //     started, we wall-clock ramp 0.0 → 1.0 over `seconds`
        // Swift retains ownership of the user's chosen volume — see
        // setVolume above; the crossfade factor multiplies, never
        // overrides.
        setCrossfadeSeconds(seconds) {
            const n = Math.max(0, Math.min(30, Number(seconds) || 0));
            if (!window.__riffXfade) return;
            window.__riffXfade.seconds = n;
            // Cancel any in-flight ramp if the user just turned
            // crossfade off, so we don't leave audio half-faded.
            if (n === 0) {
                window.__riffXfade.cancelHeadRamp();
                window.__riffXfade.factor = 1.0;
                window.__riffXfade.tailFading = false;
                window.__riffXfade.applyVolume();
            }
        },

        // Approximate per-track loudness normalization. Routes the
        // <video> element through a Web Audio graph (source → analyser
        // → gain → destination), samples ~5s of post-skip RMS, and
        // sets gain to land near -18 dBFS RMS. Not LUFS-accurate, but
        // catches the loud-pop-into-quiet-acoustic gap that's the
        // user-visible failure mode. Off by default.
        setNormalizationEnabled(on) {
            if (!window.__riffNorm) return;
            window.__riffNorm.init();
            window.__riffNorm.setEnabled(on);
            if (on) window.__riffNorm.startMeasuring();
        },

        // Repeat-one via the <video>.loop attribute. When loop=true the
        // browser restarts the source at end-of-stream and YT Music's
        // autoplay never fires. Clean per-track repeat with no DOM
        // dependence.
        setRepeatLoop(enabled) {
            const v = videoEl();
            if (v) v.loop = !!enabled;
        },

        // Park a URL the JS-side onStateChange===0 (ended) handler
        // consumes when the current track ends. Still the workhorse
        // for "Play next" / "Add to queue" because direct Redux
        // dispatch into YT's queue store requires constructing full
        // QueueItem payloads (shape undocumented; needs live page
        // inspection). The autoplay-interception path is reliable
        // now that onStateChange replaced the unreliable <video>.ended
        // we were waiting on. See queueAddViaPage below for the
        // experimental Redux path that runs alongside this as a
        // (currently best-effort) primary.
        setPendingNextURL(url) {
            window.__riffPendingNextUrl = url || null;
        },

        // Battery: called from Swift when the app is deactivated
        // (window loses focus / miniaturized). Suspends the
        // safety-poll (cheap but noticeable in Activity Monitor on
        // long-idle sessions) and the normalization tick (10Hz
        // during measurement, off outside it). Resumed on the
        // reverse notification. The playerApi event bus keeps
        // firing, so real state changes still land — this just
        // stops us waking the WebView on every tick to re-check
        // stable state.
        //
        // While backgrounded, rate changes (emitState via a media-key
        // pause/play, a store-subscription upgrade) only RECORD the
        // desired cadence (see startSafetyPoll); resuming here restarts
        // at whatever rate was last recorded, so an inactive-app state
        // change can never restart the poll in the background.
        setBackgrounded(isBackgrounded) {
            if (isBackgrounded) {
                stopSafetyPoll();
                window.__riffSafetyPollPaused = true;
                if (window.__riffNorm && window.__riffNorm.tickIntervalId !== null) {
                    clearInterval(window.__riffNorm.tickIntervalId);
                    window.__riffNorm.tickIntervalId = null;
                    window.__riffNorm.tickPaused = true;
                }
            } else {
                if (window.__riffSafetyPollPaused) {
                    window.__riffSafetyPollPaused = false;
                    // Resume only a poll that was ever configured — in
                    // mediaSession-fallback mode (setup never passed)
                    // there is no safety poll to restart.
                    if (window.__riffSafetyPollMs) startSafetyPoll(window.__riffSafetyPollMs);
                }
                if (window.__riffNorm && window.__riffNorm.tickPaused && window.__riffNorm.measuring) {
                    window.__riffNorm.startTickInterval();
                    window.__riffNorm.tickPaused = false;
                }
            }
        },

        /**
         * Attempt to inject a track into YT Music's own queue via
         * direct Redux dispatch. If it works, YT's natural autoplay
         * picks our injected item up and we don't need
         * __riffPendingNextUrl at all. If it doesn't, the autoplay-
         * interception path remains as a fallback.
         *
         * Returns true on a successful dispatch, false otherwise.
         * Both outcomes are logged via the `diagnostic` event so we
         * can iterate from `log show` output.
         *
         * The payload shape used here mirrors what th-ch's
         * music-together plugin observed YT dispatching internally
         * (action type 'ADD_ITEMS'). The `items` array expects full
         * QueueItem objects; we approximate with the minimal shape
         * YT seems to tolerate (videoId + a synthetic playlistPanel
         * wrapper). If YT rejects this shape the dispatch is a no-op
         * — no crash, just a diagnostic.
         */
        // Inject a track into the PAGE's own queue (single-authority
        // design, Phase A — see docs/QUEUE-DESIGN.md). Pipeline:
        //   1. fetch a REAL queue renderer for the videoId via the
        //      page's own music/get_queue (th-ch's proven approach —
        //      hand-built minimal renderers were silently rejected),
        //   2. dispatch ADD_ITEMS at the right index,
        //   3. VERIFY the id landed in the store, and report a
        //      `queueAddResult` event either way — Swift keeps its
        //      fallback copy until verification succeeds.
        queueAddViaPage(videoId, position) {
            (async () => {
                try {
                    reportQueueApiOnce();
                    if (!storeDispatchEnabled()) {
                        // Page-native add: hand the page ITS OWN
                        // queueAddEndpoint (what a "Play next" menu item
                        // carries) through its command resolver, so the
                        // page updates store AND player coherently. Field
                        // probe 2026-09-10: ytmusic-player-bar exposes
                        // resolveCommand. Verified by a store CHANGE (see
                        // queueAddLanded), never bare presence; the next
                        // advance's "match" audit is the player check.
                        await queueAddViaPageCommand(videoId, position);
                        return;
                    }
                    const disp = resolveQueueDispatch();
                    if (!disp) {
                        postEvent({ event: "queueAddResult", videoId: videoId, position: position, ok: false, via: "no-dispatcher" });
                        return;
                    }
                    const fetched = await fetchQueueRenderers(videoId);
                    if (!fetched.items.length) {
                        postEvent({ event: "queueAddResult", videoId: videoId, position: position, ok: false, via: "no-items:" + fetched.via });
                        return;
                    }
                    const slice = resolveQueueSlice();
                    const items = (slice.q && slice.q.items) || [];
                    // Pre-dispatch probe: verify by a change, not presence.
                    const before = queueAddProbe(videoId);
                    let selIdx = -1;
                    for (let i = 0; i < items.length; i++) {
                        const it = items[i];
                        const r = it && (it.playlistPanelVideoRenderer
                            || (it.playlistPanelVideoWrapperRenderer
                                && it.playlistPanelVideoWrapperRenderer.primaryRenderer
                                && it.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer));
                        if (r && r.selected) { selIdx = i; break; }
                    }
                    // 'next' → right after the playing row; 'end' → end
                    // of the main items (before the automix tail).
                    const index = position === "next" ? (selIdx >= 0 ? selIdx + 1 : 0) : items.length;
                    disp.dispatch({
                        type: "ADD_ITEMS",
                        payload: {
                            nextQueueItemId: (slice.q && slice.q.nextQueueItemId) || null,
                            index: index,
                            items: fetched.items,
                            shuffleEnabled: false,
                            shouldAssignIds: true,
                        },
                    });
                    const via = disp.via + "+" + fetched.via;
                    // Verify after the store settles; re-emit the mirror
                    // on success so Swift's display updates immediately.
                    setTimeout(() => {
                        try {
                            const present = queueAddLanded(videoId, position, before);
                            postEvent({ event: "queueAddResult", videoId: videoId, position: position, ok: present, via: present ? via : via + "+unchanged" });
                            if (present) {
                                window.__riffQueueSig = undefined;
                                emitQueueSnapshot();
                            }
                        } catch (e) {
                            postEvent({ event: "queueAddResult", videoId: videoId, position: position, ok: false, via: via + "+verify-threw" });
                        }
                    }, 300);
                } catch (e) {
                    postEvent({ event: "queueAddResult", videoId: videoId, position: position, ok: false, via: "threw:" + (e && e.message ? e.message : String(e)) });
                }
            })();
            return true;
        },

        // Remove a row from the PAGE's queue (Phase B). REMOVE_ITEM
        // with the item's index is the action YT's own queue menu
        // dispatches; unknown-type worst case is a redux no-op, and the
        // verification reports either way.
        queueRemoveViaPage(videoId) {
            // Rows live in TWO store arrays: `items` (the list / user
            // adds) and `automixItems` (the autoplay tail after an album
            // or playlist drains). Both render as rows and both are
            // removable — through the row's OWN menu, the page's action.
            // Field 2026-09-10: a direct REMOVE_ITEM store dispatch
            // "succeeded" (row gone from the store) and desynced store
            // and player — every later Next played an unseen track and
            // row taps stopped working. See STORE DISPATCH note.
            const finish = (ok, via) => {
                postEvent({ event: "queueRemoveResult", videoId: videoId, ok: ok, via: via });
                if (ok) { window.__riffQueueSig = undefined; emitQueueSnapshot(); }
            };
            try {
                reportQueueApiOnce();
                if (!queueHoldsVideo(videoId)) { finish(false, "not-in-items"); return true; }
                // The page's queue CONTROLLER (field probe 2026-09-10:
                // getItems / removeItem / selectQueueItem on
                // ytmusic-player-bar.queue) keeps store and player
                // coherent — one level below the row menu, same effect.
                removeViaController(videoId, (ok, via) => {
                    if (ok) { finish(true, via); return; }
                    // The store item's own menu model carries the page's
                    // "Remove from queue" service endpoint (identified by
                    // the locale-independent icon enum); the command
                    // resolver executes it exactly like a real menu click,
                    // with no DOM menu involved.
                    removeViaStoreEndpoint(videoId, (ok2, via2) => {
                        if (ok2) { finish(true, via2); return; }
                        removeViaRowMenu(videoId, (ok3, via3) => {
                            if (!ok3) {
                                // Which leg failed and why — the journal
                                // line for the NEXT field capture.
                                postEvent({ event: "diagnostic", msg: "queueRemove chain: ctrl=" + via + " endpoint=" + via2 + " menu=" + via3 });
                            }
                            finish(ok3, via3);
                        });
                    });
                });
            } catch (e) {
                finish(false, "threw:" + (e && e.message ? e.message : String(e)));
            }
            return true;
        },

        // Force a fresh mirror emit (bypasses the change signature). Used
        // after a failed page-side action so the display returns to the
        // page's truth now, not at the next page change.
        requestQueueSnapshot() {
            window.__riffQueueSig = undefined;
            emitQueueSnapshot();
            return true;
        },

        // Toggle the PAGE's shuffle (single-authority design): the page
        // permutes its own queue, the mirror displays that order, and
        // Next plays the top row — so shuffle never desynchronizes the
        // shown list from the play order. Selector candidates cover the
        // player-bar control and the queue-panel control across builds;
        // a diagnostic fires once if none is found.
        toggleShuffle() {
            for (const sel of SHUFFLE_SELECTORS) {
                const el = document.querySelector(sel);
                if (el) { el.click(); return true; }
            }
            if (!window.__riffShuffleSelectorWarned) {
                window.__riffShuffleSelectorWarned = true;
                postEvent({ event: "diagnostic", msg: "toggleShuffle: no shuffle control matched any candidate selector" });
            }
            return false;
        },

        // Play a specific row of the PAGE's queue in place (single-
        // authority design). A tapped Up Next row used to navigate to
        // the track — a page reload that RE-ROLLED the radio and
        // replaced the whole list. Instead, jump within the page's own
        // queue: it plays the row, keeps the rest, and the mirror simply
        // continues from there. Strategies, in order:
        //   1. click the matching row in the page's queue panel (rows
        //      render in store order: #contents ↔ items,
        //      #automix-contents ↔ automixItems),
        //   2. playerApi.playVideoAt(index) when the player holds the
        //      list.
        // Reports the attempt via diagnostic; Swift VERIFIES by
        // trackChanged arrival and falls back to navigation otherwise.
        queuePlayItem(videoId) {
            try {
                // IDENTITY-verified only. The previous version targeted
                // rows by store index and fell back to
                // playerApi.playVideoAt(index) — the player's index space
                // is not the store's, and that played the WRONG row; the
                // Swift fallback then navigated and re-rolled the radio.
                // Now: find the queue-panel row whose own data carries
                // this videoId; click only that; never guess.
                const rows = document.querySelectorAll("ytmusic-player-queue-item");
                let match = null;
                for (const row of rows) {
                    if (rowVideoId(row) === videoId) { match = row; break; }
                }
                if (!match) {
                    postEvent({ event: "diagnostic", msg: "queuePlayItem: " + videoId + " no identity-matched row (rows=" + rows.length + ")" });
                    return false;
                }
                const btn = (match.querySelector && match.querySelector("ytmusic-play-button-renderer, #play-button, .play-button")) || match;
                btn.click();
                postEvent({ event: "diagnostic", msg: "queuePlayItem: " + videoId + " via identity-matched row click" });
                return true;
            } catch (e) {
                postEvent({ event: "diagnostic", msg: "queuePlayItem threw: " + (e && e.message ? e.message : String(e)) });
            }
            return false;
        },

        next()     { document.querySelector(".next-button")?.click(); },
        previous() { document.querySelector(".previous-button")?.click(); },

        seek(fraction) {
            const v = videoEl();
            if (!v || !isFinite(v.duration)) return;
            v.currentTime = Math.max(0, Math.min(v.duration, v.duration * fraction));
        },

        getState() {
            const v = videoEl();
            return v ? { paused: v.paused, currentTime: v.currentTime, duration: v.duration } : null;
        },
    };
    window.musicBridge = api;

    // ---- Track-change + state-change handling ------------------------------

    let lastVideoId = "";
    let lastEmittedHadTitle = false;
    // C4: also key dedup by playlistId so a same-videoId replay from
    // a different playlist (e.g. user re-navigated to the same
    // track via a different `list=`) re-emits and Swift updates
    // currentPlaylistId. Prior dedup was videoId-only, which
    // silently swallowed playlist-context changes and left
    // autoplay-next scoped to the stale playlist.
    let lastEmittedPlaylistId = null;
    let stickyPlaylistId = null;

    function findPlaylistId() {
        // 1. Direct URL param (truthful right after navigation).
        const url = new URL(location.href);
        let id = url.searchParams.get("list");
        if (id) return id;
        // 2. Hash route — some YT Music transitions keep it there.
        if (location.hash) {
            try {
                const hashUrl = new URL(location.hash.slice(1), location.origin);
                id = hashUrl.searchParams.get("list");
                if (id) return id;
            } catch (_) { /* malformed; fall through */ }
        }
        // 3. DOM scan for any list= link — but ONLY while we don't have
        // a sticky id yet. This attribute-substring selector walks the
        // whole DOM, and since YT strips ?list= right after playback
        // starts, an unconditional scan here ran on every 2s safety
        // poll for the entire session. Once sticky is set, the scan
        // can't tell us anything new (navigations reload the page and
        // reset sticky anyway).
        if (stickyPlaylistId === null) {
            const link = document.querySelector('a[href*="list="]');
            if (link) {
                try {
                    const href = new URL(link.href, location.origin);
                    id = href.searchParams.get("list");
                    if (id) return id;
                } catch (_) {}
            }
        }
        return null;
    }

    /**
     * Fire a `trackChanged` event to Swift.
     * Pulls metadata from playerApi.getVideoData() — the canonical YT source —
     * with mediaSession.metadata as a fallback for the artwork (videoData
     * sometimes omits it).
     */
    function emitTrackChanged(reason) {
        const api = playerApi();
        if (!api) return;
        let vd;
        try { vd = api.getVideoData(); } catch (_) { return; }
        if (!vd || !vd.video_id) return;
        const found = findPlaylistId();
        if (found) stickyPlaylistId = found;
        const playlistId = stickyPlaylistId;
        // Compose the best title/artist we currently have from the
        // two sources. videodatachange's 'dataloaded' event often
        // fires BEFORE getVideoData populates title/author — the
        // canonical data lands on the subsequent 'dataupdated'
        // event. mediaSession.metadata fills in on its own clock.
        const md = navigator.mediaSession && navigator.mediaSession.metadata;
        const title = vd.title || (md && md.title) || "";
        const artist = vd.author || (md && md.artist) || "";
        // Dedup gating: skip if the videoId matches the last emit AND
        // we already emitted with non-empty title. This allows a
        // re-emit when an earlier emit had empty metadata (track
        // change just landed, getVideoData still empty) and now has
        // populated data — so Swift never gets stuck with a blank
        // title row.
        // Dedup key: (videoId, playlistId). The prior gate ignored
        // playlist changes entirely; a same-videoId replay from a
        // different `list=` was silently swallowed. (C4)
        if (vd.video_id === lastVideoId
            && playlistId === lastEmittedPlaylistId
            && lastEmittedHadTitle
            && reason !== "force") {
            return
        }
        const videoIdChanged = vd.video_id !== lastVideoId;
        lastVideoId = vd.video_id;
        lastEmittedPlaylistId = playlistId;
        lastEmittedHadTitle = title !== "";
        // Re-arm normalization measurement on a real track switch.
        // The dedup gate above prevents this from firing on the
        // late-arriving metadata re-emit for the same track.
        if (videoIdChanged && window.__riffNorm && window.__riffNorm.enabled) {
            window.__riffNorm.startMeasuring();
        }
        // Crossfade head-ramp on a real track switch — the new track's
        // <video> source is already swapped in by the time
        // videodatachange fires, so this is the right moment to start
        // ramping volume back up to the user's chosen level. Same
        // dedup gate as normalization above.
        if (videoIdChanged) {
            try { window.__riffXfade.onTrackChange(); } catch (_) {}
            // Re-mirror the page queue IMMEDIATELY on a real track
            // switch instead of waiting for the next 2s poll tick —
            // YT's radio can reshape its upcoming rows at each advance,
            // and the poll-lag window is exactly when the displayed
            // "up next" reads stale ("not true to what plays").
            // setTimeout(0) lets the store finish its own update first,
            // with a 600ms second shot for stores that settle late; the
            // sig dedup makes both free when nothing changed.
            try {
                setTimeout(emitQueueSnapshot, 0);
                setTimeout(emitQueueSnapshot, 600);
            } catch (_) {}
        }
        let artwork = null;
        if (md && md.artwork && md.artwork.length > 0) {
            artwork = md.artwork[md.artwork.length - 1].src;
        }
        postEvent({
            event: "trackChanged",
            videoId: vd.video_id,
            playlistId: playlistId,
            title: title,
            artist: artist,
            artwork: artwork,
        });
    }

    function emitState(state) {
        // YT's IFrame Player API state codes (the same set ytmusic-player.playerApi uses):
        //  -1 unstarted, 0 ENDED, 1 PLAYING, 2 PAUSED, 3 BUFFERING, 5 CUED
        if (state === 1) {
            postEvent({ event: "stateChanged", isPlaying: true });
        } else if (state === 0 || state === 2) {
            postEvent({ event: "stateChanged", isPlaying: false });
        }
        // Energy: adapt the safety-poll cadence to play state. Paused
        // → 10s (nothing advances while paused; the queue mirror still
        // gets a watchdog). Playing → the subscription-aware rate.
        // Only 1/2 drive this: -1/3/5 are transient and 0 is followed
        // by either a 1 (autoplay) or a 2. startSafetyPoll is a no-op
        // at an unchanged rate and only records the rate while
        // backgrounded (media-key pause/play fires onStateChange while
        // the app is inactive; the poll must not restart back there).
        if (state === 1 || state === 2) {
            lastPlayerStateCode = state;
            startSafetyPoll(desiredSafetyPollMs());
        }
        if (state === 0) {
            postEvent({ event: "ended" });
            // Legacy: drain __riffPendingNextUrl if set. Commit 2 removes
            // the Swift-side push that fills it, at which point this branch
            // becomes dead code.
            const pending = window.__riffPendingNextUrl;
            if (pending) {
                window.__riffPendingNextUrl = null;
                postEvent({ event: "riffNavigatedTo", url: pending, via: "onStateChange" });
                location.href = pending;
            }
        }
    }

    // ---- Safety poll + queue-store subscription (energy) --------------------
    //
    // The safety poll is the BEHAVIOR: a periodic re-check that
    // re-emits late metadata and walks the page's queue store for the
    // mirror. It always exists; only its cadence adapts:
    //
    //   2s   — playing, no store subscription (the original rate; the
    //          fallback whenever nothing better is possible)
    //   10s  — paused (nothing advances while paused), OR playing with
    //          a live store subscription (the subscription delivers
    //          queue changes push-style; the poll is only a watchdog)
    //
    // The subscription is an OPTIMISATION layered on top: when the
    // ytmusic-app store exposes redux-style `subscribe`, a listener
    // schedules a debounced emitQueueSnapshot on real queue changes —
    // so a change reaches Swift in ~100ms instead of waiting for a
    // poll tick, and the idle-session store walk drops from every 2s
    // to every 10s. It must never DELAY a snapshot: the watchdog tick
    // still emits anything the subscription missed, and a detected
    // miss (store mutated in place, no dispatch) downgrades back to
    // the 2s poll permanently for the page.
    const SAFETY_POLL_FAST_MS = 2000;
    const SAFETY_POLL_SLOW_MS = 10000;
    let lastPlayerStateCode = 1;            // last onStateChange ∈ {1, 2}
    let queueSubLastRefs = { queue: null, items: null, automix: null };
    let queueSubDebounceId = null;          // pending debounced emit, or null
    let queueSubUnsubscribe = null;         // redux unsubscribe fn, or null
    let queueSubStore = null;               // the store object we flagged
    let lateMetaTimerId = null;             // one-shot late-metadata backstop

    function desiredSafetyPollMs() {
        if (window.__riffQueueStoreSubscribed === true) return SAFETY_POLL_SLOW_MS;
        if (lastPlayerStateCode === 2) return SAFETY_POLL_SLOW_MS;
        return SAFETY_POLL_FAST_MS;
    }

    // Idempotent: a call at the currently-running rate is a no-op (so
    // every repeated onStateChange(1) doesn't churn the timer). While
    // backgrounded (setBackgrounded(true)) only the DESIRED rate is
    // recorded — setBackgrounded(false) resumes at it.
    function startSafetyPoll(ms) {
        window.__riffSafetyPollMs = ms;
        if (window.__riffSafetyPollPaused) return;
        if (window.__riffSafetyPollId && window.__riffSafetyPollRunningMs === ms) return;
        if (window.__riffSafetyPollId) clearInterval(window.__riffSafetyPollId);
        window.__riffSafetyPollRunningMs = ms;
        window.__riffSafetyPollId = setInterval(safetyPollTick, ms);
    }

    function stopSafetyPoll() {
        if (window.__riffSafetyPollId) clearInterval(window.__riffSafetyPollId);
        window.__riffSafetyPollId = null;
        window.__riffSafetyPollRunningMs = null;
    }

    function safetyPollTick() {
        const wasSubscribed = window.__riffQueueStoreSubscribed === true;
        // Backstop for the narrowed MutationObserver (see setup): YT
        // can replace the <video> element or the playerApi instance
        // across SPA transitions, including replacing the observed
        // ancestor itself — re-check here so a swap is never missed
        // for longer than one poll period.
        try {
            attachVideoListeners();
            const fresh = playerApi();
            if (fresh && !fresh.__riffSubscribed) subscribeToPlayerApi(fresh);
        } catch (_) {}
        emitTrackChanged("safety-poll");
        // The ytmusic-app store may not exist when setup() passes (the
        // gate is only playerApi + player-bar), so keep attempting the
        // subscribe from the poll until it lands, then drop to the
        // watchdog rate.
        if (!wasSubscribed && subscribeQueueStore()) {
            startSafetyPoll(desiredSafetyPollMs());
        }
        const sigBefore = window.__riffQueueSig;
        emitQueueSnapshot();
        // Watchdog miss-detection: a change the subscription should
        // have delivered but didn't (a store that mutates its arrays
        // in place fires no useful dispatch). Only when subscribed
        // BEFORE this tick (the first post-subscribe emit is expected
        // to change the sig) and no debounced emit is pending (the
        // change may simply be <100ms old).
        if (wasSubscribed
            && window.__riffQueueStoreSubscribed === true
            && queueSubDebounceId === null
            && window.__riffQueueSig !== sigBefore) {
            downgradeQueueSubscription("watchdog caught a queue change the store subscription missed");
        }
    }

    // The ytmusic-app redux-style store, when reachable. (Mirrors the
    // first branch of resolveQueueSlice; the player-element `.queue`
    // fallbacks there have no subscribe surface, so only this path can
    // upgrade.)
    function resolveAppStore() {
        const app = document.querySelector("ytmusic-app");
        const store = app && (app.store || (app.inst && app.inst.store));
        return (store && typeof store.getState === "function") ? store : null;
    }

    // Register a debounced queue-mirror listener on the page store.
    // Returns true when subscribed (now or previously). The flag lives
    // on the STORE object, not the playerApi — the MutationObserver
    // can rebind a fresh playerApi against the same store.
    function subscribeQueueStore() {
        try {
            // A proven-lossy subscription stays downgraded for the
            // rest of this document — without this, the next poll tick
            // would re-subscribe and the two would flip-flop forever.
            if (window.__riffQueueSubDisabled === true) return false;
            const store = resolveAppStore();
            if (!store || typeof store.subscribe !== "function") return false;
            if (store.__riffQueueSubscribed) {
                window.__riffQueueStoreSubscribed = true;
                return true;
            }
            // Seed the identity refs with the state as of subscription
            // so the first dispatch compares against reality, not null.
            try {
                const st0 = store.getState();
                const q0 = (st0 && st0.queue) || null;
                queueSubLastRefs = { queue: q0, items: (q0 && q0.items) || null, automix: (q0 && q0.automixItems) || null };
            } catch (_) {}
            const listener = () => {
                // Runs inside EVERY store dispatch — YT dispatches in
                // bursts, so this must be O(1) and must never throw
                // into the page's own dispatch. Only a changed
                // identity on the queue slice (or its arrays)
                // schedules the debounced O(rows) walk.
                try {
                    const st = store.getState();
                    const q = (st && st.queue) || null;
                    const items = (q && q.items) || null;
                    const automix = (q && q.automixItems) || null;
                    if (q === queueSubLastRefs.queue
                        && items === queueSubLastRefs.items
                        && automix === queueSubLastRefs.automix) return;
                    queueSubLastRefs = { queue: q, items: items, automix: automix };
                    if (queueSubDebounceId !== null) {
                        clearTimeout(queueSubDebounceId);
                        queueSubDebounceId = null;
                    }
                    // 100ms trailing debounce; sig dedup inside
                    // emitQueueSnapshot makes a no-change walk emit
                    // nothing. (The offline harness runs short timers
                    // inline — the `ranInline` dance keeps
                    // queueSubDebounceId null in that case instead of
                    // parking a stale id.)
                    let ranInline = false;
                    const tid = setTimeout(() => {
                        ranInline = true;
                        queueSubDebounceId = null;
                        emitQueueSnapshot();
                    }, 100);
                    if (!ranInline) queueSubDebounceId = tid;
                } catch (_) {}
            };
            const unsub = store.subscribe(listener);
            store.__riffQueueSubscribed = true;
            queueSubStore = store;
            queueSubUnsubscribe = (typeof unsub === "function") ? unsub : null;
            window.__riffQueueStoreSubscribed = true;
            // One-shot diagnostic (stands in for the Phase 1 handshake
            // capability report).
            if (!window.__riffQueueSubReported) {
                window.__riffQueueSubReported = true;
                postEvent({ event: "diagnostic", msg: "queue store subscribed via app.store" });
            }
            return true;
        } catch (_) {
            return false;
        }
    }

    // Revert to poll-only mirroring (the subscription proved lossy, or
    // the store was swapped out from under it). Sticky per document —
    // see the disable gate in subscribeQueueStore. Safe to call twice.
    function downgradeQueueSubscription(reason) {
        window.__riffQueueSubDisabled = true;
        try { if (queueSubUnsubscribe) queueSubUnsubscribe(); } catch (_) {}
        queueSubUnsubscribe = null;
        if (queueSubStore) {
            try { queueSubStore.__riffQueueSubscribed = false; } catch (_) {}
            queueSubStore = null;
        }
        window.__riffQueueStoreSubscribed = false;
        if (!window.__riffQueueSubDowngradeReported) {
            window.__riffQueueSubDowngradeReported = true;
            postEvent({ event: "diagnostic", msg: "queue store subscription downgraded: " + reason });
        }
        startSafetyPoll(desiredSafetyPollMs());
    }

    /**
     * Subscribe to playerApi event bus. The event names differ slightly
     * across YT builds — `videodatachange` is the canonical track-change
     * event in modern builds; `onStateChange` is universal.
     *
     * On `videodatachange` we get (name, videoData) where `name` ∈
     * {'newdata', 'dataloaded', 'dataupdated'}. We treat any non-empty
     * videoData with a new video_id as a track change.
     */
    function subscribeToPlayerApi(api) {
        if (api.__riffSubscribed) return;
        api.__riffSubscribed = true;
        try {
            api.addEventListener("videodatachange", (_name, _videoData) => {
                emitTrackChanged("videodatachange");
                // Late-metadata backstop, cadence-independent:
                // getVideoData often lacks title/author when
                // 'dataloaded' fires, and with the poll slowed to 10s
                // under a store subscription the next tick is too far
                // away to fill the blank row. One shot ~1s later
                // re-emits iff something new landed (the dedup gate in
                // emitTrackChanged makes it free otherwise).
                try {
                    if (lateMetaTimerId !== null) clearTimeout(lateMetaTimerId);
                    lateMetaTimerId = setTimeout(() => {
                        lateMetaTimerId = null;
                        emitTrackChanged("safety-poll");
                    }, 1000);
                } catch (_) {}
            });
        } catch (e) { postEvent({ event: "diagnostic", msg: "videodatachange subscribe failed: " + e }); }
        try {
            api.addEventListener("onStateChange", (state) => {
                emitState(state);
            });
        } catch (e) { postEvent({ event: "diagnostic", msg: "onStateChange subscribe failed: " + e }); }
        // Initial sync — emit what's currently loaded so Swift gets a track
        // immediately on (re)attach instead of waiting for the first
        // playerApi event.
        emitTrackChanged("force");
        // Safety-net poll: videodatachange's 'dataupdated' event isn't
        // always reliable — th-ch documents the same. The poll
        // re-evaluates and re-emits if metadata finally landed (the
        // dedup gate in emitTrackChanged guards against redundant
        // emits when nothing changed), and is the queue mirror's
        // fallback transport. Rate policy above (2s baseline).
        startSafetyPoll(desiredSafetyPollMs());
    }

    // ---- Page-queue mirror (Phase 2 radio truth) ---------------------------
    //
    // Radio queues are non-deterministic, so the only correct Up Next
    // for radio is the queue THE PAGE is actually playing. That lives in
    // the ytmusic-app Polymer store: state.queue.items (+ automixItems,
    // the autoplay extension). Items are wrapped renderers — either
    // { playlistPanelVideoRenderer } directly or
    // { playlistPanelVideoWrapperRenderer: { primaryRenderer: {...} } }
    // (the wrapper carries counterpart/video-toggle variants).
    //
    // Emitted from the 2s safety poll, deduped by a videoId+selected
    // signature so Swift only hears real changes. Failure is silent
    // after one diagnostic — Swift keeps the Phase-1 banner as fallback.
    // One-shot shape report so a failed store lookup is debuggable from
    // the unified log instead of silently showing no queue. Reports
    // which link in the chain is missing and, when a state exists, its
    // top-level keys — enough to adapt the path without live inspection.
    function reportQueueShapeOnce(stage, extra) {
        if (window.__riffQueueShapeReported) return;
        window.__riffQueueShapeReported = true;
        postEvent({ event: "diagnostic", msg: "queueSnapshot probe [" + stage + "]: " + (extra || "") });
    }

    // Find the live queue slice. YT's builds move it around:
    //   - classic: ytmusic-app.store.getState().queue
    //   - proxy-wrapped app (observed 2026-08: appKeys show inst/
    //     controllerProxy, no store): the real instance hides behind
    //     .inst, and/or the player elements expose .queue directly.
    // Returns { q, via } — q has items/automixItems when found.
    function resolveQueueSlice() {
        const app = document.querySelector("ytmusic-app");
        if (app) {
            const store = app.store || (app.inst && app.inst.store);
            if (store && typeof store.getState === "function") {
                const st = store.getState();
                if (st && st.queue) return { q: st.queue, via: "app.store" };
            }
        }
        for (const sel of ["ytmusic-player-bar", "ytmusic-player-queue"]) {
            const el = document.querySelector(sel);
            const q = el && el.queue;
            if (!q) continue;
            if (q.items || q.automixItems) return { q: q, via: sel + ".queue" };
            if (typeof q.getState === "function") {
                const st = q.getState();
                if (st && (st.items || st.automixItems)) return { q: st, via: sel + ".queue.getState()" };
                if (st && st.queue) return { q: st.queue, via: sel + ".queue.getState().queue" };
            }
            if (q.store && typeof q.store.getState === "function") {
                const st = q.store.getState();
                if (st && (st.items || st.automixItems)) return { q: st, via: sel + ".queue.store(flat)" };
                if (st && st.queue) return { q: st.queue, via: sel + ".queue.store" };
            }
            // Unknown queue-object shape — report its keys so the next
            // capture tells us how to read it.
            reportQueueShapeOnce("queue-prop-unknown-shape",
                sel + ".queue keys=" + Object.keys(q).slice(0, 25).join("|"));
        }
        return { q: null, via: "none" };
    }

    // Find a dispatch function into the page's queue store. Ordered by
    // directness; mirrors resolveQueueSlice's host list (the store and
    // its dispatch usually live together).
    // STORE DISPATCH — off by default. The ytmusic-app store is not the
    // player's playlist: dispatching ADD_ITEMS / REMOVE_ITEM edits what
    // the queue panel shows without telling the player, and the two
    // never resync (field 2026-09-10: after one REMOVE_ITEM every Next
    // played an off-screen track and identity row clicks stopped
    // playing). Queue edits go through the page's own UI actions; the
    // dispatcher stays for diagnostics and can be re-enabled per page
    // via window.__riffStoreDispatchEnabled = true once a page-native
    // add is verified.
    function storeDispatchEnabled() {
        return window.__riffStoreDispatchEnabled === true;
    }

    // One-shot dump of the page's queue API surface (method names on
    // the queue object and queue/endpoint-related methods on the app
    // elements) so a field log tells us the page-native add/remove
    // calls instead of guessing at store actions.
    function reportQueueApiOnce() {
        if (window.__riffQueueApiReported) return;
        window.__riffQueueApiReported = true;
        try {
            const fnNames = (obj, depth) => {
                const names = new Set();
                let o = obj;
                for (let d = 0; o && d < depth; d++) {
                    for (const n of Object.getOwnPropertyNames(o)) {
                        if (n === "constructor" || n.startsWith("__")) continue;
                        try { if (typeof obj[n] === "function") names.add(n); } catch (e) { /* getter threw */ }
                    }
                    o = Object.getPrototypeOf(o);
                }
                return Array.from(names);
            };
            // One event per element: a single long line is truncated by
            // the unified log.
            let any = false;
            for (const sel of ["ytmusic-player-bar", "ytmusic-player-queue", "ytmusic-app"]) {
                const el = document.querySelector(sel);
                if (!el) continue;
                any = true;
                const q = el.queue;
                if (q) postEvent({ event: "diagnostic", msg: "queueApi: " + sel + ".queue fns=" + fnNames(q, 4).slice(0, 60).join(",") });
                const elFns = fnNames(el, 6).filter((n) => /queue|endpoint|action|command|navigate|resolve/i.test(n));
                if (elFns.length) postEvent({ event: "diagnostic", msg: "queueApi: " + sel + " fns~=" + elFns.slice(0, 40).join(",") });
            }
            const row = document.querySelector("ytmusic-player-queue-item");
            if (row && row.querySelectorAll) {
                const tags = new Set();
                for (const n of row.querySelectorAll("*")) {
                    const t = (n.tagName || "").toLowerCase();
                    if (/menu|button|icon/.test(t) || (n.id && /menu|button/.test(n.id))) tags.add(t + (n.id ? "#" + n.id : ""));
                    if (tags.size >= 20) break;
                }
                postEvent({ event: "diagnostic", msg: "queueApi: row parts=" + Array.from(tags).join(",") });
            }
            // Always one summary line: what the page-native paths can use.
            postEvent({ event: "diagnostic", msg: "queueApi: summary elements=" + any
                + " controller=" + (resolveQueueController() ? "yes" : "no")
                + " command=" + (resolveCommandHost() ? "yes" : "no") });
        } catch (e) {
            postEvent({ event: "diagnostic", msg: "queueApi probe threw: " + (e && e.message ? e.message : String(e)) });
        }
    }

    function resolveQueueDispatch() {
        const app = document.querySelector("ytmusic-app");
        const store = app && (app.store || (app.inst && app.inst.store));
        if (store && typeof store.dispatch === "function") {
            return { dispatch: (a) => store.dispatch(a), via: "app.store" };
        }
        for (const sel of ["ytmusic-player-bar", "ytmusic-player-queue"]) {
            const el = document.querySelector(sel);
            const q = el && el.queue;
            if (q) {
                if (q.store && q.store.store && typeof q.store.store.dispatch === "function") {
                    return { dispatch: (a) => q.store.store.dispatch(a), via: sel + ".queue.store.store" };
                }
                if (q.store && typeof q.store.dispatch === "function") {
                    return { dispatch: (a) => q.store.dispatch(a), via: sel + ".queue.store" };
                }
                if (typeof q.dispatch === "function") {
                    return { dispatch: (a) => q.dispatch(a), via: sel + ".queue" };
                }
            }
            if (el && typeof el.dispatch === "function") {
                return { dispatch: (a) => el.dispatch(a), via: sel + ".dispatch" };
            }
        }
        return null;
    }

    // Unwrap any queue-item shape to its renderer (wrapper, direct, or
    // flat). Shared by the injection/removal verification paths.
    function unwrapQueueItem(it) {
        if (!it) return null;
        if (it.playlistPanelVideoRenderer) return it.playlistPanelVideoRenderer;
        const w = it.playlistPanelVideoWrapperRenderer;
        if (w && w.primaryRenderer) return w.primaryRenderer.playlistPanelVideoRenderer || null;
        if (typeof it.videoId === "string") return it;
        return null;
    }

    // The videoId a queue-panel row represents, read from the row's own
    // bound data (property names vary across builds) or, failing that,
    // an inner watch link. Null when the row can't be identified —
    // callers must treat that as "don't click".
    // The page's queue controller object (not the store): exposes the
    // page's own queue operations. Shape from the field probe.
    function resolveQueueController() {
        for (const sel of ["ytmusic-player-bar", "ytmusic-player-queue"]) {
            const el = document.querySelector(sel);
            const q = el && el.queue;
            if (q && typeof q.getItems === "function") return { q: q, via: sel + ".queue" };
        }
        return null;
    }

    function controllerItemVideoId(it) {
        if (!it) return null;
        const r = unwrapQueueItem(it) || (it.data && unwrapQueueItem(it.data));
        if (r && typeof r.videoId === "string") return r.videoId;
        if (typeof it.videoId === "string") return it.videoId;
        return null;
    }

    // Remove through the controller. removeItem's argument shape is not
    // documented: try the row's index in the controller's OWN list, then
    // the item object; each attempt is verified against the store so a
    // no-op never reports success and a wrong row is impossible (the
    // index is looked up in the same list the controller holds).
    // Remove through the row's OWN menu model: the store item's
    // renderer carries menu.menuRenderer.items whose "Remove from
    // queue" entry is identified by its icon enum (REMOVE_FROM_QUEUE —
    // locale-independent, unlike the label text). Executing its
    // serviceEndpoint through the page's command resolver is the same
    // page action as a menu click, minus the fragile DOM menu.
    function removeViaStoreEndpoint(videoId, done) {
        const slice = resolveQueueSlice();
        const all = (((slice.q && slice.q.items) || [])).concat((slice.q && slice.q.automixItems) || []);
        let renderer = null;
        for (const it of all) {
            const r = unwrapQueueItem(it);
            if (r && r.videoId === videoId) { renderer = r; break; }
        }
        const menuItems = renderer && renderer.menu && renderer.menu.menuRenderer && renderer.menu.menuRenderer.items;
        if (!menuItems || !menuItems.length) { done(false, "endpoint:no-menu-data"); return; }
        let endpoint = null;
        for (const mi of menuItems) {
            const svc = mi && mi.menuServiceItemRenderer;
            const icon = svc && svc.icon && svc.icon.iconType;
            if (icon && String(icon).indexOf("REMOVE") >= 0 && svc.serviceEndpoint) {
                endpoint = svc.serviceEndpoint;
                break;
            }
        }
        if (!endpoint) { done(false, "endpoint:no-remove-item"); return; }
        const host = resolveCommandHost();
        if (!host) { done(false, "endpoint:no-resolver"); return; }
        try {
            host.el.resolveCommand(endpoint, host.el);
        } catch (e) {
            done(false, "endpoint:threw");
            return;
        }
        let tries = 0;
        const poll = () => {
            tries += 1;
            if (!queueHoldsVideo(videoId)) { done(true, "endpoint:resolveCommand@" + host.via); return; }
            if (tries >= 8) { done(false, "endpoint:unverified"); return; }
            setTimeout(poll, 250);
        };
        setTimeout(poll, 250);
    }

    function removeViaController(videoId, done) {
        const c = resolveQueueController();
        if (!c || typeof c.q.removeItem !== "function") { done(false, "controller:absent"); return; }
        let items = [];
        try { items = c.q.getItems() || []; } catch (e) { done(false, "controller:getItems-threw"); return; }
        let idx = -1;
        for (let i = 0; i < items.length; i++) { if (controllerItemVideoId(items[i]) === videoId) { idx = i; break; } }
        if (idx < 0) {
            // The controller's items are not renderer-shaped here —
            // dump the first item's keys once so the next capture
            // names the real shape.
            if (!window.__riffCtrlShapeReported && items.length) {
                window.__riffCtrlShapeReported = true;
                try {
                    postEvent({ event: "diagnostic", msg: "queueRemove ctrlItem keys=" + Object.keys(items[0]).slice(0, 15).join(",") });
                } catch (e) { /* shape dump is best-effort */ }
            }
            done(false, "controller:not-in-items");
            return;
        }
        const attempt = (arg, label, next) => {
            try { c.q.removeItem(arg); } catch (e) { next(); return; }
            setTimeout(() => {
                if (!queueHoldsVideo(videoId)) done(true, c.via + ":removeItem(" + label + ")");
                else next();
            }, 300);
        };
        attempt(idx, "index", () => attempt(items[idx], "item", () => done(false, "controller:no-effect")));
    }

    // Find an element exposing the page's command resolver.
    function resolveCommandHost() {
        for (const sel of ["ytmusic-player-bar", "ytmusic-app", "ytmusic-player-queue"]) {
            const el = document.querySelector(sel);
            if (el && typeof el.resolveCommand === "function") return { el: el, via: sel };
            if (el && el.inst && typeof el.inst.resolveCommand === "function") return { el: el.inst, via: sel + ".inst" };
        }
        return null;
    }

    // Play next / add to queue through the page's own command: the same
    // queueAddEndpoint a "Play next" menu item carries. Verified by
    // polling the store (the page fetches the renderer first), up to
    // ~3s, for a CHANGE (queueAddLanded) — not presence: a Play next on
    // a row the page already holds, or on the playing track, is present
    // before the command runs, and reporting ok for a no-op would make
    // Swift drop its enforced copy. On success Swift drops its fallback
    // copy; the item is then page-owned and plays natively.
    async function queueAddViaPageCommand(videoId, position) {
        const post = (ok, via) => {
            postEvent({ event: "queueAddResult", videoId: videoId, position: position, ok: ok, via: via });
            if (ok) { window.__riffQueueSig = undefined; emitQueueSnapshot(); }
        };
        const host = resolveCommandHost();
        if (!host) { post(false, "no-page-command"); return; }
        const command = {
            queueAddEndpoint: {
                queueTarget: { videoId: videoId },
                queueInsertPosition: position === "next" ? "INSERT_AFTER_CURRENT_VIDEO" : "INSERT_AT_END",
            },
        };
        const before = queueAddProbe(videoId);
        try {
            host.el.resolveCommand(command, host.el);
        } catch (e) {
            post(false, "endpoint:resolveCommand:threw:" + (e && e.message ? e.message : String(e)));
            return;
        }
        for (let i = 0; i < 12; i++) {
            await new Promise((r) => setTimeout(r, 250));
            if (queueAddLanded(videoId, position, before)) { post(true, "endpoint:resolveCommand@" + host.via); return; }
        }
        post(false, before.count > 0 ? "endpoint:resolveCommand:already-present-unchanged" : "endpoint:resolveCommand:unverified");
    }

    // Where `videoId` sits in the page's queue (items ∪ automixItems):
    // occurrence count, whether it is the row right after the playing
    // (selected) row, and whether it is the last main row (before the
    // automix tail). Same unwrap walk as queueHoldsVideo.
    function queueAddProbe(videoId) {
        const s = resolveQueueSlice();
        const main = (s.q && s.q.items) || [];
        const all = main.concat((s.q && s.q.automixItems) || []);
        let count = 0, selIdx = -1;
        for (let i = 0; i < all.length; i++) {
            const r = unwrapQueueItem(all[i]);
            if (!r) continue;
            if (r.videoId === videoId) count++;
            if (selIdx < 0 && r.selected) selIdx = i;
        }
        const afterSel = selIdx >= 0 ? unwrapQueueItem(all[selIdx + 1]) : null;
        const last = main.length ? unwrapQueueItem(main[main.length - 1]) : null;
        return {
            count: count,
            nextIsId: !!afterSel && afterSel.videoId === videoId,
            lastIsId: !!last && last.videoId === videoId,
        };
    }

    // Did a Play next / Add to queue take effect, given the probe taken
    // before the command? True when a NEW occurrence appeared (the page
    // inserts a copy), or when the id now sits where the user asked —
    // right after the playing row for "next", the last main row for
    // "end". The positional test covers a page that MOVES an existing
    // row (count unchanged) and an intent already satisfied (reporting
    // failure there would hand Swift the legacy pending-URL reload).
    // A row that merely exists elsewhere is NOT success.
    function queueAddLanded(videoId, position, before) {
        const now = queueAddProbe(videoId);
        if (now.count > before.count) return true;
        return position === "next" ? now.nextIsId : now.lastIsId;
    }

    // Is `videoId` still anywhere in the page's queue (items ∪ automix)?
    function queueHoldsVideo(videoId) {
        const after = resolveQueueSlice();
        const all = (((after.q && after.q.items) || [])).concat((after.q && after.q.automixItems) || []);
        return all.some((it) => {
            const r = unwrapQueueItem(it);
            return !!r && r.videoId === videoId;
        });
    }

    // Remove a queue row through its own "⋯" menu — the page's action,
    // for rows the store dispatch can't reach. Identity-matched row
    // (never positional); result verified against the store.
    function removeViaRowMenu(videoId, done) {
        const rows = document.querySelectorAll("ytmusic-player-queue-item");
        let row = null;
        for (const r of rows) { if (rowVideoId(r) === videoId) { row = r; break; } }
        if (!row) { done(false, "menu:no-row"); return; }
        const btn = row.querySelector && row.querySelector(QUEUE_ROW_MENU_BUTTON);
        if (!btn) { done(false, "menu:no-button"); return; }
        btn.click();
        setTimeout(() => {
            try {
                const candidates = document.querySelectorAll(QUEUE_MENU_ITEMS);
                let item = null;
                for (const c of candidates) {
                    const t = (c.textContent || "").trim().toLowerCase();
                    if (t.indexOf("remove from queue") >= 0) { item = c; break; }
                }
                if (!item) {
                    if (document.body && document.body.click) document.body.click();   // close the menu
                    done(false, "menu:no-remove-item");
                    return;
                }
                ((item.querySelector && item.querySelector("a, tp-yt-paper-item, #navigation-endpoint")) || item).click();
                setTimeout(() => {
                    const present = queueHoldsVideo(videoId);
                    done(!present, present ? "menu:still-present" : "menu:removed");
                }, 400);
            } catch (e) {
                done(false, "menu:threw");
            }
        }, 250);
    }
    // Selectors are the fragile external API — kept in one place.
    // Field row dump 2026-09-11 ("queueApi: row parts="): the ⋯ button
    // is ytmusic-menu-renderer > div#top-level-buttons > yt-button-shape
    // > button on the current page. Older shapes kept as fallbacks.
    const QUEUE_ROW_MENU_BUTTON = "ytmusic-menu-renderer yt-button-shape button, ytmusic-menu-renderer button, ytmusic-menu-renderer #button, ytmusic-menu-renderer yt-icon-button, ytmusic-menu-renderer tp-yt-paper-icon-button, #menu button";
    const QUEUE_MENU_ITEMS = "ytmusic-menu-popup-renderer ytmusic-menu-navigation-item-renderer, ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer, tp-yt-paper-listbox ytmusic-menu-service-item-renderer";
    // Shuffle control candidates across YT builds (player-bar control
    // and queue-panel control) — shared by toggleShuffle and the
    // pageInfo selector-health report so the two can never disagree.
    const SHUFFLE_SELECTORS = [
        "ytmusic-player-bar .shuffle",
        "ytmusic-player-bar tp-yt-paper-icon-button.shuffle",
        "ytmusic-player-bar [aria-label*='huffle']",
        "#queue .shuffle",
        "ytmusic-player-queue [aria-label*='huffle']",
    ];

    function rowVideoId(row) {
        try {
            const cands = [row.data, row.queueItem, row.item, row.__data && row.__data.data];
            for (const c of cands) {
                const r = unwrapQueueItem(c);
                if (r && typeof r.videoId === "string") return r.videoId;
                if (c && typeof c.videoId === "string") return c.videoId;
            }
            const a = row.querySelector && row.querySelector('a[href*="v="]');
            if (a && a.href) {
                const v = new URL(a.href, location.origin).searchParams.get("v");
                if (v) return v;
            }
        } catch (_) {}
        return null;
    }

    // Fetch REAL queue renderers for a videoId via the page's own
    // music/get_queue — the response's queueDatas[].content are exactly
    // the playlistPanelVideoRenderer wrappers YT's ADD_ITEMS reducer
    // expects (hand-built minimal shapes get silently dropped).
    // Primary: the page's networkManager (carries auth/context itself).
    // Fallback: a same-origin InnerTube fetch built from window.ytcfg.
    async function fetchQueueRenderers(videoId) {
        const app = document.querySelector("ytmusic-app");
        const nm = app && (app.networkManager || (app.inst && app.inst.networkManager));
        if (nm && typeof nm.fetch === "function") {
            try {
                const resp = await nm.fetch("/music/get_queue", { videoIds: [videoId] });
                const datas = resp && resp.queueDatas;
                if (Array.isArray(datas) && datas.length) {
                    return { items: datas.map((d) => d && d.content).filter(Boolean), via: "networkManager" };
                }
            } catch (_) { /* fall through */ }
        }
        try {
            const cfg = ytcfg();
            const key = cfg && cfg.INNERTUBE_API_KEY;
            const ctx = cfg && cfg.INNERTUBE_CONTEXT;
            if (key && ctx) {
                const r = await fetch("/youtubei/v1/music/get_queue?key=" + encodeURIComponent(key), {
                    method: "POST",
                    credentials: "same-origin",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ context: ctx, videoIds: [videoId] }),
                });
                const resp = await r.json();
                const datas = resp && resp.queueDatas;
                if (Array.isArray(datas) && datas.length) {
                    return { items: datas.map((d) => d && d.content).filter(Boolean), via: "ytcfg-fetch" };
                }
            }
        } catch (_) {}
        return { items: [], via: "none" };
    }

    function emitQueueSnapshot() {
        try {
            const resolved = resolveQueueSlice();
            const q = resolved.q;
            if (!q) {
                reportQueueShapeOnce("no-queue-anywhere");
                return;
            }
            const unwrap = (it) => {
                if (!it) return null;
                if (it.playlistPanelVideoRenderer) return it.playlistPanelVideoRenderer;
                const w = it.playlistPanelVideoWrapperRenderer;
                if (w && w.primaryRenderer) return w.primaryRenderer.playlistPanelVideoRenderer || null;
                // Flat shape (queue-service items carry videoId directly).
                if (typeof it.videoId === "string") return it;
                return null;
            };
            const text = (t) => {
                if (!t) return "";
                if (typeof t === "string") return t;
                if (t.runs) return t.runs.map((r) => r.text).join("");
                return t.simpleText || "";
            };
            const rows = [];
            const source = (q.items || []).concat(q.automixItems || []);
            for (const raw of source) {
                const r = unwrap(raw);
                if (!r || !r.videoId) continue;
                const thumbs = (r.thumbnail && r.thumbnail.thumbnails) || [];
                rows.push({
                    videoId: r.videoId,
                    title: text(r.title),
                    byline: text(r.longBylineText) || text(r.shortBylineText),
                    // SMALLEST variant: these rows render at 36pt in the
                    // queue list, and AsyncImage decodes at native size —
                    // the largest variant would cost ~1MB of decoded
                    // bitmap per row across up to 80 rows.
                    thumbnail: thumbs.length ? thumbs[0].url : "",
                    selected: !!r.selected,
                });
                if (rows.length >= 80) break;   // cap payload; radio can run long
            }
            if (!rows.length) {
                const first = source.length ? source[0] : null;
                reportQueueShapeOnce("zero-rows",
                    "via=" + resolved.via +
                    "; queueKeys=" + Object.keys(q).slice(0, 20).join("|") +
                    "; items=" + (q.items ? q.items.length : "nil") +
                    "; automix=" + (q.automixItems ? q.automixItems.length : "nil") +
                    "; firstItemKeys=" + (first ? Object.keys(first).slice(0, 10).join("|") : "none"));
                return;
            }
            const sig = rows.map((r) => r.videoId + (r.selected ? "*" : "")).join(",");
            if (sig === window.__riffQueueSig) return;
            window.__riffQueueSig = sig;
            reportQueueShapeOnce("ok", rows.length + " rows via " + resolved.via);
            postEvent({
                event: "queueSnapshot",
                items: rows,
                // The page's own shuffle state (single-authority: in
                // page-driven contexts Swift mirrors this rather than
                // keeping a local flag that the display can't honor).
                shuffleEnabled: (typeof q.shuffleEnabled === "boolean") ? q.shuffleEnabled : null,
            });
        } catch (e) {
            if (!window.__riffQueueSnapErrLogged) {
                window.__riffQueueSnapErrLogged = true;
                postEvent({ event: "diagnostic", msg: "queueSnapshot failed: " + (e && e.message ? e.message : String(e)) });
            }
        }
    }

    // ---- Page handshake (pageInfo) -----------------------------------------
    //
    // One `pageInfo` event per document, posted BEFORE `ready` so the
    // Swift side has the page's live protocol values (clientVersion
    // above all) and the capability/selector health map in place before
    // `ready` triggers its queued-command flush. Best-effort
    // introspection throughout: a missing key reports "" / false, and a
    // throw degrades to a diagnostic — never blocks `ready`.

    // Per-document generation id. The user script re-runs on every
    // navigation, so this re-rolls per page; Swift uses it to log the
    // handshake once per document.
    const PAGE_GENERATION = Math.random().toString(36).slice(2, 10) + Date.now().toString(36);

    // The page's own config blob — two known homes for the same data.
    // Shared with fetchQueueRenderers' same-origin InnerTube fallback.
    function ytcfg() {
        return (window.yt && window.yt.config_) || (window.ytcfg && window.ytcfg.data_) || null;
    }

    function emitPageInfo() {
        try {
            const cfg = ytcfg() || {};
            const str = (v) => (typeof v === "string" ? v : (typeof v === "number" ? String(v) : ""));
            const app = document.querySelector("ytmusic-app");
            const store = app && (app.store || (app.inst && app.inst.store));
            let shuffleFound = false;
            for (const sel of SHUFFLE_SELECTORS) {
                if (document.querySelector(sel)) { shuffleFound = true; break; }
            }
            postEvent({
                event: "pageInfo",
                schema: 1,
                generation: PAGE_GENERATION,
                ytcfg: {
                    clientVersion: str(cfg.INNERTUBE_CLIENT_VERSION),
                    sessionIndex: str(cfg.SESSION_INDEX),
                    visitorData: str(cfg.VISITOR_DATA),
                    hl: str(cfg.HL),
                    gl: str(cfg.GL),
                },
                capabilities: {
                    playerApi: !!playerApi(),
                    queueController: !!resolveQueueController(),
                    commandResolver: !!resolveCommandHost(),
                    storeDispatch: !!resolveQueueDispatch(),
                    storeSubscribe: !!(store && typeof store.subscribe === "function"),
                },
                selectors: {
                    next: !!document.querySelector(".next-button"),
                    previous: !!document.querySelector(".previous-button"),
                    shuffle: shuffleFound,
                    playerBar: !!playerBar(),
                    queueRows: document.querySelectorAll("ytmusic-player-queue-item").length,
                },
            });
        } catch (e) {
            postEvent({ event: "diagnostic", msg: "pageInfo emit failed: " + (e && e.message ? e.message : String(e)) });
        }
    }

    // ---- <video> listeners (progress only — state moved to onStateChange) --

    function attachVideoListeners() {
        const v = videoEl();
        if (!v || v.__riffAttached) return;
        v.__riffAttached = true;
        // Progress is fine to read directly off the element — it fires
        // ~4Hz and we use it for the scrubber, not for end-of-track
        // decisions.
        v.addEventListener("timeupdate", () => {
            postEvent({ event: "progress", currentTime: v.currentTime, duration: v.duration });
            // Crossfade tail-ramp lives here so it runs at the same
            // ~4Hz the scrubber updates — accurate enough for a 2-8s
            // ramp, and no separate timer to babysit.
            try { window.__riffXfade.onTimeUpdate(v.currentTime, v.duration); } catch (_) {}
        });
    }

    // ---- Setup gate: poll until playerApi + player-bar exist ---------------

    let setupAttempts = 0;
    const SETUP_MAX_ATTEMPTS = 60;       // 30s at 500ms cadence
    const SETUP_INTERVAL_MS = 500;
    let setupDone = false;

    function setup() {
        if (setupDone) return;
        const api = playerApi();
        const bar = playerBar();
        if (!api || !bar) {
            setupAttempts++;
            if (setupAttempts > SETUP_MAX_ATTEMPTS) {
                // Defensive: if playerApi never appears (YT changed selectors,
                // page broken, etc.) fall back to the legacy mediaSession poll
                // so Riff doesn't silently lose track-change events. The
                // fallback's lower fidelity is acceptable; the alert tells us
                // the primary path is dead.
                postEvent({ event: "diagnostic", msg: "playerApi never appeared after " + SETUP_MAX_ATTEMPTS + " attempts; falling back to mediaSession poll" });
                startMediaSessionFallback();
                setupDone = true;
                // Handshake first, then ready — Swift installs the
                // page's protocol overrides before ready's flush.
                emitPageInfo();
                postEvent({ event: "ready" });
                return;
            }
            setTimeout(setup, SETUP_INTERVAL_MS);
            return;
        }
        setupDone = true;
        subscribeToPlayerApi(api);
        attachVideoListeners();
        // Re-attach video listeners as YT swaps the element (rare but happens
        // across some SPA transitions). MutationObserver watching the body's
        // childList is overkill for this; the videodatachange event will
        // already fire on the new element, and we just need to grab the
        // new element's timeupdate.
        // Debounced (500ms trailing): this SPA mutates near-continuously
        // while playing, and running three querySelector lookups on every
        // mutation batch kept the hidden WebView's JS runtime hot for the
        // whole session. Element swaps we're catching here are rare and a
        // half-second re-attach lag is invisible (the 2s safety poll and
        // videodatachange cover the gap).
        let riffReattachTimer = null;
        new MutationObserver(() => {
            if (riffReattachTimer !== null) return;
            riffReattachTimer = setTimeout(() => {
                riffReattachTimer = null;
                attachVideoListeners();
                // Also rebind playerApi listeners if the playerApi instance
                // changed (defensive — YT sometimes recreates the player on
                // certain navigations).
                const fresh = playerApi();
                if (fresh && !fresh.__riffSubscribed) {
                    subscribeToPlayerApi(fresh);
                }
            }, 500);
            // Narrowed target (energy): the <video> and playerApi live
            // under ytmusic-player, so observing that element's parent
            // catches a swapped/recreated player without recording
            // every mutation of this continuously-mutating SPA at the
            // document root. documentElement remains the fallback for
            // builds where only #movie_player exists (no
            // ytmusic-player element). If YT ever replaces the
            // observed ancestor itself, the safety poll's per-tick
            // re-attach backstop still catches the swap.
        }).observe(document.querySelector("ytmusic-player")?.parentElement || document.documentElement, { childList: true, subtree: true });
        // Handshake first, then ready — Swift installs the page's
        // protocol overrides before ready's queued-command flush.
        emitPageInfo();
        postEvent({ event: "ready" });
    }

    // ---- Fallback: legacy mediaSession + URL polling -----------------------
    //
    // Only used when the playerApi seam never materializes. Lower fidelity
    // but better than nothing.

    let fallbackTimerId = null;
    function startMediaSessionFallback() {
        if (fallbackTimerId) return;
        let fallbackKey = "";
        fallbackTimerId = setInterval(() => {
            const md = navigator.mediaSession && navigator.mediaSession.metadata;
            const url = new URL(location.href);
            const videoId = url.searchParams.get("v");
            if (!md || !videoId) return;
            const found = findPlaylistId();
            if (found) stickyPlaylistId = found;
            const key = videoId + "|" + (md.title || "") + "|" + (stickyPlaylistId || "");
            if (key === fallbackKey) return;
            fallbackKey = key;
            const artwork = (md.artwork && md.artwork.length > 0) ? md.artwork[md.artwork.length - 1].src : null;
            postEvent({
                event: "trackChanged",
                videoId: videoId,
                playlistId: stickyPlaylistId,
                title: md.title || "",
                artist: md.artist || "",
                artwork: artwork,
            });
        }, 500);
        // Also attach the <video> ended listener as best-effort EOT signal in
        // fallback mode (in case YT does fire it on some non-MSE contexts
        // like ads).
        const v = videoEl();
        if (v && !v.__riffFallbackAttached) {
            v.__riffFallbackAttached = true;
            v.addEventListener("ended", () => {
                postEvent({ event: "ended" });
                postEvent({ event: "stateChanged", isPlaying: false });
            });
        }
    }

    // ---- Crossfade (Tier 3 B8) --------------------------------------------
    //
    // Volume-only crossfade between consecutive tracks. The architectural
    // constraint we live under (single `<video>` element with MSE source-
    // swap; no two simultaneous audio sources) rules out a true overlap
    // crossfade in the Apple Music / AutoMix sense. What we ship instead:
    //
    //   - In the last N seconds of the current track, linearly ramp the
    //     "crossfade factor" 1.0 → 0.0. The factor multiplies the user's
    //     chosen volume in setVolume / applyVolume.
    //   - On the next `videodatachange` (the new track's source is live),
    //     wall-clock ramp the factor 0.0 → 1.0 over N seconds.
    //
    // Audible result: tail of track A fades out into head of track B
    // fading in. Both halves use the same N seconds. No DSP, no overlap,
    // no audio extraction — sits entirely inside the JS bridge.
    //
    // We never write to `<video>.volume` directly elsewhere — the user's
    // setVolume above and this module are the only writers. Sleep
    // timer's fade-out also writes via window.musicBridge.setVolume, so
    // it composes correctly too (the JS-side factor is independent of
    // the Swift-side user-volume cache).
    const xfade = {
        // User-chosen volume in [0, 1]. The Swift side calls setVolume
        // on launch + every user volume change, which keeps this in
        // sync. Initial 1.0 matches `<video>.volume`'s default.
        userVolume: 1.0,
        // Crossfade duration in seconds. 0 disables entirely.
        seconds: 0,
        // Multiplier in [0, 1]. Pinned at 1.0 outside an in-flight ramp.
        factor: 1.0,
        // True while the tail ramp is in flight on the current track.
        // Consumed by the next videodatachange to decide whether to
        // run the head ramp on the new track.
        tailFading: false,
        // Head-ramp interval id (setInterval); null when idle.
        headRampId: null,
        // Wall-clock millis at which the head ramp started; used to
        // compute the head-ramp factor without depending on the new
        // track's timeupdate cadence.
        headRampStart: 0,

        applyVolume() {
            const v = videoEl();
            if (!v) return;
            const level = Math.max(0, Math.min(1, this.userVolume * this.factor));
            v.volume = level;
        },

        // Called from the <video>.timeupdate handler. Reads currentTime
        // / duration off the element and updates `factor` if we're
        // inside the tail-fade window.
        onTimeUpdate(currentTime, duration) {
            const n = this.seconds;
            if (!n || !isFinite(duration) || duration <= 0) return;
            // Repeat-one: the browser loops the source without ever
            // firing `ended`, so a crossfade tail-ramp would dip
            // volume to silence at every loop boundary and snap back
            // to 1.0 on wrap. Skip the ramp entirely while looping;
            // also make sure factor is pinned at 1.0 so a factor left
            // over from a pre-loop tail-fade doesn't stick.
            const v = videoEl();
            if (v && v.loop) {
                if (this.tailFading || this.factor !== 1.0) {
                    this.tailFading = false;
                    this.factor = 1.0;
                    this.applyVolume();
                }
                return;
            }
            const remaining = duration - currentTime;
            // Tail window: when remaining < n, start ramping.
            // Guard against the early-seek case where currentTime
            // briefly reads near duration during a seek to end —
            // the YT auto-advance will fire shortly and reset.
            if (remaining < n && remaining >= 0) {
                this.tailFading = true;
                // Linear ramp: factor = remaining / n.
                // remaining = n → factor = 1.0
                // remaining = 0 → factor = 0.0
                this.factor = Math.max(0, Math.min(1, remaining / n));
                this.applyVolume();
            } else if (this.tailFading && remaining >= n) {
                // User scrubbed backwards out of the tail window —
                // restore full volume and clear the tail flag so we
                // don't run a head ramp on the next track change
                // we weren't really fading into.
                this.tailFading = false;
                this.factor = 1.0;
                this.applyVolume();
            }
        },

        // Called from videodatachange when a new videoId arrives.
        // If we were mid-tail-fade, start ramping the new track up
        // from current factor → 1.0 over `seconds`. If we weren't
        // fading (e.g. user pressed Next manually), snap to 1.0 so
        // the new track plays at full user-volume.
        onTrackChange() {
            if (!this.tailFading || this.seconds <= 0) {
                // No tail fade was in flight — make sure factor is
                // clean for the new track. Defends against the case
                // where a previous tail fade ended at factor=0 and
                // the track changed via a path that didn't go
                // through onTrackChange (defensive).
                this.cancelHeadRamp();
                this.factor = 1.0;
                this.applyVolume();
                return;
            }
            this.tailFading = false;
            this.startHeadRamp();
        },

        startHeadRamp() {
            this.cancelHeadRamp();
            const n = this.seconds;
            if (n <= 0) {
                this.factor = 1.0;
                this.applyVolume();
                return;
            }
            const startFactor = this.factor; // typically ~0 after tail
            this.headRampStart = Date.now();
            // 50ms tick — 20 Hz update is smooth without being
            // wasteful, matches what a CSS animation would do
            // visually. Auto-stops once elapsed >= n seconds.
            this.headRampId = setInterval(() => {
                const elapsedMs = Date.now() - this.headRampStart;
                const totalMs = this.seconds * 1000;
                const t = Math.min(1, elapsedMs / totalMs);
                // Linear ramp from startFactor → 1.0 over `seconds`.
                this.factor = startFactor + (1.0 - startFactor) * t;
                this.applyVolume();
                if (t >= 1) {
                    this.factor = 1.0;
                    this.applyVolume();
                    this.cancelHeadRamp();
                }
            }, 50);
        },

        cancelHeadRamp() {
            if (this.headRampId !== null) {
                clearInterval(this.headRampId);
                this.headRampId = null;
            }
        },
    };
    window.__riffXfade = xfade;

    // ---- Volume normalization (Web Audio RMS-based) ------------------------
    //
    // Routes the <video> element through a Web Audio graph so we can
    // (a) measure short-window RMS post-skip and (b) apply a per-track
    // gain to land near a fixed target. The native <video>.volume
    // attribute still works as the user-facing volume control — it
    // attenuates pre-graph; our GainNode scales post-graph; both
    // multiply.
    //
    // Target: -18 dBFS RMS. Approximation of -14 LUFS (the streaming
    // standard) without K-weighted filtering. Catches the loud-pop /
    // quiet-acoustic gap that's the user-visible failure mode.
    //
    // Measurement window: skip 500ms (fade-in), sample 5s, then apply.
    // Gain clamp: [0.4, 2.5] to avoid clipping or excessive boost.
    const norm = {
        ctx: null, sourceNode: null, gainNode: null, analyser: null, timeData: null,
        enabled: false, measuring: false, measureStart: 0, sumSquares: 0, sampleCount: 0,
        // Tick interval — only alive during the measurement window
        // (5.5s after a track change), otherwise null. Constant-rate
        // polling at 10Hz was the prior shape; idle 10Hz in WebKit on
        // a heavy SPA like music.youtube.com showed up as ambient hangs
        // on slow days. Now the timer literally doesn't exist outside
        // of measurement.
        tickIntervalId: null,

        init() {
            if (this.ctx) return;
            const v = videoEl();
            if (!v) return;
            try {
                const AC = window.AudioContext || window.webkitAudioContext;
                this.ctx = new AC();
                this.sourceNode = this.ctx.createMediaElementSource(v);
                this.gainNode = this.ctx.createGain();
                this.gainNode.gain.value = 1.0;
                this.analyser = this.ctx.createAnalyser();
                this.analyser.fftSize = 2048;
                this.timeData = new Uint8Array(this.analyser.fftSize);
                this.sourceNode.connect(this.analyser);
                this.analyser.connect(this.gainNode);
                this.gainNode.connect(this.ctx.destination);
            } catch (e) {
                postEvent({ event: "diagnostic", msg: "norm init failed: " + (e && e.message ? e.message : e) });
                this.ctx = null;
            }
        },

        setEnabled(on) {
            this.enabled = !!on;
            if (!on) {
                this.stopTickInterval();
                this.measuring = false;
                if (this.gainNode && this.ctx) {
                    this.gainNode.gain.setTargetAtTime(1.0, this.ctx.currentTime, 0.05);
                }
            }
        },

        startMeasuring() {
            if (!this.enabled || !this.ctx) return;
            if (this.ctx.state === "suspended") {
                this.ctx.resume().catch(() => {});
            }
            this.sumSquares = 0;
            this.sampleCount = 0;
            this.measuring = true;
            this.measureStart = this.ctx.currentTime;
            // Reset gain immediately on track change so a previous
            // loud-track boost doesn't bleed into a quiet track.
            if (this.gainNode) {
                this.gainNode.gain.setTargetAtTime(1.0, this.ctx.currentTime, 0.05);
            }
            this.startTickInterval();
        },

        startTickInterval() {
            if (this.tickIntervalId !== null) return;
            this.tickIntervalId = setInterval(() => norm.tick(), 100);
        },

        stopTickInterval() {
            if (this.tickIntervalId !== null) {
                clearInterval(this.tickIntervalId);
                this.tickIntervalId = null;
            }
        },

        tick() {
            if (!this.measuring || !this.analyser || !this.timeData) {
                // Defensive: if we somehow got here without active
                // measurement, kill the interval. Shouldn't happen,
                // but cheap to guard.
                this.stopTickInterval();
                return;
            }
            const skipMs = 500;
            const windowMs = 5000;
            const elapsedMs = (this.ctx.currentTime - this.measureStart) * 1000;
            if (elapsedMs < skipMs) return;
            if (elapsedMs > skipMs + windowMs) {
                this.apply();
                this.measuring = false;
                this.stopTickInterval();
                return;
            }
            this.analyser.getByteTimeDomainData(this.timeData);
            // Byte time-domain is 0..255 with 128 = silence. Map to -1..1.
            let sum = 0;
            for (let i = 0; i < this.timeData.length; i++) {
                const x = (this.timeData[i] - 128) / 128;
                sum += x * x;
            }
            this.sumSquares += sum;
            this.sampleCount += this.timeData.length;
        },

        apply() {
            if (!this.sampleCount || !this.gainNode || !this.ctx) return;
            const rms = Math.sqrt(this.sumSquares / this.sampleCount);
            if (rms < 1e-5) return;
            const measuredDb = 20 * Math.log10(rms);
            const targetDb = -18;
            let gain = Math.pow(10, (targetDb - measuredDb) / 20);
            gain = Math.max(0.4, Math.min(2.5, gain));
            this.gainNode.gain.setTargetAtTime(gain, this.ctx.currentTime, 0.3);
            postEvent({ event: "diagnostic", msg: "norm rms=" + rms.toFixed(4) + "dB=" + measuredDb.toFixed(1) + " gain=" + gain.toFixed(2) });
        },
    };
    window.__riffNorm = norm;

    // ---- Debug hooks ------------------------------------------------------
    // Manual probes for Safari Web Inspector (debug builds expose the
    // WebView there) and for the offline JS harness. Calling
    // emitQueueSnapshot() by hand forces a fresh mirror emit; the sig
    // dedup still applies, so clear window.__riffQueueSig first to
    // force a re-emit of unchanged state.
    window.__riffDebug = {
        emitQueueSnapshot: emitQueueSnapshot,
        resolveQueueSlice: resolveQueueSlice,
        emitPageInfo: emitPageInfo,
        subscribeQueueStore: subscribeQueueStore,
        startSafetyPoll: startSafetyPoll,
        stopSafetyPoll: stopSafetyPoll,
    };

    // ---- Kick off ---------------------------------------------------------

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", setup);
    } else {
        setup();
    }
})();
