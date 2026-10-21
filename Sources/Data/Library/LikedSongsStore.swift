import Foundation
import Observation

/// App-wide set of liked video ids, so a heart at rest tells the truth
/// on every row — not just the currently-playing one.
///
/// The canonical like state for the *playing* track comes from the
/// page's `/next` response (`PlayerBridge.liked`). Every other row used
/// to start hollow and flip only optimistically, so a song you liked
/// yesterday showed as un-liked until it became current. This store is
/// seeded from `library(.liked)` on sign-in and written through on
/// every like / unlike, giving every row a resting truth with no
/// per-row `/next` fetch.
///
/// Persisted so the hearts are right on the first frame after launch,
/// before the library re-seed lands. Cleared on sign-out.
@MainActor
@Observable
final class LikedSongsStore {
    private static let key = "library.likedVideoIds"

    private(set) var ids: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    @ObservationIgnored private let defaults: UserDefaults

    func contains(_ videoId: String) -> Bool { ids.contains(videoId) }

    /// Write-through on a like / unlike. Idempotent.
    func set(_ videoId: String, liked: Bool) {
        guard !videoId.isEmpty else { return }
        let before = ids.count
        if liked { ids.insert(videoId) } else { ids.remove(videoId) }
        if ids.count != before { persist() }
    }

    /// Replace the whole set from a fresh `library(.liked)` fetch.
    func seed(_ videoIds: [String]) {
        ids = Set(videoIds.filter { !$0.isEmpty })
        persist()
    }

    /// Sign-out: forget the previous account's likes.
    func clear() {
        ids = []
        defaults.removeObject(forKey: Self.key)
    }

    private func persist() {
        defaults.set(Array(ids), forKey: Self.key)
    }
}
