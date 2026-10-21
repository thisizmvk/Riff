import Foundation

/// One entry in the played-history journal: a `MediaItem` plus the
/// wall-clock `Date` when it was archived. The timestamp is required by
/// the Stats surface (B1) to render time-windowed views — 7-day,
/// 30-day, 90-day, all-time — over the same history the year-end Recap
/// already aggregates.
///
/// Pre-B1 the journal stored `[MediaItem]` directly. We migrate on
/// load: existing entries get `Date.distantPast` so they continue to
/// appear in the "All time" window but are excluded from any bounded
/// window (which is the only honest behaviour — we don't know when they
/// played).
struct PlayedEntry: Equatable, Hashable, Sendable, Codable {
    let item: MediaItem
    let playedAt: Date
}

/// Tiny encapsulation of the locally-persisted played-history journal.
/// Pulled out of `PlayerBridge` (audit §6.8) so the journal lifecycle
/// has one obvious owner. The rest of `PlayerBridge` keeps its own
/// in-memory `playedHistory` array for SwiftUI observation; this type
/// owns the disk side only.
///
/// Writes are eager — every `archive(_:)` synchronously persists.
/// History is small (cap N items) so the encode cost is microseconds
/// and an unexpected crash never loses more than the *current* track.
///
/// **Storage isolation:** `defaults` is injectable. Production uses
/// `.standard`; tests inject a per-suite `UserDefaults(suiteName:)` so
/// fixture data never bleeds into the running app's history. (Found
/// the hard way: a previous version used `.standard` unconditionally,
/// and `xcodebuild test` polluted production defaults with rows like
/// `{title: "T", subtitle: "Artist"}` from test fixtures.)
///
/// **Storage key versioning:** `v3` carries timestamps; the legacy
/// `v2` key stored bare `[MediaItem]`. On first launch after the B1
/// migration, `load()` reads the v2 blob (if present), wraps each item
/// in a `PlayedEntry` with `Date.distantPast`, persists under v3, and
/// removes v2. Future schema changes should bump the version in the
/// same way; UserDefaults supports millions of orphan keys without ill
/// effect, so the abandoned keys are safe to leave.
struct PlayedHistoryStore {
    private static let key = "player.history.v3"
    private static let legacyKey = "player.history.v2"
    let cap: Int
    let defaults: UserDefaults

    init(cap: Int, defaults: UserDefaults = .standard) {
        self.cap = cap
        self.defaults = defaults
        // Opportunistic one-time cleanup of the long-abandoned v1 key.
        defaults.removeObject(forKey: "player.history")
    }

    /// Load whatever was journalled in the last session. Trimmed to
    /// `cap` so a corrupted/giant store can't balloon memory; the
    /// most-recent N are kept (history is appended in chronological
    /// order, so `suffix()` preserves the latest plays).
    ///
    /// Handles the v2 → v3 migration in-line: if the v3 key is missing
    /// but the v2 key exists, decode v2 as `[MediaItem]`, wrap each in
    /// a `PlayedEntry(playedAt: .distantPast)`, persist under v3, and
    /// drop v2. Distant-past means windowed Stats views (7d/30d/90d)
    /// won't include those entries — which is correct, since we genuinely
    /// don't know when they played — while "All time" still does.
    func load() -> [PlayedEntry] {
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([PlayedEntry].self, from: data) {
            return Array(decoded.suffix(cap))
        }
        // v2 fallback
        if let data = defaults.data(forKey: Self.legacyKey),
           let legacy = try? JSONDecoder().decode([MediaItem].self, from: data) {
            let migrated = legacy.map { PlayedEntry(item: $0, playedAt: .distantPast) }
            let trimmed = Array(migrated.suffix(cap))
            save(trimmed)
            defaults.removeObject(forKey: Self.legacyKey)
            return trimmed
        }
        return []
    }

    /// Persist the current full history. Caller is responsible for
    /// applying `cap` before passing it in — keeps the rule "the
    /// in-memory array is the source of truth, this just mirrors it"
    /// from drifting.
    func save(_ entries: [PlayedEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Raw persisted journal bytes, as written by `save(_:)`. Exists
    /// for the diagnostics exporter, which dumps what would survive a
    /// relaunch rather than the in-memory copy. Routing the read
    /// through here keeps the storage key (and the storage medium)
    /// private to this type, so the export can't silently go empty
    /// the next time the schema version bumps (v2 → v3 already
    /// happened once).
    static func rawJournalData(defaults: UserDefaults = .standard) -> Data? {
        defaults.data(forKey: key)
    }

    /// Used on Sign Out to wipe the journal — keeps the next user of
    /// this Mac (or the same user who deliberately signed out) from
    /// seeing the previous session's plays.
    func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.legacyKey)
    }
}
