import XCTest
@testable import Riff

/// Tests for the two PlayerBridge extractions: `QueueManager` and
/// `BrowseIdResolver`. These are pure value-or-state types (no
/// network, no JS bridge), so they unit-test cleanly.
///
/// **Isolation:** every QueueManager built here is wired to a private
/// `UserDefaults(suiteName:)` instead of `.standard`. Earlier versions
/// of these tests wrote to `.standard` and the fixture data ("T" /
/// "Artist" rows with empty thumbnails) leaked into the running app's
/// played-history pane. The suite is wiped before and after each test
/// so a stale store from a previous run can't poison fixtures either.
@MainActor
final class QueueManagerTests: XCTestCase {

    /// Per-test isolated UserDefaults. `removePersistentDomain(forName:)`
    /// in setUp + tearDown ensures every test starts with an empty store
    /// AND leaves no data behind for the next process / xcodebuild run.
    private static let suiteName = "dev.riff.app.tests.QueueManager"

    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: Self.suiteName)
        defaults = UserDefaults(suiteName: Self.suiteName)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func item(_ id: String, title: String = "T") -> MediaItem {
        MediaItem(id: id, kind: .song, title: title, subtitle: "Artist", thumbnailURL: nil)
    }

    private func makeQueue(cap: Int = 5) -> QueueManager {
        QueueManager(historyCap: cap, defaults: defaults)
    }

    func testReplaceQueueAssignsItems() {
        let q = makeQueue()
        q.replaceQueue([item("a"), item("b"), item("c")])
        XCTAssertEqual(q.upNext.map(\.id), ["a", "b", "c"])
    }

    func testPlayNextDedupesAndMovesToFront() {
        let q = makeQueue()
        q.replaceQueue([item("a"), item("b"), item("c")])
        q.playNext(item("c"))
        XCTAssertEqual(q.upNext.map(\.id), ["c", "a", "b"],
            "Existing entry should move to the front rather than duplicate")
    }

    func testAddToEndDedupes() {
        let q = makeQueue()
        q.replaceQueue([item("a")])
        q.addToEnd(item("b"))
        q.addToEnd(item("a"))   // duplicate — must be a no-op
        XCTAssertEqual(q.upNext.map(\.id), ["a", "b"])
    }

    func testRemoveByVideoId() {
        let q = makeQueue()
        q.replaceQueue([item("a"), item("b"), item("c")])
        q.remove(videoId: "b")
        XCTAssertEqual(q.upNext.map(\.id), ["a", "c"])
    }

    func testMoveDownAndUpClampsToBounds() {
        let q = makeQueue()
        q.replaceQueue([item("a"), item("b"), item("c")])
        q.move(videoId: "a", by: -10)            // already at top — clamp
        XCTAssertEqual(q.upNext.map(\.id), ["a", "b", "c"])
        q.move(videoId: "a", by: 100)            // clamp to bottom
        XCTAssertEqual(q.upNext.map(\.id), ["b", "c", "a"])
        q.move(videoId: "c", by: -1)
        XCTAssertEqual(q.upNext.map(\.id), ["c", "b", "a"])
    }

    func testArchiveDedupesAgainstTail() {
        let q = makeQueue()
        q.archive(item("a"))
        let sizeBeforeDup = q.playedHistory.count
        q.archive(item("a"))                     // immediate dup — no-op
        XCTAssertEqual(q.playedHistory.count, sizeBeforeDup)
        q.archive(item("b"))
        XCTAssertGreaterThan(q.playedHistory.count, sizeBeforeDup)
    }

    func testArchiveRespectsCap() {
        let q = makeQueue(cap: 3)
        q.archive(item("a"))
        q.archive(item("b"))
        q.archive(item("c"))
        q.archive(item("d"))
        XCTAssertEqual(q.playedHistory.suffix(3).map(\.id), ["b", "c", "d"],
            "Cap should drop the oldest entries when exceeded")
        XCTAssertEqual(q.playedHistory.count, 3)
    }

    func testClearQueue() {
        let q = makeQueue()
        q.replaceQueue([item("a"), item("b")])
        q.clearQueue()
        XCTAssertTrue(q.upNext.isEmpty)
    }

    /// Regression test for the production-pollution bug: tests that
    /// archive items must NOT touch `UserDefaults.standard`. Anything
    /// they wrote there used to surface as "T / Artist" placeholder
    /// rows in the running app's Recently Played list.
    func testArchiveDoesNotPollutePerformanceUserDefaults() {
        // Sentinel: capture .standard's view of the production keys
        // before and after; archive should not affect either. We check
        // both v2 (legacy bare-MediaItem journal) and v3 (B1-era
        // timestamped journal) because a regression that brings back
        // .standard could land on either.
        let keys = ["player.history.v2", "player.history.v3"]
        let before = keys.map { UserDefaults.standard.data(forKey: $0) }
        let q = makeQueue()
        q.archive(item("a", title: "Test Pollution Sentinel"))
        let after = keys.map { UserDefaults.standard.data(forKey: $0) }
        XCTAssertEqual(before, after,
            "Test-suite QueueManager must never write to UserDefaults.standard — that's the production app's history journal")
    }

    // MARK: - Two-region model invariants
    //
    // Each of these guards a specific bug we've hit in this
    // codebase's history — the two-region model was born from
    // repeatedly patching around wrong-shaped state. If any of
    // these regress the same class of bug comes back.

    /// After Play Next + Add to Queue, the user region contains
    /// both in the right positions: Play Next at 0, Add to Queue
    /// at 1 (right before what would be the first server item).
    func testPlayNextAndAddToEndOccupyUserRegionInOrder() {
        let q = makeQueue()
        q.addToEnd(item("addend"))
        q.playNext(item("playnext"))
        XCTAssertEqual(q.upNext.map(\.id), ["playnext", "addend"])
        XCTAssertEqual(q.userQueueCount, 2)
    }

    /// `replaceServerRegion` MUST NOT touch user-queued items —
    /// this was the root of the "Add to Queue items get dropped
    /// on /next refresh" bug.
    func testReplaceServerRegionPreservesUserRegion() {
        let q = makeQueue()
        q.playNext(item("user1"))
        q.addToEnd(item("user2"))
        q.replaceServerRegion([item("s1"), item("s2"), item("s3")])
        XCTAssertEqual(q.upNext.map(\.id), ["user1", "user2", "s1", "s2", "s3"])
        XCTAssertEqual(q.userQueueCount, 2)
    }

    /// `replaceServerRegion` MUST dedupe against user region ids —
    /// if the server response contains a videoId already user-queued,
    /// it drops from the incoming list rather than duplicating.
    func testReplaceServerRegionDedupesAgainstUserRegion() {
        let q = makeQueue()
        q.playNext(item("shared"))
        q.replaceServerRegion([item("shared"), item("s1")])
        XCTAssertEqual(q.upNext.map(\.id), ["shared", "s1"])
        XCTAssertEqual(q.userQueueCount, 1)
    }

    /// `consumeHead` decrements userQueueCount when the head was
    /// user-queued; doesn't touch it when the head was a server item.
    func testConsumeHeadAdjustsUserRegion() {
        let q = makeQueue()
        q.playNext(item("u1"))
        q.replaceServerRegion([item("s1")])
        XCTAssertEqual(q.userQueueCount, 1)
        _ = q.consumeHead()
        XCTAssertEqual(q.upNext.map(\.id), ["s1"])
        XCTAssertEqual(q.userQueueCount, 0)
        _ = q.consumeHead()
        XCTAssertEqual(q.upNext.map(\.id), [])
        XCTAssertEqual(q.userQueueCount, 0, "must stay non-negative")
    }

    /// `consumeUpTo` (used by jump-to-row in Up Next) drops
    /// everything up to and including the target, correctly
    /// decrementing userQueueCount when items crossed the region
    /// boundary. This was the source of the "queue plays songs
    /// different from what's shown" bug.
    func testConsumeUpToDiscardsSkippedRowsAndRebalancesRegion() {
        let q = makeQueue()
        q.playNext(item("u1"))
        q.addToEnd(item("u2"))
        q.replaceServerRegion([item("s1"), item("s2"), item("s3")])
        // Queue: [u1, u2 | s1, s2, s3], userQueueCount = 2.
        let dropped = q.consumeUpTo(videoId: "s2")
        XCTAssertEqual(dropped.map(\.id), ["u1", "u2", "s1", "s2"])
        XCTAssertEqual(q.upNext.map(\.id), ["s3"])
        XCTAssertEqual(q.userQueueCount, 0, "no user region remains after consuming past the boundary")
    }

    /// `consumeUpTo` on a missing id is a no-op.
    func testConsumeUpToNoOpWhenIdMissing() {
        let q = makeQueue()
        q.playNext(item("a"))
        q.replaceServerRegion([item("s1")])
        let dropped = q.consumeUpTo(videoId: "not-in-queue")
        XCTAssertEqual(dropped, [])
        XCTAssertEqual(q.upNext.map(\.id), ["a", "s1"])
        XCTAssertEqual(q.userQueueCount, 1)
    }

    /// `replaceQueue` (fresh watch context) wipes BOTH regions —
    /// after a play(item:, clearQueue: true), no prior user-queued
    /// item should survive.
    func testReplaceQueueZeroesUserRegion() {
        let q = makeQueue()
        q.playNext(item("old"))
        q.replaceQueue([item("new1"), item("new2")])
        XCTAssertEqual(q.upNext.map(\.id), ["new1", "new2"])
        XCTAssertEqual(q.userQueueCount, 0)
    }

    /// Dedupe on Add-to-Queue: if the item is already user-queued
    /// it's a no-op. If it's a server item, it gets promoted into
    /// the user region.
    func testAddToEndDedupePromotesFromServerRegion() {
        let q = makeQueue()
        q.replaceServerRegion([item("promoteme"), item("s1")])
        XCTAssertEqual(q.userQueueCount, 0)
        q.addToEnd(item("promoteme"))
        XCTAssertEqual(q.upNext.map(\.id), ["promoteme", "s1"])
        XCTAssertEqual(q.userQueueCount, 1, "server item promoted into user region")
    }

    /// `isUserQueued(videoId:)` reports region membership correctly
    /// across mutations.
    func testIsUserQueuedTracksRegion() {
        let q = makeQueue()
        q.playNext(item("u"))
        q.replaceServerRegion([item("s")])
        XCTAssertTrue(q.isUserQueued(videoId: "u"))
        XCTAssertFalse(q.isUserQueued(videoId: "s"))
        XCTAssertFalse(q.isUserQueued(videoId: "not-in-queue"))
    }

    /// Invariant: `userQueueCount <= upNext.count` always. Runs a
    /// randomized sequence of operations and asserts the invariant
    /// after each. Catches "off-by-one" style bugs that manual tests
    /// might miss.
    func testUserQueueCountInvariantHoldsUnderRandomOps() {
        let q = makeQueue()
        var rng = SystemRandomNumberGenerator()
        let ids = (0..<20).map { "t\($0)" }
        for _ in 0..<200 {
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: q.playNext(item(ids.randomElement(using: &rng)!))
            case 1: q.addToEnd(item(ids.randomElement(using: &rng)!))
            case 2: q.remove(videoId: ids.randomElement(using: &rng)!)
            case 3: _ = q.consumeHead()
            case 4: _ = q.consumeUpTo(videoId: ids.randomElement(using: &rng)!)
            case 5: q.replaceServerRegion(ids.shuffled(using: &rng).prefix(5).map { item($0) })
            case 6: q.move(videoId: ids.randomElement(using: &rng)!, by: Int.random(in: -3...3, using: &rng))
            default: break
            }
            XCTAssertLessThanOrEqual(q.userQueueCount, q.upNext.count,
                "userQueueCount must never exceed upNext.count")
            XCTAssertGreaterThanOrEqual(q.userQueueCount, 0,
                "userQueueCount must be non-negative")
        }
    }
}

/// `BrowseIdResolver` paths 2 and 3 are pure (no network) and can be
/// tested directly. Path 1 (innerTube.playable) requires a network
/// stub — left for an integration test once we wire URLProtocol-based
/// stubs into the test target.
final class BrowseIdResolverTests: XCTestCase {

    /// VL-prefixed browseIds where InnerTube can't resolve should fall
    /// through to the direct-playlist path, with the VL stripped.
    func testVLPrefixStripFallback() async {
        // Use a mock InnerTubeClient with a session that always 404s
        // so `innerTube.playable(...)` throws → resolver moves on.
        let unreachable = InnerTubeClient(session: Self.failingSession)
        let result = await BrowseIdResolver.resolve("VLPLfake123", via: unreachable)
        XCTAssertEqual(result, .directPlaylist(playlistId: "PLfake123"))
    }

    /// Non-VL browseIds where resolution fails should land on the
    /// browse-page fallback URL.
    func testBrowsePageFallback() async {
        let unreachable = InnerTubeClient(session: Self.failingSession)
        let result = await BrowseIdResolver.resolve("MPREb_unresolvable", via: unreachable)
        let expected = URL(string: "https://music.youtube.com/browse/MPREb_unresolvable")!
        XCTAssertEqual(result, .browsePage(expected))
    }

    /// URLSession that fails every request — used to drive the resolver
    /// past the InnerTube path so we can assert the fallback branches.
    /// We don't intercept; we just point at an unreachable hostname so
    /// the request fails fast.
    private static let failingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.1
        config.timeoutIntervalForResource = 0.1
        return URLSession(configuration: config)
    }()
}

/// Tier 2 #9: per-kind playback rate defaults. The kind-derivation is
/// pure (no UserDefaults touched), so these stay tight unit tests.
final class PlaybackKindTests: XCTestCase {
    func testSongMapsToMusic() {
        XCTAssertEqual(PlayerBridge.PlaybackKind.from(.song), .music)
    }
    func testAlbumMapsToMusic() {
        XCTAssertEqual(PlayerBridge.PlaybackKind.from(.album), .music)
    }
    func testPlaylistMapsToMusic() {
        XCTAssertEqual(PlayerBridge.PlaybackKind.from(.playlist), .music)
    }
    func testArtistMapsToMusic() {
        XCTAssertEqual(PlayerBridge.PlaybackKind.from(.artist), .music)
    }
    func testEpisodeMapsToSpoken() {
        XCTAssertEqual(PlayerBridge.PlaybackKind.from(.episode), .spoken)
    }
    func testPodcastMapsToSpoken() {
        XCTAssertEqual(PlayerBridge.PlaybackKind.from(.podcast), .spoken)
    }
    func testMusicDefaultRate() {
        XCTAssertEqual(PlayerBridge.PlaybackKind.music.defaultRate, 1.0)
    }
    func testSpokenDefaultRate() {
        XCTAssertEqual(PlayerBridge.PlaybackKind.spoken.defaultRate, 1.25)
    }
}

/// Tier 3 A3: sleep timer modes. PlayerBridge itself can't be
/// instantiated without a WKWebView, but the mode enum and the
/// fade duration constant are pure surface — these guard against
/// silent renames.
final class SleepTimerModeTests: XCTestCase {
    func testModesCoverAllThreeBehaviors() {
        XCTAssertEqual(Set(PlayerBridge.SleepTimerMode.allCases),
                       [.hardStop, .fadeOut, .endOfTrack])
    }

    func testFadeOutDurationIsTenSeconds() {
        // Plan A3 fixes this at 10 seconds — bump intentionally,
        // not accidentally.
        XCTAssertEqual(PlayerBridge.fadeOutDuration, 10)
    }
}

/// Tier 3 B8: crossfade between tracks. The ramp arithmetic lives in
/// `Resources/player-bridge.js`; the Swift side owns the setting,
/// the preset list, and the clamp helper. These tests guard the
/// pure surface — the only piece testable without spinning up a
/// WKWebView.
final class CrossfadeSettingTests: XCTestCase {
    func testPresetsAreOffPlusEvenSecondsUpToEight() {
        XCTAssertEqual(PlayerBridge.crossfadePresets, [0, 2, 4, 6, 8])
    }

    func testClampSnapsToNearestPreset() {
        // Exact matches pass through unchanged.
        for preset in PlayerBridge.crossfadePresets {
            XCTAssertEqual(PlayerBridge.clampCrossfade(preset), preset)
        }
        // Off-preset values snap to the nearest supported preset.
        XCTAssertEqual(PlayerBridge.clampCrossfade(1.4), 2)
        XCTAssertEqual(PlayerBridge.clampCrossfade(3.0), 2) // ties resolve to the first-seen
        XCTAssertEqual(PlayerBridge.clampCrossfade(3.4), 4)
        XCTAssertEqual(PlayerBridge.clampCrossfade(7.0), 6) // 7 is equidistant to 6 and 8; ties resolve to first seen
        XCTAssertEqual(PlayerBridge.clampCrossfade(7.1), 8)
    }

    func testClampGuardsAgainstNonFiniteAndOutOfRange() {
        // NaN / infinity collapse to 0 (off) — a corrupted plist that
        // wrote `nan` or `inf` should never strand the user with an
        // unkillable crossfade.
        XCTAssertEqual(PlayerBridge.clampCrossfade(.nan), 0)
        XCTAssertEqual(PlayerBridge.clampCrossfade(.infinity), 0)
        XCTAssertEqual(PlayerBridge.clampCrossfade(-.infinity), 0)
        // Negative values snap to the nearest preset (0).
        XCTAssertEqual(PlayerBridge.clampCrossfade(-5), 0)
        // Beyond the top preset still snaps to the top — we don't
        // silently extend the range.
        XCTAssertEqual(PlayerBridge.clampCrossfade(120), 8)
    }
}
