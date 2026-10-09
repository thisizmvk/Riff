import SwiftUI

// MARK: - Shared subtitle formatting

/// Map a MediaItem.Kind to the human-readable prefix shown in search
/// subtitles ("Song", "Album", "Artist", …). Used by both the list
/// row and the top-result hero card.
fileprivate func kindLabelString(_ kind: MediaItem.Kind) -> String {
    switch kind {
    case .song:     return "Song"
    case .album:    return "Album"
    case .playlist: return "Playlist"
    case .artist:   return "Artist"
    case .podcast:  return "Podcast"
    case .episode:  return "Episode"
    }
}

/// Compose "Kind • Artist • 3:42" / "Album • Artist • 2024" from the
/// parsed subtitle plus the new duration/year fields. Skips the kind
/// prefix when the subtitle already starts with it, skips duration
/// when the subtitle already contains a colon-separated time token,
/// and skips year when the subtitle already contains that 4-digit
/// year — keeps the line tidy when YT already gave us a fully-formed
/// subtitle and we don't want to append duplicates.
fileprivate func formatSearchSubtitle(_ item: MediaItem, kindLabel: String) -> String {
    let trimmed = item.subtitle.trimmingCharacters(in: .whitespaces)
    var line = trimmed
    if line.isEmpty {
        line = kindLabel
    } else if !line.lowercased().hasPrefix(kindLabel.lowercased()) {
        line = "\(kindLabel) • \(line)"
    }
    if let secs = item.durationSeconds, !line.contains(":") {
        line += " • " + formatDurationLabel(secs)
    }
    if let y = item.year, !line.contains(String(y)) {
        line += " • \(y)"
    }
    return line
}

/// Compact mm:ss / h:mm:ss formatter used in search rows + tracklists.
fileprivate func formatDurationLabel(_ totalSeconds: Int) -> String {
    let h = totalSeconds / 3600
    let m = (totalSeconds % 3600) / 60
    let s = totalSeconds % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

/// One row in the search results list. Mirrors YT Music's compact list
/// layout: small square thumbnail, bold title, subtitle prefixed with
/// the kind ("Song • Artist • plays" / "Album • Artist • year").
///
/// Tap behaviour matches the rest of the app:
///   - songs / episodes play immediately
///   - albums / playlists / artists / podcasts push a DetailView
///
/// Right-click surfaces the standard `TrackContextMenu` (for songs) or
/// a play / start-radio menu (for non-songs).
struct SearchResultRow: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem
    /// Optional focus binding from the parent list. When non-nil,
    /// the row registers itself under `item.id` so ↑/↓ / ↵ / ⌘↵
    /// keyboard handlers in SearchView can drive it.
    var focusBinding: FocusState<String?>.Binding? = nil

    @State private var hovering = false
    @State private var isFocused = false

    /// Local play count — tracks only (containers don't accumulate one).
    private var playCount: Int {
        (item.kind == .song || item.kind == .episode) ? env.localPlayCount(item.id) : 0
    }

    var body: some View {
        Group {
            if item.kind == .song || item.kind == .episode {
                Button { Task { await play() } } label: { rowContent }
                    .buttonStyle(.plain)
                    .contextMenu { TrackContextMenu(item: item) }
            } else {
                NavigationLink(value: item) { rowContent }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play") { Task { await play() } }
                        if item.kind != .episode {
                            Button("Start radio") { Task { await play() } }
                        }
                        // Albums / playlists / podcasts queue their whole
                        // tracklist, resolved from the container id via
                        // playNextResolved / addToQueueEndResolved — the
                        // same path the tile hover menu uses. Search rows
                        // only offered Play / Radio, so an album found via
                        // search had no way to be queued.
                        SearchContainerQueueActions(item: item)
                    }
            }
        }
        .onHover { hovering = $0 }
        .modifier(OptionalFocusModifier(binding: focusBinding, itemId: item.id, isFocused: $isFocused))
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            ZStack {
                AsyncImage(url: item.thumbnailURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.Fill.soft
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(thumbnailShape)
                // Hover overlay: dims the thumbnail and surfaces a play
                // glyph so the user sees the row is actionable. Songs
                // get a play arrow; albums/artists get a chevron since
                // the primary action is "open detail page".
                if hovering {
                    Rectangle().fill(.black.opacity(0.45))
                        .clipShape(thumbnailShape)
                        .frame(width: 48, height: 48)
                    Image(systemName: hoverIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(env.displayTitle(for: item))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if env.hasMetadataOverride(item) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Text.secondary)
                            .help("Metadata edited locally")
                            .accessibilityLabel("Metadata edited")
                    }
                }
                // Songs/episodes: clickable artist(s). Containers keep a
                // plain subtitle (their subtitle isn't an artist credit).
                if item.kind == .song || item.kind == .episode {
                    ArtistLinkLine(
                        subtitle: formattedSubtitle,
                        primaryArtistId: item.artistId,
                        fontSize: 12,
                        baseOpacity: 0.7
                    )
                } else {
                    Text(formattedSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            // Local play-count badge for tracks played in Riff.
            if playCount >= 1 {
                Text("\(playCount)×")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Text.tertiary)
                    .help("\(playCount) play\(playCount == 1 ? "" : "s") in Riff")
                    .accessibilityLabel("\(playCount) plays")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
        .contentShape(Rectangle())
    }

    private var rowBackground: some View {
        Group {
            if isFocused {
                Theme.red.opacity(0.18)
            } else if hovering {
                Theme.Fill.faint
            } else {
                Color.clear
            }
        }
    }

    /// Artists get a circular thumbnail; everything else stays squared
    /// with rounded corners. Mirrors YT Music's row visuals.
    private var thumbnailShape: AnyShape {
        if item.kind == .artist {
            return AnyShape(Circle())
        }
        return AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb))
    }

    private var hoverIcon: String {
        switch item.kind {
        case .song, .episode: return "play.fill"
        default:              return "chevron.right"
        }
    }

    /// "Kind • subtitle" for visual parity with YT Music search rows
    /// ("Album • Ravindra Jain • 2021"). When the parsed subtitle
    /// already starts with the kind label we don't double up.
    /// Appends duration ("• 3:42") for songs/episodes that carry one,
    /// and the year for items that have it without already being in
    /// the subtitle text.
    ///
    /// D2: route through `env.displaySubtitle(for:)` so an artist /
    /// album override on a song row replaces those segments before
    /// the kind / duration / year decoration gets layered on top.
    private var formattedSubtitle: String {
        var overridden = item
        let display = env.displaySubtitle(for: item)
        if display != item.subtitle {
            overridden = MediaItem(
                id: item.id,
                kind: item.kind,
                title: item.title,
                subtitle: display,
                thumbnailURL: item.thumbnailURL,
                albumId: item.albumId,
                artistId: item.artistId,
                setVideoId: item.setVideoId,
                durationSeconds: item.durationSeconds,
                year: item.year
            )
        }
        return formatSearchSubtitle(overridden, kindLabel: kindLabel)
    }

    private var kindLabel: String { kindLabelString(item.kind) }

    private func play() async {
        switch item.kind {
        case .song, .episode: await env.player.play(item: item)
        case .album:          await env.player.playAlbum(id: item.id)
        case .playlist:       await env.player.playPlaylist(id: item.id)
        case .artist:         await env.player.playArtistRadio(id: item.id)
        case .podcast:        await env.player.playPodcast(id: item.id)
        }
    }
}

/// Wide hero card for the first search result — mirrors YT Music's
/// "Top result" panel: large square thumbnail, big bold title, subtitle,
/// prominent Play pill, and an overflow ⋮ menu on the right.
struct TopResultCard: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem

    @State private var hovering = false

    var body: some View {
        // Tappable surface — for non-songs the whole card pushes the
        // detail page (mirrors YT Music's "click a non-Top-result item
        // to open it"); for songs the card-level tap plays.
        Group {
            if item.kind == .song || item.kind == .episode {
                Button { Task { await play() } } label: { cardContent }
                    .buttonStyle(.plain)
                    .contextMenu { TrackContextMenu(item: item) }
            } else {
                NavigationLink(value: item) { cardContent }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play") { Task { await play() } }
                        if item.kind != .artist {
                            Button("Start radio") { Task { await play() } }
                        }
                        // Same container queue actions as the list rows —
                        // the top-result card is often an album/playlist
                        // and offered no way to queue it.
                        SearchContainerQueueActions(item: item)
                    }
            }
        }
        .onHover { hovering = $0 }
    }

    private var cardContent: some View {
        HStack(spacing: 16) {
            AsyncImage(url: item.thumbnailURL) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.Fill.soft
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(item.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.card)))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(env.displayTitle(for: item))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if env.hasMetadataOverride(item) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Text.secondary)
                            .help("Metadata edited locally")
                            .accessibilityLabel("Metadata edited")
                    }
                }
                Text(formattedSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    // Play pill — primary action, always visible. Stops
                    // the card-level tap so clicking the pill plays
                    // even on non-song top-results (rather than pushing
                    // detail).
                    Button {
                        Task { await play() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Play")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.white)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(16)
        .background(hovering ? Theme.Fill.medium : Theme.Fill.faint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .contentShape(Rectangle())
    }

    private var formattedSubtitle: String {
        var overridden = item
        let display = env.displaySubtitle(for: item)
        if display != item.subtitle {
            overridden = MediaItem(
                id: item.id,
                kind: item.kind,
                title: item.title,
                subtitle: display,
                thumbnailURL: item.thumbnailURL,
                albumId: item.albumId,
                artistId: item.artistId,
                setVideoId: item.setVideoId,
                durationSeconds: item.durationSeconds,
                year: item.year
            )
        }
        return formatSearchSubtitle(overridden, kindLabel: kindLabel)
    }

    private var kindLabel: String { kindLabelString(item.kind) }

    private func play() async {
        switch item.kind {
        case .song, .episode: await env.player.play(item: item)
        case .album:          await env.player.playAlbum(id: item.id)
        case .playlist:       await env.player.playPlaylist(id: item.id)
        case .artist:         await env.player.playArtistRadio(id: item.id)
        case .podcast:        await env.player.playPodcast(id: item.id)
        }
    }
}

/// Wires an optional `FocusState<String?>.Binding` onto a row and
/// mirrors its focused state into a local `Bool` so the row can
/// paint its focused-highlight without every caller having to
/// duplicate the boolean bookkeeping. When `binding` is nil (row
/// used outside a keyboard-navigable container) it's a zero-cost
/// no-op.
struct OptionalFocusModifier: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let itemId: String
    @Binding var isFocused: Bool

    func body(content: Content) -> some View {
        if let binding {
            content
                .focused(binding, equals: itemId)
                .onChange(of: binding.wrappedValue) { _, new in
                    isFocused = new == itemId
                }
        } else {
            content
        }
    }
}

/// Play-next / add-to-queue menu entries for a container (album /
/// playlist / podcast) search result. Resolves the whole tracklist via
/// `playNextResolved` / `addToQueueEndResolved`. Empty for songs,
/// episodes and artists so the one definition serves every search row
/// (list rows AND the top-result card) and can never drift apart again.
private struct SearchContainerQueueActions: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem

    var body: some View {
        if item.kind == .album || item.kind == .playlist || item.kind == .podcast {
            Divider()
            Button("Play next") {
                Task {
                    let n = await env.player.playNextResolved(item)
                    env.showToast(n > 0 ? "Added \(n) to play next" : "Nothing to queue")
                }
            }
            Button("Add to queue") {
                Task {
                    let n = await env.player.addToQueueEndResolved(item)
                    env.showToast(n > 0 ? "Added \(n) to queue" : "Nothing to queue")
                }
            }
        }
    }
}
