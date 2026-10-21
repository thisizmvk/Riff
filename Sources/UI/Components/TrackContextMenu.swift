import SwiftUI

/// Standard YT-Music-style context menu for a track row. Used by
/// queue rows, search/library results, and detail-page tracklists so
/// the user gets the same affordances ("Play next", "Add to queue",
/// "Start radio", "Go to album", "Go to artist") everywhere.
///
/// Usage:
///   ```
///   .contextMenu { TrackContextMenu(item: track) }
///   ```
///
/// All actions are gated on data we actually have:
///   - Play / Start radio: always shown for songs/episodes
///   - Play next / Add to queue: shown when there's a current track
///     (so the queue exists). Tagged in PlayerBridge's userQueuedIds
///     so when the current track reaches end-of-stream we navigate
///     to the user-queued item, beating YT Music's natural autoplay.
///   - Go to album: only when the row's MediaItem carries `albumId`
///   - Go to artist: only when the row carries `artistId`
///   - Add to playlist: signed-in only
struct TrackContextMenu: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem
    /// When true, omits the Play action — useful for the queue's own
    /// rows where the row's primary tap already plays it.
    var omitPrimaryPlay: Bool = false
    /// When true, adds a Pin / Unpin row at the bottom of the menu.
    /// Set by the Library tab's `ThumbnailButton` instances; off
    /// everywhere else so we don't clutter the menu in Home / Search
    /// / Now Playing surfaces where pinning has no destination.
    var showPinAction: Bool = false

    var body: some View {
        if !omitPrimaryPlay {
            Button("Play") {
                Task { await env.player.play(item: item) }
            }
        }
        Button(item.kind == .song || item.kind == .episode ? "Start song radio" : "Start radio") {
            Task { await env.player.startRadio(for: item) }
        }
        // "Blend from here" — the offline counterpart to radio: a
        // personal mix from local history leaning into this artist.
        // Shown only once there's enough history to blend (else it would
        // produce an empty or generic queue).
        if BlendBuilder.seedArtistId(for: item) != nil,
           BlendBuilder.isAvailable(from: env.player.playedEntries) {
            Button("Blend from here") {
                let mix = BlendBuilder.seeded(by: item, from: env.player.playedEntries)
                guard !mix.isEmpty else {
                    env.showToast("Not enough history to blend yet.")
                    return
                }
                Task { await env.player.playTracks(mix) }
                env.showToast("Blending around \(item.title) — \(mix.count) songs")
            }
        }
        Divider()
        Button("Play next") {
            env.player.playNext(item: item)
            env.showToast("Playing next: \(item.title)")
        }
        .disabled(!env.player.hasTrack)
        Button("Add to queue") {
            env.player.addToQueueEnd(item: item)
            env.showToast("Added to queue: \(item.title)")
        }
        .disabled(!env.player.hasTrack)
        if item.albumId != nil || item.artistId != nil {
            Divider()
            if let albumId = item.albumId {
                Button("Go to album") {
                    env.navigateToBrowseId(albumId, kind: .album)
                }
            }
            if let artistId = item.artistId {
                Button("Go to artist") {
                    env.navigateToBrowseId(artistId, kind: .artist)
                }
                // "Don't recommend this artist" — hides every future
                // surfacing of the artist (Home carousels, Search
                // results, /next radio, /related). Removable from
                // Settings → Library → Blocked Artists.
                //
                // For song rows: the subtitle holds the artist name
                // ("Bruno Mars · 24K Magic · 2016") so we take
                // everything up to the first " · " separator. For
                // artist tiles the row title IS the artist name.
                Button("Don't recommend this artist") {
                    let nameGuess: String
                    if item.kind == .artist {
                        nameGuess = item.title
                    } else {
                        // Split on " · " or "•" — both the dotted YT
                        // separator and the legacy bullet show up in
                        // search subtitles. trimming handles spaces.
                        let firstSegment = item.subtitle
                            .split(whereSeparator: { $0 == "·" || $0 == "•" })
                            .first
                            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? item.subtitle
                        nameGuess = firstSegment
                    }
                    env.blockArtist(id: artistId, name: nameGuess)
                    // Undo toast — blocking is easy to trigger by
                    // accident and hard to reverse (Settings → Blocked
                    // artists is buried); a one-tap undo keeps the
                    // action safe. (U2)
                    env.showToast("Blocked \(nameGuess)") {
                        env.unblockArtist(id: artistId)
                        env.showToast("Unblocked \(nameGuess)")
                    }
                }
            }
        }
        if env.isSignedIn {
            Divider()
            addToPlaylistMenu
            // Thumbs-down — the server-side steering signal local
            // artist-blocking can't send: YT's radio stops suggesting
            // the track account-wide. Songs/episodes only.
            if item.kind == .song || item.kind == .episode {
                Button("Not for me (dislike)") {
                    Task {
                        if await env.player.dislike(videoId: item.id) {
                            env.showToast("Disliked — YT Music will suggest this less")
                        } else {
                            env.showToast("Couldn't dislike \(item.title)")
                        }
                    }
                }
            }
        }
        // "Copy share link" — the music.youtube.com URL for this
        // track. Bottom of the menu so it doesn't bump the common
        // queue/play actions down. Songs + episodes only (other
        // kinds have their own kebab affordances; sharing an artist
        // isn't really a thing).
        if item.kind == .song || item.kind == .episode {
            Divider()
            // "Watch music video" — replaces the in-app audio↔video
            // toggle that kept re-leaking the WKWebView into the main
            // window (violating CLAUDE.md's load-bearing rule). YT
            // Music renders the video correctly in a normal browser
            // tab, so we hand the URL off to the system default
            // browser instead of hosting the WebView ourselves. Same
            // videoId, same experience, zero WKWebView surfacing.
            Button("Watch music video") {
                if let url = URL(string: "https://music.youtube.com/watch?v=\(item.id)") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Copy share link") {
                let url = "https://music.youtube.com/watch?v=\(item.id)"
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url, forType: .string)
            }
        }
        // D2 — "Edit metadata" opens a sheet pre-populated with the
        // current title / artist / album. Songs only; non-song rows
        // (album / playlist / artist tiles) are out of scope.
        if item.kind == .song {
            Button("Edit metadata…") {
                env.trackBeingEdited = item
            }
        }
        if showPinAction {
            Divider()
            Button(env.isPinned(item.id) ? "Unpin from top" : "Pin to top") {
                env.togglePinned(id: item.id)
            }
        }
    }

    /// Nested submenu mirroring the now-playing "Add to Playlist…" picker
    /// so the user can stash any track into a user-owned playlist
    /// without first making it the current track.
    private var addToPlaylistMenu: some View {
        Menu("Add to playlist") {
            Button("New Playlist…") {
                // .item source: file THIS row into the new playlist
                // without touching playback. (The old workaround played
                // the row first to reuse .currentTrack — interrupting
                // the current song because the user filed a track away.)
                env.newPlaylistSource = .item(item)
                env.isNewPlaylistSheetPresented = true
            }
            if env.userPlaylistsLoading {
                Text("Loading…")
            } else if env.userPlaylists.isEmpty {
                Text("No playlists yet.")
            } else {
                Divider()
                ForEach(env.userPlaylists) { pl in
                    Button(pl.title) {
                        Task {
                            // Toast both outcomes — Play next / Add to
                            // queue toast, so a silent add here read as
                            // "did that even work?"
                            do {
                                try await env.innerTube.addToPlaylist(
                                    videoId: item.id,
                                    playlistId: pl.id
                                )
                                env.showToast("Added to \(pl.title)")
                            } catch {
                                env.showToast("Couldn't add to \(pl.title)")
                            }
                        }
                    }
                }
            }
        }
        .onAppear { env.loadUserPlaylistsIfNeeded() }
    }
}
