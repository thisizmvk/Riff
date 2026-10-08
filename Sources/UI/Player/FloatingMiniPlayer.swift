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
        // FIXED, SQUARE tile. A min/ideal/max range let the window resize
        // itself run-to-run ("size is dynamic"); the user wants one stable
        // tile. 300×300 keeps square album art uncropped; the title block
        // overlays the bottom over its gradient scrim. WindowFloater locks
        // the NSWindow min==max so the resize handles are inert too.
        .frame(width: 300, height: 300)
        // Artwork as a BACKGROUND, never a layout sibling. As a ZStack
        // child, the `.fill` image proposed its natural pixel size and
        // the resizable window opened at artwork size — "a full screen
        // of artwork" over the full-screen main window. A background
        // cannot size the foreground; `.clipped()` keeps the overflow
        // inside the tile. Falls back to a dark surface while loading so
        // the controls always have contrast.
        .background {
            // Request a large artwork variant — the tile fills ~300pt
            // (600px retina) and the track's own thumbnailURL is often a
            // small (120px) image that looks soft blown up.
            AsyncImage(url: track?.thumbnailURL?.upscaledArtwork(to: 600)) { phase in
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
        private var observers: [NSObjectProtocol] = []
        private var workspaceObservers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
            // The level did not stick before: SwiftUI (and AppKit on app
            // (de)activation) reset a Window scene's level back to normal,
            // so the tile dropped behind other apps. Re-assert .floating
            // whenever activation changes or this window becomes key/main.
            guard observers.isEmpty, window != nil else { return }
            let nc = NotificationCenter.default
            let names: [Notification.Name] = [
                NSApplication.didBecomeActiveNotification,
                NSApplication.didResignActiveNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
            ]
            for name in names {
                observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reassertLevel() }
                })
            }
            // Re-float when ANY other app becomes active — the precise
            // moment a background app's floating window can get buried if
            // its level was reset. Riff's own didResignActive doesn't fire
            // for every such switch, so watch the workspace too.
            let wsNC = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(wsNC.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassertLevel() }
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            let wsNC = NSWorkspace.shared.notificationCenter
            workspaceObservers.forEach(wsNC.removeObserver)
        }

        /// Cheap, idempotent — only the properties AppKit/SwiftUI can
        /// reset out from under us.
        private func reassertLevel() {
            guard let window else { return }
            if window.level != .floating { window.level = .floating }
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Re-raise to the top of the floating band without activating
            // Riff, so switching to another app can't leave the tile
            // behind that app's windows.
            window.orderFrontRegardless()
        }

        func configureWindow() {
            guard let window else { return }
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            // Lock the size: min == max == the fixed content size, so the
            // window can't be dragged to a new size or reopen at another.
            let size = NSSize(width: 300, height: 300)
            window.minSize = size
            window.maxSize = size
            window.setContentSize(size)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}

extension URL {
    /// Request a larger square variant of a YouTube / Google artwork URL.
    /// These hosts carry a size segment after the last `=`
    /// (e.g. `…=w120-h120-l90-rj`); rewriting it to `size` yields a crisp
    /// image when the artwork is shown large (the mini-player tile, the
    /// now-playing hero). URLs without that segment, or from other hosts,
    /// are returned unchanged.
    func upscaledArtwork(to size: Int) -> URL {
        let s = absoluteString
        guard s.contains("googleusercontent.com")
                || s.contains("ggpht.com")
                || s.contains("ytimg.com") else { return self }
        guard let eq = s.lastIndex(of: "="), !s[s.index(after: eq)...].contains("/") else { return self }
        let base = String(s[..<eq])
        return URL(string: "\(base)=w\(size)-h\(size)-l90-rj") ?? self
    }
}
