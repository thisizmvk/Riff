import XCTest
@testable import Riff

/// Unit tests for `BlendBuilder` — the pure, RNG-injectable logic behind
/// the "Riff Blend" personal mix. No PlayerBridge, no UserDefaults: the
/// builder takes `[PlayedEntry]` and returns `[MediaItem]`, which is the
/// whole reason it was extracted. A seeded RNG makes the weighted
/// sampling deterministic here.
final class BlendBuilderTests: XCTestCase {

    // MARK: - Deterministic RNG

    /// SplitMix64 — tiny, seedable, good enough for reproducing the
    /// weighted-sampling order in a test.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Fixtures

    private func song(_ id: String, artist: String = "Artist", artistId: String? = nil, art: String? = nil) -> MediaItem {
        MediaItem(
            id: id,
            kind: .song,
            title: "Title-\(id)",
            subtitle: artist,
            thumbnailURL: art.flatMap(URL.init(string:)),
            artistId: artistId
        )
    }

    private func episode(_ id: String) -> MediaItem {
        MediaItem(id: id, kind: .episode, title: "Ep-\(id)", subtitle: "Show", thumbnailURL: nil)
    }

    private func entry(_ item: MediaItem, daysAgo: Double, now: Date) -> PlayedEntry {
        PlayedEntry(item: item, playedAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    /// `minimumDistinctSongs` fresh songs, each one day apart.
    private func richHistory(now: Date, count: Int = BlendBuilder.minimumDistinctSongs) -> [PlayedEntry] {
        (0..<count).map { entry(song("s\($0)", artist: "A\($0)", artistId: "A\($0)"), daysAgo: Double($0), now: now) }
    }

    // MARK: - Availability gate

    func testThinHistoryIsNotAvailable() {
        let now = Date()
        let entries = richHistory(now: now, count: BlendBuilder.minimumDistinctSongs - 1)
        XCTAssertFalse(BlendBuilder.isAvailable(from: entries, now: now))
        var rng = SeededRNG(seed: 1)
        XCTAssertTrue(BlendBuilder.build(from: entries, now: now, using: &rng).isEmpty)
    }

    func testAtThresholdIsAvailable() {
        let now = Date()
        let entries = richHistory(now: now)
        XCTAssertTrue(BlendBuilder.isAvailable(from: entries, now: now))
        var rng = SeededRNG(seed: 1)
        XCTAssertFalse(BlendBuilder.build(from: entries, now: now, using: &rng).isEmpty)
    }

    // MARK: - Filtering

    func testEpisodesAreExcluded() {
        let now = Date()
        var entries = richHistory(now: now)
        entries += (0..<5).map { entry(episode("e\($0)"), daysAgo: Double($0), now: now) }
        var rng = SeededRNG(seed: 42)
        let mix = BlendBuilder.build(from: entries, now: now, using: &rng)
        XCTAssertFalse(mix.isEmpty)
        XCTAssertTrue(mix.allSatisfy { $0.kind == .song })
    }

    func testOutOfWindowEntriesExcluded() {
        let now = Date()
        // Rich recent history, plus one ancient song well outside 60 days.
        var entries = richHistory(now: now)
        let old = song("ancient")
        entries.append(entry(old, daysAgo: Double(BlendBuilder.windowDays + 10), now: now))
        XCTAssertEqual(BlendBuilder.eligibleSongCount(from: entries, now: now), BlendBuilder.minimumDistinctSongs)
        var rng = SeededRNG(seed: 7)
        let mix = BlendBuilder.build(from: entries, now: now, using: &rng)
        XCTAssertFalse(mix.contains { $0.id == "ancient" })
    }

    func testDeduplicatesByVideoId() {
        let now = Date()
        // One song played many times, plus enough distinct others to pass
        // the gate. The repeated song must appear at most once.
        var entries = richHistory(now: now)
        let repeated = song("s0", artist: "A0", artistId: "A0")
        entries += (0..<6).map { entry(repeated, daysAgo: Double($0) * 0.1, now: now) }
        var rng = SeededRNG(seed: 99)
        let mix = BlendBuilder.build(from: entries, now: now, using: &rng)
        XCTAssertEqual(mix.filter { $0.id == "s0" }.count, 1)
        // And no id repeats at all.
        XCTAssertEqual(Set(mix.map(\.id)).count, mix.count)
    }

    func testRespectsLimit() {
        let now = Date()
        let entries = (0..<80).map { entry(song("s\($0)", artistId: "A\($0)"), daysAgo: Double($0) * 0.5, now: now) }
        var rng = SeededRNG(seed: 3)
        let mix = BlendBuilder.build(from: entries, limit: 25, now: now, using: &rng)
        XCTAssertEqual(mix.count, 25)
    }

    // MARK: - De-clumping

    func testNoThreeConsecutiveFromSameArtistWhenAlternativesExist() {
        let now = Date()
        // Two artists, plenty of songs each, interleaved history.
        var entries: [PlayedEntry] = []
        for i in 0..<12 {
            entries.append(entry(song("x\(i)", artist: "X", artistId: "X"), daysAgo: Double(i), now: now))
            entries.append(entry(song("y\(i)", artist: "Y", artistId: "Y"), daysAgo: Double(i) + 0.5, now: now))
        }
        var rng = SeededRNG(seed: 123)
        let mix = BlendBuilder.build(from: entries, now: now, using: &rng)
        var run = 1
        for i in 1..<mix.count {
            if mix[i].artistId == mix[i - 1].artistId {
                run += 1
                XCTAssertLessThanOrEqual(run, 2, "more than 2 consecutive from the same artist at index \(i)")
            } else {
                run = 1
            }
        }
    }

    // MARK: - Preview artwork

    func testPreviewArtworkIsMostRecentDistinctAndCapped() {
        let now = Date()
        let entries = [
            entry(song("a", art: "https://img/a.jpg"), daysAgo: 1, now: now),
            entry(song("b", art: "https://img/b.jpg"), daysAgo: 2, now: now),
            entry(song("a", art: "https://img/a.jpg"), daysAgo: 0.5, now: now), // dup, newer
            entry(song("c", art: "https://img/c.jpg"), daysAgo: 3, now: now),
            entry(song("d", art: "https://img/d.jpg"), daysAgo: 4, now: now),
            entry(song("e", art: "https://img/e.jpg"), daysAgo: 5, now: now),
        ]
        let covers = BlendBuilder.previewArtwork(from: entries, now: now, limit: 4)
        XCTAssertEqual(covers.count, 4)
        // Most-recent-distinct first: a (0.5d), b (2d), c (3d), d (4d).
        XCTAssertEqual(covers.first?.absoluteString, "https://img/a.jpg")
        XCTAssertEqual(Set(covers).count, covers.count)
    }

    // MARK: - Seeded blend

    func testSeededBlendLeansTowardSeedArtist() {
        let now = Date()
        // Equal play history for two artists, X and Y. A blend seeded by
        // X should, over the full mix, contain more X than Y.
        var entries: [PlayedEntry] = []
        for i in 0..<20 {
            entries.append(entry(song("x\(i)", artist: "X", artistId: "X"), daysAgo: Double(i) * 0.3, now: now))
            entries.append(entry(song("y\(i)", artist: "Y", artistId: "Y"), daysAgo: Double(i) * 0.3, now: now))
        }
        let seed = MediaItem(id: "X", kind: .artist, title: "X", subtitle: "", thumbnailURL: nil)
        var rng = SeededRNG(seed: 555)
        let mix = BlendBuilder.build(
            from: entries, limit: 30, now: now,
            boostArtistId: BlendBuilder.seedArtistId(for: seed), using: &rng
        )
        let xCount = mix.filter { $0.artistId == "X" }.count
        let yCount = mix.filter { $0.artistId == "Y" }.count
        XCTAssertGreaterThan(xCount, yCount, "seeded blend should favor the seed artist")
    }

    func testSeedArtistIdResolution() {
        let artist = MediaItem(id: "A1", kind: .artist, title: "A", subtitle: "", thumbnailURL: nil)
        XCTAssertEqual(BlendBuilder.seedArtistId(for: artist), "A1")
        let songWithArtist = song("s", artistId: "A2")
        XCTAssertEqual(BlendBuilder.seedArtistId(for: songWithArtist), "A2")
        let songNoArtist = song("s")
        XCTAssertNil(BlendBuilder.seedArtistId(for: songNoArtist))
        let emptyArtist = MediaItem(id: "", kind: .artist, title: "", subtitle: "", thumbnailURL: nil)
        XCTAssertNil(BlendBuilder.seedArtistId(for: emptyArtist))
    }

    func testEligibleSongCountCountsDistinctInWindow() {
        let now = Date()
        let entries = [
            entry(song("a"), daysAgo: 1, now: now),
            entry(song("a"), daysAgo: 2, now: now), // dup
            entry(song("b"), daysAgo: 3, now: now),
            entry(episode("e"), daysAgo: 1, now: now), // not a song
            entry(song("old"), daysAgo: Double(BlendBuilder.windowDays + 1), now: now), // out of window
        ]
        XCTAssertEqual(BlendBuilder.eligibleSongCount(from: entries, now: now), 2)
    }
}
