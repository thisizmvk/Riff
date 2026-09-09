import SwiftUI

/// "Tap to act" tile. Songs play directly (the click-to-play wedge —
/// what Kaset can't do). Album / playlist / artist / podcast tiles push
/// a DetailView onto the active tab's NavigationStack so the user can
/// review the tracklist before committing to play. The hover overlay's
/// red play button always plays immediately (a one-tap shortcut for
/// people who want the YT-Music-iOS feel).
struct ThumbnailButton: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem
    /// When true, the context menu includes a Pin / Unpin row that
    /// floats the item to the top of the Library section grid. Only
    /// the Library tab passes `true` — Home / Search / Explore tiles
    /// don't get pinning since the concept is library-scoped.
    var showPinAction: Bool = false
    /// Optional caller-owned focus: lets a carousel move tile focus with
    /// arrow keys (see HomeSectionRow). The internal `isFocused` still
    /// drives the ring; both bindings update when the button takes focus.
    var externalFocus: FocusState<String?>.Binding? = nil
    var focusKey: String = ""

    @State private var hovering: Bool = false
    @FocusState private var isFocused: Bool

    /// Whether this tile represents the track/album currently
    /// playing. Drives the now-playing overlay + subtle border
    /// tint. Matched by videoId for songs; by albumId /
    /// playlistId for containers so an album tile lights up while
    /// any of its tracks plays.
    private var isNowPlaying: Bool {
        guard let cur = env.player.currentTrack else { return false }
        switch item.kind {
        case .song, .episode: return item.id == cur.videoId
        case .album:          return item.id == cur.albumId
        case .artist:         return item.id == cur.artistId
        default:              return false
        }
    }

    /// HCI: artists render as circles (universal "person" shape),
    /// everything else as rounded squares. Matches YT Music /
    /// Spotify / Apple Music convention and communicates the
    /// affordance ("this is a person, not a container") at a
    /// glance before you read the label.
    private var thumbShape: AnyShape {
        item.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        if item.kind == .song || item.kind == .episode {
            Button(action: { Task { await playDirect() } }) { content }
                .buttonStyle(.plain)
                .focused($isFocused)
                .modifier(ExternalFocusModifier(binding: externalFocus, key: focusKey))
                .onHover { hovering = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabelText)
                .accessibilityHint("Double tap to play.")
                .accessibilityAddTraits(isNowPlaying ? [.isButton, .isSelected] : .isButton)
                .contextMenu { TrackContextMenu(item: item, showPinAction: showPinAction) }
        } else {
            NavigationLink(value: item) { content }
                .buttonStyle(.plain)
                .focused($isFocused)
                .modifier(ExternalFocusModifier(binding: externalFocus, key: focusKey))
                .onHover { hovering = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabelText)
                .accessibilityHint(item.kind == .artist
                                   ? "Double tap to open artist page."
                                   : "Double tap to open.")
                .accessibilityAddTraits(isNowPlaying ? [.isButton, .isSelected] : .isButton)
                .contextMenu {
                    Button("Play") { Task { await playDirect() } }
                    if item.kind == .album || item.kind == .artist || item.kind == .podcast {
                        Button("Start radio") { Task { await playDirect() } }
                    }
                    // Queue the whole container (albums/playlists/
                    // podcasts). Not for artists (no fixed tracklist).
                    if item.kind != .artist {
                        Divider()
                        Button("Play next") { enqueue(next: true) }
                        Button("Add to queue") { enqueue(next: false) }
                    }
                    if showPinAction {
                        Divider()
                        Button(env.isPinned(item.id) ? "Unpin from top" : "Pin to top") {
                            env.togglePinned(id: item.id)
                        }
                    }
                }
        }
    }

    /// Compose "Song title, Artist" / "Album Name, Album by Artist"
    /// etc. so VoiceOver reads a coherent phrase per tile. Uses the
    /// display-title override if the user renamed a track locally.
    private var accessibilityLabelText: String {
        let title = env.displayTitle(for: item)
        let sub = env.displaySubtitle(for: item)
        let kindWord: String
        switch item.kind {
        case .song:     kindWord = "song"
        case .episode:  kindWord = "episode"
        case .album:    kindWord = "album"
        case .playlist: kindWord = "playlist"
        case .artist:   kindWord = "artist"
        case .podcast:  kindWord = "podcast"
        }
        if sub.isEmpty {
            return "\(title), \(kindWord)"
        }
        return "\(title), \(kindWord). \(sub)"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        // Loading placeholder — subtle gradient so
                        // the tile reads as "loading" rather than
                        // "broken" without a heavyweight shimmer
                        // animation. Same on both light and dark
                        // by design (all Riff tiles sit on black).
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.03),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    default:
                        // Failure — draw the kind's SF Symbol so
                        // even a permanently-broken URL communicates
                        // *what* the tile represents (album vs
                        // artist vs playlist). Better than a blank
                        // black square.
                        ZStack {
                            Color.white.opacity(0.06)
                            Image(systemName: placeholderSymbol)
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }
                }
                .frame(width: 180, height: 180)
                .clipShape(thumbShape)
                // Now-playing tint: subtle red border + soft glow
                // on the tile whose track is currently playing.
                // Doubles as the keyboard-focus indicator when
                // `isFocused` is true so both states get one
                // visible affordance without stacking two rings.
                .overlay {
                    // AnyShape erases to Shape (not InsettableShape),
                    // so we use `stroke` instead of `strokeBorder`.
                    // The border centers on the clip edge — for a
                    // 2-3pt line the visual difference against
                    // strokeBorder is imperceptible.
                    if isNowPlaying || isFocused {
                        thumbShape
                            .stroke(Theme.red, lineWidth: isFocused ? 3 : 2)
                    }
                }
                // Directional hover-lift shadow (offset down, not
                // uniform) reads more physical than a symmetric
                // glow. Respects reduce-motion by skipping the
                // animated scale but still deepening the shadow —
                // shadow depth alone communicates hover without
                // moving the tile.
                .shadow(
                    color: .black.opacity(hovering ? 0.5 : 0.3),
                    radius: hovering ? 14 : 6,
                    y: hovering ? 8 : 3
                )
                // Explicit focus ring for keyboard nav — SwiftUI
                // draws the standard system ring but on custom
                // buttons in a dark theme it's often invisible.
                // Ours is Theme.red and 3pt so it reads clearly.

                if hovering {
                    Button {
                        Task { await playDirect() }
                    } label: {
                        ZStack {
                            Circle().fill(Theme.red)
                                .frame(width: 48, height: 48)
                                .shadow(color: Theme.red.opacity(0.5), radius: 10)
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                    .accessibilityHidden(true) // parent tile already speaks
                }
            }
            .overlay(alignment: .topLeading) {
                // Now-playing badge — an equalizer glyph in the
                // top-left when this tile is what's playing. Rests
                // above the artwork so it's readable regardless of
                // the cover's dominant colour.
                if isNowPlaying {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .bold))
                        Text("Now playing")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.red)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Quick-action cluster (top-right): "Play next" and
                // "Add to queue". Shown for every queueable kind —
                // songs/episodes enqueue directly; albums/playlists/
                // podcasts resolve their tracklist and enqueue the
                // whole block (in order), matching Spotify/Apple
                // Music behavior.
                if hovering && item.kind != .artist {
                    HStack(spacing: 6) {
                        quickActionButton(
                            systemImage: "text.line.first.and.arrowtriangle.forward",
                            help: "Play next"
                        ) {
                            enqueue(next: true)
                        }
                        quickActionButton(
                            systemImage: "text.badge.plus",
                            help: "Add to queue"
                        ) {
                            enqueue(next: false)
                        }
                    }
                    .padding(10)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(env.displayTitle(for: item))
                    // Title: red when this tile is the now-playing
                    // one so the semantic link between the tile and
                    // the mini-player is instant.
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isNowPlaying ? Theme.red : .white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                if env.hasMetadataOverride(item) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .help("Metadata edited locally")
                        .accessibilityLabel("Metadata edited")
                }
            }

            Text(env.displaySubtitle(for: item))
                .font(.system(size: 12))
                // Bumped from .75 → .85: on pure black backgrounds
                // 75% white on 14pt SF Pro measures ~4.2:1 contrast
                // (below WCAG AA 4.5:1 for normal text). 85% clears
                // 5.5:1 while still reading as secondary.
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 180, alignment: .leading)
        // Hover lift — skip the scale entirely when reduce-motion is
        // on. Non-animated users still get the shadow depth change
        // above as a hover signal.
        .scaleEffect(reduceMotion ? 1.0 : (hovering ? 1.02 : 1.0))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        // Truncated titles / subtitles still need to be readable. The
        // system tooltip surfaces the full text on hover so long album
        // or artist names aren't lost behind an ellipsis.
        .help(tileTooltip)
    }

    /// SF Symbol that stands in for a tile whose artwork failed to
    /// load. Chosen per-kind so a broken album tile still reads as
    /// "album" (not just "missing image"). Communicates the
    /// affordance before the pixels do — HIG-adjacent behavior.
    private var placeholderSymbol: String {
        switch item.kind {
        case .song, .episode: return "music.note"
        case .album:          return "square.stack"
        case .playlist:       return "music.note.list"
        case .artist:         return "person.crop.circle"
        case .podcast:        return "mic"
        }
    }

    private var tileTooltip: String {
        let title = env.displayTitle(for: item)
        let subtitle = env.displaySubtitle(for: item)
        if subtitle.isEmpty { return title }
        return "\(title) — \(subtitle)"
    }

    private func quickActionButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Queue this tile — song directly, album/playlist by resolving
    /// its tracklist. `next` chooses head-of-queue vs end. Toasts the
    /// outcome (with the track count for containers so the user knows
    /// how much landed).
    private func enqueue(next: Bool) {
        let title = env.displayTitle(for: item)
        if item.kind == .song || item.kind == .episode {
            if next {
                env.player.playNext(item: item)
                env.showToast("Playing next: \(title)")
            } else {
                env.player.addToQueueEnd(item: item)
                env.showToast("Added to queue: \(title)")
            }
            return
        }
        // Container — resolve tracks asynchronously, then toast the count.
        Task {
            let count = next
                ? await env.player.playNextResolved(item)
                : await env.player.addToQueueEndResolved(item)
            let verb = next ? "Playing next" : "Added to queue"
            if count > 0 {
                env.showToast("\(verb): \(title) (\(count) track\(count == 1 ? "" : "s"))")
            } else {
                env.showToast("Couldn't load \(title)'s tracks.")
            }
        }
    }

    private func playDirect() async {
        switch item.kind {
        case .song, .episode: await env.player.play(item: item)
        case .album:          await env.player.playAlbum(id: item.id)
        case .playlist:       await env.player.playPlaylist(id: item.id)
        case .artist:         await env.player.playArtistRadio(id: item.id)
        case .podcast:        await env.player.playPodcast(id: item.id)
        }
    }
}


/// Applies a caller-owned focus binding when one was provided.
private struct ExternalFocusModifier: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let key: String
    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}
