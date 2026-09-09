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
    check(QueuePolicy.nextUsesPageNative(isPageDriven: true, headIsUserQueued: false), "Next in radio uses the page's own next (no reload)")
    check(!QueuePolicy.nextUsesPageNative(isPageDriven: true, headIsUserQueued: true), "Next with a user-queued head plays THAT head")
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

print("")
print("RESULT: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
