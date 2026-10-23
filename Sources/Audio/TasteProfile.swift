import Foundation

/// What Riff has learned about your taste — computed on demand from the
/// local play journal, never stored, never sent anywhere. One model with
/// two consumers:
///
///   - `BlendBuilder` asks `weight(for:)` to bias its sampling (ease off
///     skipped songs and over-played artists, lean into what you play on
///     this kind of day).
///   - The "Your Taste" view renders the same numbers, plus `reasons(for:)`
///     explains any individual pick — so nothing shapes the mix that the
///     user can't see.
///
/// Signals (all from `PlayedEntry`; entries recorded before listen depth
/// existed count as neutral plays, never skips):
///
///   - **Skips** — left under 30 s and under half the track.
///   - **Day type** — weekday vs weekend listening, per artist.
///   - **Fatigue** — an artist that dominated the last few days gets eased
///     off so the mix doesn't collapse onto one obsession.
struct TasteProfile: Sendable {

    struct ArtistTaste: Identifiable, Sendable, Equatable {
        let id: String          // artist browseId, else lowercased name
        let name: String
        var plays: Int = 0      // completed (non-skip) plays in window
        var skips: Int = 0
        var weekendPlays: Int = 0
        var weekdayPlays: Int = 0
        var recentPlays: Int = 0  // completed plays in the fatigue window
        var lastPlayed: Date = .distantPast

        var listens: Int { plays + skips }
        /// Skip share once there's enough evidence to mean anything.
        var skipRate: Double? { listens >= 4 ? Double(skips) / Double(listens) : nil }
    }

    struct SongTaste: Sendable, Equatable {
        var plays: Int = 0
        var skips: Int = 0
        var lastPlayed: Date = .distantPast
    }

    static let windowDays = 60
    static let fatigueDays = 3
    /// Share of recent completed plays above which an artist counts as
    /// over-played ("you've been on a Thaman S run").
    static let fatigueShare = 0.40

    let now: Date
    let isWeekendNow: Bool
    let artists: [String: ArtistTaste]
    let songs: [String: SongTaste]
    let totalRecentPlays: Int
    let totalWeekendPlays: Int
    let totalWeekdayPlays: Int
    /// Entries in window carrying listen depth — when zero, skip-based
    /// signals are silent (journal predates the field).
    let entriesWithDepth: Int

    static func artistKey(_ item: MediaItem) -> String {
        if let id = item.artistId, !id.isEmpty { return id }
        return (PersonalizedShelves.extractArtistName(fromSubtitle: item.subtitle) ?? item.subtitle).lowercased()
    }

    static func build(from entries: [PlayedEntry], now: Date = Date(),
                      calendar: Calendar = .current) -> TasteProfile {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let recentCutoff = now.addingTimeInterval(-Double(fatigueDays) * 86_400)
        var artists: [String: ArtistTaste] = [:]
        var songs: [String: SongTaste] = [:]
        var recentTotal = 0, weekendTotal = 0, weekdayTotal = 0, withDepth = 0

        for e in entries where e.playedAt >= cutoff && e.item.kind == .song && !e.item.id.isEmpty {
            if e.listenedSeconds != nil { withDepth += 1 }
            let key = artistKey(e.item)
            let name = PersonalizedShelves.extractArtistName(fromSubtitle: e.item.subtitle) ?? e.item.subtitle
            var a = artists[key] ?? ArtistTaste(id: key, name: name)
            var s = songs[e.item.id] ?? SongTaste()
            a.lastPlayed = max(a.lastPlayed, e.playedAt)
            s.lastPlayed = max(s.lastPlayed, e.playedAt)
            if e.isSkip {
                a.skips += 1; s.skips += 1
            } else {
                a.plays += 1; s.plays += 1
                if calendar.isDateInWeekend(e.playedAt) {
                    a.weekendPlays += 1; weekendTotal += 1
                } else {
                    a.weekdayPlays += 1; weekdayTotal += 1
                }
                if e.playedAt >= recentCutoff { a.recentPlays += 1; recentTotal += 1 }
            }
            artists[key] = a
            songs[e.item.id] = s
        }
        return TasteProfile(now: now, isWeekendNow: calendar.isDateInWeekend(now),
                            artists: artists, songs: songs,
                            totalRecentPlays: recentTotal,
                            totalWeekendPlays: weekendTotal, totalWeekdayPlays: weekdayTotal,
                            entriesWithDepth: withDepth)
    }

    // MARK: - Signals

    /// Artist dominating the last `fatigueDays` (needs a real sample).
    func isFatigued(_ key: String) -> Bool {
        guard totalRecentPlays >= 10, let a = artists[key] else { return false }
        return Double(a.recentPlays) / Double(totalRecentPlays) >= Self.fatigueShare
    }

    /// Artist's lean toward today's day type, relative to your overall
    /// weekday/weekend split. >1 = "more of a weekend artist" on a weekend.
    func dayTypeLift(_ key: String) -> Double {
        guard let a = artists[key], a.plays >= 4,
              totalWeekendPlays >= 5, totalWeekdayPlays >= 5 else { return 1 }
        let mine = Double(isWeekendNow ? a.weekendPlays : a.weekdayPlays) / Double(a.plays)
        let base = Double(isWeekendNow ? totalWeekendPlays : totalWeekdayPlays)
            / Double(totalWeekendPlays + totalWeekdayPlays)
        guard base > 0 else { return 1 }
        return min(max(mine / base, 0.6), 1.6)
    }

    /// Song you keep bailing on: at least two skips and more skips than
    /// completed plays.
    func isSkippedSong(_ id: String) -> Bool {
        guard let s = songs[id] else { return false }
        return s.skips >= 2 && s.skips > s.plays
    }

    /// Multiplier applied to a song's Blend sampling weight.
    func weight(for item: MediaItem) -> Double {
        let key = Self.artistKey(item)
        var w = 1.0
        if isSkippedSong(item.id) { w *= 0.2 }
        if let rate = artists[key]?.skipRate, rate >= 0.5 { w *= 0.5 }
        if isFatigued(key) { w *= 0.55 }
        w *= dayTypeLift(key)
        return w
    }

    // MARK: - Explanations

    /// Plain-language reasons a song is in the mix — the "Why this?" line.
    /// Ordered most-specific first; callers usually show the first one or two.
    func reasons(for item: MediaItem, seedArtistId: String? = nil) -> [String] {
        let key = Self.artistKey(item)
        var out: [String] = []
        if let seed = seedArtistId, item.artistId == seed {
            out.append("Blend seeded on this artist")
        }
        if let s = songs[item.id] {
            if s.plays >= 3 { out.append("You've played this \(s.plays)×") }
            let idle = now.timeIntervalSince(s.lastPlayed) / 86_400
            if idle >= 14 { out.append("Rediscovery — not played in \(Int(idle)) days") }
        }
        let lift = dayTypeLift(key)
        if lift >= 1.25 { out.append(isWeekendNow ? "A weekend favorite" : "A weekday regular") }
        if let a = artists[key], a.plays >= 5, out.isEmpty {
            out.append("You listen to \(a.name) often")
        }
        if isFatigued(key) { out.append("Eased off — you've had a lot of \(artists[key]?.name ?? "them") lately") }
        if out.isEmpty { out.append("From your recent listening") }
        return out
    }

    // MARK: - View helpers

    /// Top artists by completed plays.
    func topArtists(limit: Int = 8) -> [ArtistTaste] {
        artists.values.sorted { l, r in
            l.plays != r.plays ? l.plays > r.plays : l.lastPlayed > r.lastPlayed
        }.prefix(limit).map { $0 }
    }

    /// Artists Blend is currently easing off, and why.
    var easedOff: [ArtistTaste] {
        artists.values.filter { isFatigued($0.id) || ($0.skipRate ?? 0) >= 0.5 }
            .sorted { $0.listens > $1.listens }
    }

    /// Artists you lean into on today's day type.
    var dayTypeFavorites: [ArtistTaste] {
        artists.values.filter { dayTypeLift($0.id) >= 1.25 }
            .sorted { $0.plays > $1.plays }
            .prefix(5).map { $0 }
    }
}

/// Portable taste profile: the play journal as versioned JSON. Export
/// lets the user see (and keep) everything the taste model knows; import
/// merges a profile back (e.g. onto a new Mac), de-duplicated by
/// song + timestamp so re-importing the same file is harmless.
enum TasteArchive {
    struct File: Codable {
        var format = "riff.taste-profile"
        var version = 1
        var exportedAt: Date
        var entries: [PlayedEntry]
    }

    enum ImportError: Error, Equatable { case notARiffProfile, unsupportedVersion(Int) }

    static func encode(_ entries: [PlayedEntry], now: Date = Date()) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(File(exportedAt: now, entries: entries))
    }

    static func decode(_ data: Data) throws -> [PlayedEntry] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let file = try? dec.decode(File.self, from: data),
              file.format == "riff.taste-profile" else { throw ImportError.notARiffProfile }
        guard file.version == 1 else { throw ImportError.unsupportedVersion(file.version) }
        return file.entries
    }

    /// Union of two journals, de-duplicated on (song id, whole-second
    /// timestamp).
    static func merge(_ a: [PlayedEntry], _ b: [PlayedEntry]) -> [PlayedEntry] {
        var seen = Set<String>()
        return (a + b).filter { e in
            seen.insert("\(e.item.id)@\(Int(e.playedAt.timeIntervalSince1970))").inserted
        }.sorted { $0.playedAt < $1.playedAt }
    }
}
