import Foundation

/// Personalization derived purely from local `playedEntries`. No
/// network, no ML, no telemetry — just group + count what the user
/// has actually listened to. Cheap enough to recompute on every
/// Home render.
///
/// Everything lives here so the algorithm is testable in isolation
/// (`PlayerBridge` doesn't need to know how "top artists" is
/// defined) and so a future replacement — LLM re-rank, embedding
/// search, whatever — has one obvious seam to swap.
enum PersonalizedShelves {
    /// Sliding recency window. 30 days matches Spotify's "top played"
    /// convention; long enough to be stable, short enough to reflect
    /// current taste. Callers can override for other cadences (e.g.
    /// a weekly recap).
    static let defaultWindowDays: Int = 30

    /// Rank a user's most-played artists in the last N days.
    ///
    /// Returns synthetic `MediaItem(kind: .artist, …)` values so the
    /// same `HomeSectionRow` / `ThumbnailButton` chain that renders
    /// browse-home carousels works unchanged. `thumbnailURL` on each
    /// returned item is the *most-recently-played song's* cover for
    /// that artist — YT doesn't expose artist portraits without
    /// another /browse round-trip, and a familiar recent album cover
    /// reads as "this is that artist" much better than an empty tile.
    ///
    /// Ordering: by play count descending, then by most-recent play
    /// (stable tiebreaker). Skips entries whose `artistId` is missing
    /// — those come from search rows that lost the artist nav
    /// endpoint and rendering them as tiles would go nowhere.
    static func topArtists(
        from entries: [PlayedEntry],
        since days: Int = defaultWindowDays,
        limit: Int = 8,
        now: Date = Date()
    ) -> [MediaItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let recent = entries.filter { $0.playedAt >= cutoff }
        guard !recent.isEmpty else { return [] }

        struct ArtistAgg {
            var count: Int = 0
            var lastPlayed: Date = .distantPast
            var mostRecentItem: MediaItem
        }
        var byId: [String: ArtistAgg] = [:]
        for entry in recent {
            guard let artistId = entry.item.artistId, !artistId.isEmpty else { continue }
            if var agg = byId[artistId] {
                agg.count += 1
                if entry.playedAt > agg.lastPlayed {
                    agg.lastPlayed = entry.playedAt
                    agg.mostRecentItem = entry.item
                }
                byId[artistId] = agg
            } else {
                byId[artistId] = ArtistAgg(count: 1, lastPlayed: entry.playedAt, mostRecentItem: entry.item)
            }
        }
        // Sort: count desc, then lastPlayed desc.
        let ranked = byId
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.value.lastPlayed > rhs.value.lastPlayed
            }
        // Filter BEFORE the limit (as topTracks does): a skipped artist
        // must not cost a tile slot, or rails render short.
        let tiles = ranked.compactMap { (artistId, agg) -> MediaItem? in
            let name = extractArtistName(fromSubtitle: agg.mostRecentItem.subtitle)
            // Skip entries where we couldn't derive a real artist
            // name — rendering "Song" or "Artist" as a tile name
            // is user-hostile (it reads as data corruption). Also
            // skip when the most-recent song had no thumbnail;
            // the tile would render as an empty black square which
            // reads the same way.
            guard let name, !name.isEmpty,
                  let thumb = agg.mostRecentItem.thumbnailURL else { return nil }
            return MediaItem(
                id: artistId,
                kind: .artist,
                title: name,
                subtitle: "\(agg.count) play\(agg.count == 1 ? "" : "s")",
                thumbnailURL: thumb
            )
        }
        return Array(tiles.prefix(limit))
    }

    /// Pull the artist name out of a played-track subtitle. Handles
    /// the two common shapes:
    ///   - Search rows: "Song • Bruno Mars • 24K Magic • 2016"
    ///     (kind label first, then artist, then album, then year)
    ///   - Queue / Home rows: "Bruno Mars" (single artist segment)
    ///
    /// Splits on `•` / `·` / ` - `, skips any leading kind-label
    /// segment ("Song" / "Album" / "Video" / "Artist" / "Podcast" /
    /// "Playlist" / "Episode"), and returns the first real segment.
    /// Returns nil when nothing usable is left — the caller drops
    /// the entry entirely rather than showing a kind label as an
    /// artist name.
    private static let kindLabels: Set<String> = [
        "Song", "Album", "Video", "Artist", "Podcast", "Playlist", "Episode",
    ]

    static func extractArtistName(fromSubtitle raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Try each separator YT uses; " • " (thin bullet), " · "
        // (interpunct), " - " (dash-space). Split then drop empty
        // pieces so we don't stall on double-separator quirks.
        let segments = trimmed
            .split(whereSeparator: { $0 == "·" || $0 == "•" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }
        // Skip a leading kind-label if the search shape put one
        // there. If ALL segments are kind labels (shouldn't happen
        // but defensive), we return nil so the caller drops the
        // entry rather than surfacing "Song" as an artist name.
        for segment in segments where !kindLabels.contains(segment) {
            // The artist run is often a multi-credit string
            // ("A.R. Rahman, Karthik, Devan" / "Thaman S & Sid Sriram").
            // A top-ARTISTS tile should name the primary artist, not a
            // truncated credits list — take the first credited name.
            let primary = segment
                .replacingOccurrences(of: " & ", with: ", ")
                .replacingOccurrences(of: " and ", with: ", ")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty })
            return primary ?? segment
        }
        return nil
    }

    /// Rank the user's most-played tracks in the last N days. Same
    /// window + tiebreak as `topArtists`. Returned as song
    /// MediaItems, ready to feed into `ThumbnailButton` (which will
    /// render Play + queue quick-actions on hover for songs).
    ///
    /// Dedupes by videoId — the same track played N times shows up
    /// as one tile with a play-count in its subtitle instead of N
    /// duplicate tiles.
    static func topTracks(
        from entries: [PlayedEntry],
        since days: Int = defaultWindowDays,
        limit: Int = 12,
        now: Date = Date()
    ) -> [MediaItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let recent = entries.filter { $0.playedAt >= cutoff }
        guard !recent.isEmpty else { return [] }

        struct TrackAgg {
            var count: Int = 0
            var lastPlayed: Date = .distantPast
            var item: MediaItem
        }
        var byId: [String: TrackAgg] = [:]
        for entry in recent {
            let id = entry.item.id
            guard !id.isEmpty else { continue }
            if var agg = byId[id] {
                agg.count += 1
                if entry.playedAt > agg.lastPlayed {
                    agg.lastPlayed = entry.playedAt
                }
                byId[id] = agg
            } else {
                byId[id] = TrackAgg(count: 1, lastPlayed: entry.playedAt, item: entry.item)
            }
        }
        return byId
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.value.lastPlayed > rhs.value.lastPlayed
            }
            .map { $0.value.item }
            // Skip tiles that would render as an empty black
            // square (no thumbnail). Some played entries come from
            // ad-hoc rows (JS-side track changes that fired before
            // metadata landed) and lack a thumbnailURL — rendering
            // them looks like data corruption.
            .filter { $0.thumbnailURL != nil }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Time-of-day shelf ("daylist"-style)

    enum DaySlot: String, CaseIterable {
        case morning, afternoon, evening, lateNight

        static func slot(for date: Date, calendar: Calendar = .current) -> DaySlot {
            let hour = calendar.component(.hour, from: date)
            switch hour {
            case 5..<11:  return .morning
            case 11..<17: return .afternoon
            case 17..<22: return .evening
            default:      return .lateNight
            }
        }

        var shelfTitle: String {
            switch self {
            case .morning:   return "Your morning rotation"
            case .afternoon: return "Your afternoon rotation"
            case .evening:   return "Your evening rotation"
            case .lateNight: return "Your late-night rotation"
            }
        }
    }

    struct TimeOfDayShelf: Equatable {
        let slot: DaySlot
        let title: String
        let items: [MediaItem]
    }

    /// Tracks you tend to play at THIS time of day, ranked by plays in
    /// the current slot over the last `days` days (recency tiebreak).
    /// Nil until the slot has enough signal (≥ `minPlays` plays across
    /// ≥ `minTracks` distinct tracks) — a shelf built on three plays
    /// reads as noise, not insight.
    static func timeOfDayShelf(
        from entries: [PlayedEntry],
        now: Date = Date(),
        since days: Int = 90,
        limit: Int = 12,
        minPlays: Int = 15,
        minTracks: Int = 8,
        calendar: Calendar = .current
    ) -> TimeOfDayShelf? {
        let slot = DaySlot.slot(for: now, calendar: calendar)
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let inSlot = entries.filter { $0.playedAt >= cutoff && DaySlot.slot(for: $0.playedAt, calendar: calendar) == slot }
        guard inSlot.count >= minPlays else { return nil }
        struct Agg { var count = 0; var last = Date.distantPast; var item: MediaItem }
        var byId: [String: Agg] = [:]
        for e in inSlot where !e.item.id.isEmpty {
            if var a = byId[e.item.id] {
                a.count += 1
                a.last = max(a.last, e.playedAt)
                byId[e.item.id] = a
            } else {
                byId[e.item.id] = Agg(count: 1, last: e.playedAt, item: e.item)
            }
        }
        // Thresholds count RENDERABLE tracks (with artwork) so the shelf
        // is nil — not an empty shelf — when the signal can't be shown.
        let renderable = byId.values.filter { $0.item.thumbnailURL != nil }
        guard renderable.count >= minTracks else { return nil }
        let ranked = renderable
            .sorted { l, r in l.count != r.count ? l.count > r.count : l.last > r.last }
            .map(\.item)
            .prefix(limit)
        guard !ranked.isEmpty else { return nil }
        return TimeOfDayShelf(slot: slot, title: slot.shelfTitle, items: Array(ranked))
    }
}
