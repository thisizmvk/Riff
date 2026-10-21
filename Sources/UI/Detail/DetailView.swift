import SwiftUI

/// Album / Playlist / Artist / Podcast detail page. One view because all
/// four use the same InnerTube /browse response shape (header + tracklist),
/// they just style slightly differently. Pushed onto the active tab's
/// NavigationStack when the user taps a non-song tile.
/// A tracklist row with a per-ENTRY identity (see `tracklist`).
private struct IndexedTrack: Identifiable {
    let id: String
    let index: Int
    let track: MediaItem
}

struct DetailView: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem

    @State private var page: InnerTubeClient.DetailPage?
    @State private var loading = true
    @State private var error: String?
    @State private var editSheetPresented = false
    /// Active sort order for this page's tracklist. Hydrated from
    /// UserDefaults by `TrackSortMenu` under the key returned by
    /// `trackSortPersistenceKey`, so revisiting the same album /
    /// playlist remembers the user's choice without leaking it across
    /// other pages.
    @State private var trackSort: LibrarySorting.TrackSortOrder = .original

    /// Dominant color of the page artwork, driving the top-anchored
    /// accent wash behind the header (Apple Music / YT Music signature).
    /// nil until extracted, and on failure, so the page falls back to the
    /// plain base background. See `.background` below and `backdropArtURL`.
    @State private var backdropColor: Color? = nil

    /// True when the open detail page represents a playlist owned by
    /// the signed-in user — checked by id against env.userPlaylists.
    /// Drives the Edit affordance: only user-owned playlists can be
    /// renamed / deleted / have tracks removed.
    private var isUserOwnedPlaylist: Bool {
        guard item.kind == .playlist else { return false }
        return env.userPlaylists.contains { $0.id == item.id }
    }

    /// Per-page UserDefaults key. Scoped to the entity id so each
    /// album / playlist remembers its own sort. nil for kinds where
    /// the sort menu doesn't render (artist / song) so the menu falls
    /// back to in-memory-only mode if it ever does mount.
    private var trackSortPersistenceKey: String? {
        switch item.kind {
        case .album, .playlist, .podcast: return "tracks.sort.\(item.id)"
        case .artist, .episode, .song:    return nil
        }
    }

    /// Surface flavor passed to the menu so the `.original` label
    /// reads naturally per kind ("Album order" / "Playlist order" /
    /// "Original order"). Podcasts get the generic phrasing — "episode
    /// order" sounds redundant on a podcast page already titled with
    /// the show name.
    private var trackSortSurface: LibrarySorting.TrackSortSurface {
        switch item.kind {
        case .album:    return .album
        case .playlist: return .playlist
        default:        return .generic
        }
    }

    /// Whether to render the sort menu above the tracklist. Hidden on
    /// surfaces where it would either confuse (artist top-tracks rail
    /// is already curated by YT) or render against an empty list.
    private var showsTrackSortMenu: Bool {
        guard let page, !page.tracks.isEmpty else { return false }
        switch item.kind {
        case .album, .playlist, .podcast: return true
        default: return false
        }
    }

    /// Order-pruned sort options. Podcasts hide the duration sorts
    /// (episode runtimes vary by hours, not a useful comparison axis
    /// for most listeners) and keep the play-history sorts off because
    /// the `PlayedEntry` journal currently records song ids, not
    /// episode-scoped data.
    private var availableTrackSorts: [LibrarySorting.TrackSortOrder] {
        switch item.kind {
        case .podcast:
            return [.original, .aToZ, .zToA]
        default:
            return LibrarySorting.TrackSortOrder.allCases
        }
    }

    /// Tracks, after applying the current sort order. Pure function;
    /// reads the live play-history journal so `.playCount` /
    /// `.lastPlayed` reflect any plays that happen while the user is
    /// on the page (e.g. tapping a track changes its own count on
    /// the next render).
    private func sortedTracks(_ tracks: [MediaItem]) -> [MediaItem] {
        LibrarySorting.sortTracks(tracks, by: trackSort, entries: env.player.playedEntries)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // In-content back button. The window toolbar (which would
                // otherwise carry NavigationStack's back button) is hidden
                // app-wide to dodge the NSToolbar duplicate-identifier
                // crash, so detail pages provide their own.
                backButton
                    .padding(.horizontal, 24)
                if let page {
                    // Album + playlist pages use YT Music web's two-column
                    // layout: a fixed header column (centered artwork /
                    // artist / title / meta / circular actions) on the
                    // left, the tracklist on the right. Artist + podcast
                    // pages keep the horizontal hero header.
                    if item.kind == .album || item.kind == .playlist {
                        albumLayout(page)
                    } else {
                        header(page)
                        Divider().background(Theme.divider)
                        trackSection(page)
                    }
                    // "More from <Artist>" / "You might also like" /
                    // "Other versions" — YT Music's at-the-bottom carousels.
                    // Falls through gracefully when YT didn't return any.
                    if !page.relatedSections.isEmpty {
                        relatedSections(page.relatedSections)
                            .padding(.top, 16)
                    }
                } else if loading {
                    DetailSkeleton(twoColumn: item.kind == .album || item.kind == .playlist)
                } else if let error {
                    ErrorBanner(message: error) {
                        Task { await load() }
                    }
                    .padding(.horizontal, 32)
                }
            }
            .padding(.top, 24)
            // Clear the mini-player bar (~72pt) when one is showing so the
            // last related rail's tile TITLES are not clipped by it — they
            // were rendering below the fold ("relevant albums don't show
            // names"). Plain 24 when nothing is playing.
            .padding(.bottom, env.player.hasTrack ? 96 : 24)
        }
        .background {
            // Backdrops live in a background stack — entirely behind the
            // ScrollView, so their sizes never feed back into its layout
            // (the fullscreen-ZStack inflation trap). A top-anchored wash
            // of the artwork's dominant color tints the header region and
            // fades to the flat base well before the tracklist, keeping
            // row text on the familiar dark ground.
            ZStack(alignment: .top) {
                Theme.Bg.base
                if let backdropColor {
                    LinearGradient(
                        stops: [
                            .init(color: backdropColor.opacity(0.34), location: 0.0),
                            .init(color: backdropColor.opacity(0.16), location: 0.14),
                            .init(color: backdropColor.opacity(0.04), location: 0.34),
                            .init(color: .clear, location: 0.52),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .transition(.opacity)
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: backdropColor)
        }
        .task(id: item.id) {
            await load()
            // Make sure userPlaylists is populated so the
            // isUserOwnedPlaylist check returns the right answer on
            // first navigation. Cheap when already loaded.
            env.loadUserPlaylistsIfNeeded()
        }
        .task(id: backdropArtURL) {
            // Pull the accent color off the artwork once it's known. Reads
            // the shared URLCache the header AsyncImage warms, so it's
            // usually instant. A cancelled fetch (fast back-navigation)
            // must not land late and clear the next page's color.
            guard let url = backdropArtURL else {
                backdropColor = nil
                return
            }
            let color = await DominantColor.extract(from: url)
            guard !Task.isCancelled else { return }
            backdropColor = color
        }
        // Edit-playlist sheet. Attached at page level (not inside a
        // header builder) because BOTH layouts — the two-column album
        // page's ⋯ menu and the classic hero header — can present it.
        .sheet(isPresented: $editSheetPresented) {
            EditPlaylistSheet(
                playlistId: item.id,
                initialTitle: resolvedTitle,
                onDeleted: {
                    // Pop back to the previous nav stack frame so
                    // the user isn't stranded on a deleted playlist.
                    // Falls back to no-op if the user was at root.
                    goBack()
                }
            )
        }
        // CRITICAL — do not remove: suppresses NavigationStack's automatic
        // back-button toolbar item AT THE SOURCE. With four tab panes
        // mounted, pushed pages in two stacks registered duplicate toolbar
        // item identifiers and NSToolbar throws (macOS 27 crashes on it).
        // Hiding the toolbar did NOT stop the registration — field crashes
        // 2026-10-09 and 2026-10-20 both died in
        // NSToolbar _insertNewItemWithItemIdentifier. Riff's back
        // affordance is the in-content `backButton` above.
        .navigationBarBackButtonHidden(true)
    }

    /// The artwork URL the accent wash is sampled from: the resolved
    /// page artwork once loaded, else the tile thumbnail the user tapped
    /// in from, so the wash appears immediately rather than after /browse.
    private var backdropArtURL: URL? {
        page?.artworkURL ?? item.thumbnailURL
    }

    /// Pops the active tab's navigation stack by one. Mirrors the
    /// per-tab path switch used elsewhere; no-ops at the root.
    private func goBack() {
        switch env.activeTab {
        case .home:    if !env.homeNavPath.isEmpty    { env.homeNavPath.removeLast() }
        case .explore: if !env.exploreNavPath.isEmpty { env.exploreNavPath.removeLast() }
        case .search:  if !env.searchNavPath.isEmpty  { env.searchNavPath.removeLast() }
        case .library: if !env.libraryNavPath.isEmpty { env.libraryNavPath.removeLast() }
        }
    }

    /// Back affordance for detail pages (the macOS toolbar back button is
    /// unavailable — the window toolbar is hidden app-wide). ⌘[ also pops.
    private var backButton: some View {
        Button(action: goBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text("Back")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Theme.Fill.strong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")
        .accessibilityLabel("Back")
    }

    /// Page title with the /browse result preferred over the (possibly
    /// stale) tile the user tapped in from.
    private var resolvedTitle: String {
        if let t = page?.title, !t.isEmpty { return t }
        return item.title
    }

    // MARK: - Album / playlist two-column layout (YT Music web)

    private func albumLayout(_ page: InnerTubeClient.DetailPage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            albumHeaderColumn(page)
                .frame(width: 340)
                .padding(.leading, 24)
            VStack(alignment: .leading, spacing: 0) {
                trackSection(page)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Sort menu + tracklist (or the empty placeholder). Shared by the
    /// two-column album layout and the classic hero layout.
    @ViewBuilder
    private func trackSection(_ page: InnerTubeClient.DetailPage) -> some View {
        if page.tracks.isEmpty {
            Text("No tracks")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Text.secondary)
                .padding(.horizontal, 32)
        } else {
            if showsTrackSortMenu {
                // Sort menu above the tracklist. Right-aligned so it
                // doesn't shove the rows around as the user toggles
                // between orders.
                HStack {
                    Spacer()
                    TrackSortMenu(
                        selection: $trackSort,
                        surface: trackSortSurface,
                        persistenceKey: trackSortPersistenceKey,
                        orders: availableTrackSorts
                    )
                }
                .padding(.horizontal, 32)
            }
            tracklist(sortedTracks(page.tracks), fallbackArtwork: page.artworkURL ?? item.thumbnailURL)
        }
    }

    /// Centered header column: HD artwork, artist line ABOVE the big
    /// title (YT web's order), "Album • 2026", "12 songs • 35 minutes",
    /// then the circular action cluster with the red Play at its center.
    private func albumHeaderColumn(_ page: InnerTubeClient.DetailPage) -> some View {
        VStack(spacing: 6) {
            AsyncImage(url: (page.artworkURL ?? item.thumbnailURL)?.upscaledArtwork(to: 600)) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: Theme.Fill.soft
                }
            }
            .frame(width: 272, height: 272)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .padding(.bottom, 16)

            artistLine(page)
                .font(.system(size: 13, weight: .medium))

            Text(resolvedTitle)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Text(kindYearLine(page))
                .font(.system(size: 12))
                .foregroundStyle(Theme.Text.secondary)
            if let counts = songsRuntimeLine(page) {
                Text(counts)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.secondary)
            }

            actionCluster(page)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    /// Just the artist for the centered column — the header subtitle's
    /// kind label ("Album"), year, and "•" separators are dropped
    /// because the column renders kind + year on its own meta line.
    /// Linked runs stay tappable.
    @ViewBuilder
    private func artistLine(_ page: InnerTubeClient.DetailPage) -> some View {
        let kept = page.subtitleRuns.filter { run in
            let t = run.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t != "•", t != "·" else { return false }
            if ["album", "playlist", "ep", "single", "podcast"].contains(t.lowercased()) { return false }
            if let y = Int(t), (1900...2099).contains(y) { return false }
            return true
        }
        if kept.isEmpty {
            // Guard the fallback with the same rules as the runs above:
            // a bare year is not an artist (playlist headers whose only
            // run is "2026" rendered the YEAR as the artist line).
            if let derived = albumArtistFallback(page: page), !derived.isEmpty,
               Int(derived.trimmingCharacters(in: .whitespaces)) == nil {
                Text(derived).foregroundStyle(Theme.Text.secondary)
            }
            // else: render nothing — the title + meta lines carry the page.
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(kept.enumerated()), id: \.offset) { idx, run in
                    if idx > 0 {
                        Text(" • ").foregroundStyle(Theme.Text.secondary)
                    }
                    if let id = run.browseId, let kind = run.kind, kind == .artist || kind == .album {
                        Button {
                            env.navigateToBrowseId(id, kind: kind)
                        } label: {
                            Text(run.text)
                                .foregroundStyle(.white)
                                .underline(true, color: Theme.Text.tertiary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(run.text).foregroundStyle(Theme.Text.secondary)
                    }
                }
            }
            .lineLimit(1)
        }
    }

    /// "Album • 2026" — year from any track, else from a bare-year
    /// header subtitle run (playlists often carry it only there).
    private func kindYearLine(_ page: InnerTubeClient.DetailPage) -> String {
        let headerYear = page.subtitleRuns
            .compactMap { Int($0.text.trimmingCharacters(in: .whitespaces)) }
            .first { (1900...2099).contains($0) }
        if let y = page.tracks.compactMap(\.year).first ?? headerYear {
            return "\(kindLabel) • \(y)"
        }
        return kindLabel
    }

    /// "12 songs • 35 minutes" — YT web spells minutes out here.
    private func songsRuntimeLine(_ page: InnerTubeClient.DetailPage) -> String? {
        guard !page.tracks.isEmpty else { return nil }
        var pieces = [page.tracks.count == 1 ? "1 song" : "\(page.tracks.count) songs"]
        let secs = page.tracks.compactMap(\.durationSeconds).reduce(0, +)
        if secs > 0 {
            let m = secs / 60
            if m < 60 {
                pieces.append(m == 1 ? "1 minute" : "\(m) minutes")
            } else {
                let h = m / 60, r = m % 60
                pieces.append(r == 0 ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h) hr \(r) min")
            }
        }
        return pieces.joined(separator: " • ")
    }

    /// Circular icon actions — shuffle · save · PLAY · share · ⋯ —
    /// with the oversized red play as the center of gravity.
    private func actionCluster(_ page: InnerTubeClient.DetailPage) -> some View {
        HStack(spacing: 14) {
            circleButton("shuffle", help: "Shuffle") {
                Task { await shuffle(page) }
            }

            if !isUserOwnedPlaylist,
               let saveId = page.playablePlaylistId, !saveId.isEmpty {
                let saved = env.isSavedToLibrary(saveId)
                circleButton(saved ? "checkmark" : "plus",
                             help: saved ? "Remove from your library" : "Save to your library",
                             tint: saved ? Theme.red : nil) {
                    env.toggleSavedToLibrary(playlistId: saveId, title: resolvedTitle)
                }
            }

            Button {
                Task { await playAll(page) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Theme.red))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play")
            .accessibilityLabel("Play \(resolvedTitle)")

            circleButton("square.and.arrow.up", help: "Copy share link") {
                copyShareLink(page)
            }

            Menu {
                if isUserOwnedPlaylist {
                    Button("Edit Playlist…") { editSheetPresented = true }
                }
                Button("Copy share link") { copyShareLink(page) }
            } label: {
                circleLabel("ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func circleButton(_ systemImage: String, help: String,
                              tint: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(systemImage, tint: tint) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }

    private func circleLabel(_ systemImage: String, tint: Color? = nil) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint ?? .white)
            .frame(width: 42, height: 42)
            .background(Circle().fill(Color.white.opacity(0.08)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .contentShape(Circle())
    }

    /// Copies the canonical music.youtube.com URL for this page. Albums
    /// use the browseId; playlists use the bare list id (VL prefix
    /// stripped — the VL form is browse-only and 404s as a share link).
    private func copyShareLink(_ page: InnerTubeClient.DetailPage) {
        let url: String
        if item.kind == .album {
            url = "https://music.youtube.com/browse/\(item.id)"
        } else {
            let pid = page.playablePlaylistId ?? item.id
            let bare = pid.hasPrefix("VL") ? String(pid.dropFirst(2)) : pid
            url = "https://music.youtube.com/playlist?list=\(bare)"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
        env.showToast("Link copied")
    }

    private func header(_ page: InnerTubeClient.DetailPage) -> some View {
        HStack(alignment: .top, spacing: 24) {
            // Artwork upscaled via the =wN-hN host rewrite — the raw
            // thumbnail YT attaches to browse rows is often 226px, which
            // is soft at 220pt on Retina.
            AsyncImage(url: (page.artworkURL ?? item.thumbnailURL)?.upscaledArtwork(to: 600)) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: Theme.Fill.soft
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(kindLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(Theme.Text.secondary)
                Text(page.title.isEmpty ? item.title : page.title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                annotatedSubtitle(page)
                    .font(.system(size: 13))
                    .lineLimit(3)
                // Metadata line: "9 songs · 32 min · 2024" (or whichever
                // pieces are available). Built from the tracks we
                // already parsed — no extra round-trip. Empty string
                // when nothing's known (renders as a zero-height
                // EmptyView via the conditional).
                if let meta = metadataLine(for: page) {
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Text.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Button {
                        Task { await playAll(page) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.red)

                    Button {
                        Task { await shuffle(page) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)

                    // Save to Library — albums and playlists the user
                    // doesn't already own. Keyed by the playable
                    // playlist id (album → OLAK5uy…, playlist → its own
                    // id). Hidden for artists (use Follow) and for
                    // playlists the user owns (already in their library).
                    if (item.kind == .album || item.kind == .playlist),
                       !isUserOwnedPlaylist,
                       let saveId = page.playablePlaylistId, !saveId.isEmpty {
                        let saved = env.isSavedToLibrary(saveId)
                        Button {
                            env.toggleSavedToLibrary(playlistId: saveId,
                                                     title: page.title.isEmpty ? item.title : page.title)
                        } label: {
                            Label(saved ? "Saved" : "Save",
                                  systemImage: saved ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(saved ? Theme.red : nil)
                        .help(saved ? "Remove from your library" : "Save to your library")
                    }

                    // Edit menu — visible only on user-owned
                    // playlists. The endpoints we expose
                    // (rename / privacy / delete) all require
                    // ownership, so showing it elsewhere would just
                    // produce errors on save.
                    if isUserOwnedPlaylist {
                        Menu {
                            Button("Edit Playlist…") {
                                editSheetPresented = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 44)
                    }

                    // Inline block/unblock button on Artist pages —
                    // mirrors the entry in TrackContextMenu and
                    // Settings → Library → Blocked Artists, but
                    // saves two clicks for users who already know
                    // they don't want to hear this artist again.
                    // We surface it only for artist detail pages;
                    // album/playlist pages already get block via
                    // the per-track context menu.
                    if item.kind == .artist {
                        if env.isSignedIn {
                            followArtistButton(page: page)
                        }
                        blockArtistButton(page: page)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    /// Inline "Don't recommend this artist" / "Recommend this artist
    /// again" button rendered on Artist detail pages. The same action
    /// lives in TrackContextMenu and Settings → Library → Blocked
    /// Artists; surfacing it inline saves two clicks for a user who's
    /// arrived on the artist page specifically because they no longer
    /// want them in their rotation.
    ///
    /// Label and SF Symbol flip based on the current block state so
    /// the button is also the unblock affordance — no need to dive
    /// into Settings to undo a misclick. We prefer `page.title` for
    /// the human-readable name because `item.title` can be stale
    /// (e.g. arriving via "Go to artist" from a song row where the
    /// artist name was a subtitle split that lost the full name).
    /// Follow / Following toggle on Artist pages — the library already
    /// has a "New from artists you follow" rail, but there was no way to
    /// follow anyone without leaving the app.
    private func followArtistButton(page: InnerTubeClient.DetailPage) -> some View {
        let following = env.isFollowing(artistId: item.id)
        return Button {
            let name = page.title.isEmpty ? item.title : page.title
            env.toggleFollow(artistId: item.id, name: name)
        } label: {
            Label(following ? "Following" : "Follow",
                  systemImage: following ? "checkmark" : "plus")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(following ? Theme.red : nil)
        .help(following ? "Stop following this artist" : "Follow this artist on YouTube Music")
    }

    @ViewBuilder
    private func blockArtistButton(page: InnerTubeClient.DetailPage) -> some View {
        let blocked = env.isBlocked(artistId: item.id)
        Button {
            if blocked {
                env.unblockArtist(id: item.id)
            } else {
                let name = page.title.isEmpty ? item.title : page.title
                env.blockArtist(id: item.id, name: name)
            }
        } label: {
            Label(
                blocked ? "Recommend Again" : "Don't Recommend",
                systemImage: blocked ? "hand.thumbsup" : "hand.thumbsdown"
            )
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .help(blocked
              ? "Resume recommending this artist across Home, Search, and radio."
              : "Hide this artist from Home, Search, and radio. Undo from Settings → Library.")
    }

    /// Renders the album / playlist tracklist. `fallbackArtwork` is used
    /// for any track whose own row didn't carry a thumbnail — common on
    /// album responses where YT omits per-track artwork because every
    /// track shares the album cover.
    private func tracklist(_ tracks: [MediaItem], fallbackArtwork: URL?) -> some View {
        // Use the same backfill as the play/shuffle paths so the row
        // display, the mini-player, the lock-screen widget, and the
        // scrobbler payload all agree on artwork + artist. The `page`
        // handoff is safe here because tracklist(...) is only ever
        // called from inside signedInBody where `page` is non-nil.
        let backfilled: [MediaItem] = page.map { p in tracks.map { backfillMetadata($0, page: p) } } ?? tracks
        // Local play counts (YT exposes no per-song counts) — computed
        // once for the whole list and handed to each row.
        let counts = LibrarySorting.playCounts(from: env.player.playedEntries)
        return LazyVStack(alignment: .leading, spacing: 0) {
            // Row identity: a playlist may legally hold the same song
            // twice (that is what `setVideoId` is for). Keying by videoId
            // alone made SwiftUI diffing undefined — double highlights,
            // the wrong row animating out. setVideoId is unique per
            // entry; otherwise id + position.
            let rows: [IndexedTrack] = backfilled.enumerated().map { pair in
                IndexedTrack(id: pair.element.setVideoId.map { "s:" + $0 } ?? "\(pair.element.id)#\(pair.offset)",
                             index: pair.offset, track: pair.element)
            }
            ForEach(rows) { row in
                let index = row.index
                let track = row.track
                TrackRow(
                    index: index,
                    item: track,
                    playCount: counts[track.id] ?? 0,
                    isUserOwnedPlaylist: isUserOwnedPlaylist,
                    onPlay: {
                        // "Play from here": tapping track N of an
                        // album / playlist / podcast plays the list
                        // FROM N (N+1… queued), matching Spotify /
                        // Apple Music / YT Music. Artist top-songs keep
                        // single-play with auto-radio. Reuses the
                        // existing playTracks call site — no new
                        // navigate / play(item:) site, QueuePolicy
                        // untouched.
                        switch item.kind {
                        case .album, .playlist, .podcast:
                            let rest = Array(backfilled[index...])
                            await env.player.playTracks(rest, playlistId: page?.playablePlaylistId, sourceTitle: resolvedTitle)
                        default:
                            await env.player.play(item: track)
                        }
                    },
                    onRemoveFromPlaylist: isUserOwnedPlaylist
                        ? { setId in await removeFromCurrentPlaylist(track: track, setVideoId: setId) }
                        : nil
                )
            }
        }
    }

    /// Renders the album / playlist / artist subtitle with the linkable
    /// segments (artist / album runs) tappable. Built as an
    /// `HStack(alignment: .firstTextBaseline)` of individual `Text` /
    /// `Button` segments because:
    ///
    ///   - `AttributedString` + `.link` was eating runs in the album
    ///     header (some responsive-header layouts wrap subtitle.runs
    ///     in attributes that lose foreground colour, leaving an
    ///     "invisible" string on black).
    ///   - Native `Button` for each linkable run gives free hover
    ///     feedback + correct accessibility labels.
    ///
    /// Tradeoff: a long subtitle won't wrap mid-run. In practice album
    /// subtitles fit on one line anyway, and `Spacer` + `lineLimit(1)`
    /// gracefully truncates with an ellipsis.
    @ViewBuilder
    private func annotatedSubtitle(_ page: InnerTubeClient.DetailPage, centered: Bool = false) -> some View {
        let runs: [InnerTubeClient.AnnotatedRun] = page.subtitleRuns.isEmpty
            ? [InnerTubeClient.AnnotatedRun(
                text: page.subtitle.isEmpty ? item.subtitle : page.subtitle,
                browseId: nil, kind: nil)]
            : page.subtitleRuns
        // Drop empty runs that would render as zero-width gaps.
        let visible = runs.filter { !$0.text.isEmpty }

        if visible.isEmpty {
            // OST and single-song albums often come back with an
            // empty subtitle — YT has no single "album artist" to
            // surface. Try the same fallback the tracklist uses
            // (first track's own artist) before dropping down to
            // the kind label; showing "Album" alone reads like the
            // data is broken.
            if let derived = albumArtistFallback(page: page), !derived.isEmpty {
                Text(derived)
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                Text(kindLabel)
                    .foregroundStyle(Theme.Text.secondary)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, run in
                    if let id = run.browseId, let kind = run.kind, kind == .artist || kind == .album {
                        Button {
                            env.navigateToBrowseId(id, kind: kind)
                        } label: {
                            Text(run.text)
                                .foregroundStyle(.white)
                                .underline(true, color: Theme.Text.tertiary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(run.text)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
                if !centered { Spacer(minLength: 0) }
            }
        }
    }

    /// Renders the carousels returned by `/browse` after the tracklist.
    /// Uses `HomeSectionRow` so the visual treatment matches the Home
    /// tab's carousels — a familiar pattern keeps the page coherent.
    private func relatedSections(_ sections: [HomeSection]) -> some View {
        // Drop tiles YT returned with no title: they render as a
        // nameless artwork square ("Releases for you" showed anonymous
        // covers). A section left empty after filtering is dropped too,
        // so no bare header sits over nothing.
        let cleaned: [HomeSection] = sections.compactMap { section in
            let named = section.items.filter { !env.displayTitle(for: $0).trimmingCharacters(in: .whitespaces).isEmpty }
            guard !named.isEmpty else { return nil }
            return HomeSection(id: section.id, title: section.title, items: named,
                               moreBrowseId: section.moreBrowseId, moreParams: section.moreParams)
        }
        return VStack(alignment: .leading, spacing: 24) {
            if !cleaned.isEmpty {
                Divider().background(Theme.divider)
                ForEach(cleaned) { section in
                    HomeSectionRow(section: section)
                        .padding(.horizontal, 32)
                }
            }
        }
    }

    /// "9 songs · 32 min · 2024" header metadata. Returns nil when
    /// the tracks list is empty AND no year is known — at that point
    /// there's nothing useful to show, and a stub line would just
    /// add noise. Year is sourced from any track that has one (album
    /// detail responses sometimes put it on the rows even when the
    /// header subtitle omits it).
    private func metadataLine(for page: InnerTubeClient.DetailPage) -> String? {
        var pieces: [String] = []
        if !page.tracks.isEmpty {
            // "song" vs "songs" — small touch, but reads less robotic.
            pieces.append(page.tracks.count == 1 ? "1 song" : "\(page.tracks.count) songs")
            let totalSeconds = page.tracks.compactMap(\.durationSeconds).reduce(0, +)
            if totalSeconds > 0 {
                pieces.append(formatTotalRuntime(totalSeconds))
            }
        }
        // Year: first non-nil from the tracks. The album's header may
        // not have surfaced it but per-track rows often do.
        if let y = page.tracks.compactMap(\.year).first {
            pieces.append(String(y))
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " • ")
    }

    /// Compact "32 min" / "1 hr 18 min" for the metadata line. Drops
    /// seconds — total album runtimes in seconds add noise.
    private func formatTotalRuntime(_ totalSeconds: Int) -> String {
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    private var kindLabel: String {
        switch item.kind {
        case .album:    return "Album"
        case .playlist: return "Playlist"
        case .artist:   return "Artist"
        case .podcast:  return "Podcast"
        case .episode:  return "Episode"
        case .song:     return "Song"
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let detail: InnerTubeClient.DetailPage
            switch item.kind {
            case .playlist:
                // For curated playlists from carousels, item.id is the playlistId
                // (we strip "VL" in the parser). detail() expects browseId.
                detail = try await env.innerTube.playlistDetail(playlistId: item.id)
            default:
                detail = try await env.innerTube.detail(forBrowseId: item.id)
            }
            page = detail
            error = nil
        } catch {
            if Task.isCancelled || LoadErrorPresenter.isCancellation(error) { return }
            self.error = LoadErrorPresenter.message(for: error, env: env)
        }
    }

    private func playAll(_ page: InnerTubeClient.DetailPage) async {
        // Prefer our parsed tracklist over YT's playlist queue. YT's
        // playlist API often returns just the album's seed track
        // (queue=1) and after it ends autoplay falls into unrelated
        // radio. The /browse album detail we already loaded has the
        // real tracklist — use it directly via playTracks so the
        // local queue chains through the actual album.
        //
        // Honor the user's current sort order: "Play" on a tracklist
        // sorted by "Most played" should queue most-played-first, not
        // album order. Matches Spotify / Apple Music behaviour and
        // keeps the visible order in sync with what plays.
        Log.bridge.debug("DetailView.playAll tracks=\(page.tracks.count) playablePlaylistId=\(page.playablePlaylistId ?? "nil", privacy: .public)")
        if !page.tracks.isEmpty {
            let ordered = sortedTracks(page.tracks)
            let backfilled = ordered.map { backfillArtwork($0, page: page) }
            // Thread the album/playlist ID so /next auto-extension
            // stays in-context when the user region drains. (C5)
            await env.player.playTracks(backfilled, playlistId: page.playablePlaylistId, sourceTitle: resolvedTitle)
        } else if let plid = page.playablePlaylistId {
            // Empty tracklist — fall back to YT's playlist endpoint.
            // Reaches here only for entities where we couldn't parse
            // any tracks (rare; mostly broken responses).
            await env.player.playPlaylist(id: plid)
        }
    }

    /// Issue ACTION_REMOVE_VIDEO and optimistically prune the row
    /// from the in-memory tracklist so the UI reflects the change
    /// before /browse re-fetches. The `try?` swallows errors so a
    /// permission failure (rare; we already gated on ownership)
    /// doesn't strand the user — the next reload will show the
    /// authoritative state.
    private func removeFromCurrentPlaylist(track: MediaItem, setVideoId: String) async {
        try? await env.innerTube.removeFromPlaylist(
            setVideoId: setVideoId,
            videoId: track.id,
            playlistId: item.id
        )
        // Optimistic prune of the local copy so the user sees the
        // removal immediately. We don't refetch here because that
        // would scroll the user back to the top; the next time the
        // page loads it'll be authoritative.
        if let current = page {
            let pruned = current.tracks.filter { $0.id != track.id || $0.setVideoId != setVideoId }
            page = InnerTubeClient.DetailPage(
                title: current.title,
                subtitle: current.subtitle,
                subtitleRuns: current.subtitleRuns,
                artworkURL: current.artworkURL,
                playablePlaylistId: current.playablePlaylistId,
                tracks: pruned,
                relatedSections: current.relatedSections
            )
            _ = current  // silence unused-let warning
        }
    }

    private func shuffle(_ page: InnerTubeClient.DetailPage) async {
        // Same path as playAll but with the local tracklist permuted.
        // YT's server-side shuffle endpoint isn't reachable from
        // public params; we drive a local-shuffled order through
        // playTracks so the entire shuffle chains via the queue.
        guard !page.tracks.isEmpty else { return }
        let shuffled = page.tracks.shuffled().map { backfillArtwork($0, page: page) }
        await env.player.playTracks(shuffled, playlistId: page.playablePlaylistId, preservesListOrder: false, sourceTitle: resolvedTitle)
    }

    /// Returns `track` with its missing thumbnail filled from the
    /// album/playlist cover, mirroring the same backfill the per-row
    /// tap action does. Keeps the now-playing strip + Now Playing view
    /// from showing a black square for tracks that didn't carry their
    /// own artwork in the InnerTube response.
    private func backfillArtwork(_ track: MediaItem, page: InnerTubeClient.DetailPage) -> MediaItem {
        backfillMetadata(track, page: page)
    }

    /// Fill in missing artwork AND missing artist subtitle from the
    /// album/playlist page header. YT's album detail response often
    /// leaves the per-track `subtitle` (flexColumn[1]) empty for OST
    /// / single-song / various-artists releases — the web app derives
    /// the artist from the page header instead. Doing the same here
    /// keeps track rows, the mini-player, the lock screen, and the
    /// scrobbler payload all showing a real artist name instead of a
    /// blank line.
    private func backfillMetadata(_ track: MediaItem, page: InnerTubeClient.DetailPage) -> MediaItem {
        let needsArtwork = track.thumbnailURL == nil
        let needsSubtitle = track.subtitle.isEmpty
        guard needsArtwork || needsSubtitle else { return track }
        let filledSubtitle = needsSubtitle ? (albumArtistFallback(page: page) ?? track.subtitle) : track.subtitle
        let filledThumb = track.thumbnailURL ?? page.artworkURL ?? item.thumbnailURL
        return MediaItem(
            id: track.id,
            kind: track.kind,
            title: track.title,
            subtitle: filledSubtitle,
            thumbnailURL: filledThumb,
            albumId: track.albumId,
            artistId: track.artistId,
            setVideoId: track.setVideoId,
            durationSeconds: track.durationSeconds,
            year: track.year,
            // Album rows ALWAYS take this path (YT omits per-track
            // artwork on album pages), so forgetting a field here
            // erases it from every album row — playsText vanished
            // exactly this way. Carry everything through.
            playsText: track.playsText
        )
    }

    /// The best guess at an "album artist" for backfilling per-track
    /// subtitles. Prefers, in order:
    ///
    ///   1. The first `.artist`-kind run of the header's subtitleRuns
    ///      — that's YT's canonical album artist.
    ///   2. The first non-empty plain run from the header subtitle,
    ///      dropped if it's just the kind label ("Album") — some
    ///      responses ship a single un-annotated artist text run.
    ///   3. Any track in the same page that has a non-empty subtitle
    ///      of its own — for various-artists albums where the header
    ///      really has no artist to name, at least one track usually
    ///      does, and that's better than showing blanks everywhere.
    ///
    /// Returns nil when nothing usable is found. The caller then
    /// leaves the row's subtitle empty rather than substituting
    /// "Album" (which reads as data corruption to the user).
    private func albumArtistFallback(page: InnerTubeClient.DetailPage) -> String? {
        if let artistRun = page.subtitleRuns.first(where: { $0.kind == .artist && !$0.text.isEmpty }) {
            return artistRun.text
        }
        // First non-empty run that isn't a separator. YT uses " • "
        // and " · " between runs; those show up as their own runs.
        let separators: Set<String> = [" • ", " · ", " - "]
        if let firstText = page.subtitleRuns.first(where: {
            !$0.text.isEmpty && !separators.contains($0.text) && $0.text != kindLabel
        }) {
            return firstText.text
        }
        // Fall through to any track's own subtitle. Uses the first
        // non-empty entry, not a majority vote — an album where one
        // track happens to carry its artist is enough of a signal.
        if let hint = page.tracks.first(where: { !$0.subtitle.isEmpty })?.subtitle {
            return hint
        }
        return nil
    }
}

// MARK: - TrackRow

/// One row in an album / playlist tracklist. Extracted as its own
/// view so each row can carry independent hover state without
/// `@State` arrays in the parent. Affordances:
///
///   - Leading column: track number → play arrow on hover → equalizer
///     icon when this row is the currently-playing track.
///   - Title turns red and gains weight when this row is playing,
///     mirroring YT Music's tracklist.
///   - Row background lights up on hover.
///   - Right-click reveals the standard TrackContextMenu plus
///     "Remove from this playlist" when the parent page is
///     user-owned and we have a setVideoId.
///   - Duration on the right is always visible when present.
private struct TrackRow: View {
    @Environment(AppEnvironment.self) private var env
    let index: Int
    let item: MediaItem
    /// Local play count for this track (0 when never played in Riff).
    var playCount: Int = 0
    let isUserOwnedPlaylist: Bool
    /// "Play from here" — plays the tracklist from this row (albums /
    /// playlists / podcasts) or single-plays (artist top songs). The
    /// row owner builds the right action; the row just invokes it.
    var onPlay: (() async -> Void)? = nil
    /// Callback for "Remove from this playlist" — when nil the menu
    /// entry is hidden. Provided by DetailView with the right
    /// closure context (it needs `self.item` for the playlistId).
    let onRemoveFromPlaylist: ((String) async -> Void)?

    @State private var hovering = false
    /// Row-local optimistic like state for *non-current* rows. We
    /// intentionally don't fetch the canonical like status for every
    /// row in the tracklist — that would require an N-row /next fetch
    /// per detail page, which is way too expensive for an affordance
    /// that's only visible on hover. Instead the heart starts hollow
    /// and flips optimistically on tap, with the InnerTube
    /// like/removeLike fired in the background. For the currently-
    /// playing row we ignore this and drive directly from
    /// `env.player.liked`, which IS canonical (PlayerBridge syncs it
    /// against /next on every track change).
    /// Per-row optimistic override. nil = show the app-wide resting
    /// truth (env.isLiked); set on tap so the heart flips instantly.
    @State private var likedOverride: Bool? = nil

    private var isCurrent: Bool {
        env.player.currentTrack?.videoId == item.id
    }

    /// Effective like state for the heart icon. Current row trusts
    /// the PlayerBridge; other rows fall back to the row-local
    /// optimistic flag.
    private var isLiked: Bool {
        if isCurrent { return env.player.liked }
        return likedOverride ?? env.isLiked(item.id)
    }

    var body: some View {
        Button {
            Task {
                if let onPlay { await onPlay() }
                else { await env.player.play(item: item) }
            }
        } label: {
            HStack(spacing: 14) {
                leadingColumn
                AsyncImage(url: item.thumbnailURL?.upscaledArtwork(to: 120)) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.Fill.soft
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? Theme.red : Color.white)
                        .lineLimit(2)
                    // Clickable artist(s) + YT's GLOBAL play count in the
                    // byline ("Thaman S • 347M plays"), matching YT Music
                    // web's tracklist. The artist names stay individual
                    // links; the plays run is plain text.
                    if !item.subtitle.isEmpty || item.playsText != nil {
                        HStack(spacing: 0) {
                            if !item.subtitle.isEmpty {
                                ArtistLinkLine(
                                    subtitle: item.subtitle,
                                    primaryArtistId: item.artistId,
                                    fontSize: 12,
                                    baseOpacity: isCurrent ? 0.75 : 0.55
                                )
                            }
                            if let plays = item.playsText {
                                Text(item.subtitle.isEmpty ? plays : " • \(plays)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(isCurrent ? 0.75 : 0.55))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Spacer()
                // Local play-count badge — only when YT gave us no global
                // count for the row (playlists often omit it). Global
                // stats live in the byline above.
                if item.playsText == nil, playCount >= 1 {
                    Text("\(playCount)×")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Text.tertiary)
                        .help("\(playCount) play\(playCount == 1 ? "" : "s") in Riff")
                        .accessibilityLabel("\(playCount) plays")
                }
                // Hover-revealed action cluster: like + overflow menu.
                // Sits between the title block and the duration, fading
                // in on hover. Duration stays put — on narrow rows the
                // icons crowd it, which is acceptable since right-click
                // remains a full fallback.
                actionButtons
                    .opacity(hovering ? 1 : 0)
                if let secs = item.durationSeconds {
                    Text(formatRowDuration(secs))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(isCurrent ? 0.8 : 0.55))
                        .padding(.trailing, 8)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            // Hover highlight + a subtle persistent tint for the
            // currently-playing row so users can find it in long
            // tracklists without having to scroll-hunt.
            Group {
                if isCurrent {
                    Theme.red.opacity(0.08)
                } else if hovering {
                    Theme.Fill.soft
                } else {
                    Color.clear
                }
            }
        )
        .onHover { hovering = $0 }
        // Cross-fade the leading-column icon swap, the action button
        // cluster, and the row background as hover toggles. 150ms
        // easeOut feels responsive without dragging on quick mouseovers.
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            TrackContextMenu(item: item)
            if isUserOwnedPlaylist, let setId = item.setVideoId, let onRemove = onRemoveFromPlaylist {
                Divider()
                Button("Remove from this playlist") {
                    Task { await onRemove(setId) }
                }
            }
        }
    }

    /// Hover-revealed action cluster: like heart + overflow menu.
    /// Both icons live here so they share one opacity drive from the
    /// parent. The overflow menu re-exposes the same entries as the
    /// right-click context menu (TrackContextMenu + the
    /// playlist-owner Remove entry), giving users without a trackpad
    /// or a knowledge of right-click an equally-discoverable path.
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                if isCurrent {
                    Task { await env.player.toggleLike() }
                } else {
                    // Non-current row: optimistically flip the heart
                    // and fire the InnerTube call in the background.
                    // We don't roll back on error — the canonical
                    // state is one /next call away (the row will
                    // re-render with truth the moment it becomes the
                    // current track), and a stuck optimistic state
                    // for a non-playing row is benign.
                    let willLike = !(likedOverride ?? env.isLiked(item.id))
                    likedOverride = willLike
                    env.likedSongs.set(item.id, liked: willLike)
                    let videoId = item.id
                    Task {
                        do {
                            if willLike {
                                try await env.innerTube.like(videoId: videoId)
                            } else {
                                try await env.innerTube.removeLike(videoId: videoId)
                            }
                        } catch {
                            // Swallow: cheap affordance, not worth a
                            // banner. Next /next fetch will reconcile.
                        }
                    }
                }
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isLiked ? Theme.red : Theme.Text.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                TrackContextMenu(item: item)
                if isUserOwnedPlaylist, let setId = item.setVideoId, let onRemove = onRemoveFromPlaylist {
                    Divider()
                    Button("Remove from this playlist") {
                        Task { await onRemove(setId) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Text.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.trailing, 4)
    }

    /// Leading column. Width is fixed so titles align across rows
    /// even when the leading content swaps (number ↔ arrow ↔ icon).
    @ViewBuilder
    private var leadingColumn: some View {
        ZStack {
            // Track number — visible by default; hidden when the row
            // is hovered (replaced by play arrow) or currently
            // playing (replaced by equalizer icon).
            Text("\(index + 1)")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.Text.tertiary)
                .opacity(hovering || isCurrent ? 0 : 1)
            // Currently-playing equalizer indicator. YT Music has an
            // animated wave here; `speaker.wave.2.fill` is the
            // closest SF Symbol and matches the icon we already use
            // in the NowPlayingView queue rows.
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.red)
                .opacity(isCurrent ? 1 : 0)
            // Hover play arrow — only shows when hovering AND this
            // row isn't already the current track.
            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(hovering && !isCurrent ? 1 : 0)
        }
        .frame(width: 28, alignment: .center)
    }

    private func formatRowDuration(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// Loading placeholder for a detail page — a ghost of the header
/// (artwork + title/subtitle bars) and a handful of tracklist rows,
/// pulsing gently. Mirrors HomeSkeleton so a cold navigation reads as
/// "loading this page" rather than a bare centered spinner on black.
private struct DetailSkeleton: View {
    /// Mirror the REAL layout that will replace this ghost: two-column
    /// for albums/playlists (centered header card left, rows right),
    /// the classic hero row for artists/podcasts. A mismatched ghost
    /// makes the loaded page appear to "jump".
    var twoColumn: Bool = false
    @State private var pulse = false
    private var fill: Color { Color.white.opacity(pulse ? 0.10 : 0.06) }

    var body: some View {
        Group {
            if twoColumn {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 12).fill(fill).frame(width: 272, height: 272)
                        RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 140, height: 12)
                        RoundedRectangle(cornerRadius: 6).fill(fill).frame(width: 220, height: 26)
                        RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 110, height: 11)
                        HStack(spacing: 14) {
                            Circle().fill(fill).frame(width: 42, height: 42)
                            Circle().fill(fill).frame(width: 42, height: 42)
                            Circle().fill(fill).frame(width: 56, height: 56)
                            Circle().fill(fill).frame(width: 42, height: 42)
                            Circle().fill(fill).frame(width: 42, height: 42)
                        }
                        .padding(.top, 10)
                    }
                    .frame(width: 340)
                    .padding(.leading, 24)
                    VStack(spacing: 14) {
                        ForEach(0..<9, id: \.self) { _ in skeletonRow }
                    }
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(fill)
                            .frame(width: 220, height: 220)
                        VStack(alignment: .leading, spacing: 12) {
                            RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 80, height: 11)
                            RoundedRectangle(cornerRadius: 6).fill(fill).frame(width: 260, height: 30)
                            RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 180, height: 13)
                            RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 220, height: 11)
                        }
                        .padding(.top, 6)
                        Spacer()
                    }
                    .padding(.horizontal, 32)

                    VStack(spacing: 14) {
                        ForEach(0..<7, id: \.self) { _ in skeletonRow }
                    }
                    .padding(.horizontal, 32)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Theme.Radius.row).fill(fill).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 200, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 120, height: 10)
            }
            Spacer()
        }
    }
}
