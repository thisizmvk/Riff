import Foundation

// ── Tiny assertion framework ────────────────────────────────────────
var passes = 0
var failures = 0
func check(_ cond: Bool, _ label: String, line: UInt = #line) {
    if cond { passes += 1 } else { failures += 1; print("FAIL [line \(line)] \(label)") }
}

func item(_ id: String) -> MediaItem {
    MediaItem(id: id, kind: .song, title: "T\(id)", subtitle: "Artist\(id)", thumbnailURL: nil)
}
func ids(_ q: QueueManager) -> [String] { q.upNext.map(\.id) }

// Isolated defaults per run so persisted history can't leak between runs.
let suite = "riff.harness.\(ProcessInfo.processInfo.processIdentifier)"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)
func freshQ(cap: Int = 500) -> QueueManager {
    defaults.removePersistentDomain(forName: suite)
    return QueueManager(historyCap: cap, defaults: defaults)
}

// Core invariants that must hold after EVERY operation.
func invariants(_ q: QueueManager, _ ctx: String, line: UInt = #line) {
    check(q.userQueueCount >= 0 && q.userQueueCount <= q.upNext.count,
          "\(ctx): 0 <= userQueueCount(\(q.userQueueCount)) <= count(\(q.upNext.count))", line: line)
    check(q.playedHistory.map(\.id) == q.playedEntries.map(\.item.id),
          "\(ctx): playedHistory mirror in sync", line: line)
}

// ── 1. Play Next / Add to Queue semantics ───────────────────────────
do {
    let q = freshQ()
    q.replaceServerRegion([item("s1"), item("s2"), item("s3")])
    q.playNext(item("u1"))                    // [u1 | s1 s2 s3]
    q.playNext(item("u2"))                    // [u2 u1 | s1 s2 s3]
    check(ids(q) == ["u2", "u1", "s1", "s2", "s3"], "playNext inserts at head, newest first")
    check(q.userQueueCount == 2, "playNext grows user region")
    q.addToEnd(item("u3"))                    // [u2 u1 u3 | s1 s2 s3]
    check(ids(q) == ["u2", "u1", "u3", "s1", "s2", "s3"], "addToEnd lands at user-region tail")
    check(q.userQueueCount == 3, "addToEnd grows user region")
    // Promote a server item via addToEnd.
    q.addToEnd(item("s2"))                    // [u2 u1 u3 s2 | s1 s3]
    check(ids(q) == ["u2", "u1", "u3", "s2", "s1", "s3"], "addToEnd promotes server item in place")
    check(q.userQueueCount == 4, "promotion grows user region")
    // addToEnd of an existing user item is a no-op.
    q.addToEnd(item("u1"))
    check(ids(q) == ["u2", "u1", "u3", "s2", "s1", "s3"] && q.userQueueCount == 4, "addToEnd dedupes user region")
    // playNext moves an existing user item to the front.
    q.playNext(item("u3"))                    // [u3 u2 u1 s2 | s1 s3]
    check(ids(q) == ["u3", "u2", "u1", "s2", "s1", "s3"] && q.userQueueCount == 4, "playNext re-fronts existing user item")
    invariants(q, "playNext/addToEnd")
}

// ── 2. replaceServerRegion dedupe (bug fix C4a) ─────────────────────
do {
    let q = freshQ()
    q.playNext(item("u1"))
    // Incoming server list: internal duplicate d1, plus u1 (already user-queued).
    q.replaceServerRegion([item("d1"), item("s2"), item("d1"), item("u1"), item("s3")])
    check(ids(q) == ["u1", "d1", "s2", "s3"], "replaceServerRegion dedupes internally AND vs user region")
    check(q.userQueueCount == 1, "user region untouched by replace")
    invariants(q, "replaceServerRegion")
    // extendServerRegion dedupes against the whole queue.
    q.extendServerRegion([item("s2"), item("s4"), item("u1"), item("s4")])
    // s4 appears twice in the incoming batch — extend dedupes vs existing queue;
    // within-batch duplicate: the filter uses a Set built from upNext only, so
    // the second s4 passes the existing check... verify actual behavior:
    let s4Count = ids(q).filter { $0 == "s4" }.count
    check(s4Count == 1, "extendServerRegion must not append the same id twice (within-batch dedupe)")
    invariants(q, "extendServerRegion")
}

// ── 3. Reorder with pre-existing duplicates must not crash (C4b) ────
do {
    let q = freshQ()
    // replaceQueue performs NO dedupe (wholesale) — the legacy path a dupe
    // could still arrive through. This used to TRAP in reorder.
    q.replaceQueue([item("a"), item("b"), item("a"), item("c")])
    q.reorder(visibleIds: ["a", "b", "a", "c"], from: IndexSet(integer: 3), to: 0)
    check(true, "reorder with duplicate ids did not crash")
    invariants(q, "reorder-duplicates")
}

// ── 4. consumeHead / consumeUpTo boundary arithmetic ────────────────
do {
    let q = freshQ()
    q.playNext(item("u1"))
    q.addToEnd(item("u2"))
    q.replaceServerRegion([item("s1"), item("s2"), item("s3")])
    // Deep jump into the server region consumes the user region too.
    let dropped = q.consumeUpTo(videoId: "s2")
    check(dropped.map(\.id) == ["u1", "u2", "s1", "s2"], "consumeUpTo returns dropped rows in order")
    check(ids(q) == ["s3"] && q.userQueueCount == 0, "consumeUpTo pops through the user region and zeroes it")
    invariants(q, "consumeUpTo")

    let q2 = freshQ()
    q2.playNext(item("u1"))
    q2.replaceServerRegion([item("s1")])
    let head = q2.consumeHead()
    check(head?.id == "u1" && q2.userQueueCount == 0 && ids(q2) == ["s1"], "consumeHead pops user head + adjusts count")
    _ = q2.consumeHead()
    let empty = q2.consumeHead()
    check(empty == nil && q2.userQueueCount == 0, "consumeHead on empty queue is nil, count stays 0")
    invariants(q2, "consumeHead")
}

// ── 5. remove + move across the region boundary ─────────────────────
do {
    let q = freshQ()
    q.playNext(item("u1")); q.addToEnd(item("u2"))
    q.replaceServerRegion([item("s1"), item("s2")])
    q.remove(videoId: "u1")
    check(q.userQueueCount == 1 && ids(q) == ["u2", "s1", "s2"], "remove inside user region shrinks count")
    q.remove(videoId: "s2")
    check(q.userQueueCount == 1 && ids(q) == ["u2", "s1"], "remove in server region leaves count")
    q.remove(videoId: "nope")
    check(ids(q) == ["u2", "s1"], "remove unknown id is a no-op")
    // move server item up into user region → promotion.
    q.move(videoId: "s1", by: -1)
    check(ids(q) == ["s1", "u2"], "move -1 swaps")
    invariants(q, "remove/move")
}

// ── 6. archive: dedupe, cap, mirror consistency ─────────────────────
do {
    let q = freshQ(cap: 5)
    for i in 1...4 { q.archive(item("h\(i)")) }
    q.archive(item("h4"))  // consecutive dupe → no-op
    check(q.playedEntries.count == 4, "archive dedupes consecutive same id")
    for i in 5...9 { q.archive(item("h\(i)")) }
    check(q.playedEntries.count == 5, "history cap enforced")
    check(q.playedEntries.map(\.item.id) == ["h5", "h6", "h7", "h8", "h9"], "cap drops OLDEST entries")
    check(q.playedHistory.map(\.id) == ["h5", "h6", "h7", "h8", "h9"], "stored mirror matches after cap trims")
    invariants(q, "archive")
}

// ── 7. SmartShuffle.merge contract ──────────────────────────────────
do {
    let base = (1...8).map { item("b\($0)") }
    let pool = (1...5).map { item("p\($0)") }
    let r = SmartShuffle.merge(base: base, pool: pool, every: 4)
    // Injections before base items at cadence: after every 3 base items.
    check(r.merged.map(\.id) == ["b1", "b2", "b3", "p1", "b4", "b5", "b6", "p2", "b7", "b8"],
          "merge injects every 4th slot (got \(r.merged.map(\.id)))")
    check(r.injectedIds == ["p1", "p2"], "injectedIds tracks pool picks")
    // Pool overlapping base is filtered.
    let r2 = SmartShuffle.merge(base: base, pool: [item("b1"), item("p1"), item("p1")], every: 4)
    check(!r2.merged.dropFirst(0).map(\.id).contains("b1") || r2.merged.filter { $0.id == "b1" }.count == 1,
          "pool item already in base never duplicates")
    check(r2.injectedIds == ["p1"], "pool internal dupes collapsed")
    // Empty pool → identity.
    let r3 = SmartShuffle.merge(base: base, pool: [item("b2")], every: 4)
    check(r3.merged.map(\.id) == base.map(\.id) && r3.injectedIds.isEmpty, "fully-filtered pool → identity")
    // every clamped to >= 2.
    let r4 = SmartShuffle.merge(base: base, pool: pool, every: 0)
    check(r4.merged.count <= base.count + base.count, "every=0 clamps, no runaway")
}

// ── 8. CookieImporter.parse ─────────────────────────────────────────
do {
    let pairs = CookieImporter.parse("SAPISID=abc123; __Secure-3PAPISID=xyz;  HSID=h1 ;empty=;=bad; SIDCC=v v")
    check(pairs["SAPISID"] == "abc123", "parse basic pair")
    check(pairs["HSID"] == "h1", "parse trims whitespace")
    check(pairs["=bad"] == nil && pairs[""] == nil, "no empty-name entries")
    check(CookieImporter.hasAuthCookie(pairs), "SAPISID detected as auth cookie")
    check(!CookieImporter.hasAuthCookie(["FOO": "bar"]), "no auth cookie → false")
}

// ── 9. Fuzz: 5000 random ops with invariants after each ─────────────
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
do {
    var rng = SplitMix64(state: 0xDEADBEEF)
    let q = freshQ(cap: 50)
    var fuzzFailures = 0
    for opIndex in 0..<5000 {
        let op = Int.random(in: 0..<11, using: &rng)
        let pick = "f\(Int.random(in: 0..<40, using: &rng))"
        let userBefore = Array(q.upNext.prefix(q.userQueueCount).map(\.id))
        switch op {
        case 0: q.playNext(item(pick))
        case 1: q.addToEnd(item(pick))
        case 2:
            let n = Int.random(in: 0..<8, using: &rng)
            let batch = (0..<n).map { _ in item("f\(Int.random(in: 0..<40, using: &rng))") }
            q.replaceServerRegion(batch)
            // User region must be preserved verbatim by replace.
            let userAfter = Array(q.upNext.prefix(q.userQueueCount).map(\.id))
            if userAfter != userBefore {
                fuzzFailures += 1
                print("FUZZ[\(opIndex)] replaceServerRegion mutated user region \(userBefore) -> \(userAfter)")
            }
        case 3:
            let n = Int.random(in: 0..<5, using: &rng)
            q.extendServerRegion((0..<n).map { _ in item("f\(Int.random(in: 0..<40, using: &rng))") })
        case 4: q.remove(videoId: pick)
        case 5: _ = q.consumeHead()
        case 6: _ = q.consumeUpTo(videoId: pick)
        case 7: q.move(videoId: pick, by: Int.random(in: -3...3, using: &rng))
        case 8:
            let visible = ids(q)
            if !visible.isEmpty {
                let src = Int.random(in: 0..<visible.count, using: &rng)
                let dst = Int.random(in: 0...visible.count, using: &rng)
                q.reorder(visibleIds: visible, from: IndexSet(integer: src), to: dst)
            }
        case 9: q.archive(item(pick))
        case 10:
            if Int.random(in: 0..<10, using: &rng) == 0 { q.clearQueue() }
        default: break
        }
        if !(q.userQueueCount >= 0 && q.userQueueCount <= q.upNext.count) {
            fuzzFailures += 1
            print("FUZZ[\(opIndex)] op=\(op) invariant broke: count=\(q.userQueueCount) len=\(q.upNext.count)")
        }
        if q.playedHistory.map(\.id) != q.playedEntries.map(\.item.id) {
            fuzzFailures += 1
            print("FUZZ[\(opIndex)] op=\(op) history mirror drifted")
        }
    }
    check(fuzzFailures == 0, "fuzz: 5000 ops, all invariants held (\(fuzzFailures) violations)")
}

// ── 10. Repeat All cycle-building algorithm (mirrors PlayerBridge) ──
do {
    // Same slice + dedupe logic as the .ended Repeat All hook.
    let entries = ["a", "b", "c", "b"].map { PlayedEntry(item: item($0), playedAt: Date()) }
    let contextStart = 1
    var cycle = entries[min(contextStart, entries.count)...].map(\.item)
    cycle.append(item("d"))  // the finishing current track
    var seen = Set<String>()
    let ordered = cycle.filter { seen.insert($0.id).inserted }
    check(ordered.map(\.id) == ["b", "c", "d"], "repeat-all cycle slices from context start, dedupes, keeps order")
    let emptyStart = min(7, entries.count)
    let none = entries[emptyStart...].map(\.item)
    check(none.isEmpty, "context start beyond history clamps safely")
}

// ── 10b. Repeat All anchor survives the history cap (mirrors ────────
//         PlayerBridge.archiveCurrent + the .ended cycle builder) ─────
// The context start is an absolute index into playedEntries; the cap
// trims from the FRONT, so every trimmed entry must shift the anchor
// down. Without the shift, a user at the cap (500 plays) got a cycle of
// just the current track and Repeat All fell into radio.
do {
    func archiveShiftingAnchor(_ q: QueueManager, _ id: String, _ anchor: inout Int) {
        let prevCount = q.playedEntries.count
        let prevTail = q.playedEntries.last
        q.archive(item(id))
        guard q.playedEntries.last != prevTail else { return }   // tail dedupe: nothing appended
        let trimmed = max(0, prevCount + 1 - q.playedEntries.count)
        if trimmed > 0 { anchor = max(0, anchor - trimmed) }
    }
    func repeatAllCycle(_ q: QueueManager, anchor: Int, current: String) -> [String] {
        var cycle = q.playedEntries[min(anchor, q.playedEntries.count)...].map(\.item)
        cycle.append(item(current))
        var seen = Set<String>()
        return cycle.filter { seen.insert($0.id).inserted }.map(\.id)
    }

    // History already AT the cap when the context starts.
    let full = freshQ(cap: 3)
    for h in ["h1", "h2", "h3"] { full.archive(item(h)) }
    var anchor = full.playedEntries.count             // context start
    archiveShiftingAnchor(full, "a1", &anchor)        // a2 starts
    archiveShiftingAnchor(full, "a2", &anchor)        // a3 starts
    check(repeatAllCycle(full, anchor: anchor, current: "a3") == ["a1", "a2", "a3"],
          "repeat-all at the history cap: 3-track context cycles all 3 tracks (was just the current one)")

    // Cap crossed MID-context.
    let mid = freshQ(cap: 5)
    for h in ["h1", "h2", "h3", "h4"] { mid.archive(item(h)) }
    var midAnchor = mid.playedEntries.count
    for a in ["a1", "a2", "a3"] { archiveShiftingAnchor(mid, a, &midAnchor) }
    check(repeatAllCycle(mid, anchor: midAnchor, current: "a4") == ["a1", "a2", "a3", "a4"],
          "repeat-all when the cap is crossed mid-context: no context track dropped, no pre-context track leaked in")

    // A context longer than the cap stays bounded (anchor clamps at 0).
    let long = freshQ(cap: 3)
    var longAnchor = 0
    for a in ["a1", "a2", "a3", "a4", "a5"] { archiveShiftingAnchor(long, a, &longAnchor) }
    check(longAnchor == 0 && repeatAllCycle(long, anchor: longAnchor, current: "a6") == ["a3", "a4", "a5", "a6"],
          "repeat-all context longer than the cap: anchor clamps at 0, cycle = retained history + current")

    // A tail-dedupe no-op at the cap must not shift the anchor.
    let dup = freshQ(cap: 3)
    for h in ["h1", "h2", "h3"] { dup.archive(item(h)) }
    var dupAnchor = 1
    archiveShiftingAnchor(dup, "h3", &dupAnchor)
    check(dupAnchor == 1 && dup.playedEntries.map(\.item.id) == ["h1", "h2", "h3"],
          "archive tail-dedupe at the cap is a no-op for the Repeat All anchor")
}


// ── 11. QueuePolicy decision table — the BEHAVIOR CONTRACT ──────────
// Each row is a user-facing promise from docs/QUEUE-DESIGN.md. Changing
// an answer here is changing the product; do it deliberately, in the
// docs and the policy together.
do {
    typealias A = QueuePolicy.AdvanceInputs
    let radioRow = A(headIsContextTrack: false, contextPlaylistId: nil, currentPlaylistId: "RDAMVMx",
                     headIsUserQueued: false, hasActiveChip: false, mirrorFresh: true, isPageDriven: true)
    check(QueuePolicy.advance(radioRow) == .native, "radio: mirrored head advances page-natively (no reload, no re-roll)")

    var albumInCtx = radioRow
    albumInCtx.headIsContextTrack = true; albumInCtx.contextPlaylistId = "OLAK5uy_a"; albumInCtx.currentPlaylistId = "OLAK5uy_a"; albumInCtx.isPageDriven = false
    check(QueuePolicy.advance(albumInCtx) == .native, "album track while page is in the album: native (no per-track radio navigation)")

    var albumAfterInterlude = albumInCtx
    albumAfterInterlude.currentPlaylistId = "RDAMVMother"
    check(QueuePolicy.advance(albumAfterInterlude) == .navigateIntoContext("OLAK5uy_a"), "album track after an interlude: navigate back INTO the album list")

    var playNextInjection = radioRow
    playNextInjection.headIsUserQueued = true
    check(QueuePolicy.advance(playNextInjection) == .navigateRadio, "unverified Play-Next injection: per-track radio navigation")

    var chipHead = radioRow
    chipHead.hasActiveChip = true
    check(QueuePolicy.advance(chipHead) == .navigateDeterministic, "chip-curated head: Swift drives with the current list")

    var preMirrorPlaylist = radioRow
    preMirrorPlaylist.isPageDriven = false; preMirrorPlaylist.mirrorFresh = false; preMirrorPlaylist.currentPlaylistId = "PLabc"
    check(QueuePolicy.advance(preMirrorPlaylist) == .navigateDeterministic, "/next-seeded deterministic head before the mirror is live: Swift drives")

    var mirroredPlaylist = preMirrorPlaylist
    mirroredPlaylist.mirrorFresh = true
    check(QueuePolicy.advance(mirroredPlaylist) == .native, "deterministic context with a live mirror: native")

    // Enforcement scope
    check(!QueuePolicy.enforcementApplies(userQueueCount: 0, hasActiveChip: false, mirrorFresh: true, isPageDriven: true), "radio + live mirror: never enforce against the page")
    check(QueuePolicy.enforcementApplies(userQueueCount: 1, hasActiveChip: false, mirrorFresh: true, isPageDriven: true), "user-queued items are enforced even in radio")
    check(QueuePolicy.enforcementApplies(userQueueCount: 0, hasActiveChip: true, mirrorFresh: true, isPageDriven: true), "chip queues are enforced")
    check(QueuePolicy.enforcementApplies(userQueueCount: 0, hasActiveChip: false, mirrorFresh: false, isPageDriven: false), "pre-mirror deterministic seeds are enforced")
    check(!QueuePolicy.enforcementApplies(userQueueCount: 0, hasActiveChip: false, mirrorFresh: true, isPageDriven: false), "deterministic context with live mirror: not enforced")

    // Mirror scope
    check(QueuePolicy.mirrorApplies(hasActiveChip: false, userQueueCount: 0), "mirror owns the display when nothing is user-queued and no chip")
    check(!QueuePolicy.mirrorApplies(hasActiveChip: false, userQueueCount: 2), "mirror never repaints beneath user-queued items")
    check(!QueuePolicy.mirrorApplies(hasActiveChip: true, userQueueCount: 0), "chip queues are never overwritten by the mirror")

    // Next / shuffle / row tap
    check(QueuePolicy.nextUsesPageNative(radioRow), "Next in radio uses the page's own next (no reload)")
    check(!QueuePolicy.nextUsesPageNative(playNextInjection), "Next with a user-queued injection plays THAT head (Swift drives)")
    check(QueuePolicy.nextUsesPageNative(albumInCtx), "Next inside an in-order album is page-native (no reload → autoplay tail doesn't re-roll)")
    var shuffledAlbum = albumInCtx
    shuffledAlbum.contextIsPageOrdered = false
    check(QueuePolicy.advance(shuffledAlbum) == .navigateIntoContext("OLAK5uy_a"), "shuffled album: heads navigate INTO the list explicitly (page order would be wrong)")
    check(!QueuePolicy.nextUsesPageNative(shuffledAlbum), "Next in a shuffled album is Swift-driven")
    var afterAlbum = radioRow
    afterAlbum.isPageDriven = false; afterAlbum.currentPlaylistId = "OLAK5uy_a"   // deterministic ctx, mirrored autoplay row
    check(QueuePolicy.nextUsesPageNative(afterAlbum), "after an album drains, Next on a mirrored autoplay row is page-native (never ?v=X&list=<album>, which restarts the album)")
    check(!QueuePolicy.nextUsesPageNative(chipHead), "Next on a chip queue is Swift-driven")
    check(!QueuePolicy.localShuffleAllowed(isPageDriven: true), "no local random pick in radio — shuffle is the page's")
    check(QueuePolicy.localShuffleAllowed(isPageDriven: false), "local shuffle allowed over Riff-owned server rows")
    check(QueuePolicy.rowTapUsesPageJump(hasActiveChip: false, mirrorFresh: true, rowIsUserQueued: false, rowIsInQueue: true), "tapping a mirrored row jumps in place (no navigation)")
    check(!QueuePolicy.rowTapUsesPageJump(hasActiveChip: false, mirrorFresh: true, rowIsUserQueued: true, rowIsInQueue: true), "tapping a user-queued row keeps context-preserving navigation")
    check(!QueuePolicy.rowTapUsesPageJump(hasActiveChip: true, mirrorFresh: true, rowIsUserQueued: false, rowIsInQueue: true), "chip rows are not page-jumped")

    // Context exhaustion
    let album: Set<String> = ["a1", "a2", "a3"]
    check(QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: album, currentId: "a3", headId: "radioX"), "last album track + only autoplay filler ahead = exhausted")
    check(QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: album, currentId: "a3", headId: nil), "last album track + empty queue = exhausted")
    check(!QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: album, currentId: "a2", headId: "a3"), "mid-album is not exhausted")
    check(!QueuePolicy.contextExhausted(userQueueCount: 1, contextTrackIds: album, currentId: "a3", headId: "x"), "user-queued items pending: not exhausted")
    check(!QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: ["seed"], currentId: "seed", headId: "r1"), "single-track radio seed never exhausts (radio is infinite)")
    check(!QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: album, currentId: "radioX", headId: "radioY"), "already past the context: not exhausted (no cycle from radio)")
}


// ── 12. Time-of-day shelf (pure) ────────────────────────────────────
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    func at(_ day: Int, _ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }
    let now = at(10, 8)   // a morning
    check(PersonalizedShelves.DaySlot.slot(for: at(10, 8), calendar: cal) == .morning, "08:00 is morning")
    check(PersonalizedShelves.DaySlot.slot(for: at(10, 13), calendar: cal) == .afternoon, "13:00 is afternoon")
    check(PersonalizedShelves.DaySlot.slot(for: at(10, 19), calendar: cal) == .evening, "19:00 is evening")
    check(PersonalizedShelves.DaySlot.slot(for: at(10, 23), calendar: cal) == .lateNight, "23:00 is late night")
    check(PersonalizedShelves.DaySlot.slot(for: at(10, 2), calendar: cal) == .lateNight, "02:00 is late night")

    func thumbed(_ id: String) -> MediaItem {
        MediaItem(id: id, kind: .song, title: id, subtitle: "A", thumbnailURL: URL(string: "https://x/\(id).jpg"))
    }
    // Too little signal → nil.
    let sparse = (0..<5).map { PlayedEntry(item: thumbed("s\($0)"), playedAt: at(1 + $0, 7)) }
    check(PersonalizedShelves.timeOfDayShelf(from: sparse, now: now, calendar: cal) == nil, "sparse morning history → no shelf")

    // Enough morning plays: m1 played 5×, m2 4×, ..., plus evening plays that must NOT count.
    var entries: [PlayedEntry] = []
    for (idx, plays) in [5, 4, 3, 3, 2, 2, 1, 1, 1, 1].enumerated() {
        for n in 0..<plays { entries.append(PlayedEntry(item: thumbed("m\(idx)"), playedAt: at(1 + n, 7 + idx % 3))) }
    }
    for n in 0..<20 { entries.append(PlayedEntry(item: thumbed("e\(n)"), playedAt: at(1 + n % 9, 20))) }
    let shelf = PersonalizedShelves.timeOfDayShelf(from: entries, now: now, calendar: cal)
    check(shelf?.slot == .morning && shelf?.title == "Your morning rotation", "shelf targets the current slot")
    check(shelf?.items.first?.id == "m0" && shelf?.items[1].id == "m1", "ranked by plays within the slot")
    check(!(shelf?.items.contains { $0.id.hasPrefix("e") } ?? true), "evening plays never leak into the morning shelf")
    // Same history, evening now → the evening tracks, not the morning ones.
    let evening = PersonalizedShelves.timeOfDayShelf(from: entries, now: at(10, 20), calendar: cal)
    check(evening?.slot == .evening && (evening?.items.allSatisfy { $0.id.hasPrefix("e") } ?? false), "evening shelf is built from evening plays only")
}

// ═══════════════════════════════════════════════════════════════════
// Sections 13–17 (QA batch 2026-09-10): policy cube, QueueManager,
// PersonalizedShelves, SmartShuffle, CookieImporter. The five rows that
// were `bug(...)` xfails when written are plain checks now (fixed).
// ═══════════════════════════════════════════════════════════════════

func nonEmpty(_ s: String?) -> Bool { if let s, !s.isEmpty { return true }; return false }

// Strict xfail: a check that documents a PROBABLE BUG found by the
// tester. While the bug exists it prints KNOWN BUG and does not count
// as a failure; once the code is fixed it FAILS so the row gets
// promoted to a plain `check(...)`.
var knownBugs = 0
func bug(_ cond: Bool, _ label: String, line: UInt = #line) {
    if cond { failures += 1; print("FIXED? [line \(line)] \(label) — promote this bug() to check()") }
    else { knownBugs += 1; print("KNOWN BUG [line \(line)] \(label)") }
}

// ── 13. QueuePolicy — exhaustive consistency + edge rows ────────────
// The table in section 11 pins named rows. This walks the WHOLE input
// cube (2^6 flags × 4 context ids × 4 current ids = 1024 rows) and
// asserts the contract-derived properties that must hold on every row.
do {
    typealias A = QueuePolicy.AdvanceInputs
    let bools = [false, true]
    let plids: [String?] = [nil, "", "OLAK5uy_a", "RDAMVMx"]
    var rows = 0
    var p1 = 0, p2 = 0, p3 = 0, p4 = 0, p5 = 0, p6 = 0, p7 = 0
    for hc in bools { for hu in bools { for chip in bools { for mf in bools { for pd in bools { for po in bools {
        for ctx in plids { for cur in plids {
            let i = A(headIsContextTrack: hc, contextPlaylistId: ctx, currentPlaylistId: cur,
                      headIsUserQueued: hu, hasActiveChip: chip, mirrorFresh: mf,
                      isPageDriven: pd, contextIsPageOrdered: po)
            let v = QueuePolicy.advance(i)
            rows += 1
            let inContext = hc && nonEmpty(ctx)
            // P1 (contract 9): Next and end-of-track share ONE verdict.
            if QueuePolicy.nextUsesPageNative(i) != (v == .native) { p1 += 1 }
            // P2: navigateIntoContext carries exactly the context id, never empty, only for context heads.
            if case .navigateIntoContext(let l) = v, (l.isEmpty || l != ctx || !inContext) { p2 += 1 }
            // P3 (contract 7): a context head with a real list id NEVER gets per-track radio.
            if inContext, v == .navigateRadio { p3 += 1 }
            // P4 (contract 5): a user-queued head outside the context is ALWAYS navigateRadio (enforced even in radio, even under a chip).
            if hu, !inContext, v != .navigateRadio { p4 += 1 }
            // P5 (contract 2): plain page-driven radio row (no chip / user / context) is native even BEFORE the first mirror.
            if pd, !chip, !hu, !inContext, v != .native { p5 += 1 }
            // P6 (contract 9): a shuffled album head is never page-native.
            if inContext, !po, v == .native { p6 += 1 }
            // P7 (contract 11): navigateIntoContext only when the page is NOT already in that list in page order.
            if case .navigateIntoContext = v, po, cur == ctx { p7 += 1 }
        } }
    } } } } } }
    check(rows == 1024, "policy cube enumerated (\(rows) rows)")
    check(p1 == 0, "P1: nextUsesPageNative == (advance == .native) on every row (\(p1) violations)")
    check(p2 == 0, "P2: navigateIntoContext payload is the non-empty context id (\(p2) violations)")
    check(p3 == 0, "P3: context heads never navigate to per-track radio (\(p3) violations)")
    check(p4 == 0, "P4: off-context user-queued heads always navigateRadio (\(p4) violations)")
    check(p5 == 0, "P5: page-driven radio rows are native even pre-mirror (\(p5) violations)")
    check(p6 == 0, "P6: shuffled album heads are never native (\(p6) violations)")
    check(p7 == 0, "P7: no navigateIntoContext while already inside the ordered list (\(p7) violations)")

    // Named edge rows not in section 11.
    let base = A(headIsContextTrack: false, contextPlaylistId: nil, currentPlaylistId: "RDAMVMx",
                 headIsUserQueued: false, hasActiveChip: false, mirrorFresh: true, isPageDriven: true)
    var chipPlusUser = base; chipPlusUser.hasActiveChip = true; chipPlusUser.headIsUserQueued = true
    check(QueuePolicy.advance(chipPlusUser) == .navigateRadio, "chip + Play-Next head: explicit intent wins (navigateRadio, not chip-deterministic)")
    var chipInsideAlbum = base
    chipInsideAlbum.hasActiveChip = true; chipInsideAlbum.headIsContextTrack = true
    chipInsideAlbum.contextPlaylistId = "OLAK5uy_a"; chipInsideAlbum.currentPlaylistId = "OLAK5uy_a"; chipInsideAlbum.isPageDriven = false
    check(QueuePolicy.advance(chipInsideAlbum) == .native, "DOCUMENTED: in-order album head inside its list is native even with a chip active (context outranks chip)")
    var emptyCtx = base; emptyCtx.headIsContextTrack = true; emptyCtx.contextPlaylistId = ""
    check(QueuePolicy.advance(emptyCtx) == .native, "empty-string context id is treated as no context (radio row stays native)")
    var emptyCtxUser = emptyCtx; emptyCtxUser.headIsUserQueued = true
    check(QueuePolicy.advance(emptyCtxUser) == .navigateRadio, "Repeat-All cycle (playTracks with nil playlistId) heads advance via per-track radio navigation — DOCUMENTED current answer")
    var radioPreMirror = base; radioPreMirror.mirrorFresh = false
    check(QueuePolicy.advance(radioPreMirror) == .native, "radio before the first mirror: still native (no reload while the page is loading)")
    var shuffledAfterInterlude = base
    shuffledAfterInterlude.headIsContextTrack = true; shuffledAfterInterlude.contextPlaylistId = "OLAK5uy_a"
    shuffledAfterInterlude.currentPlaylistId = "RDAMVMz"; shuffledAfterInterlude.contextIsPageOrdered = false; shuffledAfterInterlude.isPageDriven = false
    check(QueuePolicy.advance(shuffledAfterInterlude) == .navigateIntoContext("OLAK5uy_a"), "shuffled album after an interlude navigates INTO the album list")
    var contextHeadUserQueued = base
    contextHeadUserQueued.headIsContextTrack = true; contextHeadUserQueued.contextPlaylistId = "OLAK5uy_a"
    contextHeadUserQueued.currentPlaylistId = "OLAK5uy_a"; contextHeadUserQueued.headIsUserQueued = true; contextHeadUserQueued.isPageDriven = false
    check(QueuePolicy.advance(contextHeadUserQueued) == .native, "playTracks-seeded album rows (user region AND context) are native inside the album — no per-track radio")

    // Cross-policy: whenever the mirror does NOT own the display (chip or user items), enforcement DOES apply.
    var crossViolations = 0
    for chip in bools { for uc in [0, 1, 5] { for mf in bools { for pd in bools {
        if !QueuePolicy.mirrorApplies(hasActiveChip: chip, userQueueCount: uc),
           !QueuePolicy.enforcementApplies(userQueueCount: uc, hasActiveChip: chip, mirrorFresh: mf, isPageDriven: pd) { crossViolations += 1 }
    } } } }
    check(crossViolations == 0, "Riff owns the list ⇒ Riff enforces it (mirrorApplies=false ⇒ enforcementApplies=true)")

    // rowTapUsesPageJump: exactly one of the 16 combinations jumps.
    var jumpTrue = 0
    for chip in bools { for mf in bools { for ru in bools { for inq in bools {
        if QueuePolicy.rowTapUsesPageJump(hasActiveChip: chip, mirrorFresh: mf, rowIsUserQueued: ru, rowIsInQueue: inq) { jumpTrue += 1 }
    } } } }
    check(jumpTrue == 1, "row tap jumps in-page for exactly one flag combination (mirrored, no chip, not user-queued, in queue)")
    check(!QueuePolicy.rowTapUsesPageJump(hasActiveChip: false, mirrorFresh: false, rowIsUserQueued: false, rowIsInQueue: true), "pre-mirror row tap never page-jumps (rows aren't the page's yet)")
    check(!QueuePolicy.rowTapUsesPageJump(hasActiveChip: false, mirrorFresh: true, rowIsUserQueued: false, rowIsInQueue: false), "a row not in the queue never page-jumps (contract 3: identity or refuse)")

    // contextExhausted boundaries.
    let two: Set<String> = ["a1", "a2"]
    check(QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: two, currentId: "a2", headId: "r"), "two-track context is the smallest that can exhaust")
    check(!QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: two, currentId: nil, headId: nil), "no current track → not exhausted")
    check(!QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: [], currentId: "a1", headId: nil), "empty context never exhausts")
    check(!QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: two, currentId: "a2", headId: "a2"), "head == current (page re-emit / repeat-one) is not exhaustion")
    check(!QueuePolicy.contextExhausted(userQueueCount: 3, contextTrackIds: two, currentId: "a2", headId: nil), "user items pending with an empty head → not exhausted")
    check(QueuePolicy.contextExhausted(userQueueCount: 0, contextTrackIds: two, currentId: "a1", headId: "r1"), "leaving the context early (autoplay filler already next) counts as exhausted")
}

// ── 14. QueueManager — invariants the fuzz did not assert ───────────
do {
    // 14a. Drag reorder must never LOSE a row. The fuzz only checked the
    // count invariant; this checks the id multiset survives.
    var rng = SplitMix64(state: 0xC0FFEE)
    let q = freshQ()
    q.playNext(item("u1")); q.addToEnd(item("u2"))
    q.replaceServerRegion((1...6).map { item("s\($0)") })
    var lost = 0
    for _ in 0..<2000 {
        let before = ids(q).sorted()
        let visible = ids(q)
        let src = Int.random(in: 0..<visible.count, using: &rng)
        let dst = Int.random(in: 0...visible.count, using: &rng)
        q.reorder(visibleIds: visible, from: IndexSet(integer: src), to: dst)
        if ids(q).sorted() != before { lost += 1 }
    }
    check(lost == 0, "reorder preserves the id multiset over 2000 random drags (\(lost) losses)")
    check(q.userQueueCount == 2, "reorder preserves the NUMBER of user-tagged rows (\(q.userQueueCount))")

    // 14b. The view filters the current track out of visibleIds — that
    // row must stay at its original index.
    let q2 = freshQ()
    q2.replaceQueue([item("cur"), item("a"), item("b"), item("c")])
    q2.reorder(visibleIds: ["a", "b", "c"], from: IndexSet(integer: 2), to: 0)
    check(ids(q2) == ["cur", "c", "a", "b"], "rows absent from visibleIds keep their slot (got \(ids(q2)))")

    // 14c. PROBABLE BUG: a STALE id in visibleIds (view rendered before a
    // mirror snapshot replaced the rows) drops a real row on the floor.
    let q3 = freshQ()
    q3.replaceQueue([item("a"), item("b"), item("c")])
    q3.reorder(visibleIds: ["zzz", "a", "b", "c"], from: IndexSet(integer: 3), to: 0)
    check(ids(q3).sorted() == ["a", "b", "c"], "QueueManager.reorder: a stale id in visibleIds silently DROPS a real row (got \(ids(q3)))")

    // 14d. Positional region vs. tag bookkeeping after a drag: the doc
    // comment says a moved item "keeps its ORIGINAL user/server tag",
    // but the region is a prefix — so a server row dragged above the
    // user region BECOMES user-queued and the displaced user row is
    // demoted. Pinning the actual behavior.
    let q4 = freshQ()
    q4.playNext(item("u1"))
    q4.replaceServerRegion([item("s1"), item("s2")])
    q4.reorder(visibleIds: ["u1", "s1", "s2"], from: IndexSet(integer: 1), to: 0)
    check(ids(q4) == ["s1", "u1", "s2"] && q4.userQueueCount == 1, "drag: count of user rows preserved (1)")
    check(q4.isUserQueued(videoId: "s1") && !q4.isUserQueued(videoId: "u1"), "DOCUMENTED: after a drag the prefix decides membership — s1 is now user-queued, u1 is not (doc comment says tags are kept)")
    invariants(q4, "reorder-tags")

    // 14e. move(by:) boundaries.
    let q5 = freshQ()
    q5.playNext(item("u1")); q5.addToEnd(item("u2"))
    q5.replaceServerRegion([item("s1")])
    q5.move(videoId: "u1", by: 99)
    check(ids(q5) == ["u2", "s1", "u1"] && q5.userQueueCount == 1, "move past the end clamps and demotes (got \(ids(q5)) count=\(q5.userQueueCount))")
    q5.move(videoId: "u1", by: -99)
    check(ids(q5) == ["u1", "u2", "s1"] && q5.userQueueCount == 2, "move past the start clamps and promotes (got \(ids(q5)) count=\(q5.userQueueCount))")
    q5.move(videoId: "u2", by: 0)
    check(ids(q5) == ["u1", "u2", "s1"] && q5.userQueueCount == 2, "move by 0 is a no-op")
    q5.move(videoId: "u2", by: 1)
    check(ids(q5) == ["u1", "s1", "u2"] && q5.userQueueCount == 1, "user row moved beneath a server row is demoted")
    q5.move(videoId: "s1", by: 1)
    check(ids(q5) == ["u1", "u2", "s1"] && q5.userQueueCount == 1, "a demoted row does NOT regain user status when the server row beneath it is moved away (region is positional, count is preserved)")
    invariants(q5, "move-boundaries")
    let q6 = freshQ(); q6.playNext(item("only"))
    q6.move(videoId: "only", by: 5)
    check(ids(q6) == ["only"] && q6.userQueueCount == 1, "single-row move is a no-op")

    // 14f. consumeUpTo inside the user region.
    let q7 = freshQ()
    q7.playNext(item("u1")); q7.addToEnd(item("u2")); q7.addToEnd(item("u3"))
    q7.replaceServerRegion([item("s1")])
    let dropped = q7.consumeUpTo(videoId: "u2")
    check(dropped.map(\.id) == ["u1", "u2"] && ids(q7) == ["u3", "s1"] && q7.userQueueCount == 1, "consumeUpTo inside the user region rebalances to the survivors")

    // 14g. playNext promotes the server head to the front of the user region.
    let q8 = freshQ()
    q8.playNext(item("u1")); q8.replaceServerRegion([item("s1"), item("s2")])
    q8.playNext(item("s1"))
    check(ids(q8) == ["s1", "u1", "s2"] && q8.userQueueCount == 2, "playNext of a server row promotes it to the very next slot")
    q8.addToEnd(item("s1"))
    check(ids(q8) == ["s1", "u1", "s2"] && q8.userQueueCount == 2, "addToEnd of an item already user-queued is a no-op (keeps Play-Next position)")

    // 14h. Duplicates via the wholesale path: remove/consume act on the FIRST match only.
    let q9 = freshQ()
    q9.replaceQueue([item("a"), item("b"), item("a")])
    q9.remove(videoId: "a")
    check(ids(q9) == ["b", "a"], "remove with duplicate ids removes only the first")
    let q10 = freshQ()
    q10.replaceQueue([item("a"), item("b"), item("a")])
    check(q10.consumeUpTo(videoId: "a").map(\.id) == ["a"] && ids(q10) == ["b", "a"], "consumeUpTo stops at the first duplicate")

    // 14i. consumeHead through the region boundary.
    let q11 = freshQ()
    q11.playNext(item("u1")); q11.replaceServerRegion([item("s1"), item("s2")])
    _ = q11.consumeHead(); _ = q11.consumeHead()
    check(ids(q11) == ["s2"] && q11.userQueueCount == 0, "consuming past the region boundary never goes negative")
    q11.clearQueue()
    check(q11.consumeHead() == nil && q11.consumeUpTo(videoId: "s2").isEmpty, "consume on a cleared queue is a harmless no-op")

    // 14j. extendServerRegion: empty batch, and dedupe vs the user region.
    let q12 = freshQ()
    q12.playNext(item("u1"))
    q12.extendServerRegion([])
    check(ids(q12) == ["u1"] && q12.userQueueCount == 1, "extend with an empty batch is a no-op")
    q12.extendServerRegion([item("u1"), item("s1")])
    check(ids(q12) == ["u1", "s1"] && q12.userQueueCount == 1, "extend never duplicates a user-queued id")

    // 14k. archive with explicit timestamps keeps chronological order and de-dupes only consecutive repeats.
    let q13 = freshQ(cap: 10)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    q13.archive(item("x"), at: t0)
    q13.archive(item("y"), at: t0.addingTimeInterval(60))
    q13.archive(item("x"), at: t0.addingTimeInterval(120))
    check(q13.playedEntries.map(\.item.id) == ["x", "y", "x"], "non-consecutive repeat is a new journal entry")
    check(q13.playedEntries.map(\.playedAt) == [t0, t0.addingTimeInterval(60), t0.addingTimeInterval(120)], "archive stores the supplied timestamp")
}

// ── 15. PersonalizedShelves — boundaries, calendars, thresholds ─────
do {
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0, cal: Calendar = utc, month: Int = 9) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    typealias S = PersonalizedShelves.DaySlot
    // Exact slot edges (the switch uses half-open hour ranges).
    check(S.slot(for: at(1, 4, 59), calendar: utc) == .lateNight, "04:59 late night")
    check(S.slot(for: at(1, 5, 0), calendar: utc) == .morning, "05:00 morning (edge)")
    check(S.slot(for: at(1, 10, 59), calendar: utc) == .morning, "10:59 morning")
    check(S.slot(for: at(1, 11, 0), calendar: utc) == .afternoon, "11:00 afternoon (edge)")
    check(S.slot(for: at(1, 16, 59), calendar: utc) == .afternoon, "16:59 afternoon")
    check(S.slot(for: at(1, 17, 0), calendar: utc) == .evening, "17:00 evening (edge)")
    check(S.slot(for: at(1, 21, 59), calendar: utc) == .evening, "21:59 evening")
    check(S.slot(for: at(1, 22, 0), calendar: utc) == .lateNight, "22:00 late night (edge)")
    check(S.slot(for: at(1, 0, 0), calendar: utc) == .lateNight, "midnight late night")
    // Same instant, different calendars: the slot follows the CALENDAR's zone.
    var ist = Calendar(identifier: .gregorian); ist.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    let instant = at(1, 1, 30)   // 01:30 UTC == 07:00 IST
    check(S.slot(for: instant, calendar: utc) == .lateNight && S.slot(for: instant, calendar: ist) == .morning, "slot is evaluated in the supplied calendar's time zone")
    // DST edges in America/New_York: spring-forward gap day and fall-back overlap day.
    var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
    let springMorning = at(8, 7, 0, cal: ny, month: 3)     // 2026-03-08, after the 02:00→03:00 gap
    check(S.slot(for: springMorning, calendar: ny) == .morning, "DST spring-forward day: 07:00 local is morning")
    let fallAmbiguous = at(1, 1, 30, cal: ny, month: 11)   // 2026-11-01, 01:30 occurs twice
    check(S.slot(for: fallAmbiguous, calendar: ny) == .lateNight, "DST fall-back day: ambiguous 01:30 is late night either way")
    let gapTime = ny.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 2, minute: 30))!  // non-existent local time
    check([S.morning, S.lateNight].contains(S.slot(for: gapTime, calendar: ny)), "non-existent local time resolves to a neighboring slot without crashing")

    // Distinct subtitle per track: rails cap at 3 tiles per album/artist
    // run (capPerAlbum), so threshold/limit fixtures must not share one
    // artist or the cap - not the property under test - trims them.
    func thumbed(_ id: String) -> MediaItem {
        MediaItem(id: id, kind: .song, title: id, subtitle: "Artist-\(id)", thumbnailURL: URL(string: "https://x/\(id).jpg"))
    }
    func bare(_ id: String) -> MediaItem { MediaItem(id: id, kind: .song, title: id, subtitle: "Artist-\(id)", thumbnailURL: nil) }
    let now = at(10, 8)
    // Build `counts[i]` morning plays of track i.
    func history(_ counts: [Int], make: (String) -> MediaItem = thumbed) -> [PlayedEntry] {
        var out: [PlayedEntry] = []
        for (idx, n) in counts.enumerated() { for k in 0..<n { out.append(PlayedEntry(item: make("t\(idx)"), playedAt: at(1 + (k % 8), 7))) } }
        return out
    }
    let s15x8 = PersonalizedShelves.timeOfDayShelf(from: history([2, 2, 2, 2, 2, 2, 2, 1]), now: now, calendar: utc)
    check(s15x8 != nil && s15x8?.items.count == 8, "exactly 15 plays across 8 tracks meets the threshold")
    check(PersonalizedShelves.timeOfDayShelf(from: history([3, 2, 2, 2, 2, 2, 2]), now: now, calendar: utc) == nil, "15 plays across only 7 tracks → nil (minTracks)")
    check(PersonalizedShelves.timeOfDayShelf(from: history([2, 2, 2, 2, 2, 2, 1, 1]), now: now, calendar: utc) == nil, "14 plays across 8 tracks → nil (minPlays)")
    // Window cutoff is inclusive at exactly `days` ago.
    let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
    check(S.slot(for: cutoff, calendar: utc) == .morning, "fixture: 90 days before 08:00 is still 08:00 (same slot)")
    let onCutoff = (0..<8).flatMap { i in (0..<2).map { _ in PlayedEntry(item: thumbed("c\(i)"), playedAt: cutoff) } }
    let onCutoffShelf = PersonalizedShelves.timeOfDayShelf(from: onCutoff, now: now, calendar: utc)
    check(onCutoffShelf != nil && onCutoffShelf?.slot == .morning, "plays exactly `days` ago are inside the window (>= cutoff)")
    let justOutside = onCutoff.map { PlayedEntry(item: $0.item, playedAt: $0.playedAt.addingTimeInterval(-1)) }
    check(PersonalizedShelves.timeOfDayShelf(from: justOutside, now: now, calendar: utc) == nil, "plays one second older than the window are excluded")
    // API-contract gap: thresholds are counted BEFORE the thumbnail
    // filter, so a slot whose tracks all lack artwork yields a non-nil
    // shelf with ZERO items. (HomeView happens to guard `kept.count >= 4`,
    // so no empty rail renders today — but the function's own contract
    // "nil until the slot has enough signal" is violated.)
    let bareShelf = PersonalizedShelves.timeOfDayShelf(from: history([2, 2, 2, 2, 2, 2, 2, 1], make: bare), now: now, calendar: utc)
    check(bareShelf == nil || !(bareShelf!.items.isEmpty), "PersonalizedShelves.timeOfDayShelf returns a non-nil shelf with ZERO items when every qualifying track lacks artwork (got items=\(bareShelf?.items.count ?? -1); thresholds counted before the thumbnail filter)")
    // limit + recency tiebreak.
    let thirteen = PersonalizedShelves.timeOfDayShelf(from: history(Array(repeating: 2, count: 13)), now: now, calendar: utc)
    check(thirteen?.items.count == 12, "limit caps the rail at 12")
    // Per-album cap: a single album/artist run may occupy at most 3
    // tiles, so an album binge doesn't render the rail as N copies of
    // one artwork (field audit 2026-10-20: 7 identical Lenin OST tiles).
    func oneAlbum(_ id: String) -> MediaItem {
        MediaItem(id: id, kind: .song, title: id, subtitle: "SameArtist", thumbnailURL: URL(string: "https://x/\(id).jpg"))
    }
    let binge = PersonalizedShelves.timeOfDayShelf(from: history(Array(repeating: 2, count: 13), make: oneAlbum), now: now, calendar: utc)
    check(binge?.items.count == 3, "one album/artist run is capped at 3 tiles per rail (got \(binge?.items.count ?? -1))")
    check(PersonalizedShelves.capPerAlbum([oneAlbum("a"), oneAlbum("b"), thumbed("x"), oneAlbum("c"), oneAlbum("d")]).map(\.id) == ["a", "b", "x", "c"], "capPerAlbum keeps order, caps the clustered album at 3, and leaves other albums alone")
    var tie = history(Array(repeating: 2, count: 8))
    tie.append(PlayedEntry(item: thumbed("late"), playedAt: at(9, 9)))
    tie.append(PlayedEntry(item: thumbed("late"), playedAt: at(9, 10)))
    let tieShelf = PersonalizedShelves.timeOfDayShelf(from: tie, now: now, calendar: utc)
    check(tieShelf?.items.first?.id == "late", "equal play counts: the most recently played track ranks first")
    // Future-dated plays (clock skew) are not excluded — pin behavior.
    var skew = history(Array(repeating: 2, count: 8))
    skew.append(PlayedEntry(item: thumbed("future"), playedAt: at(20, 8)))
    skew.append(PlayedEntry(item: thumbed("future"), playedAt: at(21, 8)))
    check(PersonalizedShelves.timeOfDayShelf(from: skew, now: now, calendar: utc)?.items.first?.id == "future", "DOCUMENTED: future-dated plays count and win the recency tiebreak (no upper bound on the window)")

    // topArtists: PROBABLE BUG — `prefix(limit)` runs BEFORE the
    // name/thumbnail filter, so a skipped entry costs a tile slot.
    func played(_ id: String, artist: String, thumb: Bool, day: Int) -> PlayedEntry {
        PlayedEntry(item: MediaItem(id: id, kind: .song, title: id, subtitle: "Song • \(artist) • Album", thumbnailURL: thumb ? URL(string: "https://x/\(id).jpg") : nil, artistId: "UC\(artist)"), playedAt: at(day, 12))
    }
    let artists = [played("p1", artist: "Newest", thumb: false, day: 9), played("p2", artist: "Mid", thumb: true, day: 8), played("p3", artist: "Old", thumb: true, day: 7)]
    let top2 = PersonalizedShelves.topArtists(from: artists, limit: 2, now: now)
    check(top2.count == 2, "PersonalizedShelves.topArtists applies prefix(limit) BEFORE the name/thumbnail filter, so a skipped artist costs a tile (limit 2, 2 qualifying artists, got \(top2.map(\.title)))")
    check(PersonalizedShelves.topArtists(from: [PlayedEntry(item: thumbed("noArtist"), playedAt: now)], now: now).isEmpty, "entries without artistId never become tiles")
    let ranked = PersonalizedShelves.topArtists(from: [played("a", artist: "X", thumb: true, day: 1), played("b", artist: "X", thumb: true, day: 2), played("c", artist: "Y", thumb: true, day: 9)], now: now)
    check(ranked.map(\.title) == ["X", "Y"] && ranked.first?.subtitle == "2 plays" && ranked.last?.subtitle == "1 play", "topArtists ranks by count, then pluralizes the subtitle")
    check(ranked.first?.thumbnailURL?.absoluteString.hasSuffix("b.jpg") == true, "artist tile borrows the MOST RECENT song's cover")
    check(PersonalizedShelves.topArtists(from: [played("z", artist: "Z", thumb: true, day: 1)], since: 1, now: at(10, 12)).isEmpty, "topArtists window excludes plays older than `since` days")

    // extractArtistName shapes.
    typealias P = PersonalizedShelves
    check(P.extractArtistName(fromSubtitle: "Song • Bruno Mars • 24K Magic • 2016") == "Bruno Mars", "search-row shape skips the kind label")
    check(P.extractArtistName(fromSubtitle: "A.R. Rahman, Karthik, Devan") == "A.R. Rahman", "multi-credit comma list → primary")
    check(P.extractArtistName(fromSubtitle: "Thaman S & Sid Sriram") == "Thaman S", "ampersand credits → primary")
    check(P.extractArtistName(fromSubtitle: "Song • Album") == nil, "all-kind-label subtitles yield nil")
    check(P.extractArtistName(fromSubtitle: " • • ") == nil, "separator-only subtitle yields nil")
    check(P.extractArtistName(fromSubtitle: "Video · Artist Name · 2020") == "Artist Name", "interpunct separator handled")
    check(P.extractArtistName(fromSubtitle: "Earth, Wind & Fire") == "Earth", "DOCUMENTED LIMITATION: band names containing ',' or '&' are split as credits (Earth, Wind & Fire → Earth)")
    check(P.extractArtistName(fromSubtitle: "Florence and the Machine") == "Florence", "DOCUMENTED LIMITATION: ' and ' inside a band name is split (Florence and the Machine → Florence)")
    check(P.extractArtistName(fromSubtitle: "Artist A - Album") == "Artist A - Album", "DOCUMENTED: ' - ' is NOT a separator despite the doc comment (dash-space subtitles pass through whole)")

    // topTracks: dedupe, thumbnail filter BEFORE limit (consistent, unlike topArtists).
    let tracks = [PlayedEntry(item: bare("nt"), playedAt: at(9, 8)), PlayedEntry(item: bare("nt"), playedAt: at(9, 9)),
                  PlayedEntry(item: thumbed("t1"), playedAt: at(8, 8)), PlayedEntry(item: thumbed("t2"), playedAt: at(7, 8))]
    let tt = PersonalizedShelves.topTracks(from: tracks, limit: 2, now: now)
    check(tt.map(\.id) == ["t1", "t2"], "topTracks drops thumbnail-less tracks BEFORE applying the limit (got \(tt.map(\.id)))")
}

// ── 16. SmartShuffle.merge — protected ids, cadence edges, properties ─
do {
    let base = (1...8).map { item("b\($0)") }
    let pool = (1...5).map { item("p\($0)") }
    let prot = SmartShuffle.merge(base: base, pool: pool + [item("b3")], every: 4, protectedIds: ["p1", "b3"])
    check(!prot.injectedIds.contains("p1") && prot.injectedIds == ["p2", "p3"], "protectedIds are never injected")
    check(prot.merged.filter { $0.id == "b3" }.count == 1, "protected base rows stay exactly once")
    let two = SmartShuffle.merge(base: base, pool: pool, every: 2)
    check(two.merged.map(\.id) == ["b1", "p1", "b2", "p2", "b3", "p3", "b4", "p4", "b5", "p5", "b6", "b7", "b8"], "every=2 alternates until the pool drains, then passes the base through (got \(two.merged.map(\.id)))")
    let one = SmartShuffle.merge(base: base, pool: pool, every: 1)
    check(one.merged.map(\.id) == two.merged.map(\.id), "every=1 clamps to 2")
    let short = SmartShuffle.merge(base: [item("b1"), item("b2")], pool: pool, every: 4)
    check(short.merged.map(\.id) == ["b1", "b2"] && short.injectedIds.isEmpty, "a base shorter than the cadence gets no injection")
    let three = SmartShuffle.merge(base: [item("b1"), item("b2"), item("b3")], pool: pool, every: 3)
    check(three.merged.map(\.id) == ["b1", "b2", "p1", "b3"], "first injection lands at slot `every` (1-indexed)")
    check(SmartShuffle.merge(base: [], pool: pool).merged.isEmpty, "empty base → empty result")
    // Property fuzz: base order is a subsequence, injected ⊆ pool, no duplicate ids, bounded growth.
    var rng = SplitMix64(state: 0x5EED)
    var violations = 0
    for _ in 0..<500 {
        let n = Int.random(in: 0..<20, using: &rng), m = Int.random(in: 0..<12, using: &rng), every = Int.random(in: 0..<6, using: &rng)
        let b = (0..<n).map { item("b\($0)") }
        let p = (0..<m).map { _ in item(Bool.random(using: &rng) ? "p\(Int.random(in: 0..<8, using: &rng))" : "b\(Int.random(in: 0..<20, using: &rng))") }
        let r = SmartShuffle.merge(base: b, pool: p, every: every)
        let step = max(2, every)
        let baseOnly = r.merged.filter { !r.injectedIds.contains($0.id) }.map(\.id)
        if baseOnly != b.map(\.id) { violations += 1 }
        if !r.injectedIds.isSubset(of: Set(p.map(\.id))) { violations += 1 }
        if Set(r.merged.map(\.id)).count != r.merged.count { violations += 1 }
        if r.merged.count > n + n / (step - 1) + 1 { violations += 1 }
        if !r.injectedIds.isDisjoint(with: Set(b.map(\.id))) { violations += 1 }
    }
    check(violations == 0, "merge properties hold over 500 random inputs (\(violations) violations)")
}

// ── 17. CookieImporter — paste shapes a real user produces ──────────
do {
    typealias C = CookieImporter
    // PROBABLE BUG: Windows/Chrome DevTools copy gives CRLF; "\r" is
    // not in CharacterSet.whitespaces so it survives into the value.
    let crlf = C.parse("SAPISID=abc\r\nHSID=h1\r\n")
    check(crlf["SAPISID"] == "abc" && crlf["HSID"] == "h1", "CookieImporter.parse keeps a trailing CR on every value of a CRLF paste (got \(crlf)) — SAPISIDHASH would be computed over 'abc\\r'")
    // Doc comment: "Tolerates the `Cookie:` header form" — the raw header line INCLUDING its name.
    let header = C.parse("Cookie: SAPISID=abc; HSID=h1")
    check(C.hasAuthCookie(header), "CookieImporter.parse: a pasted 'Cookie: …' header line yields key 'Cookie: SAPISID' so hasAuthCookie is false (got keys \(header.keys.sorted()))")
    check(C.parse("SIDCC=a=b")["SIDCC"] == "a=b", "'=' inside a value is preserved (split on the first '=' only)")
    check(C.parse("A=1; A=2")["A"] == "2", "duplicate names: last one wins")
    check(C.parse("A=1\nB=2;C=3\n\n;;")  == ["A": "1", "B": "2", "C": "3"], "mixed newline/semicolon separators with blank fragments")
    check(C.parse("").isEmpty && C.parse("   ;  ; ").isEmpty, "empty / separator-only input → no pairs")
    check(C.hasAuthCookie(["__Secure-3PAPISID": "x"]), "__Secure-3PAPISID alone is an auth cookie")
    check(!C.hasAuthCookie(["sapisid": "x"]), "auth cookie names are case-sensitive (lowercase 'sapisid' is not accepted)")
    check(C.parse("X=\"a b\"")["X"] == "\"a b\"", "quoted values are kept verbatim (no unquoting)")
    check(C.parse("SAPISID=abc\tHSID=h1")["SAPISID"] == "abc\tHSID=h1", "DOCUMENTED: tab-separated (cookies.txt) pastes are NOT split — one value swallows the rest")
    check(C.parse("=novalue; name=; ok=1") == ["ok": "1"], "empty name or empty value fragments are skipped")
    check(C.parse("SAPISID = abc")["SAPISID"] == "abc", "spaces around '=' are trimmed")
}

// ── 18. RetryPolicy — idempotent-read retry decision table ──────────
do {
    // Deterministic wrapper: unit pinned unless a row overrides it.
    func d(_ e: Endpoint, attempt: Int = 1, status: Int? = nil,
           urlError: URLError.Code? = nil, retryAfter: String? = nil,
           unit: Double = 0.5) -> TimeInterval? {
        RetryPolicy.delay(endpoint: e, attempt: attempt, status: status,
                          urlError: urlError, retryAfter: retryAfter, unit: unit)
    }
    func approx(_ a: TimeInterval?, _ b: TimeInterval) -> Bool {
        guard let a = a else { return false }
        return abs(a - b) < 1e-9
    }

    // Mutations never retry, whatever the failure signal.
    let mutations: [Endpoint] = [.like, .dislike, .removeLike, .editPlaylist,
                                 .createPlaylist, .deletePlaylist, .subscribe, .unsubscribe]
    for e in mutations {
        check(d(e, status: 503) == nil, "mutation \(e.rawValue): no retry on 503")
        check(d(e, status: 429, retryAfter: "1") == nil, "mutation \(e.rawValue): no retry on 429 even with Retry-After")
        check(d(e, urlError: .networkConnectionLost) == nil, "mutation \(e.rawValue): no retry on connection lost")
    }

    // Reads retry fast-fail statuses with jitter in [0.3, 0.9].
    let reads: [Endpoint] = [.search, .browse, .next, .player, .accountMenu, .searchSuggestions]
    for e in reads {
        let v = d(e, status: 503)
        check(v != nil && v! >= 0.3 && v! <= 0.9, "read \(e.rawValue): 503 retries with jittered delay (got \(String(describing: v)))")
    }
    check(approx(d(.browse, status: 503, unit: 0.0), 0.3), "jitter floor: unit 0 gives 0.3 s")
    check(approx(d(.browse, status: 503, unit: 0.999), 0.3 + 0.999 * 0.6), "jitter is 0.3 + unit * 0.6 (unit injectable)")
    check(approx(d(.browse, status: 502), 0.6) && approx(d(.browse, status: 504), 0.6), "502 and 504 retry like 503")
    check(d(.search, status: 500) == nil, "500 is treated as deterministic — no retry")
    check(d(.next, status: 401) == nil && d(.next, status: 403) == nil, "401/403 never retry (needsReauth path)")
    check(d(.browse, status: 404) == nil && d(.browse, status: 400) == nil, "other 4xx never retry")

    // Max one retry.
    check(d(.browse, attempt: 2, status: 503) == nil, "attempt 2 gives up (max one retry)")
    check(d(.browse, attempt: 3, urlError: .networkConnectionLost) == nil, "attempt 3 gives up too")

    // 429 honours delta-seconds Retry-After, capped at 3 s (beyond → surface the error).
    check(approx(d(.search, status: 429, retryAfter: "2"), 2.0), "429 with Retry-After: 2 waits exactly 2 s")
    check(approx(d(.search, status: 429, retryAfter: "3"), 3.0), "429 with Retry-After: 3 sits exactly at the cap")
    check(d(.search, status: 429, retryAfter: "4") == nil, "429 with Retry-After: 4 is beyond the cap")
    check(d(.search, status: 429, retryAfter: "60") == nil, "429 with Retry-After: 60 gives up (capped-out)")
    check(approx(d(.search, status: 429), 0.6), "429 without a hint falls back to jitter")
    check(approx(d(.search, status: 429, retryAfter: "Fri, 11 Sep 2026 12:00:00 GMT"), 0.6), "HTTP-date Retry-After is treated as no hint")
    check(approx(d(.search, status: 429, retryAfter: "-5"), 0.6), "negative Retry-After is treated as no hint")
    check(approx(d(.search, status: 429, retryAfter: " 1 "), 1.0), "whitespace around delta-seconds is tolerated")
    check(approx(d(.search, status: 429, retryAfter: "0"), 0.0), "Retry-After: 0 retries immediately")

    // Transport errors: retry only fast-fail signals.
    check(d(.browse, urlError: .networkConnectionLost) != nil, "connection lost retries")
    check(d(.browse, urlError: .cannotConnectToHost) != nil, "cannot-connect retries")
    check(d(.browse, urlError: .dnsLookupFailed) != nil, "DNS failure retries")
    check(d(.browse, urlError: .timedOut) == nil, "timedOut never retries (10 s budget already spent)")
    check(d(.browse, urlError: .notConnectedToInternet) == nil, "offline never retries")
    check(d(.browse, urlError: .cancelled) == nil, "cancellation never retries")
    check(d(.browse, urlError: .badServerResponse) == nil, "other URL errors never retry")

    // No failure signal at all → no retry.
    check(d(.browse) == nil, "no status and no urlError yields nil")
}

// ── 19. TasteProfile — skip / fatigue / day-type signals ────────────
do {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    // 2026-10-21 is a Wednesday (weekday); 2026-10-24 a Saturday.
    func day(_ d: Int, _ h: Int = 12) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))!
    }
    func song(_ id: String, artist: String) -> MediaItem {
        MediaItem(id: id, kind: .song, title: id, subtitle: artist,
                  thumbnailURL: URL(string: "https://x/\(id)"), artistId: artist)
    }
    func play(_ id: String, _ artist: String, _ at: Date, listened: Double? = 200, total: Double? = 200) -> PlayedEntry {
        PlayedEntry(item: song(id, artist: artist), playedAt: at,
                    listenedSeconds: listened, trackSeconds: total)
    }

    // Skip definition.
    check(play("a", "A", day(20), listened: 10).isSkip, "10 s of 200 is a skip")
    check(!play("a", "A", day(20), listened: 120).isSkip, "120 s of 200 is a listen")
    check(!play("a", "A", day(20), listened: 25, total: 40).isSkip, "25 s of a 40 s interlude is NOT a skip")
    check(!play("a", "A", day(20), listened: nil, total: nil).isSkip, "legacy entry without depth is never a skip")

    // Skipped song is down-weighted; plain song is neutral.
    var entries: [PlayedEntry] = []
    for i in 0..<3 { entries.append(play("bad", "B", day(10 + i), listened: 5)) }
    for i in 0..<3 { entries.append(play("good", "G", day(10 + i))) }
    var t = TasteProfile.build(from: entries, now: day(21), calendar: utc)
    check(t.isSkippedSong("bad"), "song skipped 3x with no full plays is flagged")
    check(!t.isSkippedSong("good"), "song played through is not flagged")
    check(t.weight(for: song("bad", artist: "B")) < t.weight(for: song("good", artist: "G")),
          "skipped song weighs less than a played one")

    // Fatigue: one artist dominating the last 3 days.
    entries = []
    for i in 0..<9 { entries.append(play("t\(i)", "T", day(20, 8 + i))) }
    for i in 0..<3 { entries.append(play("o\(i)", "O", day(20, 18 + i))) }
    t = TasteProfile.build(from: entries, now: day(21), calendar: utc)
    check(t.isFatigued("T"), "artist with 75% of recent plays is fatigued")
    check(!t.isFatigued("O"), "minority artist is not fatigued")
    check(t.reasons(for: song("t0", artist: "T")).contains { $0.hasPrefix("Eased off") },
          "fatigued artist's reasons explain the easing")
    check(TasteProfile.build(from: Array(entries.prefix(6)), now: day(21), calendar: utc).totalRecentPlays < 10
          && !TasteProfile.build(from: Array(entries.prefix(6)), now: day(21), calendar: utc).isFatigued("T"),
          "fatigue needs at least 10 recent plays of evidence")

    // Day type: a weekend-only artist lifts on a Saturday, not on a Wednesday.
    entries = []
    for w in [3, 10, 17] {           // Saturdays in Oct 2026
        for i in 0..<3 { entries.append(play("w\(w)\(i)", "W", day(w, 10 + i))) }
    }
    for d in [5, 6, 7, 12, 13, 14] {  // weekdays
        for i in 0..<2 { entries.append(play("d\(d)\(i)", "D", day(d, 10 + i))) }
    }
    let sat = TasteProfile.build(from: entries, now: day(24), calendar: utc)
    let wed = TasteProfile.build(from: entries, now: day(21), calendar: utc)
    check(sat.dayTypeLift("W") > 1.25, "weekend artist lifts on a Saturday")
    check(wed.dayTypeLift("W") < 1, "weekend artist dips on a Wednesday")
    check(sat.reasons(for: song("w30", artist: "W")).contains("A weekend favorite"),
          "weekend lift is explained")
}

// ── 20. TasteArchive — export / import / merge ──────────────────────
do {
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    func e(_ id: String, _ offset: Double, listened: Double? = nil) -> PlayedEntry {
        PlayedEntry(item: MediaItem(id: id, kind: .song, title: id, subtitle: "A",
                                    thumbnailURL: nil, artistId: "A"),
                    playedAt: base.addingTimeInterval(offset),
                    listenedSeconds: listened, trackSeconds: listened == nil ? nil : 200)
    }
    let journal = [e("a", 0, listened: 12), e("b", 60), e("c", 120, listened: 180)]
    let data = try! TasteArchive.encode(journal, now: base)
    let back = try! TasteArchive.decode(data)
    check(back == journal, "export → import round-trips every field (incl. listen depth)")
    check(back[0].isSkip && !back[2].isSkip, "skip signal survives the round-trip")

    // Not a profile / wrong version.
    check((try? TasteArchive.decode(Data("{\"hello\":1}".utf8))) == nil, "arbitrary JSON is rejected")
    var wrong = TasteArchive.File(exportedAt: base, entries: journal); wrong.version = 9
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    do { _ = try TasteArchive.decode(try! enc.encode(wrong)); check(false, "future version should throw") }
    catch { check((error as? TasteArchive.ImportError) == .unsupportedVersion(9), "future version is reported, not misread") }

    // Merge: re-importing the same file adds nothing; new entries interleave by time.
    check(TasteArchive.merge(journal, journal).count == 3, "re-import of the same profile is idempotent")
    let merged = TasteArchive.merge(journal, [e("z", 30)])
    check(merged.map(\.item.id) == ["a", "z", "b", "c"], "merged journal is time-ordered")

    // Legacy JSON (entries without depth fields) still decodes.
    let legacy = """
    {"format":"riff.taste-profile","version":1,"exportedAt":"2026-10-21T00:00:00Z",
     "entries":[{"item":{"id":"x","kind":"song","title":"x","subtitle":"A"},"playedAt":"2026-10-20T00:00:00Z"}]}
    """
    let legacyOK = (try? TasteArchive.decode(Data(legacy.utf8)))?.first.map { $0.listenedSeconds == nil && !$0.isSkip } ?? false
    check(legacyOK, "entries without listen depth decode as neutral listens")
}

print("KNOWN BUGS (strict xfail, not counted as failures): \(knownBugs)")

print("")
print("RESULT: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
