import Foundation
import Observation
import SwiftUI
import AppKit

/// Top-level tab identifier. Lifted out of `MainTabs` so the app-level
/// `CommandGroup` (which doesn't see private nested types) can bind
/// ⌘1/2/3/4 shortcuts to switch tabs.
enum AppTab: Hashable {
    case home, explore, search, library
}

@MainActor
@Observable
final class AppEnvironment {
    /// Process-wide weak reference to the currently-live AppEnvironment.
    /// **Intents-only.** The SwiftUI environment-injected instance is the
    /// canonical one; AppIntents has no access to SwiftUI's environment, so
    /// `AppEnvironment.init` populates this so `RiffIntents` can reach the
    /// live PlayerBridge / InnerTubeClient without spinning up a duplicate
    /// WKWebView. Do not consume this from view code.
    ///
    /// MainActor-isolated like the rest of the class; intent `perform()`
    /// bodies are `@MainActor`, so they read this safely.
    static weak var current: AppEnvironment?

    let innerTube: InnerTubeClient
    let player: PlayerBridge
    let nowPlaying: NowPlayingCenter

    /// True when an OAuth Device Flow token (or a fallback SAPISID cookie)
    /// is present. Recomputed via `refreshSignedInState()` on app start
    /// and after sign-in/out.
    private(set) var isSignedIn: Bool = false

    func refreshSignedInState() {
        let hasToken = OAuthTokens.load() != nil
        // Require a NON-EXPIRED session cookie, not merely its
        // presence. A stale SAPISID / __Secure-3PAPISID left over
        // from a dead session would otherwise flip us to
        // "signed in" — hiding the Sign In button and silently
        // failing every Library / personalized call. A cookie with
        // no expiresDate is a session cookie (valid for the browser
        // session); treat that as live too.
        let now = Date()
        let hasLiveCookie = HTTPCookieStorage.shared.cookies?.contains(where: { cookie in
            guard ["SAPISID", "__Secure-3PAPISID"].contains(cookie.name) else { return false }
            if let expires = cookie.expiresDate { return expires > now }
            return true  // session cookie — no explicit expiry
        }) ?? false
        isSignedIn = hasToken || hasLiveCookie
    }

    /// Sign out clears OAuth tokens + cookies and re-evaluates state.
    /// `isSignedIn` flips to false SYNCHRONOUSLY (so the UI updates
    /// immediately), then the WebView session is purged in the
    /// background so a later re-sign-in actually shows Google's
    /// login page instead of silently reusing the old account.
    func signOut() {
        OAuthDeviceFlow.signOut()
        HTTPCookieStorage.shared.cookies?
            .filter { $0.domain.contains("youtube.com") || $0.domain.contains("google.com") }
            .forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        refreshSignedInState()
        // Full WebView session purge — cookies + localStorage +
        // IndexedDB for Google/YouTube. Backgrounded because
        // removeData is async; isSignedIn is already false so the
        // corner button has already flipped to "Sign In".
        Task { await CookieJar.purgeWebViewSession() }
        showToast("Signed out.")
    }

    /// Drives the manual presentation of the sign-in sheet. Set to true from
    /// the menu bar action or Library empty-state CTA. Sign-in is not
    /// auto-presented — the app works anonymously by default.
    var isSignInSheetPresented: Bool = false

    /// Drives the Settings sheet (custom OAuth credentials, sign-out).
    var isSettingsSheetPresented: Bool = false

    /// Drives the "New playlist" name-prompt sheet.
    var isNewPlaylistSheetPresented: Bool = false

    /// Drives the "Your Riff Highlights" recap sheet. Raised from the
    /// Help menu entry; consumed by a `.sheet` on RootView.
    var isRecapSheetPresented: Bool = false

    /// Drives the "Create lyric card" sheet. Raised from the lyrics
    /// tab in NowPlayingView; consumed by a `.sheet` on RootView.
    var isLyricCardSheetPresented: Bool = false

    /// Drives the AI Queue Builder sheet (vibe → queue). Raised from
    /// the "✨ Build" button in the Up Next pane header. Independent
    /// of `isNewPlaylistSheetPresented` so the two can't collide.
    var isQueueBuilderSheetPresented: Bool = false

    /// Drives the ⌘K command palette. A single fuzzy launcher that
    /// jumps to tabs, opens sheets, toggles playback modes, and pushes
    /// discrete sleep-timer / crossfade values without navigating
    /// through Settings.
    var isCommandPaletteOpen: Bool = false

    /// Lightweight transient toast for confirming mutations the user
    /// can't otherwise see (queue additions from Home / Search /
    /// Library carousels, artist block, sign-out from a nested menu).
    /// Auto-dismisses after `Toast.duration`; overwriting `currentToast`
    /// mid-life just cancels the pending dismissal and starts fresh.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        /// Optional "Undo" callback surfaced as a tappable pill on the
        /// right side of the toast. Nil for pure info messages.
        var undo: (@MainActor () -> Void)? = nil
        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
        static let duration: TimeInterval = 3.0
    }

    private(set) var currentToast: Toast? = nil
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>? = nil

    /// Show a toast with optional undo. Overwrites any active toast.
    func showToast(_ message: String, undo: (@MainActor () -> Void)? = nil) {
        toastDismissTask?.cancel()
        let toast = Toast(message: message, undo: undo)
        currentToast = toast
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Toast.duration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.currentToast?.id == toast.id {
                self.currentToast = nil
            }
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        currentToast = nil
    }

    /// True on the very first launch (i.e. before the user has
    /// completed or dismissed the onboarding sheet). Read once at
    /// init; flipping `markOnboardingComplete()` sets the persisted
    /// flag so subsequent launches skip the sheet.
    var isOnboardingSheetPresented: Bool = false

    private static let onboardingCompleteKey = "onboarding.hasCompleted"

    /// Called from OnboardingSheet on any exit (Complete or ✕).
    /// Persists the flag so we don't re-show. Deliberately marks
    /// complete on dismiss too — a user who saw the sheet once
    /// doesn't need to see it again on the next cold start.
    func markOnboardingComplete() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
        isOnboardingSheetPresented = false
    }

    /// Bumped by `focusSearchField()` (⌘F). SearchView observes this
    /// via `.onChange` and pulls focus into its text field on every
    /// change. Using a UUID rather than a Bool means back-to-back
    /// ⌘F presses still trigger even when the field is already
    /// nominally focused (avoids a stuck-toggle race).
    private(set) var focusSearchToken: UUID = UUID()

    /// Snapshot of `player.isPlaying` captured at `willSleepNotification`.
    /// Consulted on `didWakeNotification` to reassert the pre-sleep
    /// state — WKWebView's audio pipeline can auto-resume on wake
    /// even when we paused it, and this override forces the user's
    /// intent back.
    @ObservationIgnored fileprivate var wasPlayingBeforeSleep: Bool = false

    /// The in-flight wake-reassertion task. Held so a bounced
    /// sleep/wake sequence (double-wake, rapid sleep-again) can
    /// cancel a pending reassert rather than stacking two 500 ms
    /// tasks that fight each other for the audio state.
    @ObservationIgnored private var wakeReassertTask: Task<Void, Never>? = nil

    // Progress-tick throttle state. Track the last dispatch's videoId
    // + isPlaying so we can detect "same track, still playing, only
    // elapsed changed" and rate-limit the heavy pipeline
    // (NowPlayingCenter update, snapshot writer, scrobbler observe)
    // to 2Hz instead of the JS bridge's ~4Hz timeupdate cadence.
    // Track / state changes bypass the throttle and fire immediately.
    @ObservationIgnored private var lastOnUpdateVideoId: String? = nil
    @ObservationIgnored private var lastOnUpdateIsPlaying: Bool = false
    @ObservationIgnored private var lastOnUpdateAt: Date = .distantPast
    private static let progressTickMinInterval: TimeInterval = 0.5

    /// Called by the app-level ⌘F handler. Switches to the Search
    /// tab and bumps the focus token; SearchView reacts by focusing
    /// its text field.
    func focusSearchField() {
        activeTab = .search
        focusSearchToken = UUID()
    }

    /// Whether the menu bar mini player (`MenuBarExtra` scene in
    /// `RiffApp`) is inserted into the system menu bar. Defaults to
    /// true; persisted to UserDefaults so the user's preference
    /// survives quit. Mutating this property auto-persists and the
    /// `MenuBarExtra` `.isInserted` binding reacts.
    var menuBarExtraEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(menuBarExtraEnabled, forKey: Self.menuBarExtraEnabledKey)
        }
    }
    private static let menuBarExtraEnabledKey = "ui.menuBarExtraEnabled"

    /// D2 — per-videoId on-device metadata overrides. Local-only;
    /// never propagated to YouTube. UI rows render through the
    /// `displayTitle(for:) / displayArtist(for:) / displayAlbum(for:)`
    /// helpers below so the override applies everywhere with one
    /// switch. @Observable so SwiftUI re-renders rows when a user
    /// hits Save on the Edit-metadata sheet.
    let trackOverrides: TrackOverrideStore

    /// Returns the user-overridden title if one exists, else falls
    /// back to the original. `videoId` is the song's id; for non-song
    /// MediaItems the id is e.g. an album/playlist browseId and never
    /// has an override.
    func displayTitle(for item: MediaItem) -> String {
        if item.kind == .song,
           let t = trackOverrides.overriddenTitle(for: item.id) {
            return t
        }
        return item.title
    }

    /// Returns the user-overridden artist if one exists. The artist
    /// for a song row lives inside the `subtitle` field as the first
    /// " · " or " • " segment ("Bruno Mars · 24K Magic · 2016"), so
    /// when an override exists we splice it in place of that first
    /// segment to keep the rest of the subtitle line (album, year)
    /// intact. For non-song items, returns the original subtitle.
    func displaySubtitle(for item: MediaItem) -> String {
        guard item.kind == .song else { return item.subtitle }
        let videoId = item.id
        let artistOverride = trackOverrides.overriddenArtist(for: videoId)
        let albumOverride = trackOverrides.overriddenAlbum(for: videoId)
        if artistOverride == nil && albumOverride == nil {
            return item.subtitle
        }
        // Split the subtitle into segments on " · " / " • ". The
        // first segment is the artist; the second (if present) is
        // the album; anything after that is year / view count and
        // is preserved verbatim.
        var segments = item.subtitle
            .split(whereSeparator: { $0 == "·" || $0 == "•" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        // If subtitle was empty, synthesize a 2-segment line so we
        // have somewhere to drop the artist/album.
        if segments.isEmpty {
            segments = ["", ""]
        } else if segments.count == 1 {
            segments.append("")
        }
        if let a = artistOverride { segments[0] = a }
        if let a = albumOverride, segments.count >= 2 { segments[1] = a }
        // Re-join with the unicode middle dot. Drop trailing empties
        // so we don't render "Artist · ".
        while let last = segments.last, last.isEmpty {
            segments.removeLast()
        }
        return segments.joined(separator: " · ")
    }

    /// Direct accessor for the album-only override. Surfaced for
    /// callers (DetailView, the Edit sheet itself) that already split
    /// title / artist / album apart and don't want to round-trip
    /// through `displaySubtitle`.
    func displayAlbum(for videoId: String, fallback: String) -> String {
        trackOverrides.overriddenAlbum(for: videoId) ?? fallback
    }

    /// Whether any override field is set for `item`. Drives the small
    /// "edited" pencil glyph on rows.
    func hasMetadataOverride(_ item: MediaItem) -> Bool {
        item.kind == .song && trackOverrides.hasOverride(for: item.id)
    }

    /// Drives the "Edit metadata" sheet from TrackContextMenu.
    /// When set non-nil, RootView raises the sheet pre-populated
    /// with this item's current (possibly already-overridden) values.
    var trackBeingEdited: MediaItem? = nil

    /// Lazy LLM provider. The provider type itself is stateless —
    /// secrets live in Keychain and are read fresh on every `chat()`
    /// call so a key rotation doesn't require rebuilding the provider.
    /// Lazy so app launch stays fast for users who never touch AI
    /// features (no Keychain read on startup).
    ///
    /// @ObservationIgnored because @Observable can't synthesize
    /// observation for `lazy var` (the macro rewrites property
    /// access in a way that's incompatible with Swift's lazy
    /// initialization). Provider identity never changes anyway,
    /// so nothing to observe.
    /// Rebuilt on every access so a mid-session provider switch in
    /// Settings takes effect immediately. Providers are cheap value
    /// types (they only hold a URLSession reference); no observable
    /// state, so hopping between them is safe.
    @ObservationIgnored
    var llmProvider: any LLMProvider {
        LLMProviderKind.active.makeProvider()
    }

    /// The model id to hand to `llmProvider.chat(_:model:)`. Reads
    /// from the active provider's own storage — Anthropic keychain,
    /// Groq keychain, or Ollama defaults — so switching backends
    /// preserves each backend's model choice.
    var llmModel: String {
        LLMProviderKind.active.currentModel()
    }

    /// True when the active provider is configured well enough to
    /// answer a chat request. Drives every AI-triggering UI's
    /// disabled state.
    var hasLLMAPIKey: Bool {
        LLMProviderKind.active.isConfigured()
    }

    /// Lyrics translation engine (B3). Caches per `(videoId, language)`
    /// in memory; no persistence across launches. @ObservationIgnored
    /// for the same `lazy var` reason as `llmProvider`. The translator
    /// is NOT `@Observable` — views read its output via the
    /// `translate()` async call, not by observing internal state, so
    /// the SwiftUI dependency graph doesn't need to track it.
    @ObservationIgnored
    lazy var lyricsTranslator: LyricsTranslator = LyricsTranslator()

    /// Target language for the lyrics-translation toggle. Persisted to
    /// UserDefaults under `lyrics.translationLanguage`. Defaults to
    /// "English" on first launch.
    var translationLanguage: String = "English" {
        didSet {
            UserDefaults.standard.set(translationLanguage, forKey: LyricsTranslator.languageKey)
        }
    }

    /// Whether the lyrics-translation toggle on the Now Playing lyrics
    /// tab is engaged. Persisted under `lyrics.translationEnabled` so
    /// the user's preference survives quit.
    var lyricsTranslationEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(lyricsTranslationEnabled, forKey: LyricsTranslator.enabledKey)
        }
    }

    /// X-Ray context cards service (B4). Generates 3-6 magazine-style
    /// cards (people / place / era / sample / trivia) for the current
    /// track via the user's configured `LLMProvider`. Same shape as
    /// `lyricsTranslator` — @MainActor, in-memory cache keyed by
    /// videoId. @ObservationIgnored for the `lazy var` reason.
    @ObservationIgnored
    lazy var xrayCardsService: XRayCardsService = XRayCardsService()

    /// D1 — last.fm + ListenBrainz scrobbling. The coordinator owns
    /// eligibility tracking (per-track started-at + threshold gating)
    /// and dispatches to every registered service. Both services
    /// gate their own dispatch on credentials + the per-service
    /// enabled toggle, so flipping a service off in Settings stops
    /// scrobbling without any wiring changes here.
    ///
    /// @ObservationIgnored: views don't observe scrobbler state, the
    /// coordinator is purely a sink for player updates.
    @ObservationIgnored
    lazy var scrobbler: ScrobblerCoordinator = ScrobblerCoordinator(
        services: [LastFmScrobbler(), ListenBrainzScrobbler()]
    )

    /// Wall-clock start time of the *current* track. We pin this on
    /// every videoId change inside `onUpdate` so scrobbles carry the
    /// real listen-start, not "the moment we crossed the threshold".
    @ObservationIgnored
    private var scrobbleTrackStartedAt: Date = .distantPast
    @ObservationIgnored
    private var scrobbleLastSeenVideoId: String? = nil

    /// Which source seeds the next-presented New Playlist sheet.
    /// Default is the historical behavior (add current tvamsrack); the
    /// "Save queue" button on the Up Next pane flips this to `.queue`
    /// before raising `isNewPlaylistSheetPresented`.
    var newPlaylistSource: NewPlaylistSheet.Source = .currentTrack

    /// Per-tab navigation paths. Held here so the TopTabBar can pop a tab
    /// to its root when the user taps the already-active tab — standard
    /// "tap home to go home" behaviour.
    var homeNavPath = NavigationPath()
    var exploreNavPath = NavigationPath()
    var searchNavPath = NavigationPath()
    var libraryNavPath = NavigationPath()

    /// Currently-active main tab. Lifted out of MainTabs so the app-level
    /// CommandGroup can drive it via ⌘1 / ⌘2 / ⌘3 keyboard shortcuts.
    var activeTab: AppTab = .home

    /// Map of artist browseId → display name for artists the user has
    /// chosen never to see again. Items whose `artistId` is in the map
    /// get filtered from Home carousels, Search results, /next radio
    /// queues, and /related songs.
    ///
    /// We store the name alongside the id (rather than just the id, as
    /// the original `Set<String>` did) so Settings can render a useful
    /// row label instead of opaque `UCxx…` ids.
    ///
    /// Stored under `library.blockedArtists` in UserDefaults — a fresh
    /// key, so the legacy `library.blockedArtistIds` set is silently
    /// migrated on first load (names default to the id until the user
    /// re-encounters and re-blocks the artist).
    ///
    /// Client-side only: server-side propagation isn't possible
    /// without a YT API for "block artist" (none documented). YT
    /// Music's autoplay can still pick a blocked artist when the
    /// current track ends — settings text spells that out.
    private(set) var blockedArtists: [String: String] = [:]
    private static let blockedArtistsKey = "library.blockedArtists"
    private static let legacyBlockedArtistIdsKey = "library.blockedArtistIds"

    /// Sorted ids, exposed read-only for views that need stable iteration.
    var blockedArtistIds: [String] { blockedArtists.keys.sorted() }

    func blockedArtistName(id: String) -> String {
        blockedArtists[id] ?? id  // fall back to id when migrating from legacy storage
    }

    func isBlocked(artistId: String?) -> Bool {
        guard let id = artistId, !id.isEmpty else { return false }
        return blockedArtists[id] != nil
    }

    func isBlocked(_ item: MediaItem) -> Bool {
        // Block by artist match OR when the item itself IS the blocked
        // artist (e.g. an Artist tile in a search-result list).
        if item.kind == .artist && blockedArtists[item.id] != nil { return true }
        return isBlocked(artistId: item.artistId)
    }

    /// Block by id + capture the human-readable name in one call.
    /// Callers from track context menus already have both (the
    /// MediaItem carries title for artist tiles, or carries the
    /// subtitle which holds the artist name for song rows).
    func blockArtist(id: String, name: String) {
        guard !id.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Don't let an empty name overwrite an existing one — if the
        // caller passes "" we keep whatever name we previously knew.
        blockedArtists[id] = trimmed.isEmpty ? (blockedArtists[id] ?? id) : trimmed
        persistBlockedArtists()
    }

    func unblockArtist(id: String) {
        blockedArtists.removeValue(forKey: id)
        persistBlockedArtists()
    }

    private func persistBlockedArtists() {
        UserDefaults.standard.set(blockedArtists, forKey: Self.blockedArtistsKey)
    }

    /// Set of MediaItem ids the user has explicitly pinned to the top
    /// of their Library section grid. Persisted under `library.pinned`
    /// in UserDefaults as a sorted `[String]` (Set is not a PLIST type).
    ///
    /// Pinning is purely client-side and cross-section: the same set is
    /// consulted by every Library section (playlists, albums, podcasts,
    /// artists). An item with id "X" pinned in the Playlists view stays
    /// pinned if it ever shows up in Albums — which it won't, but the
    /// id-based shape makes that trivially correct.
    ///
    /// We deliberately don't gate pinning on `isSignedIn`: anonymous
    /// users still see a Library tab (it just renders the empty state),
    /// and the moment they sign in their pins are already in place.
    private(set) var pinnedLibraryIds: Set<String> = []
    private static let pinnedLibraryIdsKey = "library.pinned"

    func isPinned(_ id: String) -> Bool {
        !id.isEmpty && pinnedLibraryIds.contains(id)
    }

    /// Toggle the pin state of a Library item. The Pin / Unpin button
    /// in `TrackContextMenu` and `ThumbnailButton`'s context menu both
    /// route through here so the persistence side-effect lives in one
    /// place.
    func togglePinned(id: String) {
        guard !id.isEmpty else { return }
        if pinnedLibraryIds.contains(id) {
            pinnedLibraryIds.remove(id)
        } else {
            pinnedLibraryIds.insert(id)
        }
        persistPinnedLibrary()
    }

    private func persistPinnedLibrary() {
        UserDefaults.standard.set(pinnedLibraryIds.sorted(), forKey: Self.pinnedLibraryIdsKey)
    }

    private func loadPinnedLibrary() {
        if let arr = UserDefaults.standard.stringArray(forKey: Self.pinnedLibraryIdsKey) {
            pinnedLibraryIds = Set(arr)
        }
    }

    private func loadBlockedArtists() {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.blockedArtistsKey) as? [String: String] {
            blockedArtists = dict
            return
        }
        // One-time migration from the legacy Set<String> shape. Names
        // default to the id; the next "Don't recommend" tap on the
        // same artist will upgrade the entry with a real name.
        if let arr = UserDefaults.standard.stringArray(forKey: Self.legacyBlockedArtistIdsKey) {
            blockedArtists = Dictionary(uniqueKeysWithValues: arr.map { ($0, $0) })
            persistBlockedArtists()
            UserDefaults.standard.removeObject(forKey: Self.legacyBlockedArtistIdsKey)
        }
    }

    /// Navigate to a media item's detail page, regardless of where the
    /// caller is. Closes the full-screen Now Playing overlay (so the
    /// destination is actually visible) and pushes the item onto the
    /// active tab's NavigationStack. Used by "Go to album" / "Go to
    /// artist" context-menu actions, including from the player itself.
    func navigate(to item: MediaItem) {
        if player.isFullPlayerOpen {
            player.isFullPlayerOpen = false
        }
        switch activeTab {
        case .home:    homeNavPath.append(item)
        case .explore: exploreNavPath.append(item)
        case .search:  searchNavPath.append(item)
        case .library: libraryNavPath.append(item)
        }
    }

    /// Convenience: navigate to an album / artist by its browseId,
    /// synthesizing a minimal `MediaItem`. Used when we have only the
    /// id (e.g. from a now-playing track's `albumId`) and not a full
    /// item to push.
    func navigateToBrowseId(_ id: String, kind: MediaItem.Kind, fallbackTitle: String = "") {
        let item = MediaItem(
            id: id,
            kind: kind,
            title: fallbackTitle,
            subtitle: "",
            thumbnailURL: nil
        )
        navigate(to: item)
    }

    /// Open an artist's page. Prefers a known browseId; when the source
    /// (e.g. the now-playing track) doesn't carry one — common for radio
    /// tracks whose `/next` row lacked an artist nav endpoint — resolves
    /// by name via a Search("Artists") and opens the first artist hit.
    /// No-ops when there's neither an id nor a usable name.
    func navigateToArtist(name: String, artistId: String?) {
        if let id = artistId, !id.isEmpty {
            navigateToBrowseId(id, kind: .artist, fallbackTitle: name)
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { [innerTube] in
            let results = (try? await innerTube.search(query: trimmed, filter: .artists)) ?? []
            guard let artist = results.first(where: { $0.kind == .artist }) else { return }
            await MainActor.run {
                self.navigateToBrowseId(artist.id, kind: .artist, fallbackTitle: artist.title)
            }
        }
    }

    /// Cached user-owned playlists for "Add to Playlist" menus. Loaded on
    /// demand when a UI surface needs them; refreshed whenever the user
    /// signs in/out.
    private(set) var userPlaylists: [MediaItem] = []
    private(set) var userPlaylistsLoading = false
    func loadUserPlaylistsIfNeeded() {
        guard isSignedIn, !userPlaylistsLoading, userPlaylists.isEmpty else { return }
        reloadUserPlaylists()
    }

    func reloadUserPlaylists() {
        guard isSignedIn else { return }
        userPlaylistsLoading = true
        Task { [innerTube] in
            let items = (try? await innerTube.library(section: .playlists)) ?? []
            await MainActor.run {
                userPlaylists = items.filter { $0.kind == .playlist }
                userPlaylistsLoading = false
            }
        }
    }

    init() {
        // Bump URLCache.shared for thumbnail reuse. SwiftUI's
        // AsyncImage uses URLSession.shared which reads from
        // URLCache.shared; the system default (~4 MB memory /
        // ~20 MB disk) is dwarfed by a Riff session — Home +
        // Search + Library + Up Next carousels can pull hundreds
        // of covers per hour. A larger disk-backed cache turns
        // repeat visits into zero-network re-renders. 512 MB disk
        // is generous but bounded; macOS reclaims it under
        // pressure.
        let mem = 64 * 1024 * 1024            // 64 MB in-memory
        let disk = 512 * 1024 * 1024          // 512 MB on-disk
        URLCache.shared = URLCache(
            memoryCapacity: mem,
            diskCapacity: disk,
            diskPath: "riff.imageCache"
        )
        self.innerTube = InnerTubeClient()
        self.player = PlayerBridge(innerTube: innerTube)
        self.nowPlaying = NowPlayingCenter(player: player)
        self.trackOverrides = TrackOverrideStore()
        self.refreshSignedInState()
        self.loadBlockedArtists()
        self.loadPinnedLibrary()
        // First-run onboarding: raise the sheet once, then never
        // again (the completion flag is persisted synchronously
        // on dismiss).
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey) {
            self.isOnboardingSheetPresented = true
        }
        // Honor the persisted menu-bar-extra toggle. The key defaults to
        // `true` when absent (first launch / never-toggled), preserving
        // the "show by default" behavior. Read via `object(forKey:)` so
        // we can distinguish "absent" from "explicitly set to false".
        if let stored = UserDefaults.standard.object(forKey: Self.menuBarExtraEnabledKey) as? Bool {
            self.menuBarExtraEnabled = stored
        }
        // Lyrics-translation preferences (B3). Read via `object(forKey:)`
        // so an absent key (first launch) doesn't shadow the property's
        // default value. Setting via the property's `didSet` would
        // re-persist; we go around it by assigning directly to avoid
        // a no-op write on every launch.
        if let lang = UserDefaults.standard.string(forKey: LyricsTranslator.languageKey),
           !lang.isEmpty {
            self.translationLanguage = lang
        }
        if let toggle = UserDefaults.standard.object(forKey: LyricsTranslator.enabledKey) as? Bool {
            self.lyricsTranslationEnabled = toggle
        }
        // Publish ourselves as the process-wide handle for AppIntents.
        // RiffApp creates exactly one AppEnvironment; if that ever
        // changes, the weak ref naturally tracks the latest instance.
        Self.current = self
        // Subscribe to MetricKit on launch — Apple's built-in crash /
        // hang / perf reporter. Payloads land daily under
        // ~/Library/Application Support/Riff/diagnostics/. No network
        // exfiltration; user shares manually if asked.
        DiagnosticsCenter.shared.start()
        // Snapshot the playback session on app exit so "Continue
        // where you left off" survives a quit. The progress-driven
        // snapshot is rate-limited to once-per-5s; this catches the
        // delta between the last rate-limited write and quit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [player] _ in
            MainActor.assumeIsolated { player.snapshotSession() }
        }

        // Battery: suspend the JS-side safety-poll + normalization
        // tick when the app loses focus. Playback keeps going
        // (WebKit's audio pipeline is independent), but we stop
        // waking the JS runtime every 2s to re-check state that
        // hasn't changed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [player] _ in
            MainActor.assumeIsolated {
                Task { await player.setBackgrounded(true) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self, player] _ in
            MainActor.assumeIsolated {
                Task { await player.setBackgrounded(false) }
                // Re-evaluate sign-in on reactivation: a session
                // cookie can expire while the app is backgrounded,
                // and this flips the UI back to signed-out (showing
                // the Sign In button) instead of leaving a dead
                // avatar in the corner.
                self?.refreshSignedInState()
            }
        }

        // Sleep / wake handling: WKWebView's <video> element
        // sometimes auto-resumes on wake even when we paused it
        // before sleep. macOS fires willSleep + didWake notifications
        // via NSWorkspace (NOT NSApplication — sleep is a system
        // event, not an app event). We capture pre-sleep isPlaying,
        // and on wake force the state back to what the user had.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Cancel any pending wake reassertion in-flight —
                // rapid sleep-wake-sleep sequences would otherwise
                // stack tasks, each fighting the user's next input.
                self.wakeReassertTask?.cancel()
                self.wakeReassertTask = nil
                self.wasPlayingBeforeSleep = self.player.isPlaying
            }
        }
        workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Cancel a previous wake's reassertion if still
                // pending (double-wake / sleep-bounce).
                self.wakeReassertTask?.cancel()
                self.wakeReassertTask = Task { @MainActor [weak self] in
                    // 500 ms lets WebKit's own resume attempt fire
                    // first so our reassertion definitively wins.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, !Task.isCancelled else { return }
                    // Re-read at FIRE time — if the user hit Play
                    // during the 500 ms window, wasPlayingBeforeSleep
                    // is still the pre-sleep value but the user's
                    // action supersedes: leave audio alone.
                    if !self.wasPlayingBeforeSleep && self.player.isPlaying {
                        await self.player.togglePlay()
                    }
                    self.wakeReassertTask = nil
                }
            }
        }

        // Mirror PlayerBridge state into MPNowPlayingInfoCenter on every
        // change. NowPlayingCenter holds a strong ref to player; here we go
        // the other way without retaining nowPlaying strongly inside player.
        self.player.onUpdate = { [weak self] in
            guard let self else { return }
            guard let track = self.player.currentTrack else {
                // No active track — wipe the widget snapshot so it
                // doesn't keep advertising the last-played song after
                // the user stops playback.
                NowPlayingSnapshotWriter.shared.clear()
                self.scrobbler.reset()
                self.scrobbleLastSeenVideoId = nil
                self.lastOnUpdateVideoId = nil
                self.lastOnUpdateAt = .distantPast
                return
            }
            // Throttle: if this is a same-track, same-isPlaying
            // update (i.e. only elapsed advanced), don't run the
            // heavy pipeline more than every progressTickMinInterval.
            // Track/state changes bypass — those need to hit
            // NowPlayingCenter + widget instantly.
            let now = Date()
            let sameTrack = self.lastOnUpdateVideoId == track.videoId
            let sameState = self.lastOnUpdateIsPlaying == self.player.isPlaying
            let isProgressOnly = sameTrack && sameState
            if isProgressOnly,
               now.timeIntervalSince(self.lastOnUpdateAt) < Self.progressTickMinInterval {
                return
            }
            self.lastOnUpdateVideoId = track.videoId
            self.lastOnUpdateIsPlaying = self.player.isPlaying
            self.lastOnUpdateAt = now
            self.nowPlaying.update(
                title: track.title,
                artist: track.subtitle,
                artwork: track.thumbnailURL,
                duration: self.player.duration,
                elapsed: self.player.elapsed
            )
            // B9 — mirror the same payload into the App-Group-shared
            // snapshot the Notification Center widget reads. The
            // writer rate-limits internally so this stays cheap on
            // the ~250ms progress tick.
            NowPlayingSnapshotWriter.shared.update(
                videoId: track.videoId,
                title: track.title,
                subtitle: track.subtitle,
                thumbnailURL: track.thumbnailURL,
                isPlaying: self.player.isPlaying,
                elapsed: self.player.elapsed,
                duration: self.player.duration
            )
            // D1 — scrobbler dispatch. Pin start time on every videoId
            // change so the eventual scrobble carries the real listen
            // start, not the moment the threshold was crossed.
            if self.scrobbleLastSeenVideoId != track.videoId {
                self.scrobbleTrackStartedAt = Date()
                self.scrobbleLastSeenVideoId = track.videoId
            }
            let durationSeconds: Int? = self.player.duration > 0 ? Int(self.player.duration) : nil
            let scrobbleTrack = ScrobbleTrack(
                artist: track.subtitle,
                title: track.title,
                album: nil,  // YT Music's watch URL doesn't surface album text on the player payload; left nil.
                durationSeconds: durationSeconds,
                startedAt: self.scrobbleTrackStartedAt
            )
            self.scrobbler.observe(
                track: scrobbleTrack,
                videoId: track.videoId,
                elapsed: self.player.elapsed,
                duration: self.player.duration,
                isPlaying: self.player.isPlaying
            )
        }
        // Hand PlayerBridge the predicate it uses to filter blocked
        // artists out of upNext / related. Closure captures self
        // weakly; if env is gone the filter falls back to "block
        // nothing" via the default initializer.
        self.player.shouldBlock = { [weak self] item in
            self?.isBlocked(item) ?? false
        }

        // B9 — drain any widget command that landed while the app was
        // backgrounded. The widget's transport buttons enqueue a
        // pending command into the shared App Group defaults and set
        // openAppWhenRun=true, which foregrounds us. We catch the
        // foreground transition here and dispatch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainWidgetCommands() }
        }
        // Also drain on launch — first foreground after the system
        // routes the AppIntent to a freshly-launched process may
        // arrive before didBecomeActive fires.
        Task { @MainActor [weak self] in
            self?.drainWidgetCommands()
        }
    }

    // Pull any queued widget command off the shared store and route
    // it to PlayerBridge. Safe to call repeatedly — dequeue clears
    // the pending field so the second call is a no-op.
    private func drainWidgetCommands() {
        guard let command = WidgetCommandStore.dequeue() else { return }
        switch command {
        case .togglePlay:
            Task { await self.player.togglePlay() }
        case .next:
            Task { await self.player.next() }
        case .previous:
            Task { await self.player.previous() }
        }
    }
}
