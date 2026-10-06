import Foundation
import Observation

/// Playlist ids the user has saved to their library from inside Riff,
/// so the detail-header Save button reads "Saved" on a return visit
/// without a round-trip. Keyed by the id Riff saves WITH — an album's
/// playable playlist id (`OLAK5uy…`) or a playlist's own id.
///
/// Persisted, and remembers only what the user saved through Riff; it
/// is not a mirror of the full server-side library (that would need a
/// browseId→playlistId reconciliation the library feed doesn't carry),
/// so an album saved elsewhere opens showing "Save" until re-saved —
/// never a false "Saved". Cleared on sign-out.
@MainActor
@Observable
final class SavedLibraryStore {
    private static let key = "library.savedPlaylistIds"

    private(set) var ids: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    @ObservationIgnored private let defaults: UserDefaults

    func contains(_ playlistId: String) -> Bool { ids.contains(playlistId) }

    func set(_ playlistId: String, saved: Bool) {
        guard !playlistId.isEmpty else { return }
        let before = ids.count
        if saved { ids.insert(playlistId) } else { ids.remove(playlistId) }
        if ids.count != before { persist() }
    }

    func clear() {
        ids = []
        defaults.removeObject(forKey: Self.key)
    }

    private func persist() {
        defaults.set(Array(ids), forKey: Self.key)
    }
}
