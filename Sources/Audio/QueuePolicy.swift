import Foundation

/// PURE queue decision policy — the single-authority behavior contract
/// (docs/QUEUE-DESIGN.md, "Behavior contract") as functions with no
/// side effects and no dependencies. `PlayerBridge` feeds these its
/// state and executes what they return; `tools/harness` enumerates the
/// decision table, so an enhancement that changes an answer fails the
/// harness instead of silently regressing playback.
///
/// Rule of thumb for future changes: if you find yourself adding a
/// branch to PlayerBridge that decides WHETHER to navigate, enforce,
/// mirror, or shuffle locally — it belongs here, with a table row.
enum QueuePolicy {

    // MARK: - Advance (what happens when the current track ends)

    struct AdvanceInputs: Equatable {
        /// The head belongs to the current deterministic context
        /// (album / playTracks list).
        var headIsContextTrack: Bool
        /// The context's playlist id (album / playlist), nil for radio.
        var contextPlaylistId: String?
        /// The playlist id the page is currently in.
        var currentPlaylistId: String?
        /// The head is an explicit Play-Next / Add-to-queue item.
        var headIsUserQueued: Bool
        /// A Tune chip is active (Riff-curated queue; page-unaware).
        var hasActiveChip: Bool
        /// The current page's queue mirror has landed at least once.
        var mirrorFresh: Bool
        /// Plain radio, no chip — the page is the queue authority.
        var isPageDriven: Bool
    }

    enum Advance: Equatable {
        /// The page's own advance plays the head — arm NOTHING. Forcing a
        /// location.href here reloads the page and (in radio) re-rolls
        /// the queue.
        case native
        /// Navigate to the head INSIDE its context list (restores an
        /// album/playlist context after an interlude).
        case navigateIntoContext(String)
        /// Navigate to the head with its own per-track radio (a
        /// Play-Next injection from outside the context).
        case navigateRadio
        /// Navigate keeping the current non-radio list (chip queues and
        /// /next-seeded deterministic heads before the mirror is live).
        case navigateDeterministic
    }

    static func advance(_ i: AdvanceInputs) -> Advance {
        if i.headIsContextTrack, let ctx = i.contextPlaylistId, !ctx.isEmpty {
            return i.currentPlaylistId == ctx ? .native : .navigateIntoContext(ctx)
        }
        if i.headIsUserQueued { return .navigateRadio }
        if i.hasActiveChip || (!i.mirrorFresh && !i.isPageDriven) { return .navigateDeterministic }
        return .native
    }

    // MARK: - Enforcement (snap an autoplay divergence back to the shown head)

    /// Only where Riff genuinely owns the next-up order. In page-driven
    /// contexts with a live mirror the shown queue IS the page's, so any
    /// "divergence" is mirror lag — enforcing would fight the page.
    static func enforcementApplies(userQueueCount: Int, hasActiveChip: Bool,
                                   mirrorFresh: Bool, isPageDriven: Bool) -> Bool {
        userQueueCount > 0 || hasActiveChip || (!mirrorFresh && !isPageDriven)
    }

    // MARK: - Mirror (page queue → displayed Up Next)

    /// Chip queues are Riff-curated; while the user region has items the
    /// user's list is the queue (repainting filler beneath it is churn).
    static func mirrorApplies(hasActiveChip: Bool, userQueueCount: Int) -> Bool {
        !hasActiveChip && userQueueCount == 0
    }

    // MARK: - Next button / shuffle / row tap

    /// Next advances via the page's own control (no reload) whenever the
    /// page owns the head.
    static func nextUsesPageNative(isPageDriven: Bool, headIsUserQueued: Bool) -> Bool {
        isPageDriven && !headIsUserQueued
    }

    /// A local random pick is only legitimate where the shown list is
    /// Riff's; in page-driven contexts shuffle belongs to the page.
    static func localShuffleAllowed(isPageDriven: Bool) -> Bool {
        !isPageDriven
    }

    /// A tapped row plays IN the page queue (no navigation) when the page
    /// owns that row.
    static func rowTapUsesPageJump(hasActiveChip: Bool, mirrorFresh: Bool,
                                   rowIsUserQueued: Bool, rowIsInQueue: Bool) -> Bool {
        !hasActiveChip && mirrorFresh && !rowIsUserQueued && rowIsInQueue
    }

    // MARK: - Context exhaustion (Repeat All / autoplay-off stop)

    /// "The album/list is over": the finishing track is a context track,
    /// nothing user-queued remains, and the next shown row (if any) is
    /// NOT a context track — i.e. only the page's autoplay filler is
    /// left. A single-track context (plain radio seed) never exhausts.
    static func contextExhausted(userQueueCount: Int, contextTrackIds: Set<String>,
                                 currentId: String?, headId: String?) -> Bool {
        guard userQueueCount == 0, contextTrackIds.count > 1,
              let cur = currentId, contextTrackIds.contains(cur) else { return false }
        guard let headId else { return true }
        return !contextTrackIds.contains(headId)
    }
}
