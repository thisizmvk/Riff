import XCTest
@testable import Riff

/// Tests for D1 — last.fm + ListenBrainz scrobbling.
/// Pure logic only: eligibility math, last.fm signature, payload
/// construction, and the coordinator's dispatch ordering. No network.
final class ScrobblerTests: XCTestCase {

    // MARK: - Eligibility

    func testEligibilityRejectsVeryShortTracks() {
        // <30s track never counts, no matter how much you played.
        XCTAssertFalse(ScrobbleEligibility.isEligible(elapsed: 25, duration: 25))
        XCTAssertFalse(ScrobbleEligibility.isEligible(elapsed: 1000, duration: 29))
    }

    func testEligibilityFiresAtHalfDuration() {
        // 4-minute track: half = 120s.
        XCTAssertFalse(ScrobbleEligibility.isEligible(elapsed: 119, duration: 240))
        XCTAssertTrue(ScrobbleEligibility.isEligible(elapsed: 120, duration: 240))
        XCTAssertTrue(ScrobbleEligibility.isEligible(elapsed: 200, duration: 240))
    }

    func testEligibilityFiresAt240sCap() {
        // 20-minute track: half=600s, but the 240s cap fires first.
        XCTAssertFalse(ScrobbleEligibility.isEligible(elapsed: 239, duration: 1200))
        XCTAssertTrue(ScrobbleEligibility.isEligible(elapsed: 240, duration: 1200))
        XCTAssertTrue(ScrobbleEligibility.isEligible(elapsed: 600, duration: 1200))
    }

    func testEligibilityBoundaryAtMinDuration() {
        // Exactly 30s — half=15s elapsed counts.
        XCTAssertFalse(ScrobbleEligibility.isEligible(elapsed: 14, duration: 30))
        XCTAssertTrue(ScrobbleEligibility.isEligible(elapsed: 15, duration: 30))
    }

    // MARK: - last.fm signature

    /// Canonical example from last.fm's auth spec. Given a known set
    /// of params + a known shared secret, the MD5 signature is
    /// deterministic — we verify against a value computed by hand
    /// (and reproducible by anyone hashing the same input).
    func testLastFmSignatureMatchesSpecExample() {
        // Manually-constructed: keys sorted alphabetically, values
        // concatenated, then secret. We're testing the algorithm,
        // not the spec's literal example (which uses real-world keys
        // we don't ship).
        let params: [String: String] = [
            "api_key": "key123",
            "method": "auth.getSession",
            "token": "tok456",
        ]
        // Expected concat: "api_keykey123methodauth.getSessiontokentok456secret789"
        let secret = "secret789"
        let sig = LastFmScrobbler.signature(params: params, secret: secret)
        // MD5 of the above is stable; compute it independently:
        //   printf "api_keykey123methodauth.getSessiontokentok456secret789" | md5sum
        XCTAssertEqual(sig, "dad7310733feb22209dff541ebb76cba")
    }

    func testLastFmSignatureIsLowercaseHex() {
        let sig = LastFmScrobbler.signature(params: ["a": "1"], secret: "x")
        XCTAssertEqual(sig.count, 32)
        XCTAssertEqual(sig, sig.lowercased())
        XCTAssertTrue(sig.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testLastFmSignatureKeyOrderingIsAlphabetical() {
        // Two inputs that differ only in dict ordering must produce
        // the same signature.
        let a: [String: String] = ["z": "1", "a": "2", "m": "3"]
        let b: [String: String] = ["a": "2", "m": "3", "z": "1"]
        XCTAssertEqual(
            LastFmScrobbler.signature(params: a, secret: "k"),
            LastFmScrobbler.signature(params: b, secret: "k")
        )
    }

    // MARK: - ListenBrainz payload shape

    func testListenBrainzScrobblePayload() {
        let track = ScrobbleTrack(
            artist: "Artist X",
            title: "Song Y",
            album: "Album Z",
            durationSeconds: 245,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let payload = ListenBrainzScrobbler.buildPayload(track: track, listenType: .single)
        XCTAssertEqual(payload["listen_type"] as? String, "single")
        let listens = payload["payload"] as? [[String: Any]]
        XCTAssertEqual(listens?.count, 1)
        let listen = listens?.first
        XCTAssertEqual(listen?["listened_at"] as? Int, 1_700_000_000)
        let meta = listen?["track_metadata"] as? [String: Any]
        XCTAssertEqual(meta?["track_name"] as? String, "Song Y")
        XCTAssertEqual(meta?["artist_name"] as? String, "Artist X")
        XCTAssertEqual(meta?["release_name"] as? String, "Album Z")
        let addl = meta?["additional_info"] as? [String: Any]
        XCTAssertEqual(addl?["duration_ms"] as? Int, 245_000)
    }

    func testListenBrainzPlayingNowOmitsListenedAt() {
        let track = ScrobbleTrack(
            artist: "Artist", title: "Title", album: nil,
            durationSeconds: nil, startedAt: Date()
        )
        let payload = ListenBrainzScrobbler.buildPayload(track: track, listenType: .playingNow)
        XCTAssertEqual(payload["listen_type"] as? String, "playing_now")
        let listen = (payload["payload"] as? [[String: Any]])?.first
        // listened_at must NOT be in playing_now payloads — the API
        // rejects them otherwise.
        XCTAssertNil(listen?["listened_at"])
        // And nil album / nil duration shouldn't leak null fields.
        let meta = listen?["track_metadata"] as? [String: Any]
        XCTAssertNil(meta?["release_name"])
        XCTAssertNil(meta?["additional_info"])
    }

    func testListenBrainzPayloadIsValidJSON() {
        // Round-trip through JSONSerialization to catch any non-JSON
        // values (NSDate, etc.) that would silently break the wire
        // format.
        let track = ScrobbleTrack(
            artist: "A", title: "T", album: "B",
            durationSeconds: 100, startedAt: Date(timeIntervalSince1970: 1)
        )
        let payload = ListenBrainzScrobbler.buildPayload(track: track, listenType: .single)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload, options: []))
    }

    // MARK: - Coordinator

    /// In-memory stub service that records every call. Lets us verify
    /// dispatch ordering without a network.
    private final class StubService: ScrobblerService, @unchecked Sendable {
        let displayName = "Stub"
        var isReady: Bool = true
        private let lock = NSLock()
        private var _nowPlayingCalls: [ScrobbleTrack] = []
        private var _scrobbleCalls: [ScrobbleTrack] = []

        var nowPlayingCalls: [ScrobbleTrack] { lock.lock(); defer { lock.unlock() }; return _nowPlayingCalls }
        var scrobbleCalls:   [ScrobbleTrack] { lock.lock(); defer { lock.unlock() }; return _scrobbleCalls }

        func updateNowPlaying(_ track: ScrobbleTrack) async {
            lock.lock(); _nowPlayingCalls.append(track); lock.unlock()
        }
        func scrobble(_ track: ScrobbleTrack) async {
            lock.lock(); _scrobbleCalls.append(track); lock.unlock()
        }
    }

    @MainActor
    func testCoordinatorFiresNowPlayingOnceAndScrobbleOnceAtThreshold() async {
        let stub = StubService()
        let coord = ScrobblerCoordinator(services: [stub])
        let track = ScrobbleTrack(
            artist: "A", title: "T", album: nil,
            durationSeconds: 200, startedAt: Date()
        )

        let t0 = Date()

        // First playing tick: now-playing fires, scrobble doesn't.
        coord.observe(track: track, videoId: "v1", elapsed: 1, duration: 200,
                      isPlaying: true, now: t0)
        // Allow the Task in observe() a beat to run.
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(stub.nowPlayingCalls.count, 1, "now-playing fires on first eligible tick")
        XCTAssertEqual(stub.scrobbleCalls.count, 0, "not yet eligible")

        // 49 more ticks, 2 s of wall clock apart ⇒ 98 s LISTENED:
        // still under the 100 s (50 %) threshold. Eligibility is
        // measured on listened time, not position, so the elapsed
        // values are irrelevant here.
        for i in 1...49 {
            coord.observe(track: track, videoId: "v1", elapsed: Double(i) * 2, duration: 200,
                          isPlaying: true, now: t0.addingTimeInterval(Double(i) * 2))
        }
        await Task.yield()
        XCTAssertEqual(stub.nowPlayingCalls.count, 1, "now-playing is once-per-track")
        XCTAssertEqual(stub.scrobbleCalls.count, 0, "98 s listened < 100 s threshold")

        // The tick that crosses 100 s listened: scrobble fires.
        coord.observe(track: track, videoId: "v1", elapsed: 100, duration: 200,
                      isPlaying: true, now: t0.addingTimeInterval(100))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(stub.scrobbleCalls.count, 1)

        // Further ticks don't re-scrobble the same track.
        coord.observe(track: track, videoId: "v1", elapsed: 102, duration: 200,
                      isPlaying: true, now: t0.addingTimeInterval(102))
        await Task.yield()
        XCTAssertEqual(stub.scrobbleCalls.count, 1, "scrobble is once-per-track")
    }

    /// The regression the listened-time gate fixes: a restored session
    /// (or a seek) that lands past 50 % must NOT scrobble — position
    /// is not proof the user heard the track.
    @MainActor
    func testCoordinatorDoesNotScrobbleOnSeekPastThreshold() async {
        let stub = StubService()
        let coord = ScrobblerCoordinator(services: [stub])
        let track = ScrobbleTrack(artist: "A", title: "T", album: nil,
                                  durationSeconds: 200, startedAt: Date())
        let t0 = Date()
        coord.observe(track: track, videoId: "v1", elapsed: 150, duration: 200,
                      isPlaying: true, now: t0)
        coord.observe(track: track, videoId: "v1", elapsed: 151, duration: 200,
                      isPlaying: true, now: t0.addingTimeInterval(1))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(stub.nowPlayingCalls.count, 1)
        XCTAssertEqual(stub.scrobbleCalls.count, 0,
                       "position 150 s but only ~1 s listened — no scrobble")
    }

    @MainActor
    func testCoordinatorDoesNotFireWhenPaused() async {
        let stub = StubService()
        let coord = ScrobblerCoordinator(services: [stub])
        let track = ScrobbleTrack(
            artist: "A", title: "T", album: nil,
            durationSeconds: 200, startedAt: Date()
        )
        // Paused observation: no now-playing.
        coord.observe(track: track, videoId: "v1", elapsed: 1, duration: 200, isPlaying: false)
        await Task.yield()
        XCTAssertEqual(stub.nowPlayingCalls.count, 0)
    }

    @MainActor
    func testCoordinatorTreatsNewVideoIdAsFreshTrack() async {
        let stub = StubService()
        let coord = ScrobblerCoordinator(services: [stub])
        let t1 = ScrobbleTrack(artist: "A", title: "T1", album: nil, durationSeconds: 200, startedAt: Date())
        let t2 = ScrobbleTrack(artist: "A", title: "T2", album: nil, durationSeconds: 200, startedAt: Date())
        let t0 = Date()
        // Play the first track to 100 s of LISTENED time (51 ticks,
        // 2 s of wall clock apart).
        for i in 0...50 {
            coord.observe(track: t1, videoId: "v1", elapsed: Double(i) * 2, duration: 200,
                          isPlaying: true, now: t0.addingTimeInterval(Double(i) * 2))
        }
        await Task.yield(); await Task.yield()
        XCTAssertEqual(stub.scrobbleCalls.count, 1)
        // Switch to a new videoId — now-playing and scrobble both
        // become available again, and the listened window restarts
        // from zero.
        let s0 = t0.addingTimeInterval(200)
        coord.observe(track: t2, videoId: "v2", elapsed: 1, duration: 200,
                      isPlaying: true, now: s0)
        await Task.yield(); await Task.yield()
        XCTAssertEqual(stub.nowPlayingCalls.count, 2)
        for i in 1...50 {
            coord.observe(track: t2, videoId: "v2", elapsed: Double(i) * 2, duration: 200,
                          isPlaying: true, now: s0.addingTimeInterval(Double(i) * 2))
        }
        await Task.yield(); await Task.yield()
        XCTAssertEqual(stub.scrobbleCalls.count, 2)
    }

    @MainActor
    func testCoordinatorSkipsUnreadyServices() async {
        let ready = StubService()
        let notReady = StubService()
        notReady.isReady = false
        let coord = ScrobblerCoordinator(services: [ready, notReady])
        let track = ScrobbleTrack(artist: "A", title: "T", album: nil, durationSeconds: 200, startedAt: Date())
        let t0 = Date()
        for i in 0...50 {
            coord.observe(track: track, videoId: "v1", elapsed: Double(i) * 2, duration: 200,
                          isPlaying: true, now: t0.addingTimeInterval(Double(i) * 2))
        }
        await Task.yield(); await Task.yield()
        XCTAssertEqual(ready.nowPlayingCalls.count, 1)
        XCTAssertEqual(ready.scrobbleCalls.count, 1)
        XCTAssertEqual(notReady.nowPlayingCalls.count, 0)
        XCTAssertEqual(notReady.scrobbleCalls.count, 0)
    }

    @MainActor
    func testCoordinatorResetClearsPending() async {
        let stub = StubService()
        let coord = ScrobblerCoordinator(services: [stub])
        let track = ScrobbleTrack(artist: "A", title: "T", album: nil, durationSeconds: 200, startedAt: Date())
        coord.observe(track: track, videoId: "v1", elapsed: 5, duration: 200, isPlaying: true)
        await Task.yield()
        XCTAssertEqual(stub.nowPlayingCalls.count, 1)
        // Reset → same track now becomes "fresh" again, fires
        // now-playing a second time.
        coord.reset()
        coord.observe(track: track, videoId: "v1", elapsed: 5, duration: 200, isPlaying: true)
        await Task.yield()
        XCTAssertEqual(stub.nowPlayingCalls.count, 2)
    }

    // MARK: - Form encoding

    func testFormEncodeEscapesReservedCharacters() {
        let data = Scrobblers.formEncode([
            "method": "track.scrobble",
            "artist": "AC/DC",
            "track": "Hello World!",
        ])
        let body = String(data: data, encoding: .utf8) ?? ""
        // Keys are sorted: artist, method, track.
        XCTAssertEqual(body, "artist=AC%2FDC&method=track.scrobble&track=Hello%20World%21")
    }
}
