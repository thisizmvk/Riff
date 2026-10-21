import Foundation
import Combine

/// D1 — last.fm + ListenBrainz scrobbling.
///
/// A *scrobble* is a record of a track that a user actually listened to,
/// posted to a third-party service. The user's listening history then
/// lives outside Riff's local journal, freeing them from the data silo.
/// Both services follow the same broad shape:
///
/// 1. As soon as a track starts: send a "now playing" update (lightweight,
///    advertises what the user is currently listening to).
/// 2. Once the user has played enough of the track: send a real scrobble.
///    The IFPI/last.fm rule is **at least 50% of the track OR 4 minutes,
///    whichever comes first.** Tracks shorter than 30s are not eligible —
///    last.fm rejects them, and ListenBrainz follows the same convention.
///
/// Both services are completely opt-in. Credentials live in Keychain. We
/// never POST anything until the user pastes credentials and toggles the
/// service on.
///
/// Concurrency: the protocol methods are `async` so individual scrobblers
/// can hop off the MainActor. Implementations are `Sendable` and use
/// their own internal `URLSession`. The MainActor-side coordinator
/// (`ScrobblerCoordinator`) decides when to invoke them.
enum Scrobblers {}

/// Minimal description of a track for scrobbling purposes. We
/// deliberately keep this small and decoupled from `MediaItem` /
/// `PlayerBridge.Track` so the scrobbler layer can be tested without
/// dragging in the rest of the app.
struct ScrobbleTrack: Sendable, Equatable {
    /// Required by both services. From `subtitle` on `Track`.
    let artist: String
    /// Required.
    let title: String
    /// Optional. Riff doesn't always know the album from the watch URL,
    /// but when it does (album-context playback) we pass it through.
    let album: String?
    /// Track duration in seconds. Used by both eligibility math AND the
    /// scrobble payload (last.fm + ListenBrainz both accept it).
    let durationSeconds: Int?
    /// Wall-clock time the user started listening to this track. Both
    /// services key scrobbles by this timestamp.
    let startedAt: Date
}

/// Eligibility rule. Returns true when the track has been listened to
/// long enough to count as a scrobble.
///
/// last.fm's rule is the canonical reference:
///   https://www.last.fm/api/scrobbling — "a track should be scrobbled
///   when the user has played more than half its length OR for at least
///   4 minutes (240s), whichever occurs earlier."
///
/// Pure free function so we can unit-test it without spinning up a
/// `PlayerBridge`.
enum ScrobbleEligibility {
    /// Tracks shorter than 30s are not scrobbled. Matches both services.
    static let minDurationSeconds: Double = 30
    /// Absolute cap — 4 minutes of listening always counts, regardless
    /// of track length.
    static let alwaysEligibleAfterSeconds: Double = 240

    static func isEligible(elapsed: Double, duration: Double) -> Bool {
        guard duration >= minDurationSeconds else { return false }
        if elapsed >= alwaysEligibleAfterSeconds { return true }
        return elapsed >= duration * 0.5
    }
}

/// Shared interface every scrobbler service implements. Coordinator
/// dispatches the same two events to each.
protocol ScrobblerService: Sendable {
    /// Display name shown in Settings ("last.fm" / "ListenBrainz").
    var displayName: String { get }
    /// True when the user has pasted credentials AND not toggled the
    /// service off. The coordinator gates dispatch on this.
    var isReady: Bool { get }
    /// Send the "user is listening to this track" hint. Cheap, fire-
    /// and-forget; servers throttle dupes.
    func updateNowPlaying(_ track: ScrobbleTrack) async
    /// Record a real scrobble. Called once per track, only after the
    /// eligibility threshold is met.
    func scrobble(_ track: ScrobbleTrack) async
}

// MARK: - Health

/// Per-service scrobble health, for Settings to render. Scrobble POSTs
/// are fire-and-forget, so without this a bad secret or a revoked
/// session key fails silently forever — the toggle stays on and the
/// user believes they are scrobbling. Services report each POST's
/// outcome here (hopping to the MainActor from their own executor);
/// Settings observes it and shows the last failure next to each toggle.
@MainActor
final class ScrobbleHealth: ObservableObject {
    static let shared = ScrobbleHealth()

    enum Outcome: Equatable {
        case success(at: Date)
        case failure(code: Int?, message: String, at: Date)
    }

    /// Last POST outcome, keyed by the service's `displayName`.
    @Published private(set) var lastOutcome: [String: Outcome] = [:]
    /// Services whose stored auth is known-bad (e.g. last.fm error 9,
    /// invalid session key). Permanent — retrying won't help, so
    /// Settings should render "Reconnect" until the user re-auths.
    @Published private(set) var needsReauth: Set<String> = []

    func recordSuccess(service: String) {
        lastOutcome[service] = .success(at: Date())
        needsReauth.remove(service)
    }

    func recordFailure(service: String, code: Int?, message: String, permanent: Bool) {
        lastOutcome[service] = .failure(code: code, message: message, at: Date())
        if permanent { needsReauth.insert(service) }
    }

    /// Called when the user saves fresh credentials or clears them.
    func clear(service: String) {
        lastOutcome[service] = nil
        needsReauth.remove(service)
    }
}

// MARK: - Coordinator

/// Owns the lifecycle of eligibility tracking and dispatches to every
/// registered scrobbler service.
///
/// Why a separate coordinator (rather than inlining into `PlayerBridge`):
/// - Scrobble eligibility is independent of YT Music playback mechanics.
///   We compute it from `(track, elapsed, duration)` ticks that
///   `PlayerBridge` already publishes — keeping the bookkeeping out of
///   the bridge means PlayerBridge stays focused on the WKWebView
///   protocol.
/// - Adding a third service later (libre.fm, Maloja, etc.) is a single-
///   line registration here.
///
/// MainActor-isolated because it reads `PlayerBridge` state. The actual
/// HTTP work hops off-main via the service implementations' own
/// `URLSession`.
@MainActor
final class ScrobblerCoordinator {
    private let services: [ScrobblerService]

    /// Current track being tracked, if any. Reset on every track change
    /// (or on Stop) so the next track gets its own start time + own
    /// eligibility window.
    private struct Pending {
        let videoId: String
        let track: ScrobbleTrack
        /// True once we've fired `updateNowPlaying` for this track.
        /// Suppresses repeated now-playing pings for the same track on
        /// every progress tick.
        var nowPlayingSent: Bool = false
        /// True once we've fired a real `scrobble` for this track.
        /// Suppresses duplicate scrobbles when elapsed keeps advancing
        /// past the threshold.
        var scrobbled: Bool = false
        /// Wall-clock moment of the first *playing* tick for this
        /// window. Overrides `track.startedAt` in outgoing payloads so
        /// a restored-then-resumed session (or a Repeat-One replay)
        /// carries the real listen start, not app launch / first play.
        var startedAt: Date? = nil
        /// Wall-clock seconds actually listened, accumulated across
        /// playing ticks. Used for eligibility instead of the raw
        /// player position, so a seek to 90% doesn't scrobble a track
        /// the user heard for two seconds.
        var listened: Double = 0
        /// Time of the previous playing tick; nil while paused. Gaps
        /// are capped so sleep/App Nap can't inflate `listened`.
        var lastTickAt: Date? = nil
        /// Player position at the previous tick — for detecting a
        /// Repeat-One loop wrap (end → 0 with no track-change event).
        var lastElapsed: Double = 0
    }
    private var pending: Pending?

    init(services: [ScrobblerService]) {
        self.services = services
    }

    /// Called from `PlayerBridge.onUpdate`. Idempotent — safe to call on
    /// every progress tick.
    ///
    /// Behavior:
    /// - If `track` differs from the tracked one (or is nil), reset
    ///   state. The previous track's scrobble window is closed without
    ///   firing — if the user skipped before reaching the threshold,
    ///   that's intentional behavior.
    /// - On the first call for a new track, fire `updateNowPlaying` to
    ///   every ready service.
    /// - When wall-clock *listened* time (accumulated across playing
    ///   ticks — NOT the raw player position, which a restore or a seek
    ///   can teleport) first exceeds the eligibility threshold, fire
    ///   `scrobble` once.
    ///
    /// `now` is injectable for tests; production callers use the default.
    func observe(
        track: ScrobbleTrack?,
        videoId: String?,
        elapsed: Double,
        duration: Double,
        isPlaying: Bool,
        now: Date = Date()
    ) {
        guard let track, let videoId, !videoId.isEmpty else {
            pending = nil
            return
        }
        // Track change → reset pending. Don't carry an "already
        // scrobbled" flag across tracks.
        if pending?.videoId != videoId {
            pending = Pending(videoId: videoId, track: track)
        } else if let cur = pending {
            // Repeat-One loop wrap: `<video>.loop` restarts the same
            // videoId without an ended/trackChanged event, so pending
            // would otherwise stay `scrobbled` forever and every replay
            // is lost. Detect the wrap narrowly — previous tick within
            // a few seconds of the end AND this tick back near zero —
            // so a mid-track backward scrub (200s → 150s) never
            // matches and can't double-scrobble one listen.
            let wrapped = isPlaying
                && duration > 0
                && cur.lastElapsed >= duration - 3.0
                && elapsed < 3.0
                && elapsed < cur.lastElapsed
            if wrapped {
                // Fresh play: new eligibility window, new startedAt
                // (stamped below on this playing tick), and a fresh
                // now-playing ping.
                pending = Pending(videoId: videoId, track: track)
            } else if cur.track.durationSeconds == nil, track.durationSeconds != nil {
                // Same track, update the duration field if it landed
                // late (JS bridge often reports duration ~500ms after
                // the title event). Both services accept a missing
                // duration; we upgrade in-place — preserving all
                // bookkeeping, including the stamped startedAt — so
                // the actual scrobble carries the real value.
                pending = Pending(
                    videoId: cur.videoId,
                    track: track,
                    nowPlayingSent: cur.nowPlayingSent,
                    scrobbled: cur.scrobbled,
                    startedAt: cur.startedAt,
                    listened: cur.listened,
                    lastTickAt: cur.lastTickAt,
                    lastElapsed: cur.lastElapsed
                )
            }
        }
        guard var cur = pending else { return }

        // Accumulate wall-clock listened time on playing ticks. Each
        // gap is capped at 2s so sleep, wake and App Nap can't inflate
        // the total (ticks normally arrive every ~0.5s). Paused ticks
        // clear the anchor so the pause itself never counts.
        if isPlaying {
            if cur.startedAt == nil { cur.startedAt = now }
            if let last = cur.lastTickAt {
                cur.listened += min(max(now.timeIntervalSince(last), 0), 2.0)
            }
            cur.lastTickAt = now
        } else {
            cur.lastTickAt = nil
        }
        cur.lastElapsed = elapsed
        pending = cur

        // Fire now-playing once per track. We require `isPlaying` so an
        // accidental scrub on a paused track doesn't advertise the
        // user as listening when they're not.
        if !cur.nowPlayingSent && isPlaying {
            cur.nowPlayingSent = true
            pending = cur
            let snapshot = outgoingTrack(cur)
            for service in services where service.isReady {
                Task { await service.updateNowPlaying(snapshot) }
            }
        }

        // Fire scrobble once when the threshold is hit. Gated on
        // `isPlaying` and on *listened* time (not position) so a
        // restored session that comes back past 50%, or a seek to 90%,
        // can't scrobble a track that was never actually heard. Use
        // the duration from the live tick so a late-landing duration
        // doesn't block the scrobble — we compute against whatever the
        // player is currently reporting.
        if !cur.scrobbled, isPlaying,
           ScrobbleEligibility.isEligible(elapsed: cur.listened, duration: duration) {
            cur.scrobbled = true
            pending = cur
            let snapshot = outgoingTrack(cur)
            for service in services where service.isReady {
                Task { await service.scrobble(snapshot) }
            }
        }
    }

    /// Payload for the services: the caller's track, with `startedAt`
    /// replaced by the coordinator's own stamp (the first playing tick
    /// of this window) when available. The caller pins its startedAt on
    /// videoId change, which is wrong for a restored-then-resumed
    /// session (stamp = launch time) and for Repeat-One replays (stamp
    /// = first play).
    private func outgoingTrack(_ cur: Pending) -> ScrobbleTrack {
        ScrobbleTrack(
            artist: cur.track.artist,
            title: cur.track.title,
            album: cur.track.album,
            durationSeconds: cur.track.durationSeconds,
            startedAt: cur.startedAt ?? cur.track.startedAt
        )
    }

    /// Stop tracking. Called when the user signs out / disables all
    /// services / quits.
    func reset() {
        pending = nil
    }
}

// MARK: - Shared HTTP helpers

extension Scrobblers {
    /// Tuned URLSession — same shape as InnerTubeClient.defaultSession()
    /// (10s request, 30s resource). Scrobble POSTs should land in
    /// 100-500ms on a healthy network; long hangs would just stack up
    /// scrobble Tasks if the user is on a flaky connection.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        // Don't use the URLCache — scrobble POSTs aren't cacheable, and
        // the system cache file is one fewer thing for the user to
        // worry about.
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    /// last.fm-style x-www-form-urlencoded body. RFC3986 escapes (`+`
    /// stays literal in the alphanumeric set; space → `+`, everything
    /// else → percent-encoded). last.fm's signature is computed over
    /// the *raw* values, NOT the encoded ones, so this function is
    /// only used for the wire body — never re-fed to the signature.
    static func formEncode(_ params: [String: String]) -> Data {
        // Stable order — only for test determinism. Real wire order
        // doesn't matter (server parses by key).
        let pairs = params.keys.sorted().map { key -> String in
            let value = params[key] ?? ""
            return "\(percentEncode(key))=\(percentEncode(value))"
        }
        return pairs.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private static let unreservedAllowed: CharacterSet = {
        // RFC3986 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreservedAllowed) ?? s
    }
}

// MARK: - Keychain key constants

/// Shared namespace for all scrobbler-related Keychain entries. Distinct
/// keys per service so a user enabling both doesn't collide.
enum ScrobblerKeychain {
    static let lastFmSessionKey = "scrobbler.lastfm.sessionKey"
    static let lastFmUsername   = "scrobbler.lastfm.username"
    static let lastFmAPIKey     = "scrobbler.lastfm.apiKey"
    static let lastFmSecret     = "scrobbler.lastfm.apiSecret"
    static let listenBrainzToken = "scrobbler.listenbrainz.token"
}

/// Shared namespace for scrobbler UserDefaults toggles (NOT credentials
/// — those live in Keychain).
enum ScrobblerDefaults {
    static let lastFmEnabled = "scrobbler.lastfm.enabled"
    static let listenBrainzEnabled = "scrobbler.listenbrainz.enabled"
    /// Cached username for ListenBrainz so Settings can render it
    /// without storing it in Keychain (the token implies the user, but
    /// we lookup-cache the user-friendly handle for display).
    static let listenBrainzUsername = "scrobbler.listenbrainz.username"
}
