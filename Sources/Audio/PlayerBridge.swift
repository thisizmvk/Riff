import Foundation
import Observation
import WebKit

/// Public playback API. SwiftUI views call methods here; this class translates
/// to JS evaluations on the hidden WKWebView, and observes the page's events
/// back into observable state.
@Observable
@MainActor
final class PlayerBridge {
    private(set) var isPlaying: Bool = false
    private(set) var elapsed: Double = 0   // seconds
    private(set) var duration: Double = 0  // seconds; 0 until the page reports it
    var progress: Double { duration > 0 ? elapsed / duration : 0 }
    private(set) var currentTrack: Track? = nil

    /// Owns Up Next + played-history. `let` because the manager itself
    /// is immutable; @Observable still tracks accesses to its own
    /// properties (queue.upNext / queue.playedHistory) so SwiftUI
    /// re-renders on mutation through the pass-throughs below.
    let queue = QueueManager()

    /// Pass-through accessors. Existing views read `env.player.upNext`
    /// and `env.player.playedHistory` — keeping the API stable while
    /// the actual storage moves to `QueueManager`.
    var upNext: [MediaItem] { queue.upNext }
    var playedHistory: [MediaItem] { queue.playedHistory }
    /// Timestamped played history. Consumed by the always-on Stats
    /// surface (B1) so its 7d / 30d / 90d filters can read play wall
    /// times directly. Legacy callers continue using `playedHistory`.
    var playedEntries: [PlayedEntry] { queue.playedEntries }

    private(set) var related: [MediaItem] = []
    /// Titled shelves YT shipped on the Related tab — "Other versions"
    /// (live / acoustic / cover variants of the current track),
    /// "Recommended tracks", "More from <Artist>", "You might also like".
    /// Populated alongside `related` on tab open. Empty when the watch
    /// context returned a flat song list with no carousels (some
    /// podcasts, explicit playlists).
    private(set) var relatedSections: [HomeSection] = []
    /// Tune chips parsed from the latest `/next` response (e.g. All,
    /// Familiar, Discover, Popular, Telugu, 2010s, …). Empty when YT
    /// didn't include a chip cloud for the current watch context.
    private(set) var availableChips: [InnerTubeClient.QueueChip] = []
    /// Id of the chip currently driving `upNext`. nil before the first
    /// `/next` lands or when the user hasn't selected one explicitly —
    /// in which case we treat the YT-marked `isSelected` chip as the
    /// active one for highlighting purposes.
    private(set) var selectedChipId: String? = nil
    private(set) var lyrics: String? = nil
    private(set) var lyricsLines: [InnerTubeClient.LyricLine] = []
    private(set) var lyricsTimed: Bool = false
    private(set) var lyricsLoading: Bool = false
    /// Terminal "YT has no lyrics for this track": the fetch completed
    /// and the server returned none. Distinct from a transient failure
    /// (offline blip, cancelled request), which leaves everything nil
    /// so reopening the tab retries. The UI renders its own empty
    /// state; the copy is never stored in `lyrics` — a sentinel string
    /// there leaked into the toolbar gates, the translation / X-Ray
    /// prompts and the lyric-card seed as if it were real lyric text.
    private(set) var lyricsUnavailable: Bool = false
    private(set) var liked: Bool = false
    /// Whether the full-screen Now Playing view is presented.
    var isFullPlayerOpen: Bool = false
    var hasTrack: Bool { currentTrack != nil }

    /// Cached browse IDs from /next response — used to lazy-load lyrics
    /// and related songs only when the user opens those tabs.
    @ObservationIgnored private var lyricsBrowseId: String?
    @ObservationIgnored private var relatedBrowseId: String?
    /// Playlist ID extracted from the current /watch URL. Required to fetch
    /// the right Up Next queue when playing inside a playlist (without it,
    /// /next returns radio-style suggestions instead of the playlist's tracks).
    @ObservationIgnored private var currentPlaylistId: String?
    /// True when the current playback context is an auto-generated radio
    /// (no deterministic playlist — either no `list=` at all or a radio
    /// prefix like `RDAMVM…`/`RD…`). Radio queues are non-deterministic:
    /// the WebView plays its OWN radio, which an independent `/next` call
    /// cannot reproduce (ytmusicapi: "get a radio playlist (changes each
    /// time)"). So for radio we do NOT display a separately-fetched queue
    /// that wouldn't match what actually plays — the UI shows an autoplay
    /// hint instead. Deterministic contexts (albums, user playlists) DO
    /// match and keep their real queue. Reads an ObservationIgnored field,
    /// so views should re-read it alongside an observed one (e.g. upNext),
    /// which is exactly how the queue panel consumes it.
    var isRadioContext: Bool {
        guard let plid = currentPlaylistId, !plid.isEmpty else { return true }
        return plid.hasPrefix("RD")
    }
    /// True when the PAGE is the queue's source of truth: plain radio
    /// with no Tune chip active. Here Riff mirrors the page's own queue
    /// (Phase 2), never arms forced navigation, and skips WYSIWYG
    /// enforcement (the mirror lags the page by up to a poll tick).
    /// A chip-tuned queue is Riff-curated — the page knows nothing
    /// about it — so chips keep the enforce-by-navigation model.
    var isPageDrivenContext: Bool { isRadioContext && activeChip == nil }
    /// The chip the user last picked from the tune-chip popover, or nil
    /// when no chip is active. Threaded into every `/next` fetch inside
    /// the current watch context so autoplaying past track 1 doesn't
    /// silently drop the chip and revert to generic radio. Cleared
    /// only on a fresh watch context (play(item:, clearQueue: true))
    /// — chip changes are per-watch, not per-track.
    @ObservationIgnored private var activeChip: InnerTubeClient.QueueChip?

    /// In-flight `/next` refresh, if any. Held so we can cancel-and-replace
    /// when the user clicks rapidly through tracks — without this, multiple
    /// concurrent `/next` requests race and the last-to-complete wins,
    /// which may not be the most-recent click.
    @ObservationIgnored private var nextQueueTask: Task<Void, Never>?
    /// In-flight per-track METADATA fetch (like state + lyrics/related
    /// browse ids) — deliberately separate from `nextQueueTask` so it
    /// can never cancel an in-flight QUEUE refresh (a play(item:) seed
    /// or the autoplay auto-extension). See `refreshTrackMetadata`.
    @ObservationIgnored private var trackMetadataTask: Task<Void, Never>?
    /// In-flight lyrics / related fetches. Held so a track change can
    /// cancel them — their completions also identity-check against the
    /// browse id, so a slow response for track A can never land on
    /// track B's tabs (or feed B's Smart Shuffle pool).
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var relatedTask: Task<Void, Never>?

    /// Fires after any state change (track, play/pause, progress). Used by
    /// AppEnvironment to drive NowPlayingCenter without coupling the two
    /// classes directly. @ObservationIgnored: this is plumbing, not state.
    @ObservationIgnored
    var onUpdate: (() -> Void)?

    /// Closure that returns true when a given (artistId, item) should
    /// be filtered out of recommendations. Set by AppEnvironment
    /// (which owns the block-list) post-init. Defaults to "block
    /// nothing" so unit tests don't need to wire it. Called from the
    /// queue assignment + related-songs assignment paths.
    @ObservationIgnored
    var shouldBlock: (MediaItem) -> Bool = { _ in false }
    /// Invoked when a tapped Up Next row could not be played in place
    /// (page-queue jump didn't take). AppEnvironment shows a toast.
    var onJumpFailed: ((MediaItem) -> Void)? = nil
    /// The page refused to remove a queue row (both the store dispatch
    /// and the row menu failed). The row is put back on screen; the UI
    /// tells the user.
    var onRemoveFailed: ((String) -> Void)? = nil

    // NOTE: The old `userQueuedIds` set was replaced by
    // `QueueManager.userQueueCount` — a positional region at the
    // head of upNext instead of an unordered priority set. That
    // means the head of `upNext` is always the true "next track" —
    // no more walking the array looking for a user-queued match.
    // See QueueManager for the two-region model.

    /// Mirror of `window.__riffPendingNextUrl` — true whenever
    /// `syncPendingNextURL` pushed a non-empty URL. The JS-side
    /// onStateChange==0 handler consumes that URL and navigates
    /// synchronously on end-of-track; Swift's own `.ended` handler
    /// used to fire `advanceToUserQueuedIfAny` unconditionally, which
    /// then navigated to the same head 50-150ms later — the second
    /// navigate cut the first one off and the user saw "song started
    /// then jumped to another song." Gated on this flag, Swift only
    /// runs the fallback when JS had nothing armed to navigate with.
    @ObservationIgnored
    private var pendingNextURLArmed: Bool = false

    @ObservationIgnored
    private let innerTube: InnerTubeClient

    @ObservationIgnored
    private let webBridge: HiddenPlayerWebView

    /// `window.musicBridge` doesn't exist until the JS user script has run.
    /// Eval calls before the bridge fires `ready` get queued; we flush on
    /// the first `ready` event. Without this, the very first click after
    /// app launch races against the initial music.youtube.com load and
    /// silently no-ops.
    @ObservationIgnored
    private var bridgeReady: Bool = false
    @ObservationIgnored
    private var pendingCommands: [String] = []

    /// Generation id of the last `pageInfo` handshake we logged. The
    /// page posts one handshake per document with a fresh random id;
    /// deduping on it keeps the .notice line at once-per-page even if
    /// the JS ever re-emits (the override refresh itself is idempotent
    /// and runs on every arrival).
    @ObservationIgnored
    private var lastPageInfoGeneration: String? = nil

    init(innerTube: InnerTubeClient) {
        self.innerTube = innerTube
        // Restore playback prefs from prior launch.
        let storedVolume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double
        self.volume = storedVolume ?? 1.0
        // One-time migration: the old single `player.rate` key (set
        // by pre-Tier-2-#9 builds) becomes the music-kind default.
        if let legacy = UserDefaults.standard.object(forKey: Self.legacyRateKey) as? Double,
           UserDefaults.standard.object(forKey: Self.rateKey(for: .music)) == nil {
            UserDefaults.standard.set(legacy, forKey: Self.rateKey(for: .music))
            UserDefaults.standard.removeObject(forKey: Self.legacyRateKey)
        }
        // Initial kind is .music (nothing playing yet); rate follows.
        self.playbackRate = Self.storedRate(for: .music)
        if let raw = UserDefaults.standard.string(forKey: Self.repeatKey),
           let mode = RepeatMode(rawValue: raw) {
            self.repeatMode = mode
        }
        self.shuffleEnabled = UserDefaults.standard.bool(forKey: Self.shuffleKey)
        self.smartShuffleEnabled = UserDefaults.standard.bool(forKey: Self.smartShuffleKey)
        self.normalizationEnabled = UserDefaults.standard.bool(forKey: Self.normalizationKey)
        // Autoplay defaults ON (endless similar music at queue end),
        // matching Spotify/Apple Music. `object(forKey:)` so a
        // first-launch absence stays true instead of a bool default
        // of false.
        if let stored = UserDefaults.standard.object(forKey: Self.autoplayKey) as? Bool {
            self.autoplayEnabled = stored
        }
        // Crossfade between tracks (Tier 3 B8). Persisted as Double
        // seconds; absent default ⇒ off. `object(forKey:)` so first-
        // launch absence stays a clean 0 (no key write yet) rather than
        // forcing 0 into UserDefaults at every init.
        if let raw = UserDefaults.standard.object(forKey: Self.crossfadeKey) as? Double {
            self.crossfadeSeconds = Self.clampCrossfade(raw)
        }
        // Eager init: start loading music.youtube.com offscreen at app start,
        // so by the time the user clicks anything the page is loaded.
        self.webBridge = HiddenPlayerWebView()
        self.webBridge.onEvent = { [weak self] event in self?.handle(event) }
        // QueueManager loads its own persisted history; nothing to do
        // here besides depending on the `let queue = QueueManager()`
        // initializer that already ran.
        // Restore "what was playing" so the mini bar isn't empty on
        // launch. Doesn't auto-play — the WebView won't navigate
        // until the user presses play.
        restoreLastSession()
    }

    private static let volumeKey = "player.volume"
    /// Legacy single-rate UserDefaults key. Migrated to the new
    /// per-kind `player.rate.music` / `player.rate.spoken` keys on
    /// first launch; see init.
    private static let legacyRateKey = "player.rate"
    private static let repeatKey = "player.repeat"
    private static let shuffleKey = "player.shuffle"
    private static let smartShuffleKey = "player.smartShuffle"
    private static let normalizationKey = "player.normalizationEnabled"
    private static let autoplayKey = "player.autoplayEnabled"
    private static let crossfadeKey = "player.crossfadeSeconds"
    private static let lastSessionKey = "player.lastSession"

    /// Snapshot of "what was playing when the user quit" — mirrors YT
    /// Music's behavior of showing your last-played track on the mini
    /// bar at app launch. Press play to resume from the saved position.
    /// Not auto-resumed: launching the app shouldn't blast audio at
    /// you; the user has to opt in by pressing play.
    private struct LastSession: Codable {
        let videoId: String
        let title: String
        let subtitle: String
        let thumbnailURL: URL?
        let albumId: String?
        let artistId: String?
        let elapsed: Double
        let duration: Double
        let savedAt: Date
    }

    /// (videoId, elapsed, duration) pending playback. Set during init
    /// when a LastSession was restored; consumed by the next
    /// user-initiated play action (`togglePlay` checks for it first).
    /// nil otherwise. `duration` is the snapshot's saved duration —
    /// used by the resume SEEK to verify the loaded media is the
    /// saved track and not a pre-roll ad (durations must match).
    @ObservationIgnored
    private var pendingResume: (videoId: String, elapsed: Double, duration: Double)? = nil

    /// Armed by togglePlay's resume path AFTER the navigation is
    /// issued; consumed by the first `.progress` event whose duration
    /// matches the saved snapshot. Event-driven replacement for the
    /// old fixed 1.5 s sleep-then-seek, which skipped the seek on a
    /// cold WebView / slow network (the 40-minute podcast restarted
    /// from 0) and could race YT's own initial seek on a fast one.
    /// Cleared by `navigate()` (any supervening navigation) and
    /// `play(item:)` (explicit click supersedes the resume).
    @ObservationIgnored
    private var pendingResumeSeek: (videoId: String, elapsed: Double, duration: Double)? = nil

    /// Persist a snapshot of the currently-playing track. Called on
    /// every progress event (rate-limited via `lastSnapshotAt`) and on
    /// app exit. UserDefaults write is atomic so a crash mid-write
    /// can't corrupt the snapshot.
    @ObservationIgnored private var lastSnapshotAt: Date = .distantPast
    private static let snapshotEverySeconds: TimeInterval = 5

    private func snapshotSessionIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastSnapshotAt) >= Self.snapshotEverySeconds else { return }
        snapshotSession()
    }

    /// Force a snapshot — used on app exit and on every track change
    /// regardless of the snapshot rate-limit.
    func snapshotSession() {
        guard let track = currentTrack else { return }
        lastSnapshotAt = Date()
        let snap = LastSession(
            videoId: track.videoId,
            title: track.title,
            subtitle: track.subtitle,
            thumbnailURL: track.thumbnailURL,
            albumId: track.albumId,
            artistId: track.artistId,
            elapsed: elapsed,
            duration: duration,
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.lastSessionKey)
        }
    }

    private func restoreLastSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastSessionKey),
              let snap = try? JSONDecoder().decode(LastSession.self, from: data) else {
            return
        }
        // Don't restore if the session is older than 7 days — at that
        // point the user has likely moved on, and showing a stale
        // mini-bar on launch is more confusing than helpful.
        if Date().timeIntervalSince(snap.savedAt) > 7 * 24 * 60 * 60 { return }
        currentTrack = Track(
            videoId: snap.videoId,
            title: snap.title,
            subtitle: snap.subtitle,
            thumbnailURL: snap.thumbnailURL,
            duration: snap.duration,
            albumId: snap.albumId,
            artistId: snap.artistId
        )
        elapsed = snap.elapsed
        duration = snap.duration
        // Stash the resume target — consumed by the first user play.
        if snap.elapsed > 1 {
            pendingResume = (videoId: snap.videoId, elapsed: snap.elapsed, duration: snap.duration)
        }
    }

    /// Repeat modes. `.off` is YT Music's natural autoplay; `.one`
    /// loops the current `<video>` source via the browser's native
    /// loop attribute. Repeat-all isn't shipped yet — it would
    /// require intercepting end-of-queue and racing the page's
    /// autoplay, which is fragile. Track for v1.1.
    enum RepeatMode: String, Sendable {
        case off, all, one
    }
    private(set) var repeatMode: RepeatMode = .off
    /// Index into `queue.playedEntries` marking where the CURRENT
    /// listening context began (set on every fresh-context play).
    /// Repeat All uses the entries from here forward as the cycle:
    /// when the queue drains at end-of-track, everything played in
    /// this context (plus the finishing track) is re-queued in order.
    /// `archiveCurrent` shifts it down whenever the history cap trims
    /// entries off the front, so it keeps naming the same entry.
    @ObservationIgnored private var contextStartHistoryIndex: Int = 0
    /// The track ids belonging to the current deterministic context
    /// (album / playTracks list), plus its playlist id. Used by the
    /// advance logic: a queued head that belongs to this context should
    /// play IN the context (page-native advance, or a `list=<context>`
    /// navigation to restore it) — NOT via a per-track RDAMVM radio URL.
    /// Per-track radio navigation was re-seeding a fresh page radio on
    /// every album track: the mirror then painted that radio's rows
    /// under the album ("queue changes dynamically") and at album end
    /// the page radio took over ("returns to a new radio").
    @ObservationIgnored private var contextTracksIds: Set<String> = []
    @ObservationIgnored private var contextPlaylistId: String? = nil
    /// False when the context list was handed to us in a non-page order
    /// (shuffled album): the page's native next would be wrong, so
    /// context heads navigate explicitly. See QueuePolicy.
    @ObservationIgnored private var contextIsPageOrdered: Bool = true
    /// Phase C (docs/QUEUE-DESIGN.md): true once a queueSnapshot from
    /// the CURRENT page has been applied. While fresh, the mirror owns
    /// the server region in every non-chip context and /next refreshes
    /// are metadata-only; a navigation resets it so the /next fetch can
    /// seed the initial rows before the new page's first snapshot.
    @ObservationIgnored private var mirrorFresh: Bool = false
    /// Ids whose page-queue add VERIFIED (Phase B): the page owns them
    /// now, so their arrival is expected even though they left Riff's
    /// user region — WYSIWYG enforcement must not snap them away.
    /// Consumed on arrival; cleared on navigation (new page, new queue).
    @ObservationIgnored private var pageOwnedQueuedIds: Set<String> = []
    /// The row the user just tapped (page-queue jump). Its arrival is a
    /// deliberate jump, not divergence — the audit line labels it so.
    @ObservationIgnored private var pendingJumpTarget: String? = nil
    /// In-flight row-tap verification: the 2.5 s "did the page jump?"
    /// timer armed by `skipTo`. Stored (mirroring `nextQueueTask`) so
    /// the matching arrival or a supervening navigation can cancel it
    /// — an untracked timer raised a false "couldn't play" toast when
    /// the user tapped a row and then clicked elsewhere within 2.5 s.
    @ObservationIgnored private var jumpVerifyTask: Task<Void, Never>? = nil
    /// Wall-clock deadline for pause enforcement. After a sleep-timer
    /// end-of-track or an autoplay-off end-of-queue pause, the page can
    /// still natively start the next track; any `stateChanged(playing)`
    /// before this deadline is force-paused. Cleared by every DELIBERATE
    /// user transport so the user can always override: togglePlay,
    /// play(item:) with clearQueue (click-to-play / start radio),
    /// next(), previous(), skipTo(item:) (row tap), playTracks, and
    /// beginNavigatedContext (playlist / album / artist-radio play).
    /// Never by the automatic paths: the trackChanged enforcement snap
    /// and the `.ended` fallback call play(item:, clearQueue: false),
    /// and clearing there would let the page's native advance play
    /// straight through a sleep-timer stop.
    @ObservationIgnored private var pauseEnforceUntil: Date = .distantPast
    private(set) var shuffleEnabled: Bool = false
    /// B5 Smart Shuffle. When ON *together with* `shuffleEnabled`, the
    /// visible Up Next gets interleaved with /related recommendations
    /// (one every `SmartShuffle.defaultEvery` slots), each tagged in
    /// `smartShuffleInjectedIds` so the QueueRow can render a "+"
    /// badge. Independent of regular shuffle by spec — but only takes
    /// effect when shuffle is on, mirroring Spotify's gating. The
    /// toggle preference is persisted independently so a user who
    /// flips shuffle off + back on keeps their smart-shuffle choice.
    private(set) var smartShuffleEnabled: Bool = false
    /// VideoIds of upNext rows that were injected by Smart Shuffle. A
    /// `Set` (rather than a property on `MediaItem`) so toggling smart
    /// shuffle off can strip injections without rebuilding every item
    /// in the queue. Resets on every track change + every queue
    /// replacement so a stale injection from a previous radio context
    /// can't carry forward.
    private(set) var smartShuffleInjectedIds: Set<String> = []

    /// Cycle through repeat modes: off → all → one → off (the order
    /// every mainstream player uses). `.one` maps to <video>.loop in
    /// JS; `.all` is Swift-side — see the queue-drain hook in `.ended`.
    func toggleRepeat() async {
        let next: RepeatMode
        switch repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        repeatMode = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.repeatKey)
        // An armed end-of-track sleep timer lifted the loop so the track
        // can end; don't re-arm it under the timer (clearSleepTimerState
        // restores it once the timer is done or cancelled).
        let loop = next == .one && !endOfTrackArmed
        await eval("window.musicBridge.setRepeatLoop(\(loop ? "true" : "false"))")
    }

    /// Toggle shuffle. Affects only what `next()` does — see the
    /// implementation note there. We don't permute `upNext` itself
    /// because the row order on screen is part of the user's mental
    /// model ("I see this is coming up next"); shuffling it would
    /// confuse more than help.
    func toggleShuffle() {
        shuffleEnabled.toggle()
        UserDefaults.standard.set(shuffleEnabled, forKey: Self.shuffleKey)
        // Page-driven contexts delegate to the PAGE's shuffle: it
        // permutes the queue we mirror, so the shown order stays the
        // play order. The next snapshot re-syncs our flag from the
        // page (authoritative), correcting an optimistic flip if the
        // control wasn't found.
        if isPageDrivenContext {
            Task { [weak self] in await self?.eval("window.musicBridge.toggleShuffle()") }
        }
        // Flipping shuffle changes whether Smart Shuffle is "active".
        // Re-run the merge so the queue picks up (or sheds) injections
        // immediately rather than waiting for the next /next response.
        applySmartShuffleToCurrentQueue()
    }

    /// Toggle Smart Shuffle. Separate from regular shuffle by B5 spec
    /// — a user can have Smart Shuffle armed without it actually
    /// running (the injection only fires when shuffle is also on).
    /// Triggering with shuffle ON immediately re-merges the queue;
    /// triggering with shuffle OFF just flips the preference for next
    /// time shuffle goes on. Also kicks off a /related fetch if we
    /// have a browseId but haven't loaded recommendations yet — the
    /// Related tab is the lazy path, but Smart Shuffle needs the data
    /// proactively.
    func toggleSmartShuffle() {
        smartShuffleEnabled.toggle()
        UserDefaults.standard.set(smartShuffleEnabled, forKey: Self.smartShuffleKey)
        if smartShuffleEnabled {
            loadRelatedIfNeeded()
        }
        applySmartShuffleToCurrentQueue()
    }

    /// Re-merge the visible upNext with the Smart Shuffle pool. Called
    /// on every event that could change the merge inputs: shuffle /
    /// smart-shuffle toggle, /next response landed, /related response
    /// landed. Idempotent — repeatedly calling with the same inputs
    /// produces the same output.
    ///
    /// When either gating flag is off (or there's nothing to inject)
    /// this strips any previously-injected ids out of upNext so the
    /// view returns to a clean base queue. That's how the toggle-off
    /// path "undoes" smart shuffle without forcing a /next refresh.
    func applySmartShuffleToCurrentQueue() {
        let injectedNow = smartShuffleInjectedIds
        // Operate ONLY on the server region — the user region (Play
        // Next / Add to Queue / album chain) is never reshuffled and
        // never has injections spliced in. Using replaceQueue here
        // (as an earlier version did) wiped `userQueueCount` and
        // demoted every user-queued item to server region, making
        // them vulnerable to the next /next refresh dropping them.
        let serverStart = queue.userQueueCount
        let currentServer = Array(queue.upNext.dropFirst(serverStart))
        let baseServer = currentServer.filter { !injectedNow.contains($0.id) }
        // Page-driven radio: the server region mirrors the page's own
        // queue, and enforcement/pending-URL are deliberately off — an
        // injected row would be DISPLAYED as next but the page plays its
        // own row (WYSIWYG violation), then the next snapshot silently
        // strips the injection. Smart Shuffle only makes sense where
        // Riff controls the advance (albums/playlists/chip queues).
        guard !isPageDrivenContext else {
            if !injectedNow.isEmpty {
                queue.replaceServerRegion(baseServer)
                smartShuffleInjectedIds = []
            }
            return
        }
        guard smartShuffleEnabled, shuffleEnabled, !related.isEmpty, !baseServer.isEmpty else {
            if !injectedNow.isEmpty {
                queue.replaceServerRegion(baseServer)
                smartShuffleInjectedIds = []
            }
            return
        }
        // Nothing in the base server region is a currentTrack (the
        // playing track is either currentTrack itself or was
        // already popped via consumeHead). No further protection
        // needed — SmartShuffle.merge just needs the base list and
        // the pool.
        let result = SmartShuffle.merge(
            base: baseServer,
            pool: related,
            every: SmartShuffle.defaultEvery,
            protectedIds: []
        )
        // No-op short-circuit so we don't churn the observable
        // upNext when the merge result matches what's already
        // shown — keeps SwiftUI from over-redrawing on every toggle.
        if result.merged.map(\.id) == currentServer.map(\.id),
           result.injectedIds == injectedNow {
            return
        }
        queue.replaceServerRegion(result.merged)
        smartShuffleInjectedIds = result.injectedIds
    }

    struct Track: Hashable {
        let videoId: String
        let title: String
        let subtitle: String
        let thumbnailURL: URL?
        let duration: Double
        /// Album browseId, when known. Drives "Go to album" from the
        /// now-playing menu. Sourced from the MediaItem the user clicked,
        /// or backfilled from the `/next` queue row that matches videoId.
        var albumId: String? = nil
        /// Artist browseId, when known. Drives "Go to artist".
        var artistId: String? = nil
    }

    // MARK: - Commands

    /// YT Music's auto-radio playlist prefix. Tacked onto the watch URL
    /// when a song is played with no other playlist context — the browser
    /// does the same: clicking a single tile navigates to
    /// `?v=<id>&list=RDAMVM<id>`, which triggers a server-generated radio
    /// queue (25-50 related tracks that auto-extends). Without it, /next
    /// returns just the current track and Up Next sits empty.
    private static func radioPlaylistId(for videoId: String) -> String {
        "RDAMVM" + videoId
    }

    /// Navigate the WebView to a watch URL for `videoId`.
    ///
    /// - parameter explicitPlaylistId: when non-nil, use this in the
    ///   `?list=` query — typical for preserving an in-flight
    ///   playlist (`PLxyz`) when advancing within it. When nil,
    ///   defaults to per-track auto-radio (`RDAMVM<videoId>`).
    ///
    /// Does NOT touch `currentPlaylistId`. The caller (`play(item:)`)
    /// is responsible for setting that when a context reset is
    /// intended — otherwise mid-playlist skips would clobber the
    /// context to per-track radio and future refetches would fall
    /// out of the playlist. (C2)
    func play(videoId: String, explicitPlaylistId: String? = nil) async {
        // Consumed by togglePlay's resume path; a fresh explicit play
        // supersedes any lingering last-session resume target.
        pendingResume = nil
        let list = explicitPlaylistId ?? Self.radioPlaylistId(for: videoId)
        await navigate(watchURL(videoId: videoId, playlistId: list))
    }

    /// For callers that reach `play(videoId:)` directly on a deliberate
    /// user action (opening a YT Music link). play(videoId:) itself can't
    /// do this — it is also the tail of the automatic play(item:,
    /// clearQueue: false) snaps. Arms the click grace and lifts the
    /// pause-enforcement window, like every other user transport.
    func noteUserTransportIntent() {
        userClickedAt = Date()
        pauseEnforceUntil = .distantPast
    }

    /// Click-to-play with an item we already have full metadata for (search
    /// rows, home carousels, library lists). Pre-populates `currentTrack`
    /// so the mini-bar shows the right title/artist/artwork *immediately*,
    /// before the WebView even starts loading. Without this, anonymous YT
    /// Music plays 2-3 video ads first and the mini-bar flickers through
    /// each ad's metadata before settling on the real song.
    /// Play `item` as the new current track.
    ///
    /// - parameter clearQueue: when `true` (default — for all the
    ///   "external entry point" call sites like clicking a song row),
    ///   resets upNext to just the preserved user-queued items so the
    ///   refresh can populate a fresh radio around `item`. When
    ///   `false`, the visible upNext is left intact (the just-played
    ///   track will fall off via refreshNextQueueAndIds' "surviving"
    ///   filter). Used by skip-from-queue / autoplay-from-queue paths
    ///   where the user expects the existing list to stay stable.
    func play(item: MediaItem, clearQueue: Bool = true) async {
        // Attribution line: every play() is a page NAVIGATION (reload).
        // In a log capture, a reload-per-advance pattern traces back to
        // whoever called this — pair with the "ready" events.
        Audit.note("play(item:) id=\(item.id) clearQueue=\(clearQueue)")
        // A fresh-context play is a deliberate user click (every UI
        // entry point uses the default clearQueue: true): the song they
        // just chose must not be force-paused by a sleep-timer /
        // autoplay-off stop window. clearQueue: false is ALSO the
        // automatic enforcement snap and the .ended fallback, which must
        // keep the window — user callers of that form (next, skipTo,
        // playTracks) lift it themselves.
        if clearQueue {
            pauseEnforceUntil = .distantPast
        }
        // Archive the outgoing track before we overwrite `currentTrack`.
        // Without this, an explicit click (search row, home carousel,
        // Up Next row) never reaches the archive branch in
        // handle(trackChanged:) — that branch only fires on the
        // "new videoId" path, and the click has already reassigned
        // currentTrack to the new item by the time trackChanged
        // arrives with sameVideoId=true. QueueManager.archive dedups
        // against tail, so a same-song reclick is a no-op.
        if let existing = currentTrack, existing.videoId != item.id {
            archiveCurrent()
        }
        // Fresh watch context → new Repeat All cycle boundary. Marked
        // AFTER archiving the outgoing track so the old track belongs
        // to the OLD context's cycle. Single-song play = a radio
        // context with no deterministic tracklist.
        if clearQueue {
            contextStartHistoryIndex = queue.playedEntries.count
            contextTracksIds = [item.id]
            contextPlaylistId = nil
            contextIsPageOrdered = true
        } else {
            // A track that is about to play is never an upcoming row.
            // currentTrack is set optimistically below, so the real
            // arrival is `sameVideoId` and the consume path skips it —
            // a force-played Play-Next row stayed in the user region as
            // a ghost and was played AGAIN when the page moved on
            // (field 2026-09-10, "the previous song repeats").
            queue.remove(videoId: item.id)
        }
        // A pending resume from restoreLastSession only applies to the
        // very first play. An explicit click of a different song
        // supersedes it — clear so the next togglePlay doesn't yank
        // the WebView back to the old track. Same for an armed resume
        // SEEK (also cleared in navigate(); repeated here so the
        // supersede rule is visible at the click entry point).
        pendingResume = nil
        pendingResumeSeek = nil
        currentTrack = Track(
            videoId: item.id,
            title: item.title,
            subtitle: item.subtitle,
            thumbnailURL: item.thumbnailURL,
            duration: 0,
            albumId: item.albumId,
            artistId: item.artistId
        )
        // Switch playback kind + rate before navigation so the
        // setPlaybackRate JS call lands as soon as the bridge is ready.
        await applyRate(for: PlaybackKind.from(item.kind))
        // Reset & pre-fetch surrounding context (queue + lyrics/related ids).
        // Use the auto-radio playlist (RDAMVM<videoId>) so /next returns a
        // proper YT-Music-style radio queue instead of just the current
        // track. play(videoId:) below sets currentPlaylistId; we mirror it
        // here so the queue refresh has the right context immediately.
        //
        // BUG-1 fix: a wholesale `queue.clearQueue()` here would drop
        // any user-queued items (Play next / Add to queue) the user
        // had pending against the *previous* track. Filter the clear
        // so user-tagged items survive into refreshNextQueueAndIds,
        // where they get merged into the head of the fresh /next
        // response. The just-promoted track itself is excluded — it
        // already became currentTrack, no need to leave a duplicate
        // in upNext.
        //
        // When clearQueue=false (skip-from-queue / autoplay-of-head),
        // we skip the queue reset entirely — refreshNextQueueAndIds'
        // own "surviving" filter pops the just-played head and the
        // tail-extension logic keeps the rest stable.
        if clearQueue {
            // Fresh watch context — wipe both regions of the queue.
            // The old implementation cherry-picked user-queued items
            // to survive, but in the two-region model those items
            // are already the responsibility of the CALLER (e.g.
            // playTracks explicitly re-seeds them for album chain
            // play; playNext / addToQueueEnd never call play with
            // clearQueue=true). Preserving them here would only
            // create phantom rows from previous sessions.
            queue.replaceQueue([])
            // Tune chips are per-watch-context. Clear them so the popover
            // doesn't briefly show the previous track's chips while the new
            // /next is in flight, and drop any active chip selection so
            // the fresh /next fetch isn't scoped by a chip from the
            // previous context.
            availableChips = []
            selectedChipId = nil
            activeChip = nil
        }
        // Per-track state is UNKNOWN until fresh metadata lands. The
        // heart must not carry the previous track's like state — a
        // click in that stale window inverts the user's intent (it
        // sends removeLike for a track that isn't liked). And the
        // lyrics/related BROWSE IDS must reset along with the content:
        // with the old id left in place, a tab open across the change
        // would fetch (or keep showing) the PREVIOUS track's lyrics
        // under the new track. refreshTrackMetadata / the /next
        // refresh below repopulate all of it, identity-checked.
        liked = false
        resetPerTrackTabState()
        // Chip clear used to also live here, unconditionally — which
        // dropped the active chip on every `next()` / autoplay
        // (clearQueue=false), so chips were effectively single-track.
        // The clear now only fires inside the `if clearQueue` branch
        // above (fresh watch context). Continuation calls preserve
        // the chip via `activeChip`, which refreshNextQueueAndIds
        // threads into the next `/next` fetch.
        // Reset progress so the scrubber starts at 0 instead of carrying
        // over the previous track's elapsed/duration. The JS bridge will
        // populate fresh values once the new media loads.
        elapsed = 0
        duration = 0
        lastTrackChangeAt = Date()
        userClickedAt = Date()
        // Only seed a fresh /next queue when the caller signaled a
        // FRESH watch context (`clearQueue: true`). YT Music's
        // model: `/next` fires ONCE when you start a mix and
        // returns the whole queue; subsequent tracks just consume
        // through it. Riff used to re-hit /next on every
        // trackChanged and every jump-to-row, which replaced the
        // server region N times through a mix and made the queue
        // "change constantly" for the user. Now:
        //   - clearQueue: true  → fresh context, fetch new queue
        //     around item.id
        //   - clearQueue: false → jump-within-context; the
        //     existing user + server regions stay intact and
        //     playback just skips to `item`.
        // C2: only overwrite `currentPlaylistId` on a FRESH watch
        // context. Skip-within-context (clearQueue=false) preserves
        // whatever playlist we were already in — otherwise mid-playlist
        // skips would clobber to per-track radio and later refetches
        // would drift out of the playlist.
        let radio = Self.radioPlaylistId(for: item.id)
        if clearQueue {
            currentPlaylistId = radio
            refreshNextQueueAndIds(forVideoId: item.id, playlistId: radio)
        } else {
            // No /next fires on this path, and the follow-up
            // trackChanged is same-videoId (currentTrack was just set
            // optimistically above) so the new-track branch won't
            // fetch either. Without this, the like state and lyrics /
            // related keys reset above would stay empty for the whole
            // track. Metadata only — the queue regions stay untouched.
            refreshTrackMetadata(forVideoId: item.id, playlistId: currentPlaylistId)
        }
        onUpdate?()
        // Thread the effective playlist context to the JS bridge so
        // YT autoplay stays inside the playlist when advancing.
        // Never navigate an OFF-context track into a deterministic list:
        // `?v=X&list=<album>` with X outside the album makes YouTube
        // restart the album from track 1 ("album repeated"). Known
        // context tracks keep their list; anything else gets its own
        // radio.
        let offContext = !clearQueue
            && !contextTracksIds.isEmpty && !contextTracksIds.contains(item.id)
            && !(currentPlaylistId ?? "").hasPrefix("RD")
        let effectiveList = clearQueue || offContext ? radio : (currentPlaylistId ?? radio)
        await play(videoId: item.id, explicitPlaylistId: effectiveList)
    }

    /// Last time `play(item:)` ran. Used to gate when we accept JS-side
    /// metadata updates for the *same* videoId — within `userClickGraceSeconds`
    /// we ignore them (catches pre-roll ads), after that window we trust
    /// them (catches autoplay advances where the URL videoId stays put).
    @ObservationIgnored private var userClickedAt: Date = .distantPast
    private static let userClickGraceSeconds: TimeInterval = 30
    private static let historyCap = 50
    /// When the server region of upNext has this many or fewer
    /// items left, the trackChanged handler refetches /next around
    /// the current track. Extends the queue transparently before
    /// the user hits the bottom. Chosen to leave ~10s of network
    /// runway at typical listening cadence.
    private static let serverRegionRefetchThreshold: Int = 3

    /// VideoId of the last track we successfully prefetched
    /// artwork FOR (i.e. current track at the moment of prefetch).
    /// Guards `prefetchNextArtworkIfDue` from firing repeatedly on
    /// every post-85% progress tick — once per current track is
    /// enough.
    @ObservationIgnored private var lastPrefetchTriggeredFor: String? = nil
    /// URLCache reuses whatever `URLSession.shared` reads, which is
    /// what SwiftUI's AsyncImage uses. A no-frills GET to the URL
    /// with `URLRequest(cachePolicy: .returnCacheDataElseLoad)` is
    /// enough to warm the cache; the response body is discarded
    /// (`_ = data`).
    private static let prefetchThreshold: Double = 0.85

    private func prefetchNextArtworkIfDue() {
        guard duration > 30 else { return }               // ignore ads / clips
        guard elapsed / duration >= Self.prefetchThreshold else { return }
        guard let currentId = currentTrack?.videoId else { return }
        // Fire exactly once per current track — but ONLY once a
        // fetch actually kicked off. Earlier this branch set the
        // sentinel even when upNext was empty, so /next populating
        // seconds later would still be blocked and the artwork
        // popped on advance. (C6)
        guard lastPrefetchTriggeredFor != currentId else { return }
        guard let next = upNext.first(where: { $0.id != currentId }),
              let url = next.thumbnailURL else {
            // Nothing to prefetch yet — leave sentinel nil so we
            // retry once /next arrives with real rows.
            return
        }
        lastPrefetchTriggeredFor = currentId
        Task.detached { @Sendable in
            var req = URLRequest(url: url)
            req.cachePolicy = .returnCacheDataElseLoad
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Last time we transitioned to a NEW track (different videoId, post-
    /// click-grace). Used to filter out stale `progress` events from the
    /// just-ended track while YT Music's SPA swaps the `<video>` element's
    /// media source. Without this, the elapsed/duration UI briefly shows
    /// the previous track's tail end (e.g. "6:43 / 8:42" on a fresh song).
    @ObservationIgnored private var lastTrackChangeAt: Date = .distantPast
    /// Ignore progress events for this long after a track change. Tuned
    /// against the typical 500ms `timeupdate` cadence; the JS bridge will
    /// report fresh values on the next tick after YT loads the new media.
    private static let trackChangeGraceSeconds: TimeInterval = 1.2

    private func archiveCurrent() {
        guard let old = currentTrack else {
            Log.bridge.debug("archiveCurrent: no current track to archive")
            return
        }
        let item = MediaItem(
            id: old.videoId, kind: .song,
            title: old.title, subtitle: old.subtitle,
            thumbnailURL: old.thumbnailURL,
            albumId: old.albumId, artistId: old.artistId
        )
        // QueueManager handles dedup-against-tail + cap + persist
        // synchronously, so we don't have to. "Appended" is judged by the
        // TAIL entry, not the size: at the history cap an append trims
        // the front and the size stays put.
        let prevCount = queue.playedEntries.count
        let prevTail = queue.playedEntries.last
        queue.archive(item)
        let newCount = queue.playedEntries.count
        guard queue.playedEntries.last != prevTail else {
            Log.bridge.debug("archiveCurrent: skip dup last=\(item.title, privacy: .private) (\(item.id, privacy: .public))")
            return
        }
        // `contextStartHistoryIndex` is an absolute index into
        // playedEntries; entries trimmed off the front by the cap shift
        // every index down. Shift the Repeat All anchor with them —
        // otherwise, at the cap, the anchor points past the end for the
        // whole context and the cycle collapses to the current track.
        let trimmed = max(0, prevCount + 1 - newCount)
        if trimmed > 0 {
            contextStartHistoryIndex = max(0, contextStartHistoryIndex - trimmed)
        }
        Log.bridge.debug("archiveCurrent: appended \(item.title, privacy: .private) (\(item.id, privacy: .public)); historySize=\(newCount)")
    }

    /// Pull /next for the given videoId — populates `upNext` and stashes
    /// browse IDs for lyrics + related which are loaded on demand.
    /// Pass `playlistId` when known so /next returns the playlist's track
    /// list instead of generic radio suggestions.
    /// - parameter updateQueue: when false, only track metadata is
    ///   applied (like state, lyrics/related browse ids, chips) and the
    ///   queue regions are left untouched. Used on page-driven radio
    ///   advances, where the server region mirrors the page's own queue
    ///   and a /next-driven replace would wipe it for ~2s per track.
    private func refreshNextQueueAndIds(forVideoId id: String, playlistId: String?, updateQueue: Bool = true) {
        // Cancel-and-replace: clicking 5 tracks in 2 seconds shouldn't fan out
        // 5 concurrent `/next` requests where the last-to-complete wins.
        nextQueueTask?.cancel()
        // Snapshot the chip on the main thread so the background task
        // uses whatever was active at the moment of the refresh, not
        // whatever happens to be there when the fetch finally runs.
        let chip = activeChip
        nextQueueTask = Task { [innerTube, weak self] in
            guard let response = try? await innerTube.nextQueue(videoId: id, playlistId: playlistId, chip: chip) else {
                Log.bridge.debug("refreshNextQueue: nextQueue threw or returned nil for v=\(id, privacy: .public)")
                return
            }
            // Bail if we were superseded by a newer click while awaiting.
            if Task.isCancelled { return }
            Log.bridge.debug("refreshNextQueue v=\(id, privacy: .public) plid=\(playlistId ?? "nil", privacy: .public) → queue=\(response.queue.count) likeStatus=\(String(describing: response.likeStatus), privacy: .public)")

            // /next sometimes returns just the currently-playing track in
            // its queue (especially right after navigation, before the
            // page populates the full panel). When we know we're inside
            // a playlist (including the auto-radio "RDAMVM" prefix that
            // play(item:) attaches for single-song clicks), fall back to
            // fetching the playlist's own tracklist via /browse so Up
            // Next isn't empty. (`fetched` rather than `queue` to avoid
            // shadowing the QueueManager property name.)
            var fetched = response.queue
            if fetched.count <= 1, let plid = playlistId, !plid.isEmpty {
                // Fallback A: real playlist id (PL… / OLAK5uy_…) — fetch
                // its track list directly. Not applicable for auto-radio
                // RDAMVM<videoId> ids (YT doesn't expose them via /browse).
                if !plid.hasPrefix("RDAMVM"),
                   let detail = try? await innerTube.playlistDetail(playlistId: plid) {
                    if Task.isCancelled { return }
                    Log.bridge.debug("refreshNextQueue: fallback to playlistDetail \(plid, privacy: .public) → \(detail.tracks.count) tracks")
                    fetched = detail.tracks
                }
            }
            // Fallback B: /next came back thin AND we have a related
            // browseId for the current track — use related songs to
            // seed Up Next so a single-track click doesn't leave the
            // queue empty. Common for regional / long-tail tracks
            // where YT's auto-radio is sparse. We synthesize a
            // current-track entry at the head so the merge step
            // below still has a valid curId anchor.
            if fetched.count <= 1, let relatedId = response.relatedBrowseId {
                if let relatedItems = try? await innerTube.related(browseId: relatedId), !relatedItems.isEmpty {
                    if Task.isCancelled { return }
                    Log.bridge.debug("refreshNextQueue: fallback to related \(relatedId, privacy: .public) → \(relatedItems.count) tracks")
                    // Preserve whatever /next told us about the current
                    // track (typically a singleton entry at index 0),
                    // then tack the related results on as the body.
                    fetched = response.queue + relatedItems
                }
            }

            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                // Two-region model: /next fetches ONLY drive the
                // server region. User-queued items (top of upNext)
                // stay put by construction — `replaceServerRegion`
                // preserves them verbatim and dedupes any server
                // items whose id already lives in the user region.
                //
                // The currently-playing track is dropped from the
                // /next response so it doesn't appear as an upcoming
                // row. Blocked-artist filtering happens before the
                // handoff so blocked rows never enter upNext.
                let curId = self.currentTrack?.videoId
                // PHASE 1 (interim): radio contexts are non-deterministic —
                // the WebView plays its OWN radio, which this independent
                // /next call can't reproduce (docs: "changes each time").
                // Displaying that mismatched queue is exactly what produced
                // "random songs". For radio we clear the server region and
                // let the page's native autoplay drive; the UI shows an
                // autoplay hint. Explicit user-queued items (Play Next /
                // Add to queue) stay in the user region and are still
                // honored via the pending-URL + reconciliation path.
                // Deterministic contexts (albums, playlists) DO match, so
                // they populate as before. (Phase 2 will mirror the page's
                // real queue and restore a radio Up Next that's correct.)
                // Chip-tuned fetches are Riff-curated and DO populate
                // (the page doesn't know the chip); only plain radio
                // defers to the page mirror.
                let isRadio = chip == nil && (playlistId?.hasPrefix("RD") ?? true)
                // While the user region holds the list (album via
                // playTracks, queued songs), a /next tail beneath it is
                // speculative: it is re-fetched on every navigation and
                // re-rolls each time ("songs next to the album keep
                // changing"). Paint nothing there; the REAL tail arrives
                // from the mirror once the user region drains — same
                // rule as mirrorApplies (never repaint beneath user rows).
                // Scoped to tracklist-seeded contexts (album/playlist
                // via playTracks): a Play-Next row in a page playlist
                // keeps the playlist's rows beneath it.
                let userOwnsList = chip == nil && self.queue.userQueueCount > 0
                    && !self.contextTracksIds.isEmpty && self.contextPlaylistId != nil
                // Exclude tracks already played this session. /next (and
                // the playlistDetail fallback, which returns the FULL
                // tracklist) includes tracks BEFORE the current one; the
                // auto-extension refetch fires on every advance once the
                // server region runs low, so without this filter played
                // album tracks re-accumulate below the remaining ones and
                // the album loops back to track 1 instead of ending.
                let playedIds = Set(self.queue.playedEntries.suffix(200).map { $0.item.id })
                // Phase C: once the current page's mirror is live, IT
                // owns the server region (in non-chip contexts) — a
                // /next replace here would fight it. The fetch still
                // ran for the metadata applied below. Chip queues stay
                // /next-driven.
                let mirrorOwnsQueue = self.mirrorFresh && self.activeChip == nil
                if updateQueue, !mirrorOwnsQueue {
                    let serverItems: [MediaItem] = (isRadio || userOwnsList) ? [] : fetched.filter { item in
                        item.id != curId && !playedIds.contains(item.id) && !self.shouldBlock(item)
                    }
                    self.queue.replaceServerRegion(serverItems)
                    // Push the new visible head into JS's pending-next URL
                    // so the next end-of-stream intercepts YT's autoplay
                    // with our choice. Without this, YT picks the next
                    // track from its internal queue — which can diverge
                    // from upNext after a related-songs fallback or block
                    // filter. Fire-and-forget; the JS bridge tolerates
                    // out-of-order updates.
                    Task { [weak self] in await self?.syncPendingNextURL() }
                }
                // Backfill the current track's album/artist IDs if /next
                // returned them and the track we have on screen is missing
                // them — common when the user clicks a carousel tile whose
                // parent shelf didn't carry album navigation.
                if let cur = self.currentTrack,
                   (cur.albumId == nil || cur.artistId == nil),
                   let match = fetched.first(where: { $0.id == cur.videoId }),
                   (match.albumId != nil || match.artistId != nil) {
                    self.currentTrack = Track(
                        videoId: cur.videoId,
                        title: cur.title,
                        subtitle: cur.subtitle,
                        thumbnailURL: cur.thumbnailURL,
                        duration: cur.duration,
                        albumId: cur.albumId ?? match.albumId,
                        artistId: cur.artistId ?? match.artistId
                    )
                }
                self.lyricsBrowseId = response.lyricsBrowseId
                self.relatedBrowseId = response.relatedBrowseId
                // Scope the like flag to the track it was fetched FOR:
                // this completion can land after playback advanced past
                // `id`, and the heart binds to the shared flag — a
                // stale write would make the next click send the
                // inverse of the user's intent.
                if self.currentTrack?.videoId == id {
                    self.liked = response.likeStatus == .like
                }
                self.availableChips = response.chips
                // Highlight the chip we sent in the request (if any) so
                // the popover stays visually consistent across autoplay
                // transitions; fall back to whatever YT marked active
                // in the response.
                self.selectedChipId = chip?.id ?? response.chips.first(where: \.isSelected)?.id
                // Invalidate previously cached tab content for the old
                // track — and cancel any fetch still in flight for it,
                // so a slow response can't land under the new browse
                // ids (the completions identity-check besides; this is
                // belt-and-braces plus bandwidth hygiene).
                self.lyricsTask?.cancel()
                self.relatedTask?.cancel()
                self.lyrics = nil
                self.lyricsLines = []
                self.lyricsTimed = false
                self.lyricsLoading = false
                self.lyricsUnavailable = false
                self.related = []
                self.relatedSections = []
                // The injected-ids set is per-watch-context: a fresh
                // /next means a fresh `related` pool will land soon
                // (if Smart Shuffle is on) and we'll re-inject around
                // the new base queue. Clearing now prevents a stale
                // badge from clinging to a row whose id happens to
                // re-appear in the new queue.
                self.smartShuffleInjectedIds = []
                // Kick off /related proactively when Smart Shuffle is
                // armed so the injections land soon after the queue
                // populates. Without this, the user wouldn't see "+"
                // rows until they opened the Related tab manually.
                if self.smartShuffleEnabled, self.shuffleEnabled {
                    self.loadRelatedIfNeeded()
                }
            }
        }
    }

    /// Wipe the per-track tab state (lyrics + related) AND the browse
    /// ids that key their lazy fetches, cancelling any fetch still in
    /// flight. Called wherever the current track's identity changes
    /// before fresh /next metadata exists — play(item:) and the
    /// trackChanged new-track branch. With a stale browse id left in
    /// place, a tab open across the advance would load (or a slow
    /// in-flight response would deliver) the PREVIOUS track's content
    /// under the new track.
    private func resetPerTrackTabState() {
        lyricsTask?.cancel()
        relatedTask?.cancel()
        lyrics = nil
        lyricsLines = []
        lyricsTimed = false
        lyricsLoading = false
        lyricsUnavailable = false
        related = []
        relatedSections = []
        lyricsBrowseId = nil
        relatedBrowseId = nil
    }

    /// Fetch ONLY per-track metadata — the like state and the lyrics /
    /// related browse ids — for advances where no full /next refresh
    /// fires (deterministic contexts with plenty of server rows left,
    /// autoplay off, play(item:, clearQueue: false) jumps). Without
    /// it, the reset-to-unknown on track change would leave every
    /// liked album track showing a hollow heart (and dead lyrics
    /// tabs) for its whole duration.
    ///
    /// Deliberately NOT `refreshNextQueueAndIds(updateQueue: false)`:
    /// its cancel-and-replace on `nextQueueTask` could kill an
    /// in-flight queue refresh, and its completion also rewrites
    /// chips, smart-shuffle ids and queue-adjacent state. This task
    /// never touches the queue regions, and its result is dropped
    /// unless the track is still current when it lands.
    private func refreshTrackMetadata(forVideoId id: String, playlistId: String?) {
        trackMetadataTask?.cancel()
        trackMetadataTask = Task { [innerTube, weak self] in
            guard let response = try? await innerTube.nextQueue(videoId: id, playlistId: playlistId, chip: nil) else {
                Log.bridge.debug("refreshTrackMetadata: nextQueue threw or returned nil for v=\(id, privacy: .public)")
                return
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                // Identity: playback may have advanced again while the
                // round-trip was in flight — stale metadata must not
                // land on the new track.
                guard self.currentTrack?.videoId == id else { return }
                self.liked = response.likeStatus == .like
                self.lyricsBrowseId = response.lyricsBrowseId
                self.relatedBrowseId = response.relatedBrowseId
            }
        }
    }

    /// Apply a Tune chip — re-issues `/next` with the chip's (playlistId,
    /// params) and replaces `upNext` with the resulting queue. The
    /// currently-playing track keeps playing (we don't navigate the
    /// WebView), only the suggested-next queue changes.
    func applyChip(_ chip: InnerTubeClient.QueueChip) {
        guard let videoId = currentTrack?.videoId else { return }
        // Optimistically reflect the selection in the UI before the
        // network round-trip completes.
        selectedChipId = chip.id
        // Persist the chip so subsequent /next fetches (autoplay
        // advance, explicit next) keep the same chip context —
        // otherwise chips were single-track and the next fetch
        // reverted to generic radio.
        activeChip = chip
        // C3: Chip mode reshapes the server region to tracks scoped
        // to a mood/genre. Reset currentPlaylistId to the CURRENT
        // track's auto-radio so downstream URL construction — pending
        // URLs, playlist-aware refetches — uses per-track radio
        // instead of building `?v=chipTrack&list=<oldPL>` where
        // chipTrack isn't in the old playlist. Without this,
        // end-of-stream navigation escapes the chip's suggestions
        // back into the outer playlist.
        currentPlaylistId = Self.radioPlaylistId(for: videoId)
        nextQueueTask?.cancel()
        nextQueueTask = Task { [innerTube, weak self] in
            guard let response = try? await innerTube.nextQueue(videoId: videoId, playlistId: nil, chip: chip) else {
                Log.bridge.debug("applyChip: nextQueue threw for chip=\(chip.id, privacy: .public)")
                return
            }
            if Task.isCancelled { return }
            Log.bridge.debug("applyChip \(chip.id, privacy: .public) → queue=\(response.queue.count)")
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                // Chip apply = fresh SERVER region, user region
                // untouched. In the two-region model,
                // `replaceServerRegion` handles the dedup against
                // user-queued items automatically. Everything the
                // user explicitly queued (Play Next / Add to Queue)
                // stays exactly where it was; only the auto-radio
                // continuation flavor changes.
                let filtered = response.queue.filter { !self.shouldBlock($0) }
                self.queue.replaceServerRegion(filtered)
                // Push the chip-mode head into the JS pending-next
                // URL so end-of-stream navigates to OUR choice rather
                // than YT's chip-context autoplay (which can diverge).
                Task { [weak self] in await self?.syncPendingNextURL() }
                // Refresh chip set: YT returns the same cloud back, but
                // with a different chip's `isSelected=true`.
                if !response.chips.isEmpty {
                    self.availableChips = response.chips
                }
            }
        }
    }

    /// Toggle the like state on the current track. Optimistically updates
    /// `liked` so the UI feels immediate; rolls back on InnerTube error.
    func toggleLike() async {
        guard let track = currentTrack else { return }
        // An in-flight per-track metadata fetch carries the PRE-toggle
        // like state — landing after the optimistic flip below would
        // clobber it.
        trackMetadataTask?.cancel()
        let wasLiked = liked
        liked.toggle()
        do {
            if wasLiked {
                try await innerTube.removeLike(videoId: track.videoId)
            } else {
                try await innerTube.like(videoId: track.videoId)
            }
        } catch {
            // Roll back on failure (e.g. needsReauth when not signed
            // in) — but only while the SAME track is still showing.
            // After an advance the shared flag belongs to the NEW
            // track (same identity guard `dislike` uses); an unguarded
            // rollback here overwrote the new track's real state.
            if currentTrack?.videoId == track.videoId {
                liked = wasLiked
            }
        }
    }

    /// Thumbs-down a track. Trains YT Music's server-side radio away
    /// from it — the one steering signal local artist-blocking can't
    /// send. Returns true on success so the caller can toast.
    func dislike(videoId: String) async -> Bool {
        do {
            try await innerTube.dislike(videoId: videoId)
            if currentTrack?.videoId == videoId { liked = false }
            return true
        } catch {
            Log.bridge.error("dislike failed for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Lazy-load lyrics on tab open. Sets `lyricsLoading` while in flight.
    /// Populates either `lyricsLines` (with `lyricsTimed=true`) for synced
    /// lyrics or just the plain `lyrics` text fallback.
    func loadLyricsIfNeeded() {
        // `lyricsUnavailable` is terminal for this track (a completed
        // round-trip said there are none) — without it in the guard, a
        // lyric-less track would refetch on every tab open. A
        // transient failure leaves it false, so reopening retries.
        guard lyrics == nil, lyricsLines.isEmpty, !lyricsLoading, !lyricsUnavailable,
              let id = lyricsBrowseId else { return }
        lyricsLoading = true
        lyricsTask?.cancel()
        lyricsTask = Task { [innerTube, weak self] in
            do {
                let result = try await innerTube.lyrics(browseId: id)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    // Identity check on the BROWSE id, not the videoId:
                    // currentTrack flips to the new track before its
                    // /next lands, but the browse id only changes when
                    // the new metadata does — so this is the id the
                    // fetch belongs to. A stale completion returns
                    // WITHOUT touching `lyricsLoading`: if the new
                    // track's own fetch is already in flight, clearing
                    // the flag here would allow a duplicate request.
                    guard self.lyricsBrowseId == id else { return }
                    if let result {
                        self.lyricsLines = result.lines
                        self.lyricsTimed = result.timed
                        self.lyrics = result.lines.map(\.text).joined(separator: "\n")
                    } else {
                        // Completed round-trip, YT has no lyrics:
                        // terminal for this track. The UI shows its own
                        // empty state — never store the copy in
                        // `lyrics`, where it read as real lyric text to
                        // the toolbar, translation, X-Ray and the card.
                        self.lyricsUnavailable = true
                    }
                    self.lyricsLoading = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    guard self.lyricsBrowseId == id else { return }
                    // Transient failure (offline blip): leave `lyrics`
                    // nil and `lyricsUnavailable` false so reopening
                    // the tab retries.
                    self.lyricsLoading = false
                }
            }
        }
    }

    /// Lazy-load related songs on tab open. Single browse round-trip
    /// produces both the flat song list (`related`) and the titled
    /// shelves (`relatedSections`, including "Other versions" / "Other
    /// performances" — the live, acoustic, cover variants A5 surfaces).
    func loadRelatedIfNeeded() {
        guard related.isEmpty, relatedSections.isEmpty, let id = relatedBrowseId else { return }
        relatedTask?.cancel()
        relatedTask = Task { [innerTube, weak self] in
            // One network call, two parses — `relatedPage(browseId:)`
            // POSTs the browseId once and projects the same body into
            // the flat song list and the titled shelves. Failure is
            // all-or-nothing: a transient error leaves both `related`
            // and `relatedSections` empty, so the isEmpty guard above
            // lets the next trigger (tab open, toggle, /next) retry.
            let page: (items: [MediaItem], sections: [HomeSection])? =
                try? await innerTube.relatedPage(browseId: id)
            let items: [MediaItem] = page?.items ?? []
            let sections: [HomeSection] = page?.sections ?? []
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                // Identity check (same rationale as loadLyricsIfNeeded):
                // a slow response for the previous track must not become
                // the new track's Related tab — or, worse, its Smart
                // Shuffle pool via the re-merge below.
                guard self.relatedBrowseId == id else { return }
                self.related = items.filter { !self.shouldBlock($0) }
                self.relatedSections = sections.compactMap { section in
                    let filtered = section.items.filter { !self.shouldBlock($0) }
                    guard !filtered.isEmpty else { return nil }
                    return HomeSection(id: section.id, title: section.title, items: filtered)
                }
                // Fresh /related pool — re-run the Smart Shuffle merge
                // so the "+" rows show up in upNext without waiting on
                // the next /next refresh. No-op when Smart Shuffle is
                // off or shuffle is off (see applySmartShuffle... guard).
                self.applySmartShuffleToCurrentQueue()
            }
        }
    }

    /// Plays a YT Music playlist. Tries direct /watch?list= first (works
    /// for proper PL... / OLAK5uy_... ids); on failure falls back to the
    /// browseId resolver path which will fetch the playlist's first track
    /// and navigate /watch?v=&list= explicitly.
    /// Play a fully-parsed tracklist in order — used by album +
    /// playlist detail pages so we get the actual tracklist instead
    /// of trusting YT's playlist queue API (which for many albums
    /// returns just the seed track, causing autoplay to fall into
    /// unrelated radio after song 1).
    ///
    /// Loads every remaining track into the user region of the
    /// queue (via `addToEnd`), in album order, so `/next` refreshes
    /// can never displace them. The first track goes through
    /// `play(item:, clearQueue: true)` for the fresh watch context;
    /// subsequent tracks chain via the JS end-of-track handler
    /// which navigates to `upNext.first` — always the correct next
    /// album track because the user region preserves insertion
    /// order.
    func playTracks(_ tracks: [MediaItem], playlistId: String? = nil, preservesListOrder: Bool = true) async {
        guard let first = tracks.first else { return }
        let rest = Array(tracks.dropFirst())
        Log.bridge.debug("playTracks ENTRY firstId=\(first.id, privacy: .public) restCount=\(rest.count) plid=\(playlistId ?? "nil", privacy: .public)")
        // User intent (album / playlist / queue-builder play): lift any
        // pause-enforcement window so the first track isn't force-paused.
        // The one automatic caller — the Repeat All cycle in `.ended` —
        // is mutually exclusive with the branches that arm the window.
        pauseEnforceUntil = .distantPast
        // Fresh watch context — full queue reset + Repeat All boundary.
        queue.replaceQueue([])
        contextStartHistoryIndex = queue.playedEntries.count
        // Deterministic tracklist context: these ids advance IN this
        // context (page-native / list=<plid>), never via per-track radio.
        contextTracksIds = Set(tracks.map(\.id))
        contextPlaylistId = playlistId
        contextIsPageOrdered = preservesListOrder
        // Seed the user region with the tail of the album in order.
        for track in rest {
            queue.addToEnd(track)
        }
        Log.bridge.debug("playTracks AFTER seeding user region upNext=\(self.upNext.count) userQueueCount=\(self.queue.userQueueCount)")
        // C5: seed currentPlaylistId + fire refreshNextQueueAndIds
        // scoped to the album so metadata (lyrics/related browseIds,
        // chip cloud) is album-scoped from track 1 AND when the user
        // region eventually drains, the auto-extension refetch is
        // scoped to the album rather than per-track radio.
        if let playlistId, !playlistId.isEmpty {
            currentPlaylistId = playlistId
            refreshNextQueueAndIds(forVideoId: first.id, playlistId: playlistId)
        } else {
            // No playlist context (e.g. AI queue builder hands a bare
            // tracklist). Reset to the FIRST track's auto-radio — the
            // follow-up play(clearQueue: false) deliberately preserves
            // context, so without this a stale RDAMVM<oldTrack> from the
            // previous session would (a) navigate the page into the OLD
            // song's radio and (b) keep isPageDrivenContext true, letting
            // the page mirror append that old radio under the hand-built
            // queue.
            currentPlaylistId = Self.radioPlaylistId(for: first.id)
        }
        await syncPendingNextURL()
        await play(item: first, clearQueue: false)
    }

    func playPlaylist(id: String) async {
        // Strip a "VL" prefix if it's still attached — VL ids are browse
        // ids (used to fetch playlist details), not playable ids.
        let cleaned = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
        Log.resolver.debug("playPlaylist id=\(id, privacy: .public) cleaned=\(cleaned, privacy: .public)")
        // Generic playlists assumed music — YT Music doesn't surface
        // podcast playlists as a kind we can tell apart at this seam.
        await applyRate(for: .music)
        // Seed currentPlaylistId proactively: YT Music strips `list=`
        // from the URL almost immediately after playback begins, and
        // the JS bridge's stickyPlaylistId can miss the initial value
        // if `findPlaylistId` runs after the strip and before the
        // queue DOM is populated with a `list=` link. If that happens
        // and we didn't seed here, the first trackChanged would
        // arrive with playlistId=nil, /next would fall into per-track
        // auto-radio, and every track from #3 onward would drift into
        // random recommendations. Seeding + the "don't clobber with
        // nil" guard in handle(trackChanged:) keeps the context.
        // Playlist context: the tracklist is server-driven (no local
        // ids), but the context playlist id still anchors advances.
        beginNavigatedContext(playlistId: cleaned)
        await navigate(watchURL(videoId: nil, playlistId: cleaned))
    }

    func playAlbum(id: String)    async {
        await applyRate(for: .music)
        await playByResolvingBrowseId(id)
    }
    func playPodcast(id: String)  async {
        await applyRate(for: .spoken)
        await playByResolvingBrowseId(id)
    }
    func playArtistRadio(id: String) async {
        await applyRate(for: .music)
        await playByResolvingBrowseId(id)
    }

    /// Hand off browseId resolution to `BrowseIdResolver` and navigate
    /// the WKWebView to the resolved destination. The resolver owns
    /// the resolution policy (primary path / VL strip / browse-page
    /// fallback); this method owns the navigation side only.
    private func playByResolvingBrowseId(_ browseId: String) async {
        let destination = await BrowseIdResolver.resolve(browseId, via: innerTube)
        switch destination {
        case let .watch(videoId, playlistId):
            let url = watchURL(videoId: videoId, playlistId: playlistId)
            Log.resolver.debug("\(browseId, privacy: .public) → v=\(videoId ?? "nil", privacy: .public) list=\(playlistId ?? "nil", privacy: .public) → \(url, privacy: .public)")
            // Seed Swift-side playlist context before nav — see the
            // longer note in playPlaylist above. Same URL-strip race,
            // same drift-into-radio symptom if we don't seed.
            beginNavigatedContext(playlistId: playlistId)
            await navigate(url)
        case let .directPlaylist(plid):
            Log.resolver.debug("\(browseId, privacy: .public) → resolver failed; falling back to direct playlist plid=\(plid, privacy: .public)")
            beginNavigatedContext(playlistId: plid)
            await navigate(watchURL(videoId: nil, playlistId: plid))
        case let .browsePage(url):
            Log.resolver.debug("\(browseId, privacy: .public) → no playable endpoint and no fallback; navigating to browse page")
            await navigate(url.absoluteString)
        }
    }

    private func watchURL(videoId: String?, playlistId: String?) -> String {
        // The base string is a compile-time literal, but we still avoid the
        // force-unwrap so a future typo can't crash on launch. Falling back
        // to the home URL is preferable to `fatalError` — playback won't
        // start, but the WebView stays alive and the user can recover.
        guard var components = URLComponents(string: "https://music.youtube.com/watch") else {
            return "https://music.youtube.com/"
        }
        var items: [URLQueryItem] = []
        if let videoId, !videoId.isEmpty { items.append(URLQueryItem(name: "v", value: videoId)) }
        if let playlistId, !playlistId.isEmpty { items.append(URLQueryItem(name: "list", value: playlistId)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url?.absoluteString ?? "https://music.youtube.com/"
    }

    /// A user-initiated hard navigation into a NEW page context
    /// (playlist / album / artist radio by URL). The rows on screen
    /// belong to the OLD page: left in place, the new page's first
    /// trackChanged is judged against a stale head and the WYSIWYG
    /// enforcement navigates back to it with the NEW list — seen in
    /// the field as a radio head pushed into an album list (which
    /// restarts the album). Clear the display (the mirror repaints
    /// within ~2s), arm the click grace — this IS user intent — and
    /// anchor the context for advances. `playTracks` does the same
    /// inline because it then seeds the user region.
    private func beginNavigatedContext(playlistId: String?) {
        queue.replaceQueue([])
        userClickedAt = Date()
        pauseEnforceUntil = .distantPast   // user intent beats a stop window
        currentPlaylistId = playlistId
        contextTracksIds = []
        contextPlaylistId = playlistId
        contextIsPageOrdered = true
        contextStartHistoryIndex = queue.playedEntries.count
        Audit.note("context switch → list=\(playlistId ?? "nil") (display cleared, click grace armed)")
    }

    private func navigate(_ url: String) async {
        // Any hard navigation starts a fresh playback context, so a
        // stale last-session resume target must not survive it —
        // otherwise a later togglePlay would yank the WebView back
        // to the restored track over the top of what's playing now.
        pendingResume = nil
        // Same for an armed resume SEEK: the new page is a different
        // context, so the saved position must not seek into it.
        // (togglePlay arms its target AFTER play(videoId:) — and thus
        // this clear — returns, so its own resume survives.)
        pendingResumeSeek = nil
        // A navigation supersedes any row-tap jump still being
        // verified: cancel the 2.5 s timer and drop the target so it
        // can't raise a false "couldn't play" toast for a tap the
        // user has already clicked past.
        jumpVerifyTask?.cancel()
        jumpVerifyTask = nil
        pendingJumpTarget = nil
        // New page → its queue store is fresh; until its first snapshot
        // arrives, /next fetches may seed the visible rows. Page-owned
        // queued items die with the old page's queue.
        mirrorFresh = false
        pageOwnedQueuedIds = []
        await eval("window.musicBridge.navigate(\(url.jsonQuoted))")
    }

    /// Pause without toggle semantics — used by the pause-enforcement
    /// window (sleep end-of-track, autoplay-off end-of-queue) so an
    /// enforcement pause can't accidentally RESUME a paused player.
    /// Deliberately does NOT clear `pauseEnforceUntil`.
    func forcePause() async {
        await eval("window.musicBridge.pause()")
    }

    func togglePlay() async {
        // User intent overrides any pause-enforcement window: pressing
        // play after a sleep-timer stop should actually play.
        pauseEnforceUntil = .distantPast
        // Consume a pending resume from the restored session: the
        // WebView hasn't navigated to the saved track yet, so a plain
        // togglePlay would target an empty <video>. Instead navigate
        // to the track and seek to the saved position once playback
        // begins.
        if let resume = pendingResume {
            pendingResume = nil
            await play(videoId: resume.videoId)
            // Arm the seek target AFTER play(videoId:) returns:
            // navigate() clears pendingResumeSeek (any hard navigation
            // invalidates a saved position), so arming before the call
            // would wipe the target we just set. The eval completes
            // before the new page's first `.progress` can arrive, so
            // nothing is missed. The seek itself fires event-driven in
            // the `.progress` handler on the first tick whose duration
            // matches the snapshot — no fixed sleep, so a cold WebView
            // / slow network can't skip it and a fast load can't race
            // YT's own initial seek.
            pendingResumeSeek = resume
            return
        }
        await eval("window.musicBridge.togglePlay()")
    }
    /// Advance to the next track.
    ///
    /// Priority order (this is what makes "Play album, then Next"
    /// behave):
    ///   1. USER REGION always advances in order first — an album or
    ///      explicitly-queued tracks are the user's stated intent, so
    ///      Next steps through them one by one even when shuffle is
    ///      on. Shuffle must NOT scramble an album you pressed Play on.
    ///   2. Only once the user region is exhausted does shuffle apply,
    ///      and then only to the SERVER region (radio/autoplay) — that's
    ///      the part shuffle is meant to randomize.
    ///   3. Server head (shuffle off).
    ///   4. YT's own autoplay as a last resort.
    func next() async {
        // User transport: whatever this advances to (every branch below)
        // must not be force-paused by a sleep-timer / autoplay-off stop
        // window. See `pauseEnforceUntil`.
        pauseEnforceUntil = .distantPast
        let currentId = currentTrack?.videoId
        guard let head = upNext.first(where: { $0.id != currentId }) else {
            // Nothing surfaced — let YT's autoplay continue.
            await eval("window.musicBridge.next()")
            return
        }
        // 1. Page-native whenever the natural advance would be (policy):
        //    radio rows, an in-order album the page is already inside,
        //    mirrored autoplay rows after an album. No reload → no
        //    re-rolled tail; no off-list row pushed into an album list.
        if QueuePolicy.nextUsesPageNative(advanceInputs(for: head)) {
            Audit.note("next() → page-native advance (head=\(head.id))")
            userClickedAt = Date()   // user intent; don't let enforcement misread the jump
            await eval("window.musicBridge.next()")
            return
        }
        // 2. User region (explicit intent / shuffled album order) —
        //    advance its head in order, regardless of shuffle.
        if queue.isUserQueued(videoId: head.id) {
            await skipTo(item: head)
            return
        }
        // 3. Local shuffle over Riff-owned server rows only.
        if shuffleEnabled, QueuePolicy.localShuffleAllowed(isPageDriven: isPageDrivenContext) {
            let serverCandidates = Array(upNext.dropFirst(queue.userQueueCount)).filter { $0.id != currentId }
            if let pick = serverCandidates.randomElement() {
                await skipTo(item: pick)
                return
            }
        }
        // 4. Swift drives the head (chip queues, pre-mirror seeds).
        await play(item: head, clearQueue: false)
    }
    func previous()   async {
        // The incoming trackChanged (the PRIOR track) is the user's own
        // navigation — its videoId is never in upNext (already consumed),
        // so without the click-grace the WYSIWYG enforcement would read
        // it as autoplay divergence and snap FORWARD to the shown head,
        // making Previous jump the wrong way. Arm the grace like every
        // other user-intent transport.
        userClickedAt = Date()
        pauseEnforceUntil = .distantPast   // user intent beats a stop window
        await eval("window.musicBridge.previous()")
    }
    func seek(to fraction: Double) async {
        await eval("window.musicBridge.seek(\(fraction))")
    }

    /// Coarse split for per-kind default playback rates. Spoken-word
    /// content (podcasts, episodes) defaults to 1.25× because that's
    /// where most podcast listeners live; music defaults to 1.0×.
    /// The user's last-set rate for each kind is persisted separately,
    /// so flipping between a podcast (1.5×) and a song (1.0×) doesn't
    /// reset either preference.
    enum PlaybackKind: String, Hashable, Sendable {
        case music, spoken

        static func from(_ kind: MediaItem.Kind) -> PlaybackKind {
            switch kind {
            case .episode, .podcast: return .spoken
            default: return .music
            }
        }

        var defaultRate: Double {
            switch self {
            case .music:  return 1.0
            case .spoken: return 1.25
            }
        }
    }

    /// The current playback kind. Updated whenever a play(item:)-style
    /// entry point fires; autoplay-advanced tracks inherit the current
    /// kind (autoplay never crosses the music ↔ spoken boundary in
    /// practice — YT's radio queues are kind-homogeneous).
    private(set) var currentKind: PlaybackKind = .music

    // MARK: - Spoken-word resume positions (podcasts)

    /// videoId → last known position (seconds) for spoken-word tracks.
    /// Persisted so an episode you stopped halfway resumes there next
    /// time instead of restarting from 0. Music is never tracked.
    @ObservationIgnored private var episodePositions: [String: Double] =
        (UserDefaults.standard.dictionary(forKey: PlayerBridge.episodePositionsKey) as? [String: Double]) ?? [:]
    @ObservationIgnored private var lastEpisodePositionSaveAt: Date = .distantPast
    /// The videoId we already applied a resume seek for (once per track).
    @ObservationIgnored private var resumeAppliedFor: String? = nil
    private static let episodePositionsKey = "player.episodePositions"
    private static let episodeResumeMinSeconds: Double = 30
    private static let episodeFinishedMarginSeconds: Double = 20

    private func persistEpisodePositions() {
        // Bound the store: keep the 200 most recently written entries
        // (dictionary order is arbitrary; dropping any 1+ is fine).
        if episodePositions.count > 200 {
            for key in episodePositions.keys.prefix(episodePositions.count - 200) {
                episodePositions.removeValue(forKey: key)
            }
        }
        UserDefaults.standard.set(episodePositions, forKey: Self.episodePositionsKey)
    }

    /// Called from the progress handler: record position for spoken
    /// tracks every ~5s; clear it once the episode is essentially done.
    /// `force: true` (used on pause) bypasses the 5 s rate limit so the
    /// saved resume position is exact at the moment the user stops —
    /// the kind/duration guards still apply.
    private func trackEpisodePosition(videoId: String, elapsed: Double, duration: Double, force: Bool = false) {
        guard currentKind == .spoken, duration > 0 else { return }
        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastEpisodePositionSaveAt) >= 5 else { return }
        }
        lastEpisodePositionSaveAt = now
        if elapsed >= duration - Self.episodeFinishedMarginSeconds {
            if episodePositions.removeValue(forKey: videoId) != nil { persistEpisodePositions() }
        } else if elapsed >= Self.episodeResumeMinSeconds {
            episodePositions[videoId] = elapsed
            persistEpisodePositions()
        }
    }

    /// Called when a track's duration first becomes known: seek to the
    /// saved position for spoken tracks (once per track).
    private func applyEpisodeResumeIfNeeded(videoId: String, duration: Double) {
        guard currentKind == .spoken, duration > 0, resumeAppliedFor != videoId,
              let saved = episodePositions[videoId],
              saved >= Self.episodeResumeMinSeconds,
              saved < duration - Self.episodeFinishedMarginSeconds else { return }
        resumeAppliedFor = videoId
        Log.bridge.debug("episode resume: \(videoId, privacy: .public) → \(Int(saved))s of \(Int(duration))s")
        Task { [weak self] in await self?.seek(to: saved / duration) }
    }

    /// Playback rate (0.5x – 2.0x). The setter writes through to the
    /// current kind's UserDefaults entry so the next time that kind
    /// plays, this rate is restored.
    private(set) var playbackRate: Double = 1.0
    func setPlaybackRate(_ rate: Double) async {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: Self.rateKey(for: currentKind))
        await eval("window.musicBridge.setPlaybackRate(\(rate))")
    }

    private static func rateKey(for kind: PlaybackKind) -> String {
        "player.rate.\(kind.rawValue)"
    }

    /// Look up the persisted rate for a kind, falling back to the
    /// kind's default. Doesn't touch JS state — call applyRate(for:)
    /// when you also want the page's rate to follow.
    private static func storedRate(for kind: PlaybackKind) -> Double {
        UserDefaults.standard.object(forKey: rateKey(for: kind)) as? Double ?? kind.defaultRate
    }

    /// Switch the current kind and push the corresponding stored rate
    /// to both this observable property and the JS bridge. Called from
    /// the play(item:) / playPodcast(id:) entry points whenever the
    /// kind might change.
    private func applyRate(for kind: PlaybackKind) async {
        currentKind = kind
        let rate = Self.storedRate(for: kind)
        playbackRate = rate
        await eval("window.musicBridge.setPlaybackRate(\(rate))")
    }

    /// Skip ±N seconds — podcast-style transport. Negative skips back.
    func skip(by seconds: Double) async {
        await eval("window.musicBridge.skipBy(\(seconds))")
    }

    /// Toggle the JS-side background mode. When `true`, the safety-
    /// poll (2s tick that re-emits trackChanged so late-arriving
    /// metadata doesn't leave the mini-player stuck on a blank row)
    /// and the normalization measurement tick (10Hz during the
    /// ~5s post-track window) suspend. Both resume on `false`.
    /// Audio playback is unaffected — the WebKit media pipeline is
    /// independent of these timers.
    func setBackgrounded(_ backgrounded: Bool) async {
        await eval("window.musicBridge.setBackgrounded(\(backgrounded))")
    }

    /// Add the currently-playing track to a user-owned playlist. Caller
    /// supplies the target playlistId. Requires sign-in (SAPISID cookie).
    func addCurrentTrackToPlaylist(playlistId: String) async throws {
        guard let videoId = currentTrack?.videoId else { return }
        try await innerTube.addToPlaylist(videoId: videoId, playlistId: playlistId)
    }

    /// Create a fresh user-owned playlist and add the currently-playing
    /// track to it. Returns the new playlistId on success.
    @discardableResult
    func createPlaylistWithCurrentTrack(title: String) async throws -> String? {
        guard let videoId = currentTrack?.videoId else { return nil }
        let plid = try await innerTube.createPlaylist(title: title)
        if let plid {
            try await innerTube.addToPlaylist(videoId: videoId, playlistId: plid)
        }
        return plid
    }

    /// "Save queue as playlist" — YT Music's Up-Next save action.
    /// Creates a fresh private playlist and adds every track currently
    /// in `upNext` (in order). Adds are sequential because YT
    /// Music's editPlaylist ACTION_ADD_VIDEO doesn't accept a batch
    /// list — one round-trip per track. Returns the new playlistId.
    /// Errors after the playlist is created are non-fatal (the
    /// playlist exists with whatever subset got added before the
    /// error); we surface the first error to the caller.
    @discardableResult
    func savePlaylistFromQueue(title: String) async throws -> String? {
        // Snapshot the queue so a /next refresh that lands during
        // this method doesn't change the membership we're saving.
        let snapshot = upNext
        guard !snapshot.isEmpty else { return nil }
        guard let plid = try await innerTube.createPlaylist(title: title) else {
            return nil
        }
        var firstError: Error?
        for track in snapshot {
            do {
                try await innerTube.addToPlaylist(videoId: track.id, playlistId: plid)
            } catch {
                if firstError == nil { firstError = error }
                Log.bridge.error("savePlaylistFromQueue: add failed for \(track.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Keep going — partial-saved is better than zero-saved.
            }
        }
        if let firstError { throw firstError }
        return plid
    }

    /// "Play next" — YT Music's "insert at position 0 of the user
    /// region". Item becomes the very next track to play. The
    /// two-region model in QueueManager handles dedupe + position;
    /// PlayerBridge just triggers the pending-URL push so the JS
    /// end-of-track handler navigates to our new head.
    func playNext(item: MediaItem) {
        queue.playNext(item)
        Task {
            await tryQueueAddViaPage(videoId: item.id, position: "next")
            await syncPendingNextURL()
        }
    }

    /// "Add to queue" — YT Music's insertion at the BOTTOM of the
    /// user region (i.e. right before the first server item, NOT at
    /// the absolute end). The item plays after everything else the
    /// user has explicitly queued but before any radio / album
    /// continuation. QueueManager handles the region boundary.
    func addToQueueEnd(item: MediaItem) {
        queue.addToEnd(item)
        Task {
            await tryQueueAddViaPage(videoId: item.id, position: "end")
            await syncPendingNextURL()
        }
    }

    /// Resolve a container (album / playlist) to its ordered
    /// tracklist, or return the item itself for a song/episode.
    /// Used by the container-aware queue actions below so "Play
    /// next" / "Add to queue" on an album tile enqueues every track.
    private func resolveContainerTracks(_ item: MediaItem) async -> [MediaItem] {
        switch item.kind {
        case .playlist:
            return (try? await innerTube.playlistDetail(playlistId: item.id))?.tracks ?? []
        case .album, .podcast:
            return (try? await innerTube.detail(forBrowseId: item.id))?.tracks ?? []
        default:
            return [item]
        }
    }

    /// "Play next" for a tile of ANY kind. Songs insert directly;
    /// albums/playlists fetch their tracklist and insert the whole
    /// block at the head of the user region, in order. Returns the
    /// number of tracks queued so the caller can toast.
    @discardableResult
    func playNextResolved(_ item: MediaItem) async -> Int {
        let tracks = await resolveContainerTracks(item)
        guard !tracks.isEmpty else { return 0 }
        // Insert reversed so each head-insert leaves the block in
        // album order (track 1 ends up first).
        for track in tracks.reversed() { queue.playNext(track) }
        await syncPendingNextURL()
        return tracks.count
    }

    /// "Add to queue" for a tile of any kind. Songs append directly;
    /// albums/playlists append their whole tracklist to the end of
    /// the user region, in order.
    @discardableResult
    func addToQueueEndResolved(_ item: MediaItem) async -> Int {
        let tracks = await resolveContainerTracks(item)
        guard !tracks.isEmpty else { return 0 }
        for track in tracks { queue.addToEnd(track) }
        await syncPendingNextURL()
        return tracks.count
    }

    /// Fire the JS-side experimental Redux-dispatch path. Outcome is
    /// logged by the JS bridge via the `diagnostic` channel; we don't
    /// branch on success/failure here because the fallback path
    /// (setPendingNextURL + onStateChange===0 interception) is always
    /// armed alongside.
    private func tryQueueAddViaPage(videoId: String, position: String) async {
        let js = "window.musicBridge.queueAddViaPage(\(videoId.jsonQuoted), \(position.jsonQuoted))"
        await eval(js)
    }

    /// Push the head of upNext's watch URL to
    /// `window.__riffPendingNextUrl` so the JS end-of-track handler
    /// navigates to OUR choice instead of letting YT autoplay pick
    /// something else. The pending URL is always the visible head
    /// (userQueueCount preserves user-region order at the top by
    /// construction, so "head = user's next intent" is baked in).
    /// Empty string means "no queue — let YT autoplay do whatever
    /// it wants."
    /// How the NEXT advance to `head` should happen. Central decision
    /// shared by syncPendingNextURL and the .ended fallback so they
    /// can't disagree.
    ///
    ///   - .native: the page's own advance already plays `head` (it's
    ///     the next row of the context the page is in) — arm nothing;
    ///     forcing location.href would reload the page per track and
    ///     re-seed a fresh radio (the exact bug behind "album shows 49
    ///     random rows then falls into radio").
    ///   - .navigate(url): Swift must force the advance (true Play-Next
    ///     injections, context restoration after an interlude,
    ///     deterministic server heads).
    private enum AdvancePlan { case native, navigate(String) }
    /// The policy inputs for a candidate head — one builder so Next and
    /// end-of-track can never disagree about the same row.
    private func advanceInputs(for head: MediaItem) -> QueuePolicy.AdvanceInputs {
        .init(
            headIsContextTrack: contextTracksIds.contains(head.id),
            contextPlaylistId: contextPlaylistId,
            currentPlaylistId: currentPlaylistId,
            headIsUserQueued: queue.isUserQueued(videoId: head.id),
            hasActiveChip: activeChip != nil,
            mirrorFresh: mirrorFresh,
            isPageDriven: isPageDrivenContext,
            contextIsPageOrdered: contextIsPageOrdered
        )
    }

    private func advancePlan(to head: MediaItem) -> AdvancePlan {
        // Decision lives in QueuePolicy (pure, harness-tested); this
        // only maps the verdict to a URL.
        let verdict = QueuePolicy.advance(advanceInputs(for: head))
        switch verdict {
        case .native:
            return .native
        case .navigateIntoContext(let ctx):
            return .navigate(watchURL(videoId: head.id, playlistId: ctx))
        case .navigateRadio:
            return .navigate(watchURL(videoId: head.id, playlistId: Self.radioPlaylistId(for: head.id)))
        case .navigateDeterministic:
            let plid: String
            if let ctx = currentPlaylistId, !ctx.isEmpty, !ctx.hasPrefix("RDAMVM") {
                plid = ctx
            } else {
                plid = Self.radioPlaylistId(for: head.id)
            }
            return .navigate(watchURL(videoId: head.id, playlistId: plid))
        }
    }

    private func syncPendingNextURL() async {
        let curId = currentTrack?.videoId
        let head = upNext.first { $0.id != curId }
        let url: String
        if let chosen = head {
            switch advancePlan(to: chosen) {
            case .native:             url = ""
            case .navigate(let dest): url = dest
            }
        } else {
            url = ""
        }
        Log.bridge.debug("syncPendingNextURL → \(url, privacy: .public)")
        // Mirror what we're pushing to JS so the ended handler can
        // decide whether Swift's fallback advance is needed. Empty
        // string means "clear" — JS falls back to YT's autoplay, and
        // Swift's belt-and-braces should DO nothing (YT's autoplay
        // is the intended behavior at that point).
        pendingNextURLArmed = !url.isEmpty
        await eval("window.musicBridge.setPendingNextURL(\(url.jsonQuoted))")
    }

    /// Explicitly start the auto-radio for `item` — same flow as
    /// `play(item:)` since RDAMVM is our default. Kept as a separate
    /// entry point so context-menu code reads naturally and so we can
    /// later differentiate "play in album context" vs "start radio"
    /// without touching every call site.
    func startRadio(for item: MediaItem) async {
        await play(item: item)
    }

    /// Remove a track from the local Up Next list. Doesn't (yet) sync the
    /// removal to YT Music's server-side queue — InnerTube's queue-mutation
    /// endpoint isn't documented for our client; the WebView's queue still
    /// holds the original list. Treat this as a local-UX hint until we
    /// implement a JS bridge into the page's queue API.
    /// "Jump to this row in Up Next" — used by row-tap in the
    /// queue UI and by the shuffle branch of `next()`. Removes
    /// the item from `upNext` FIRST, then plays with
    /// `clearQueue: false`. This makes the subsequent
    /// `consumeUpTo(item.id)` in the trackChanged handler a
    /// no-op, which preserves every row that was ABOVE the tap —
    /// user-queued or otherwise.
    ///
    /// Without this pre-remove, `consumeUpTo` pops `[0…tappedIdx]`
    /// inclusive: taps deep in the queue would silently drop
    /// every intervening row (C1).
    func skipTo(item: MediaItem) async {
        // Row tap / Next is user intent: the tapped track must not be
        // force-paused by a sleep-timer / autoplay-off stop window.
        pauseEnforceUntil = .distantPast
        // Single-authority: a tapped row of a PAGE-OWNED queue plays in
        // place via the page's own queue (no navigation). The old path
        // navigated — a page reload that re-rolled the radio and replaced
        // the whole list, when the user expected the list to continue
        // from the tapped row. Scoped to mirrored rows (the page has
        // them); user-region rows keep the context-preserving navigation.
        if QueuePolicy.rowTapUsesPageJump(
            hasActiveChip: activeChip != nil, mirrorFresh: mirrorFresh,
            rowIsUserQueued: queue.isUserQueued(videoId: item.id),
            rowIsInQueue: upNext.contains(where: { $0.id == item.id })) {
            userClickedAt = Date()   // user intent; arrival ≠ old head is expected
            pendingJumpTarget = item.id
            Audit.note("skipTo: page-queue jump → \(item.id)")
            await eval("window.musicBridge.queuePlayItem(\(item.id.jsonQuoted))")
            // Verify by arrival: if the page didn't jump (row not
            // rendered / selector drift), fall back to navigation so the
            // tap always does SOMETHING — at the cost of a re-roll.
            let target = item
            jumpVerifyTask?.cancel()
            jumpVerifyTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                // `try?` swallows CancellationError, so check explicitly:
                // a cancelled verifier (matching arrival, or a navigation
                // superseding the tap) must never toast.
                guard !Task.isCancelled else { return }
                // Only verify the jump the user is still waiting on — a
                // consumed or superseded target means the tap resolved
                // (or the user deliberately played something else).
                guard let self,
                      self.pendingJumpTarget == target.id,
                      self.currentTrack?.videoId != target.id else { return }
                // Genuine miss: drop the target so a LATER natural
                // arrival of the same id is audited as match/MISMATCH,
                // not mislabelled "jump (row tap)".
                self.pendingJumpTarget = nil
                // NON-destructive fallback. Navigating here reloads the
                // page and RE-ROLLS the radio — replacing the entire list
                // the user was looking at, which is worse than a tap that
                // didn't take. Tell them and keep the queue intact; the
                // diagnostic line names which strategy missed.
                Log.bridge.error("skipTo: page didn't jump to \(target.id, privacy: .public) in 2.5s — keeping queue intact (no navigation)")
                self.onJumpFailed?(target)
            }
            return
        }
        queue.remove(videoId: item.id)
        await play(item: item, clearQueue: false)
    }

    /// "Clear" button on the Up Next header. Empties both queue regions
    /// (playing track unaffected) and resyncs the JS pending-next URL so
    /// end-of-track doesn't navigate to a head that no longer exists —
    /// with an empty queue the sync pushes "" and YT's own autoplay
    /// takes over, matching YT Music's clear-queue behavior.
    func clearUpNext() async {
        queue.clearQueue()
        await syncPendingNextURL()
    }

    func removeFromQueue(videoId: String) async {
        // QueueManager.remove updates the region boundary if the
        // removed row was inside the user region — no separate
        // bookkeeping needed here.
        queue.remove(videoId: videoId)
        pageOwnedQueuedIds.remove(videoId)
        // Phase B: also remove from the PAGE's queue so its autoplay
        // can't play a row the user deleted. Verified via
        // queueRemoveResult; on failure the local removal stands as a
        // display-only hint (pre-Phase-B behavior) — the mirror's next
        // snapshot would resurface a row the page still intends to
        // play, which is truthful even if unwelcome.
        if activeChip == nil {
            await eval("window.musicBridge.queueRemoveViaPage(\(videoId.jsonQuoted))")
        }
        await syncPendingNextURL()
    }

    /// Local-only reorder. Same caveat as removeFromQueue: this only
    /// affects the Up Next list Riff displays, not the WebView's actual
    /// playback queue. Useful for users who want to inspect / curate
    /// what's coming up.
    func moveInQueue(videoId: String, by offset: Int) {
        queue.move(videoId: videoId, by: offset)
    }

    /// Drag-drop reorder pass-through. `visibleIds` is the id order
    /// as the view currently renders it (`upNext` post-filter for
    /// current-track / chip mode); `source` / `destination` are the
    /// SwiftUI `.onMove` args in that same coordinate space.
    func reorderQueue(visibleIds: [String], from source: IndexSet, to destination: Int) {
        queue.reorder(visibleIds: visibleIds, from: source, to: destination)
    }

    // MARK: - Sleep timer

    /// How the sleep timer ends playback when the countdown hits zero.
    ///
    /// - `hardStop`: immediate pause (original behavior; Spotify
    ///   desktop, YT Music mobile default).
    /// - `fadeOut`: ramp `<video>.volume` from the user's current level
    ///   down to 0 over `fadeOutDuration` seconds, then pause and
    ///   restore the user's volume. Mirrors Apple Music's sleep fade.
    /// - `endOfTrack`: stop on the next `.ended` event so the current
    ///   track plays out cleanly. Niche but loved by audiophiles —
    ///   neither Spotify nor YT Music desktop ship it.
    enum SleepTimerMode: Sendable, Hashable, CaseIterable {
        case hardStop
        case fadeOut
        case endOfTrack
    }

    /// Seconds remaining before the sleep timer fires, or nil when no
    /// timer is set. Updated once per second by `sleepTimerTask` so
    /// the UI can display a live countdown.
    private(set) var sleepTimerRemaining: TimeInterval? = nil

    /// Mode for the currently-armed sleep timer. `nil` when no timer
    /// is set. The next call to `setSleepTimer(minutes:mode:)`
    /// overwrites it; `cancelSleepTimer` clears it.
    private(set) var sleepTimerMode: SleepTimerMode? = nil

    /// Set to `true` once the countdown of an `endOfTrack` timer has
    /// elapsed and we are waiting for the current track's `.ended`
    /// event to pause. The `.ended` handler reads + clears this flag.
    private(set) var endOfTrackArmed: Bool = false

    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?

    /// Duration of the `.fadeOut` ramp once the timer expires.
    static let fadeOutDuration: TimeInterval = 10

    /// Arm a sleep timer that pauses playback after `minutes`. Replaces
    /// any existing timer. Intentionally not persisted across launches
    /// — sleep timers are session-scoped by every other player's
    /// convention (Apple Music, YT Music mobile, Spotify).
    func setSleepTimer(minutes: Int, mode: SleepTimerMode = .hardStop) {
        cancelSleepTimer()
        let totalSeconds = TimeInterval(minutes * 60)
        sleepTimerRemaining = totalSeconds
        sleepTimerMode = mode
        let startedAt = Date()
        sleepTimerTask = Task { [weak self] in
            // Tick once per second so the UI shows live countdown.
            // Loop instead of one big sleep so cancellation is prompt.
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                let remaining = max(0, totalSeconds - elapsed)
                await MainActor.run { self?.sleepTimerRemaining = remaining }
                if remaining <= 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // Run the mode INSIDE this tracked task (PlayerBridge is
            // @MainActor, so the task already runs on the main actor).
            // It used to hop into an untracked inner Task, so cancelling
            // mid-fade cancelled nothing: the ramp kept going and then
            // paused playback after the user had cancelled the timer.
            guard let self, !Task.isCancelled else { return }
            await self.fireSleepTimer(mode: mode)
        }
    }

    /// Execute the chosen sleep-timer mode. Called from `sleepTimerTask`
    /// when the countdown reaches zero. Extracted so each mode can be
    /// reasoned about in isolation.
    private func fireSleepTimer(mode: SleepTimerMode) async {
        switch mode {
        case .hardStop:
            if isPlaying {
                await togglePlay()
            }
            clearSleepTimerState()
        case .fadeOut:
            await runVolumeFade(duration: Self.fadeOutDuration)
            // Cancelled mid-fade (cancelSleepTimer, or a new timer
            // replacing this one): the canceller already restored the
            // volume and cleared the state — possibly for a NEW timer —
            // so don't pause, re-push volume or clear anything.
            guard !Task.isCancelled else { return }
            if isPlaying {
                await togglePlay()
            }
            // Restore the user's persisted volume to the JS side so the
            // next play resumes at the level they expect. We didn't
            // touch `self.volume` during the ramp — only the raw
            // `<video>.volume` — so this is a single re-push.
            await evalWithTimeout(js: "window.musicBridge.setVolume(\(volume))")
            clearSleepTimerState()
        case .endOfTrack:
            // Don't pause yet; let the current track play out. The
            // `.ended` event handler observes `endOfTrackArmed` and
            // closes the loop. We intentionally keep
            // `sleepTimerMode == .endOfTrack` set so the UI can show
            // "ending after track" rather than pretending we're idle.
            endOfTrackArmed = true
            sleepTimerRemaining = nil
            // Disarm the JS pending-next URL: its onStateChange handler
            // navigates SYNCHRONOUSLY on ended — before our .ended pause
            // can land — so an armed URL would start the next track and
            // the "stop after this track" timer would play all night.
            // If the timer is cancelled, syncPendingNextURL re-arms on
            // the next queue mutation / track change.
            pendingNextURLArmed = false
            await eval("window.musicBridge.setPendingNextURL(\"\")")
            // Repeat One is `<video>.loop`, and a looping element never
            // reaches end-of-stream — `.ended` would never arrive and the
            // timer would play all night. Lift the loop for the rest of
            // this track WITHOUT touching the user's repeatMode;
            // clearSleepTimerState re-arms it (cancel or completion), and
            // the page-load re-apply / toggleRepeat skip it while armed.
            // `endOfTrackArmed` is re-checked after the await above: a
            // cancel in between already cleared it and queued the restore.
            if repeatMode == .one && endOfTrackArmed {
                await eval("window.musicBridge.setRepeatLoop(false)")
            }
        }
    }

    /// 10-step linear ramp on `<video>.volume`. We multiply the user's
    /// current volume by an interpolated factor (1.0 → 0.0) rather than
    /// writing absolute levels — that way the audible fade scales with
    /// whatever level the user picked.
    private func runVolumeFade(duration: TimeInterval) async {
        let steps = 10
        let userVolume = volume
        let stepNs = UInt64((duration / Double(steps)) * 1_000_000_000)
        for i in 1...steps {
            if Task.isCancelled { return }
            let factor = Double(steps - i) / Double(steps)
            let level = max(0.0, min(1.0, userVolume * factor))
            await evalWithTimeout(js: "window.musicBridge.setVolume(\(level))")
            try? await Task.sleep(nanoseconds: stepNs)
        }
    }

    /// Reset all sleep-timer state. Called both from `cancelSleepTimer`
    /// (user-initiated) and at the tail of `fireSleepTimer` (timer
    /// completed naturally).
    private func clearSleepTimerState() {
        let wasEndOfTrack = endOfTrackArmed
        sleepTimerTask = nil
        sleepTimerRemaining = nil
        sleepTimerMode = nil
        endOfTrackArmed = false
        // endOfTrack arming disarmed the JS pending-next URL; restore it
        // so a cancelled timer doesn't leave queued songs un-enforced.
        // It also lifted the Repeat One loop — give it back (read at run
        // time, so a repeat toggle in between is honored).
        if wasEndOfTrack {
            Task { [weak self] in
                guard let self else { return }
                if self.repeatMode == .one && !self.endOfTrackArmed {
                    await self.eval("window.musicBridge.setRepeatLoop(true)")
                }
                await self.syncPendingNextURL()
            }
        }
    }

    func cancelSleepTimer() {
        // If the user cancels mid-fade, push the persisted volume back
        // to the JS side so we don't leave audio stuck at a partially-
        // ramped-down level. Cheap and idempotent for the other modes.
        let wasFading = sleepTimerMode == .fadeOut && sleepTimerTask != nil
        sleepTimerTask?.cancel()
        let restoreVolume = volume
        if wasFading {
            Task { await self.evalWithTimeout(js: "window.musicBridge.setVolume(\(restoreVolume))") }
        }
        clearSleepTimerState()
    }

    /// Volume 0.0...1.0. Persisted across track changes within the session
    /// (defaults to 1.0 on launch, the WebView's natural state).
    private(set) var volume: Double = 1.0
    func setVolume(_ level: Double) async {
        let clamped = max(0.0, min(1.0, level))
        volume = clamped
        UserDefaults.standard.set(clamped, forKey: Self.volumeKey)
        await eval("window.musicBridge.setVolume(\(clamped))")
    }

    /// Approximate per-track loudness normalization. JS-side measures
    /// ~5s of RMS post-skip and scales a Web Audio GainNode toward
    /// -18 dBFS. Off by default — the toggle lives in Settings →
    /// Playback. The native `<video>.volume` (driven by `setVolume`)
    /// still works as the user-facing volume; both attenuations
    /// multiply through the audio path.
    private(set) var normalizationEnabled: Bool = false
    func setNormalizationEnabled(_ enabled: Bool) async {
        normalizationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.normalizationKey)
        await eval("window.musicBridge.setNormalizationEnabled(\(enabled))")
    }

    /// Autoplay ("Enhance"). When ON (default), the queue
    /// auto-extends with related/radio tracks as it nears the end,
    /// so music never stops — matching Spotify/Apple Music. When
    /// OFF, playback stops when the queue is exhausted. Gates the
    /// threshold-refetch in the trackChanged handler.
    private(set) var autoplayEnabled: Bool = true
    func setAutoplayEnabled(_ enabled: Bool) {
        autoplayEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoplayKey)
    }

    /// Crossfade between tracks (Tier 3 B8). 0 disables; supported
    /// presets are 0 / 2 / 4 / 6 / 8 seconds (Apple Music's default
    /// is ~6s). Persisted across launches. All ramp arithmetic lives
    /// in `Resources/player-bridge.js` — see `__riffXfade` there.
    /// The Swift side just owns the setting and pushes it to the JS
    /// bridge on every change and on every page reload.
    private(set) var crossfadeSeconds: Double = 0
    static let crossfadePresets: [Double] = [0, 2, 4, 6, 8]
    static func clampCrossfade(_ raw: Double) -> Double {
        // Snap to nearest supported preset rather than clamp to a
        // continuous range — settings UI only offers the discrete
        // presets, and we never want a corrupted plist to leave us
        // with a 1.7-second fade.
        guard raw.isFinite else { return 0 }
        return crossfadePresets.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 0
    }
    func setCrossfadeSeconds(_ seconds: Double) async {
        let snapped = Self.clampCrossfade(seconds)
        crossfadeSeconds = snapped
        UserDefaults.standard.set(snapped, forKey: Self.crossfadeKey)
        await eval("window.musicBridge.setCrossfadeSeconds(\(snapped))")
    }

    /// Per-call timeout for JS evaluation. A hung WKWebView (e.g. an
    /// unresponsive page) shouldn't leave our awaiting Task pending forever
    /// — that's how UI commands silently stop working without an error to
    /// surface. 5s is generous: a healthy bridge resolves in <50ms.
    private static let jsEvalTimeoutSeconds: UInt64 = 5

    private func eval(_ js: String) async {
        guard bridgeReady else {
            pendingCommands.append(js)
            return
        }
        await evalWithTimeout(js: js)
    }

    private func flushPending() async {
        let cmds = pendingCommands
        pendingCommands.removeAll()
        for cmd in cmds {
            await evalWithTimeout(js: cmd)
        }
    }

    /// Race the JS eval against a timeout via a single-resume
    /// continuation. The old task-group version could NOT time out: a
    /// Task suspended on WebKit's completion-handler continuation
    /// isn't released by cancel(), and withTaskGroup implicitly awaits
    /// every remaining child — so on a wedged page the group (and
    /// every `await eval` caller behind it) stayed suspended forever
    /// while the log claimed the timeout fired. Here whichever side
    /// finishes first resumes the caller; a late eval completion is
    /// simply ignored (WebKit still runs it — the orphaned callback
    /// costs nothing). We don't surface the timeout as an error
    /// (callers `try?`'d the original) but we log it so a hung bridge
    /// is debuggable.
    private func evalWithTimeout(js: String) async {
        let webView = webBridge.webView
        let timeoutNs = Self.jsEvalTimeoutSeconds * 1_000_000_000
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The body runs synchronously in this method's MainActor
            // context; Swift 5.10's withCheckedContinuation doesn't
            // carry that isolation formally, so assert it to talk to
            // WebKit.
            MainActor.assumeIsolated {
                let gate = EvalResumeGate()
                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: timeoutNs)
                    guard gate.claim() else { return }
                    Log.bridge.debug("eval timed out after \(Self.jsEvalTimeoutSeconds)s; js prefix=\(js.prefix(80), privacy: .public)")
                    continuation.resume()
                }
                webView.evaluateJavaScript(js) { _, _ in
                    // Completion lands on the main thread; hop through
                    // a MainActor task so the gate stays actor-bound.
                    Task { @MainActor in
                        guard gate.claim() else { return }
                        timeoutTask.cancel()
                        continuation.resume()
                    }
                }
            }
        }
    }

    // MARK: - Event handling

    private func handle(_ event: HiddenPlayerWebView.BridgeEvent) {
        switch event {
        case .pageInfo(let info):
            // Handshake — posted once per DOCUMENT, immediately before
            // `ready`, and re-posted by every navigate() (each is a
            // full page load). Deliberately its own case OUTSIDE the
            // `.ready` first-time gate: the protocol override must
            // refresh per document, not once per app run.
            //
            // The page's live clientVersion overrides the
            // hand-maintained constant; the value is untrusted page
            // input headed for an HTTP header, so InnerTubeClient
            // validates it and falls back to the constant otherwise.
            // sessionIndex / hl / gl / visitorData ride along
            // informationally only (the review refuted redirecting
            // X-Goog-AuthUser: in-app sign-in yields a single-account
            // jar), and visitorData arrives pre-redacted as a length —
            // the diagnostics export promises "no secrets".
            InnerTubeClient.updatePageClientVersion(info.clientVersion)
            if info.generation != lastPageInfoGeneration {
                lastPageInfoGeneration = info.generation
                let caps: String = info.capabilities
                    .sorted(by: { $0.key < $1.key })
                    .map { "\($0.key)=\($0.value ? 1 : 0)" }
                    .joined(separator: " ")
                Log.bridge.notice("pageInfo schema=\(info.schema) clientVersion=\(info.clientVersion, privacy: .public) sessionIndex=\(info.sessionIndex, privacy: .public) hl=\(info.hl, privacy: .public) gl=\(info.gl, privacy: .public) visitorDataLen=\(info.visitorDataLength) caps: \(caps, privacy: .public) selectors: \(info.selectorSummary, privacy: .public)")
            }
        case .ready:
            // `ready` fires once per DOCUMENT, and every navigate() is a
            // full `location.href` load: the user script re-runs with a
            // fresh <video> (loop off, rate 1.0, the page's own stored
            // volume), a fresh `__riffXfade` (0 s) and `__riffNorm` (off).
            // Queued commands flush only on the FIRST ready (after it,
            // eval() goes straight through), but the persisted prefs are
            // re-applied on EVERY ready — gating them with the flush made
            // the second page silently drop Repeat One / crossfade /
            // normalization / rate / volume while the UI showed them on.
            // Audit token distinct from the raw per-event "… ready" line
            // (HiddenPlayerWebView logs that one at debug): fieldcheck
            // counts THIS token as a page reload when grading a journal
            // export, and must never double-count a live capture that
            // carries both lines.
            Audit.note("page ready → bridge armed")
            let isFirstReady = !bridgeReady
            bridgeReady = true
            Task { [weak self] in
                guard let self else { return }
                if isFirstReady {
                    await self.flushPending()
                }
                // Re-apply persisted prefs to the freshly-loaded page.
                // Volume and rate unconditionally (cheap, idempotent): at
                // 100% the new document would otherwise keep YT Music's
                // own stored player volume, and the current kind's rate
                // (spoken-word 1.25×, or a reset back to 1.0×) must
                // re-arm too. setVolume runs first so it seeds the fresh
                // `__riffXfade.userVolume` before crossfade can ramp.
                await self.evalWithTimeout(js: "window.musicBridge.setVolume(\(self.volume))")
                await self.evalWithTimeout(js: "window.musicBridge.setPlaybackRate(\(self.playbackRate))")
                // Repeat One = the new element's `loop` attribute (off
                // by default). Skipped while an end-of-track sleep timer
                // is armed: arming lifted the loop so the track can end
                // (clearSleepTimerState restores it).
                if self.repeatMode == .one && !self.endOfTrackArmed {
                    await self.evalWithTimeout(js: "window.musicBridge.setRepeatLoop(true)")
                }
                if self.normalizationEnabled {
                    await self.evalWithTimeout(js: "window.musicBridge.setNormalizationEnabled(true)")
                }
                // Re-arm crossfade on every page (re)load. Cheap
                // no-op when seconds == 0; idempotent otherwise.
                if self.crossfadeSeconds > 0 {
                    await self.evalWithTimeout(js: "window.musicBridge.setCrossfadeSeconds(\(self.crossfadeSeconds))")
                }
            }
        case .stateChanged(let playing):
            isPlaying = playing
            // Pause enforcement: after a sleep-timer end-of-track or an
            // autoplay-off end-of-queue pause, the page can natively
            // start the next track anyway. Any playback that starts
            // before the deadline is force-paused (forcePause, not
            // togglePlay — every user transport, togglePlay included,
            // CLEARS the window, so the user can always override; see
            // `pauseEnforceUntil`).
            if playing, Date() < pauseEnforceUntil {
                Log.bridge.debug("stateChanged(playing) inside pause-enforce window → forcing pause")
                Task { [weak self] in await self?.forcePause() }
            }
            if !playing {
                // Exact position on pause: the periodic snapshot can
                // lag by up to `snapshotEverySeconds`, and
                // `willTerminate` never fires on a crash, force-quit,
                // or power loss. Pausing is the natural "done for now"
                // signal, so persist the precise elapsed time — and,
                // for spoken content, the episode resume position —
                // right here. Both writes are cheap UserDefaults sets;
                // no navigation, no page interaction.
                snapshotSession()
                if let vid = currentTrack?.videoId {
                    trackEpisodePosition(videoId: vid, elapsed: elapsed, duration: duration, force: true)
                }
            }
        case .ended:
            // Track reached end-of-stream. If an `endOfTrack` sleep
            // timer is armed, pause now and short-circuit the normal
            // autoplay handoff — we don't want a "Play next" item to
            // sneak in and start the next track right as we're trying
            // to fall asleep. Otherwise, if the user explicitly queued
            // a track via "Play next" / "Add to queue", play it now.
            // The race against YT Music's natural autoplay (which also
            // fires on the same video.ended) is now won proactively in
            // the JS bridge — see setPendingNextURL below; this
            // Swift-side handler is a belt-and-braces fallback for the
            // case where the JS interception didn't fire (e.g. user
            // clicked Play next within a few ms of end-of-stream and
            // we didn't have time to push the URL).
            Log.bridge.debug(".ended fired; upNextHeadIds=\(self.upNext.prefix(3).map(\.id), privacy: .public) userQueueCount=\(self.queue.userQueueCount) endOfTrackArmed=\(self.endOfTrackArmed, privacy: .public)")
            if endOfTrackArmed {
                Task { [weak self] in
                    guard let self else { return }
                    await self.forcePause()
                    // The page may still natively advance and start the
                    // next track; enforce silence for the next 12s.
                    self.pauseEnforceUntil = Date().addingTimeInterval(12)
                    self.clearSleepTimerState()
                }
            } else {
                let curId = self.currentTrack?.videoId
                let head = upNext.first(where: { $0.id != curId })
                // "The context is over" in the mirror world: the queue
                // may never literally drain (the page pads album/playlist
                // ends with automix radio rows, and the mirror shows
                // them). The context is exhausted when the finishing
                // track IS a context track, the user region is empty,
                // and the next shown row is NOT a context track (i.e.
                // only autoplay filler remains).
                let contextExhausted = QueuePolicy.contextExhausted(
                    userQueueCount: queue.userQueueCount, contextTrackIds: contextTracksIds,
                    currentId: currentTrack?.videoId, headId: head?.id)
                // Repeat All: context over → cycle it. The cycle is
                // everything played since this context started plus the
                // track that just finished, in original order. Runs
                // before the autoplay fallbacks so YT's radio doesn't
                // take over at the end of an album on repeat.
                if repeatMode == .all, head == nil || contextExhausted {
                    let start = min(contextStartHistoryIndex, queue.playedEntries.count)
                    var cycle = queue.playedEntries[start...].map(\.item)
                    if let cur = currentTrack {
                        cycle.append(MediaItem(
                            id: cur.videoId, kind: .song, title: cur.title,
                            subtitle: cur.subtitle, thumbnailURL: cur.thumbnailURL,
                            albumId: cur.albumId, artistId: cur.artistId
                        ))
                    }
                    // Dedupe by id, preserving first occurrence order.
                    var seen = Set<String>()
                    let ordered = cycle.filter { seen.insert($0.id).inserted }
                    if !ordered.isEmpty {
                        Log.bridge.debug(".ended → Repeat All: cycling \(ordered.count) tracks")
                        Task { [weak self] in
                            await self?.playTracks(ordered, playlistId: nil)
                        }
                        return
                    }
                }
                // Autoplay OFF + nothing left (or only autoplay filler
                // left) → stop, matching the Settings copy ("stop at
                // the end of the current queue or album"). Without this
                // the page drifts into its own radio at album end
                // regardless of the setting.
                if !autoplayEnabled, head == nil || contextExhausted {
                    Log.bridge.debug(".ended → autoplay off, queue drained → pausing")
                    Task { [weak self] in
                        guard let self else { return }
                        await self.forcePause()
                        self.pauseEnforceUntil = Date().addingTimeInterval(12)
                    }
                    return
                }
                if !pendingNextURLArmed {
                    // JS had nothing armed. Either the page's native
                    // advance covers the head (.native — album context /
                    // mirrored radio row: force-playing would reload the
                    // page per track), or Swift must drive (.navigate).
                    // Same advancePlan as syncPendingNextURL so the two
                    // paths can't disagree.
                    if let head, case .navigate = advancePlan(to: head) {
                        Task { [weak self] in
                            await self?.play(item: head, clearQueue: false)
                            Audit.note(".ended → Swift fallback played head=\(head.id)")
                        }
                    }
                } else {
                    // JS is armed to navigate to the displayed head via
                    // the pending URL. Trust it here — but the
                    // AUTHORITATIVE WYSIWYG enforcement lives in the
                    // trackChanged handler, not here: YT Music's MSE
                    // pipeline frequently does NOT emit a reliable ENDED
                    // (see player-bridge.js header), so this branch may
                    // never run for a radio advance. Whatever ends up
                    // playing surfaces as a trackChanged, and that's
                    // where we reconcile against the shown queue.
                    pendingNextURLArmed = false
                    Audit.note(".ended → JS armed via pending URL; WYSIWYG reconciled in trackChanged")
                }
            }
        case .queueAddResult(let videoId, let position, let ok, let via):
            // Phase B self-migration (docs/QUEUE-DESIGN.md): a VERIFIED
            // page-queue add means the page now owns the item — its own
            // autoplay will play it at the right slot, and the mirror
            // will display it. Drop Swift's fallback copy so the two
            // authorities can't fight. Per-id and order-safe with
            // multiple queued items: dispatches insert at the
            // then-selected+1 in call order, which reproduces exactly
            // the ordering playNext/addToEnd built Swift-side. Items
            // whose add did NOT verify stay in the user region and keep
            // the proven fallback. Chip contexts keep Swift ownership.
            if ok, activeChip == nil,
               queue.isUserQueued(videoId: videoId) {
                queue.remove(videoId: videoId)
                pageOwnedQueuedIds.insert(videoId)
                Task { [weak self] in await self?.syncPendingNextURL() }
                Audit.note("queueAddResult VERIFIED (\(position) via \(via)) → page owns \(videoId); Swift fallback dropped")
            } else {
                Audit.note("queueAddResult ok=\(ok) pos=\(position) via=\(via) id=\(videoId) (fallback retained)")
            }
        case .queueRemoveResult(let videoId, let ok, let via):
            Audit.note("queueRemoveResult ok=\(ok) via=\(via) id=\(videoId)")
            // On ok the JS re-emits the mirror (display already updated
            // locally). On failure the page still holds the row and WILL
            // play it: put it back on screen NOW (a change-gated snapshot
            // would only arrive at the next page change — the field log
            // showed the "removed" row playing next) and say so.
            // `not-in-items` is NOT a failure: it is the expected answer
            // for a Swift-owned row the page never held (unverified Play
            // Next, a Repeat-All cycle, an AI-built list). The page can't
            // play a row it doesn't have, so the local removal is the
            // whole truth — no toast, no forced re-snapshot.
            let absentFromPage = via == "not-in-items"
            if !ok, !absentFromPage, activeChip == nil {
                Task { [weak self] in await self?.eval("window.musicBridge.requestQueueSnapshot()") }
                onRemoveFailed?(videoId)
            }
        case .queueSnapshot(let items, let pageShuffle):
            // Page-driven contexts: the page's shuffle state is the
            // truth — a lit local shuffle icon the display can't honor
            // is exactly what produced "queue order seems off".
            if isPageDrivenContext, let pageShuffle, pageShuffle != shuffleEnabled {
                shuffleEnabled = pageShuffle
                UserDefaults.standard.set(pageShuffle, forKey: Self.shuffleKey)
                Log.bridge.debug("queueSnapshot: synced shuffle from page → \(pageShuffle, privacy: .public)")
            }
            // PHASE 2 radio truth: mirror the page's OWN queue into the
            // server region. Radio queues are non-deterministic — an
            // independent /next fetch shows a different radio than the
            // page plays — so the store snapshot is the only correct
            // source. Deterministic contexts (albums/playlists) keep
            // the /next fetch, whose rows are richer (album/artist ids),
            // and chip-tuned queues are Riff-curated (page-unaware).
            // Phase C: the mirror is the display truth in EVERY context
            // except chip-tuned queues (Riff-curated; the page doesn't
            // know the chip). Deterministic contexts included — the page
            // queue in an album/playlist context IS the album/playlist.
            guard QueuePolicy.mirrorApplies(hasActiveChip: activeChip != nil,
                                            userQueueCount: queue.userQueueCount) else { break }
            // While the user region has items, the USER'S list is the
            // queue — repainting radio filler beneath it on every poll
            // is churn ("queue changes dynamically"), and those rows
            // wouldn't play until the user region drains anyway. The
            // mirror resumes automatically once it does.
            let curId = currentTrack?.videoId
            // Staleness gate: a snapshot posted by the OLD page can be
            // delivered after a navigation reset the queue — mirroring it
            // would fill the fresh context with the previous radio's rows.
            // The page's queue always contains its own current track, so
            // a snapshot that doesn't know our current track is not from
            // our page: drop it (the new page emits within ~2s).
            if let curId, !items.contains(where: { $0.videoId == curId }) {
                Audit.note("queueSnapshot: dropped stale snapshot (no \(curId) among \(items.count) rows)")
                break
            }
            // Upcoming = rows after the page's selected row; fall back
            // to slicing after the current videoId when no row is
            // marked (briefly true right after a navigation).
            var upcomingRows = items
            if let selIdx = items.lastIndex(where: { $0.selected }) {
                upcomingRows = Array(items[items.index(after: selIdx)...])
            } else if let curId, let curIdx = items.lastIndex(where: { $0.videoId == curId }) {
                upcomingRows = Array(items[items.index(after: curIdx)...])
            }
            let mapped: [MediaItem] = upcomingRows
                .filter { $0.videoId != curId }
                .map {
                    MediaItem(id: $0.videoId, kind: .song, title: $0.title,
                              subtitle: $0.byline, thumbnailURL: $0.thumbnailURL)
                }
                .filter { !shouldBlock($0) }
            queue.replaceServerRegion(mapped)
            mirrorFresh = true
            // Re-evaluate the armed pending-next URL now that its
            // policy inputs changed (mirrorFresh just flipped, and
            // replaceServerRegion may have changed the head): a /next
            // refresh that raced the page's FIRST snapshot armed
            // `.navigateDeterministic` while !mirrorFresh, and the JS
            // onStateChange===0 handler would consume that URL at
            // track end — a full location.href reload per advance in a
            // URL-started playlist (contract items 2/7). The verdict
            // is `.native` now, so the re-sync pushes "" and clears
            // it; when Riff still owns the advance it re-points the
            // URL at the mirror's real head. Mirrors the
            // replace-then-sync pattern in refreshNextQueueAndIds.
            Task { [weak self] in await self?.syncPendingNextURL() }
            // Mirrored rows are the page's, not Smart Shuffle's — clear
            // stale injection ids so no mirrored row whose id happens to
            // match an old injection wears a false "+" badge.
            if !smartShuffleInjectedIds.isEmpty { smartShuffleInjectedIds = [] }
            // head3: the first shown rows, by id — lets a log capture
            // verify WYSIWYG (next trackChanged id should equal head3[0]).
            Audit.note("queueSnapshot → mirrored \(mapped.count) rows (of \(items.count)); head3=\(mapped.prefix(3).map(\.id).joined(separator: ","))")
        case .progress(let t, let d):
            // Filter stale events that arrive in the window right after a
            // track change. YT Music's SPA can keep firing `timeupdate`
            // events with the previous track's currentTime/duration for
            // ~500-1000ms before the new media source loads — without this
            // guard the scrubber jumps to the previous track's tail.
            let inGrace = Date().timeIntervalSince(lastTrackChangeAt) < Self.trackChangeGraceSeconds
            if inGrace, t > 5 {
                return
            }
            // Sanitize before publishing. `<video>.duration` is NaN until a
            // new track's metadata loads and can report ±inf on edge builds;
            // a non-finite value poisons every scrubber Range/Slider
            // downstream (0...NaN traps). Store 0 in that window — the UI
            // treats a 0/unknown duration as "not ready yet".
            let durationWasUnknown = duration <= 0
            elapsed = t.isFinite ? t : 0
            duration = (d.isFinite && d > 0) ? d : 0
            if let vid = currentTrack?.videoId {
                // Session-resume seek (armed by togglePlay). Checked
                // INDEPENDENTLY of `durationWasUnknown`: on the resume
                // path `duration` starts at the restored snapshot value
                // (> 0), so the was-unknown transition may never happen.
                // The duration-match guard excludes pre-roll ads — an
                // ad <video>'s timeupdate can precede the ad's own
                // trackChanged, so `vid` alone is not proof we're
                // looking at the saved track. Runs BEFORE the episode
                // resume and marks it applied, so a spoken track with
                // both a session snapshot and an episodePositions entry
                // gets one seek, not two.
                if let r = pendingResumeSeek, r.videoId == vid, duration > 0,
                   r.duration <= 0 || abs(duration - r.duration) < 2,
                   r.elapsed < duration - 5 {
                    pendingResumeSeek = nil
                    resumeAppliedFor = vid
                    let fraction = r.elapsed / duration
                    Log.bridge.debug("session resume: seeking \(vid, privacy: .public) to \(Int(r.elapsed))s on first matching progress")
                    Task { [weak self] in await self?.seek(to: fraction) }
                }
                if durationWasUnknown, duration > 0 {
                    applyEpisodeResumeIfNeeded(videoId: vid, duration: duration)
                }
                trackEpisodePosition(videoId: vid, elapsed: elapsed, duration: duration)
            }
            // Snapshot for "Continue where you left off" — rate-limited
            // to one write per `snapshotEverySeconds` so we're not
            // writing UserDefaults every 500 ms.
            snapshotSessionIfDue()
            // Prefetch the next track's artwork so the mini-player /
            // Now Playing hero swap is instant on advance. Fires
            // once per track at 85% elapsed; guarded by a
            // per-videoId sentinel so we don't re-warm on every
            // progress tick after the threshold.
            prefetchNextArtworkIfDue()
        case .trackChanged(let id, let playlistId, let title, let artist, let art):
            let sameVideoId = currentTrack?.videoId == id
            let titleChanged = currentTrack?.title != title
            let withinClickGrace = Date().timeIntervalSince(userClickedAt) < Self.userClickGraceSeconds

            // STRICT WYSIWYG enforcement for autoplay advances.
            //
            // The next track that plays MUST be the HEAD of the queue
            // we're showing. YT Music's native autoplay is an
            // independent source — after a user-queued song it continues
            // THAT song's radio, which is unrelated to the server region
            // we're displaying — so on a natural advance it can land on:
            //   • a track nowhere in our list ("random song"), or
            //   • a track DEEPER in our list, skipping the head.
            // Both violate "what you see is what plays next"; we snap to
            // the shown head instead. This is the authoritative guard:
            // YT's MSE pipeline frequently does NOT emit a reliable ENDED
            // (see player-bridge.js header), so the pending-URL nav in
            // the .ended handler can't be trusted to fire — but whatever
            // actually plays ALWAYS surfaces here as a trackChanged.
            //
            // Guards make this fire ONLY on genuine autoplay divergence,
            // never on legitimate navigation:
            //   • !sameVideoId — re-poll / same-track metadata churn.
            //   • !withinClickGrace — inside 30s of a deliberate
            //     play(item:) we're seeing the user's own click, a
            //     jumped-to row (skipTo routes through play, arming the
            //     grace), or a pre-roll ad (distinct videoId, first ~10s).
            //   • head exists AND head.id != id — the arrival isn't the
            //     shown head. If it IS the head, this is normal
            //     progression: fall through and consume it.
            // Evaluated BEFORE consumeUpTo so a deep jump is measured
            // against the REAL head, not a post-consume one. Converges in
            // one hop: the override plays the head, whose trackChanged is
            // sameVideoId and falls through. Deliberately NOT the old
            // userQueuedIds shadow-set reconciliation (which misfired on
            // legitimate plays — "song plays 2-5s then jumps"); the
            // discriminator here is the visible queue itself.
            // Radio scope guard (Phase 2): in a radio context with no
            // user-queued items, the SHOWN queue is itself a mirror of
            // the page's queue — the page is the source of truth and
            // the mirror can lag it by up to one 2s poll tick. Enforcing
            // the mirror against the page would chase our own tail
            // (override → navigation → new radio → new mirror → …), so
            // enforcement applies only when the user has explicitly
            // queued something, or in deterministic (album/playlist)
            // contexts where the shown queue is independently correct.
            // Phase C: with the mirror as display truth everywhere,
            // enforcement is only meaningful where Riff genuinely owns
            // the next-up order — explicit user-queued items and
            // chip-curated queues. Everywhere else the shown queue IS
            // the page's, so "divergence" can only be mirror lag.
            let wysiwygEnforceable = QueuePolicy.enforcementApplies(
                userQueueCount: queue.userQueueCount, hasActiveChip: activeChip != nil,
                mirrorFresh: mirrorFresh, isPageDriven: isPageDrivenContext)
            // A verified page-owned queued item arriving is EXPECTED —
            // the page inserted it ahead of the shown head by design.
            if !sameVideoId, pageOwnedQueuedIds.contains(id) {
                pageOwnedQueuedIds.remove(id)
                Log.bridge.debug("trackChanged: \(id, privacy: .public) is a verified page-owned queued item — expected arrival")
            } else if wysiwygEnforceable,
               !sameVideoId, !withinClickGrace,
               let head = upNext.first(where: { $0.id != currentTrack?.videoId }),
               head.id != id {
                Audit.note("trackChanged: arrived \(id) ≠ shown head \(head.id); autoplay diverged → overriding to head")
                Task { [weak self] in await self?.play(item: head, clearQueue: false) }
                return
            }

            // Two-region model: the just-arrived track lives somewhere in
            // upNext (the head after natural progression, or further down
            // if the user tapped a row to skip ahead within click-grace).
            // Pop it AND everything above it — matching YT Music's
            // "jump to row" semantic where skipped rows are discarded.
            // Gated on !sameVideoId: the JS bridge legitimately re-emits
            // the current track (late-title re-emit, "force" after player
            // re-subscription), and an ungated consume would silently eat
            // a "Play Next" of the currently-playing song.
            if !sameVideoId {
                // WYSIWYG audit line: arrived vs the head we were
                // showing. "match" is the healthy case; "MISMATCH" in a
                // log capture pinpoints display-vs-playback divergence.
                let shownHead = upNext.first(where: { $0.id != currentTrack?.videoId })?.id ?? "nil"
                let isJump = pendingJumpTarget == id
                if isJump {
                    pendingJumpTarget = nil
                    // Jump verified by arrival — stand down the 2.5 s
                    // failure timer so it can't toast a success.
                    jumpVerifyTask?.cancel()
                    jumpVerifyTask = nil
                }
                let label: String
                if shownHead == id { label = "match" }
                else if isJump { label = "jump (row tap)" }
                else if shownHead == "nil" { label = "context start (no shown head)" }
                else { label = "MISMATCH" }
                Audit.note("advance arrived=\(id) shownHead=\(shownHead) \(label)")
            }
            if !sameVideoId, upNext.contains(where: { $0.id == id }) {
                _ = queue.consumeUpTo(videoId: id)
            }
            // Always resync the pending URL after a track change: page
            // navigations reset window.__riffPendingNextUrl (new page =
            // new window), so we re-push the next URL on every load.
            Task { await syncPendingNextURL() }

            if sameVideoId && !titleChanged {
                // Identical event (re-poll). Just refresh duration if it's
                // newly available.
                if duration > 0, let existing = currentTrack, existing.duration == 0 {
                    currentTrack = Track(
                        videoId: existing.videoId,
                        title: existing.title,
                        subtitle: existing.subtitle,
                        thumbnailURL: existing.thumbnailURL,
                        duration: duration,
                        albumId: existing.albumId,
                        artistId: existing.artistId
                    )
                }
                // Playlist context can flip under the same videoId — the
                // JS bridge's stickyPlaylistId picks up a new `list=`
                // when the user hash-navs to the same track from a
                // different playlist. Refresh /next against the new
                // context so autoplay-next uses the right queue.
                if let newPlid = playlistId, !newPlid.isEmpty, newPlid != currentPlaylistId {
                    currentPlaylistId = newPlid
                    refreshNextQueueAndIds(forVideoId: id, playlistId: newPlid)
                }
            } else if sameVideoId && withinClickGrace {
                // Pre-roll ad / startup churn. Keep the user's clicked
                // metadata; just absorb duration if we got it.
                if duration > 0, let existing = currentTrack, existing.duration == 0 {
                    currentTrack = Track(
                        videoId: existing.videoId,
                        title: existing.title,
                        subtitle: existing.subtitle,
                        thumbnailURL: existing.thumbnailURL,
                        duration: duration,
                        albumId: existing.albumId,
                        artistId: existing.artistId
                    )
                }
            } else {
                // New track — different videoId, OR same videoId but
                // outside the click-grace window (autoplay advance).
                // Archive the previous track to history before replacing.
                archiveCurrent()
                // Reset progress to 0 immediately. Stale `<video>`
                // currentTime/duration from the previous track will
                // bleed through `timeupdate` events for up to ~1s while
                // YT Music's SPA swaps media sources; the grace window
                // checked in the .progress branch suppresses those.
                elapsed = 0
                duration = 0
                lastTrackChangeAt = Date()
                // Per-track state is UNKNOWN until fresh metadata
                // lands: the heart must not carry the previous track's
                // like state (a click in that window inverts the
                // user's intent — see toggleLike), and the lyrics /
                // related browse ids must not keep serving the
                // previous track's content on advances where no /next
                // fires. Repopulated below by whichever metadata path
                // runs (full refresh, metadata-only refresh, or
                // refreshTrackMetadata), each identity-checked.
                liked = false
                resetPerTrackTabState()
                // JS bridge doesn't surface album/artist IDs (they're not
                // on `<video>` or mediaSession.metadata). Backfill from
                // the queue if it has them — typical when autoplaying
                // through an Up Next that came back from /next with
                // longBylineText nav endpoints intact.
                let queueMatch = upNext.first(where: { $0.id == id })
                currentTrack = Track(
                    videoId: id,
                    title: title,
                    subtitle: artist,
                    thumbnailURL: art,
                    duration: 0,
                    albumId: queueMatch?.albumId,
                    artistId: queueMatch?.artistId
                )
                // Only overwrite currentPlaylistId with a non-nil
                // report. A nil arrives whenever the JS bridge's
                // findPlaylistId lost visibility of `list=` (YT
                // strips it from the URL soon after playback starts;
                // if the DOM link fallback hasn't populated yet,
                // stickyPlaylistId can be null on the very first
                // emit after a playPlaylist navigation). Clobbering
                // a good context with nil is what drops the queue
                // into per-track auto-radio after track 2. The
                // fresh-context paths (playPlaylist, playAlbum,
                // playByResolvingBrowseId, play(item:)) all seed
                // currentPlaylistId themselves before navigating, so
                // "preserve on nil" here can't mask a legitimate
                // context reset.
                if let playlistId, !playlistId.isEmpty {
                    currentPlaylistId = playlistId
                }
                let effectivePlid = currentPlaylistId
                userClickedAt = .distantPast  // stop being protective
                // Match YT Music's queue lifecycle: DON'T re-fetch
                // /next on every track advance. When you start a
                // mix on song X, YT returns a whole queue of ~25
                // tracks; subsequent tracks just consume through it.
                // Riff's old behavior fired /next per trackChanged,
                // which replaced the server region N times through a
                // mix — the queue "changed constantly" for the user.
                //
                // Refetch only when the server region is running
                // low (auto-extension). Threshold 3: leaves enough
                // runway for the network round-trip to land before
                // the user hits the bottom of the queue.
                // Autoplay gate: only auto-extend when the user hasn't
                // turned Autoplay off. With it off, the queue plays
                // out and stops at the end (Spotify/Apple Music
                // "Autoplay" behavior).
                let serverCount = upNext.count - queue.userQueueCount
                if isPageDrivenContext {
                    // Page-driven radio: the queue is mirrored from the
                    // page (never /next), but per-track METADATA still
                    // needs a refresh — without it the heart shows the
                    // previous track's like state, the Lyrics tab serves
                    // the previous track's lyrics, and chips go stale on
                    // every native advance.
                    refreshNextQueueAndIds(forVideoId: id, playlistId: effectivePlid, updateQueue: false)
                } else if autoplayEnabled, serverCount <= Self.serverRegionRefetchThreshold {
                    refreshNextQueueAndIds(forVideoId: id, playlistId: effectivePlid)
                } else {
                    // Neither refresh fires here (deterministic
                    // context with plenty of server rows left, or
                    // autoplay off): fetch ONLY the per-track metadata
                    // so the heart / lyrics / related keys still
                    // follow the track — otherwise the reset above
                    // would leave a liked album track hollow-hearted
                    // for its whole duration.
                    refreshTrackMetadata(forVideoId: id, playlistId: effectivePlid)
                }
                // New track → snapshot now (rather than waiting for
                // the rate-limited progress snapshot) so a quick
                // skip-then-quit still captures the latest track.
                snapshotSession()
                // Reconciliation is GONE in the two-region model.
                // The old code checked "is this track the head of
                // userQueuedIds? If not, override" — which racing
                // against advanceToUserQueuedIfAny (which pre-emptively
                // removed the head from the set) caused legitimate
                // plays to be wrongly override-cancelled ("song plays
                // for 2-5s then jumps"). Now: whatever arrived IS
                // what plays. `consumeHead` above already pops it
                // off upNext, so the queue stays consistent with
                // the currently-playing track.
            }
        }
        onUpdate?()
    }
}

/// One-shot gate for `evalWithTimeout`'s eval-vs-timeout race.
/// MainActor-bound (which also makes it Sendable), so a plain Bool is
/// a sufficient guard — both racers hop to the main actor to claim.
@MainActor
private final class EvalResumeGate {
    private var resumed = false
    /// True exactly once. The caller that gets `true` resumes the
    /// continuation; the loser does nothing.
    func claim() -> Bool {
        if resumed { return false }
        resumed = true
        return true
    }
}

private extension String {
    var jsonQuoted: String {
        let data = try? JSONSerialization.data(withJSONObject: [self])
        let s = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(s.dropFirst().dropLast())
    }
}
