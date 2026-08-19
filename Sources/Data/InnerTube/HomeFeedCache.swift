import Foundation

/// Disk-backed cache of the last successful `browseHome()` response.
/// Serves an instant Home render on cold start; the fresh network
/// fetch runs in parallel and swaps in when it lands.
///
/// Storage: a single JSON blob under
/// `~/Library/Caches/dev.riff.app/homeFeed.json`. Caches don't need
/// to survive a "clear caches" step by the user or the system, so
/// Caches/ is the right home. Small (~50-200 KB for a full home
/// feed; much less without artwork resolution details), synchronous
/// writes are microseconds.
///
/// Concurrency: read/write helpers are static and take pure inputs
/// so callers can hop off MainActor as needed (see HomeView.load).
enum HomeFeedCache {
    /// Serializable snapshot of `InnerTubeClient.HomeFeed`. Kept
    /// separate from `HomeFeed` so future non-cacheable fields
    /// (async continuations, etc.) can be added to HomeFeed without
    /// bloating the on-disk shape.
    struct Snapshot: Codable {
        let chips: [InnerTubeClient.HomeChip]
        let sections: [HomeSection]
        let savedAt: Date
    }

    /// Max age we serve the cache for. Older payloads are ignored —
    /// they'd render a home feed from days ago that likely no longer
    /// matches YT's server-side personalization. A day is enough
    /// to make repeat visits feel instant while still recycling
    /// through fresh content daily.
    static let maxAgeSeconds: TimeInterval = 24 * 60 * 60

    // MARK: - Paths

    private static var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.riff.app", isDirectory: true)
    }

    private static var fileURL: URL? {
        cacheDirectory?.appendingPathComponent("homeFeed.json")
    }

    // MARK: - Read

    /// Return the cached snapshot if present and fresh. Returns nil
    /// on any read/decode error or when the cache is older than
    /// `maxAgeSeconds` — callers should render the skeleton in
    /// that case, same as before.
    static func load() -> Snapshot? {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince(snap.savedAt) < maxAgeSeconds else {
            return nil
        }
        return snap
    }

    // MARK: - Write

    /// Persist a fresh feed to disk. Best-effort — a write failure
    /// (disk full, permissions) just means the next cold start
    /// falls back to the network, which is exactly what happens
    /// today anyway.
    static func save(_ snapshot: Snapshot) {
        guard let dir = cacheDirectory, let file = fileURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Wipe the cached snapshot. Called from Settings "Clear caches"
    /// or when the user signs out (their personalized shelves
    /// shouldn't survive into a fresh sign-in).
    static func clear() {
        guard let file = fileURL else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
