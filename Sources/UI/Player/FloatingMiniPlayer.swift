import SwiftUI
import AppKit

/// Compact always-on-top playback tile. Lives in its own NSWindow so the
/// user can keep audio controls visible while another app has focus.
/// Toggled via the Window menu (Riff → Window → Mini Player) or ⌥⌘M.
///
/// Layout: a square-ish artwork dominates the tile, with title and subtitle
/// pinned to the bottom over a gradient scrim. Transport controls (prev /
/// play / next) are hover-reveal — they fade in over a darkened artwork
/// scrim when the pointer is inside the window, and fade back out when it
/// leaves. This keeps the resting state a clean, glanceable "what's playing"
/// tile while still putting controls one mouse-move away.
///
/// The window itself is resizable (see RiffApp's `Window` scene with a
/// `defaultSize` of 320×180 and `windowResizability(.contentMinSize)`),
/// pinned at `.floating` window level, joins all spaces, and re-renders the
/// same SwiftUI tree at any size — the artwork uses
/// `aspectRatio(contentMode: .fill)` and the controls scale with the tile.
struct FloatingMiniPlayerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isHovering: Bool = false

    var body: some View {
        let track = env.player.currentTrack
        ZStack(alignment: .bottom) {
            // Bottom gradient + title block — always visible so the user
            // can read what's playing without hovering.
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Text(track?.subtitle ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.top, 28)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65), .black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Hover-reveal scrim + transport row. Fades in over the
            // artwork; allowsHitTesting is gated on isHovering so the
            // resting tile doesn't intercept window-drag gestures.
            ZStack {
                Color.black.opacity(0.45)
                VStack(spacing: 6) {
                    Spacer()
                    HStack(spacing: 18) {
                        button(systemName: "backward.fill", size: 16, help: "Previous") {
                            Task { await env.player.previous() }
                        }
                        button(
                            systemName: env.player.isPlaying ? "pause.fill" : "play.fill",
                            size: 24,
                            help: env.player.isPlaying ? "Pause" : "Play"
                        ) {
                            Task { await env.player.togglePlay() }
                        }
                        button(systemName: "forward.fill", size: 16, help: "Next") {
                            Task { await env.player.next() }
                        }
                    }
                    // Tune-chip strip. Only rendered when YT gave
                    // us chips for the current watch context; blank
                    // in solo-song mode so the tile stays clean.
                    if !env.player.availableChips.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(env.player.availableChips) { chip in
                                    miniChip(chip)
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                        .frame(maxHeight: 20)
                    }
                    Spacer().frame(height: 42) // sit above the title block
                }
            }
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .allowsHitTesting(isHovering)

            // Progress strip pinned to the very top of the tile.
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.Fill.soft)
                        Rectangle()
                            .fill(Theme.red)
                            .frame(width: geo.size.width * env.player.progress)
                    }
                    // Click to seek, same affordance as the main-window
                    // bottom bar.
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let fraction = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                                Task { await env.player.seek(to: fraction) }
                            }
                    )
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .frame(height: 5)
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 480,
               minHeight: 140, idealHeight: 180, maxHeight: 270)
        // Artwork as a BACKGROUND, never a layout sibling. As a ZStack
        // child, the `.fill` image proposed its natural pixel size and
        // the resizable window opened at artwork size — "a full screen
        // of artwork" over the full-screen main window. A background
        // cannot size the foreground; `.clipped()` keeps the overflow
        // inside the tile. Falls back to a dark surface while loading so
        // the controls always have contrast.
        .background {
            AsyncImage(url: track?.thumbnailURL) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.92)
                }
            }
            .clipped()
        }
        .background(Theme.Bg.base)
        .preferredColorScheme(.dark)
        .onHover { hovering in
            isHovering = hovering
        }
        .contentShape(Rectangle())
        .contextMenu { nowPlayingMenuItems }
        .background(WindowFloater())
    }

    @ViewBuilder
    private var nowPlayingMenuItems: some View {
        if let track = env.player.currentTrack {
            let item = MediaItem(
                id: track.videoId,
                kind: .song,
                title: track.title,
                subtitle: track.subtitle,
                thumbnailURL: track.thumbnailURL,
                albumId: track.albumId,
                artistId: track.artistId
            )
            TrackContextMenu(item: item, omitPrimaryPlay: true)
        }
    }

    private func button(
        systemName: String,
        size: CGFloat,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func miniChip(_ chip: InnerTubeClient.QueueChip) -> some View {
        let selected = chip.id == env.player.selectedChipId
        return Button {
            env.player.applyChip(chip)
        } label: {
            Text(chip.label)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selected ? Theme.red : Theme.Fill.strong)
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Tune queue: \(chip.label)")
    }
}

/// Reaches into the hosting NSWindow to set window level + appearance to
/// match a floating utility panel: always-on-top (above other apps'
/// windows too), joins all spaces, hidden from Mission Control. Done via
/// NSViewRepresentable because SwiftUI doesn't expose `.windowLevel`.
///
/// Applied from `viewDidMoveToWindow`, not a one-shot `DispatchQueue.main
/// .async` after `makeNSView`: the SwiftUI `Window` scene attaches the
/// view to its NSWindow later than that tick, so the old guard returned
/// early and the tile stayed a normal-level window — behind every other
/// app ("mini player isn't hovering over Comet / Claude"). Re-applied on
/// each update so nothing SwiftUI resets can stick.
private struct WindowFloater: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FloaterView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FloaterView)?.configureWindow()
    }

    final class FloaterView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }
        func configureWindow() {
            guard let window else { return }
            if window.level != .floating { window.level = .floating }
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            // A tile, not a document: bounded size, no zoom-to-screen,
            // and no restored oversize frame from a previous session.
            window.isRestorable = false
            window.minSize = NSSize(width: 280, height: 140)
            window.maxSize = NSSize(width: 480, height: 270)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            if window.frame.width > 480 || window.frame.height > 270 {
                window.setContentSize(NSSize(width: 320, height: 180))
            }
        }
    }
}
