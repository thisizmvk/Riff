import Foundation

/// "Riff Blend" — a personal mix computed entirely from the local
/// `playedEntries` journal. No network, no ML service, no telemetry:
/// just a recency-weighted sample of what the user actually listens to,
/// reshuffled each time so the same history yields a fresh running
/// order. The experimental counterpart to `PersonalizedShelves` (which
/// ranks; this one *sequences* into a playable queue).
///
/// Kept pure and RNG-injectable so the weighting + de-clumping is
/// testable in isolation — `HomeView` only calls `build` and hands the
/// result to `PlayerBridge.playTracks`, adding no force-play call site.
enum BlendBuilder {
    /// How far back the blend reaches. Wider than the 30-day top-artists
    /// window: a mix benefits from the occasional older favorite, not
    /// just the current month.
    static let windowDays: Int = 60

    /// Recency half-life for the play-weight decay, in days. A track
    /// played today counts double one played `halfLife` days ago.
    static let halfLifeDays: Double = 21

    /// Minimum distinct songs in-window before a blend is offered. Below
    /// this the sample is too thin to feel like a mix, so the Home card
    /// stays hidden (the ranked shelves already cover light histories).
    static let minimumDistinctSongs: Int = 8

    /// Default mix length. Long enough to be a session, short enough to
    /// stay personal rather than drifting into "everything I've heard".
    static let defaultLimit: Int = 40

    /// Build the blend: a de-duplicated, recency-weighted, lightly
    /// artist-declumped ordering of songs drawn from `entries`.
    ///
    /// Returns `[]` when history is too thin (see `minimumDistinctSongs`)
    /// so callers can treat empty as "don't show the entry point".
    static func build(
        from entries: [PlayedEntry],
        limit: Int = defaultLimit,
        now: Date = Date(),
        using rng: inout some RandomNumberGenerator
    ) -> [MediaItem] {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)

        // Aggregate plays per song. Episodes are excluded — a blend is a
        // music mix; podcast episodes belong to their own linear queues.
        struct Agg {
            var weight: Double = 0
            var lastPlayed: Date = .distantPast
            var item: MediaItem
        }
        var byId: [String: Agg] = [:]
        for entry in entries where entry.playedAt >= cutoff {
            let item = entry.item
            guard item.kind == .song, !item.id.isEmpty else { continue }
            let ageDays = max(0, now.timeIntervalSince(entry.playedAt)) / 86_400
            // Exponential recency decay, summed across plays, so both
            // "played a lot" and "played recently" lift a track.
            let w = pow(2.0, -ageDays / halfLifeDays)
            if var agg = byId[item.id] {
                agg.weight += w
                if entry.playedAt > agg.lastPlayed {
                    agg.lastPlayed = entry.playedAt
                    agg.item = item
                }
                byId[item.id] = agg
            } else {
                byId[item.id] = Agg(weight: w, lastPlayed: entry.playedAt, item: item)
            }
        }

        guard byId.count >= minimumDistinctSongs else { return [] }

        // Weighted sampling without replacement (Efraimidis–Spirakis):
        // key = U^(1/weight), take the largest keys. Heavier tracks tend
        // to surface, but every eligible track keeps a real chance, so
        // the order genuinely varies run to run.
        let keyed: [(item: MediaItem, key: Double, artist: String)] = byId.values.map { agg in
            let u = Double.random(in: Double.leastNonzeroMagnitude...1, using: &rng)
            let key = pow(u, 1.0 / max(agg.weight, Double.leastNonzeroMagnitude))
            return (agg.item, key, artistKey(for: agg.item))
        }
        let ordered = keyed.sorted { $0.key > $1.key }.map { ($0.item, $0.artist) }

        // Light de-clumping: avoid three-in-a-row from the same artist so
        // the mix doesn't open with one album's deep cuts back to back.
        let declumped = declump(ordered, maxRun: 2)
        return Array(declumped.prefix(limit))
    }

    /// Non-throwing convenience over the system RNG for call sites that
    /// don't need determinism (the Home card).
    static func build(
        from entries: [PlayedEntry],
        limit: Int = defaultLimit,
        now: Date = Date()
    ) -> [MediaItem] {
        var rng = SystemRandomNumberGenerator()
        return build(from: entries, limit: limit, now: now, using: &rng)
    }

    /// Distinct in-window songs available to a blend. Cheap enough to
    /// call on every Home render to decide whether to show the entry
    /// point (no RNG, no sorting).
    static func eligibleSongCount(from entries: [PlayedEntry], now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        var ids = Set<String>()
        for entry in entries where entry.playedAt >= cutoff {
            let item = entry.item
            if item.kind == .song, !item.id.isEmpty { ids.insert(item.id) }
        }
        return ids.count
    }

    /// Whether the history is rich enough to offer a blend.
    static func isAvailable(from entries: [PlayedEntry], now: Date = Date()) -> Bool {
        eligibleSongCount(from: entries, now: now) >= minimumDistinctSongs
    }

    /// Up to `limit` cover URLs for the card's collage — the most-recent
    /// distinct in-window song artworks. Deterministic (no RNG) so the
    /// card art is stable between renders; the *mix* is what reshuffles.
    static func previewArtwork(from entries: [PlayedEntry], now: Date = Date(), limit: Int = 4) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        var seen = Set<String>()
        var urls: [URL] = []
        for entry in entries.sorted(by: { $0.playedAt > $1.playedAt }) where entry.playedAt >= cutoff {
            let item = entry.item
            guard item.kind == .song, !item.id.isEmpty, let url = item.thumbnailURL else { continue }
            guard seen.insert(item.id).inserted else { continue }
            urls.append(url)
            if urls.count >= limit { break }
        }
        return urls
    }

    /// Grouping key for de-clumping: artistId when present, else a
    /// normalized subtitle so "same artist, missing id" still clusters.
    private static func artistKey(for item: MediaItem) -> String {
        if let id = item.artistId, !id.isEmpty { return "id:" + id }
        return "name:" + item.subtitle.lowercased()
    }

    /// Greedy pass that never places more than `maxRun` consecutive items
    /// sharing an artist key: when the next pick would overflow the run,
    /// pull forward the nearest following item from a different artist.
    /// Order is otherwise preserved, so the weighting still dominates.
    private static func declump(
        _ items: [(MediaItem, String)],
        maxRun: Int
    ) -> [MediaItem] {
        var remaining = items
        var out: [MediaItem] = []
        var lastArtist = ""
        var run = 0
        while !remaining.isEmpty {
            var pick = 0
            if run >= maxRun {
                // Find the first upcoming item from a different artist.
                if let alt = remaining.firstIndex(where: { $0.1 != lastArtist }) {
                    pick = alt
                }
                // If every remaining item is the same artist, fall through
                // and accept the clump — nothing else to interleave.
            }
            let (item, artist) = remaining.remove(at: pick)
            out.append(item)
            if artist == lastArtist {
                run += 1
            } else {
                lastArtist = artist
                run = 1
            }
        }
        return out
    }
}
