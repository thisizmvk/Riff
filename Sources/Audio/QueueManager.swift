import Foundation
import Observation

/// Owns Riff's local "Up Next" queue and the played-history log.
///
/// **Two-region queue model** (matches YT Music's web/mobile app):
///
///   `upNext = [ user-queued items | server-derived items ]`
///
/// Items in indices `[0, userQueueCount)` are user intent — they came
/// from Play Next / Add to Queue and their **position matters**.
/// Refreshes from `/next` never touch them.
///
/// Items in indices `[userQueueCount, end)` are server-derived —
/// album continuation, radio suggestions, chip-driven queues. Full
/// replacement is safe here; the user has no ordering claim on them.
///
/// Play Next inserts at index 0 (very next track).
/// Add to Queue inserts at index `userQueueCount` (bottom of user
/// region, right before the first server item — matches YT Music's
/// mobile Add-to-queue placement).
///
/// This replaces the earlier "unordered `userQueuedIds` set" model
/// that treated user-queue membership as a priority flag with no
/// positional intent. That design meant "Add to queue on the last
/// row" wrongly pre-empted intermediate rows on end-of-track, and
/// `/next` refreshes had to reason about surviving user items
/// scattered anywhere in the array. The region boundary removes
/// both classes of bug.
///
/// Local-only caveat: this is *Riff's* view of what plays next. The
/// hidden WKWebView keeps its own server-driven queue. When YT
/// autoplays the next track, we intercept via the JS bridge's
/// `__riffPendingNextUrl` and navigate to `upNext.first` (the head).
/// See `PlayerBridge.syncPendingNextURL`.
@Observable
@MainActor
final class QueueManager {
    /// Upcoming tracks. Layout described in the type doc.
    private(set) var upNext: [MediaItem] = []

    /// How many items at the head of `upNext` are user-queued.
    /// Everything before this index is user intent (Play Next / Add
    /// to Queue), stable across `/next` refreshes. Everything at
    /// this index and beyond is server-derived and replaceable.
    ///
    /// Invariant: `0 <= userQueueCount <= upNext.count`.
    private(set) var userQueueCount: Int = 0

    /// Tracks heard earlier in this session (most-recent last).
    /// Stored (not computed): NowPlayingView's body reads this at
    /// ~4Hz via progress-tick re-renders, and a computed
    /// `playedEntries.map(\.item)` allocated a fresh ~400-element
    /// array on every access. Maintained by `archive`.
    private(set) var playedHistory: [MediaItem] = []

    /// Timestamped played history (most-recent last). Persisted.
    private(set) var playedEntries: [PlayedEntry] = []

    @ObservationIgnored private let historyCap: Int
    @ObservationIgnored private let historyStore: PlayedHistoryStore

    init(historyCap: Int = 500, defaults: UserDefaults = .standard) {
        self.historyCap = historyCap
        self.historyStore = PlayedHistoryStore(cap: historyCap, defaults: defaults)
        self.playedEntries = historyStore.load()
        self.playedHistory = playedEntries.map(\.item)
    }

    // MARK: - Region helpers

    /// True iff the given index falls inside the user-queued prefix
    /// of `upNext`. Used by view code that wants to render a badge
    /// on user-queued rows.
    func isUserQueued(index: Int) -> Bool {
        index >= 0 && index < userQueueCount
    }

    /// True iff the given videoId is currently in the user-queued
    /// region. O(userQueueCount) — fine, region is typically tiny.
    func isUserQueued(videoId: String) -> Bool {
        upNext.prefix(userQueueCount).contains(where: { $0.id == videoId })
    }

    // MARK: - Mutation

    /// Fresh watch context — a wholesale replace. Called after
    /// `play(item:, clearQueue: true)`. Zeroes the user region: the
    /// previous session's user-queued items shouldn't survive into
    /// a fresh play unless the caller explicitly preserves them.
    func replaceQueue(_ items: [MediaItem]) {
        upNext = items
        userQueueCount = 0
    }

    /// Replace ONLY the server region while preserving the user
    /// region verbatim. Called from `refreshNextQueueAndIds` and
    /// `applyChip` — those want fresh server content but must not
    /// disturb the user's Play Next / Add to Queue intent.
    ///
    /// Any incoming item whose id already exists in the user region
    /// is dropped from `serverItems` to avoid duplicates.
    func replaceServerRegion(_ serverItems: [MediaItem]) {
        let userRegion = Array(upNext.prefix(userQueueCount))
        let userIds = Set(userRegion.map(\.id))
        // Dedupe against the user region AND within serverItems itself:
        // playlistDetail fallbacks (playlists legitimately repeat songs)
        // and the page-queue mirror (items ∪ automixItems can overlap)
        // both deliver internal duplicates, and duplicate ids downstream
        // trap `reorder`'s uniqueKeysWithValues dictionary.
        var seen = userIds
        let filteredServer = serverItems.filter { seen.insert($0.id).inserted }
        upNext = userRegion + filteredServer
        // userQueueCount unchanged by definition.
    }

    /// APPEND fresh server tracks to the existing server region,
    /// keeping everything already shown in place. This is the
    /// auto-extension path (queue running low): we tack new
    /// suggestions onto the END rather than replacing the tail, so
    /// the visible queue doesn't churn under the user as tracks
    /// play. Only items not already anywhere in `upNext` are added
    /// (dedupe against the whole queue, user + server).
    func extendServerRegion(_ serverItems: [MediaItem]) {
        // Dedupe against the whole queue AND within the incoming batch
        // itself (found by the fuzz harness: a batch repeating an id
        // appended it twice, recreating the duplicate-id hazard that
        // replaceServerRegion already guards).
        var seen = Set(upNext.map(\.id))
        let fresh = serverItems.filter { seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        upNext.append(contentsOf: fresh)
        // userQueueCount unchanged — appends land in the server region.
    }

    /// Empty the queue completely. Rare — mostly for defensive
    /// resets in error paths.
    func clearQueue() {
        upNext = []
        userQueueCount = 0
    }

    /// "Play next" — insert at index 0 of the user region. If the
    /// item is already anywhere in `upNext`, move it (dedupe).
    func playNext(_ item: MediaItem) {
        if let existing = upNext.firstIndex(where: { $0.id == item.id }) {
            let wasInUserRegion = existing < userQueueCount
            upNext.remove(at: existing)
            if wasInUserRegion { userQueueCount -= 1 }
        }
        upNext.insert(item, at: 0)
        userQueueCount += 1
    }

    /// "Add to queue" — insert at the END of the user region,
    /// right before the first server item. Matches YT Music's
    /// Add-to-queue placement: the item plays after everything the
    /// user has explicitly queued, but before the server's radio /
    /// album continuation.
    ///
    /// No-op if already in the user region (dedupe). If it was a
    /// server item, promote it into the user region at that spot.
    func addToEnd(_ item: MediaItem) {
        if let existing = upNext.firstIndex(where: { $0.id == item.id }) {
            if existing < userQueueCount { return }
            upNext.remove(at: existing)
        }
        upNext.insert(item, at: userQueueCount)
        userQueueCount += 1
    }

    /// Remove a row by `videoId`. Updates the region boundary if
    /// the removed item was inside the user region.
    func remove(videoId: String) {
        guard let idx = upNext.firstIndex(where: { $0.id == videoId }) else { return }
        upNext.remove(at: idx)
        if idx < userQueueCount { userQueueCount -= 1 }
    }

    /// Pop and return the head of the queue. Used by the trackChange
    /// handler when playback advances into the next queued item —
    /// removes it from `upNext` so it doesn't render twice (once as
    /// currentTrack, again as the top of upNext).
    ///
    /// Returns nil when the queue is empty. Adjusts `userQueueCount`
    /// if the head was user-queued.
    @discardableResult
    func consumeHead() -> MediaItem? {
        guard !upNext.isEmpty else { return nil }
        let head = upNext.removeFirst()
        if userQueueCount > 0 { userQueueCount -= 1 }
        return head
    }

    /// Consume every item up to and including the one with the
    /// given `videoId`. Used when the user taps a row deep in Up
    /// Next — everything before that row is archived to history
    /// (or discarded, per YT Music behavior), and playback jumps
    /// to the tapped track.
    ///
    /// Returns the archived items (in play order) so the caller
    /// can push them to `playedEntries`. No-op if the id isn't
    /// in the queue.
    func consumeUpTo(videoId: String) -> [MediaItem] {
        guard let idx = upNext.firstIndex(where: { $0.id == videoId }) else { return [] }
        let dropped = Array(upNext.prefix(idx + 1))
        upNext.removeFirst(idx + 1)
        userQueueCount = max(0, userQueueCount - (idx + 1))
        return dropped
    }

    /// Nudge a row by ±offset within `upNext`. Clamps within
    /// bounds. Recomputes region membership: an item dragged from
    /// server region into user region gets promoted (userQueueCount
    /// grows); vice versa demotes it.
    func move(videoId: String, by offset: Int) {
        guard let index = upNext.firstIndex(where: { $0.id == videoId }) else { return }
        let newIndex = max(0, min(upNext.count - 1, index + offset))
        guard newIndex != index else { return }
        applyMove(from: index, to: newIndex)
    }

    /// Drag-drop reorder. `visibleIds` is the id order as the view
    /// renders it (current-track filtered out); `source` / `dest`
    /// are the SwiftUI `.onMove` args in that same space. The move
    /// crosses region boundaries freely — a user promoting a server
    /// item into the user region by dragging it up is a legitimate
    /// intent.
    func reorder(visibleIds: [String], from source: IndexSet, to destination: Int) {
        guard !visibleIds.isEmpty else { return }
        var visible = visibleIds
        visible.move(fromOffsets: source, toOffset: destination)
        // Rebuild upNext preserving items not in visibleIds (e.g.
        // the currently-playing track filtered out by the view) at
        // their original positions.
        // uniquingKeysWith rather than uniqueKeysWithValues: the latter
        // TRAPS on duplicate ids, and while replaceServerRegion now
        // dedupes, a duplicate that slips in via any other path must
        // degrade gracefully instead of crashing a drag gesture.
        let byId: [String: MediaItem] = Dictionary(upNext.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The view captured `visibleIds` at render time; a mirror
        // snapshot landing mid-drag can leave STALE ids in it. Drop them
        // AFTER the move (so real rows keep their intended relative
        // order) — otherwise a stale slot consumed the iterator and the
        // real row that stood there was silently lost.
        visible = visible.filter { byId[$0] != nil }
        let visibleSet = Set(visible)
        var out: [MediaItem] = []
        var reorderedIter = visible.makeIterator()
        var newUserCount = 0
        for (originalIdx, item) in upNext.enumerated() {
            let wasUserQueued = originalIdx < userQueueCount
            if visibleSet.contains(item.id) {
                if let nextId = reorderedIter.next(), let picked = byId[nextId] {
                    out.append(picked)
                    // A moved item keeps its ORIGINAL user/server
                    // tag — we don't infer promotion from position.
                    let pickedWasUserQueued: Bool = {
                        guard let originalPickedIdx = upNext.firstIndex(where: { $0.id == picked.id }) else { return false }
                        return originalPickedIdx < userQueueCount
                    }()
                    if pickedWasUserQueued { newUserCount += 1 }
                }
            } else {
                out.append(item)
                if wasUserQueued { newUserCount += 1 }
            }
        }
        upNext = out
        userQueueCount = min(newUserCount, out.count)
    }

    /// Internal helper for `move(videoId:by:)`. Adjusts the region
    /// boundary based on whether the move crossed it.
    private func applyMove(from oldIdx: Int, to newIdx: Int) {
        let wasUserQueued = oldIdx < userQueueCount
        let item = upNext.remove(at: oldIdx)
        // Adjust userQueueCount for the removal.
        var count = userQueueCount
        if wasUserQueued { count -= 1 }
        // Now insert. If it lands inside what's currently the user
        // region, it stays user-queued; if it lands past it, it
        // becomes a server item.
        let willBeUserQueued = newIdx < count || (wasUserQueued && newIdx <= count)
        upNext.insert(item, at: newIdx)
        if willBeUserQueued { count += 1 }
        userQueueCount = count
    }

    // MARK: - History

    func archive(_ item: MediaItem, at date: Date = Date(),
                 listenedSeconds: Double? = nil, trackSeconds: Double? = nil) {
        if playedEntries.last?.item.id == item.id { return }
        playedEntries.append(PlayedEntry(item: item, playedAt: date,
                                         listenedSeconds: listenedSeconds,
                                         trackSeconds: trackSeconds))
        playedHistory.append(item)
        if playedEntries.count > historyCap {
            playedEntries.removeFirst(playedEntries.count - historyCap)
            playedHistory.removeFirst(playedHistory.count - historyCap)
        }
        historyStore.save(playedEntries)
    }

    func clearPersistedHistory() {
        historyStore.clear()
    }

    /// Replace the whole journal (taste import / reset). Sorted
    /// oldest-first like `archive` appends, capped, persisted, and the
    /// observed `playedHistory` mirror rebuilt.
    func replaceHistory(_ entries: [PlayedEntry]) {
        var sorted = entries.sorted { $0.playedAt < $1.playedAt }
        if sorted.count > historyCap { sorted.removeFirst(sorted.count - historyCap) }
        playedEntries = sorted
        playedHistory = sorted.map(\.item)
        historyStore.save(playedEntries)
    }
}
