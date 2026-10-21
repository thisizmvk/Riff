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
        // FIXED, SQUARE tile. 300×300 keeps square album art uncropped;
        // the title block overlays the bottom over its gradient scrim. The
        // hosting panel (MiniPlayerPanelController) locks min==max so the
        // resize handles are inert.
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

/// A non-activating floating panel for the Mini Player. A regular,
/// Dock-based app cannot show a plain `NSWindow` over ANOTHER app's native
/// full-screen Space at any window level — but an `NSPanel` with
/// `.nonactivatingPanel`, pinned at `.screenSaver` level with
/// `.canJoinAllSpaces`, floats over everything (other apps' normal windows
/// AND their full-screen Spaces) and never steals focus when clicked.
final class FloatingPanel: NSPanel {
    // Controls must be clickable, but the panel must never become the
    // app's main window — it's an accessory overlay.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the single Mini Player panel: builds it on demand, keeps it above
/// everything on the active display, and toggles it from the Window menu /
/// ⌥⌘M / command palette. Replaces the old SwiftUI `Window` scene, whose
/// `NSWindow` could not be coaxed over other apps' full-screen.
@MainActor
final class MiniPlayerPanelController {
    static let shared = MiniPlayerPanelController()
    private init() {}

    private var panel: FloatingPanel?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private static let tileSize = NSSize(width: 300, height: 300)

    /// Show when hidden, hide when visible (⌥⌘M behaves as a toggle).
    func toggle(environment: AppEnvironment) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show(environment: environment)
        }
    }

    func show(environment: AppEnvironment) {
        let panel = panel ?? makePanel(environment: environment)
        self.panel = panel
        applyLevel()
        moveToActiveScreen()
        panel.orderFrontRegardless()
    }

    private func makePanel(environment: AppEnvironment) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.tileSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .black
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let host = NSHostingView(rootView: FloatingMiniPlayerView().environment(environment))
        host.frame = NSRect(origin: .zero, size: Self.tileSize)
        panel.contentView = host
        panel.setContentSize(Self.tileSize)
        panel.minSize = Self.tileSize
        panel.maxSize = Self.tileSize
        panel.center()
        installObservers()
        return panel
    }

    /// Re-float + follow when the app or the active Space/app changes —
    /// the moments the "current screen" moves or a background overlay can
    /// get buried.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleActivation() }
            })
        }
        let wsNC = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(wsNC.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleActivation() }
            })
        }
    }

    private func handleActivation() {
        guard let panel, panel.isVisible else { return }
        applyLevel()
        moveToActiveScreen()
    }

    private func applyLevel() {
        guard let panel else { return }
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
    }

    /// Move the tile onto the currently-active display (the screen under
    /// the cursor), preserving its relative position. No-op when already
    /// there, so dragging it around one display is never disturbed.
    private func moveToActiveScreen() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let target else { return }
        let current = panel.screen ?? NSScreen.main
        guard let current, target !== current else { return }
        let src = current.visibleFrame
        let dst = target.visibleFrame
        let fx = src.width > 0 ? (panel.frame.minX - src.minX) / src.width : 0.5
        let fy = src.height > 0 ? (panel.frame.minY - src.minY) / src.height : 0.5
        var origin = NSPoint(x: dst.minX + fx * dst.width, y: dst.minY + fy * dst.height)
        origin.x = min(max(origin.x, dst.minX), dst.maxX - panel.frame.width)
        origin.y = min(max(origin.y, dst.minY), dst.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
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
