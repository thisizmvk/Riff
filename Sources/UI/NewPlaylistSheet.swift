import SwiftUI

/// Tiny sheet that prompts for a playlist name, then creates the
/// playlist and seeds it from a configurable source. Two modes today
/// (and easy to extend if more "Create playlist from X" flows show
/// up):
///
///   - **`.currentTrack`** — adds the currently-playing track. The
///     original flow; reachable from the now-playing add-to-playlist
///     menu's "New Playlist…" entry.
///   - **`.queue`** — adds every track currently in `upNext`.
///     Reachable from the "Save queue" button at the top of the Up
///     Next pane. Mirrors YT Music's "Save" affordance.
struct NewPlaylistSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var creating: Bool = false
    @State private var error: String?

    /// Source that seeds the new playlist's first batch of tracks.
    enum Source: Equatable {
        case currentTrack
        case queue
        /// A specific track (context-menu "Add to playlist → New
        /// Playlist…" from any row) — previously that path had to
        /// PLAY the row first to reuse .currentTrack, interrupting
        /// whatever the user was listening to.
        case item(MediaItem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headline)
                .font(.system(size: 16, weight: .semibold))
            Text(subheadline)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Playlist name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if creating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Strings adapt to the source so the sheet is self-explanatory.
    private var headline: String {
        switch env.newPlaylistSource {
        case .currentTrack: return "New Playlist"
        case .queue:        return "Save Queue as Playlist"
        case .item:         return "New Playlist"
        }
    }

    private var subheadline: String {
        switch env.newPlaylistSource {
        case .currentTrack:
            return "Creates a private playlist and adds the currently-playing track."
        case .queue:
            let n = env.player.upNext.count
            return "Creates a private playlist and adds the \(n) track\(n == 1 ? "" : "s") currently in Up Next."
        case .item(let item):
            return "Creates a private playlist and adds “\(item.title)”."
        }
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        creating = true
        error = nil
        let source = env.newPlaylistSource
        Task {
            do {
                switch source {
                case .currentTrack:
                    _ = try await env.player.createPlaylistWithCurrentTrack(title: trimmed)
                case .queue:
                    _ = try await env.player.savePlaylistFromQueue(title: trimmed)
                case .item(let item):
                    let plid = try await env.innerTube.createPlaylist(title: trimmed)
                    if let plid {
                        try await env.innerTube.addToPlaylist(videoId: item.id, playlistId: plid)
                    }
                }
                env.reloadUserPlaylists()
                await MainActor.run {
                    creating = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = "Couldn't create playlist: \(error.localizedDescription)"
                    creating = false
                }
            }
        }
    }
}
