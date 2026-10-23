import AppKit
import SwiftUI

/// Full-screen player. Layout matches YT Music desktop:
///   - hero blurred backdrop (whole window)
///   - left side: artwork + title + scrubber + transport
///   - right side: tabbed pane Up Next / Lyrics / Related
///   - top bar: prominent close button (chevron-down) + "Now Playing"
///   - ESC dismisses
struct NowPlayingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var bottomTab: BottomTab = .upNext
    @State private var queueMode: QueueMode = .related
    /// Anchor for extrapolating `env.player.elapsed` between polls.
    /// The bridge polls JS at ~1Hz; without these anchors the per-word
    /// karaoke fill would tick in 1s steps. Recorded each time the
    /// player ticks; while playing, the active-line view linearly
    /// extrapolates `(now - anchorAt) + anchorElapsed`.
    @State private var anchorElapsed: Double = 0
    @State private var anchorAt: Date = Date()
    /// Cached translation for the current track + language. Reset
    /// whenever either changes. Held in view state (not env) so the
    /// view re-renders when the translation lands; the translator's
    /// own cache is the persistence layer across track switches.
    @State private var translation: LyricsTranslator.Translation? = nil
    @State private var translationLoading: Bool = false
    @State private var translationError: String? = nil
    /// Token identifying the newest translation request. Bumped on
    /// every new request and on track/language change so a superseded
    /// request's completion (success OR failure) can never overwrite
    /// state that now belongs to a newer request.
    @State private var translationRequestID = UUID()

    /// X-Ray cards for the current track (B4). Held in view state so
    /// the view re-renders when the bundle lands; the service's own
    /// cache is the persistence layer across track switches.
    @State private var xrayCards: XRayCardsService.Bundle? = nil
    @State private var xrayLoading: Bool = false
    @State private var xrayError: String? = nil
    /// Same supersession token as `translationRequestID`, for X-Ray.
    @State private var xrayRequestID = UUID()

    /// The videoId currently being dragged-over inside the Up Next
    /// list. Drives the 2pt red insertion indicator above the target
    /// row. Nil when no drag is in flight.
    @State private var dragHoverTargetId: String? = nil

    /// Adaptive backdrop accent color extracted from the current
    /// track's artwork (Apple Music-style). Nil until extracted;
    /// the backdrop falls back to the plain blurred art + black.
    @State private var backdropColor: Color? = nil

    /// Fullscreen lyrics mode — hides the art + side pane and fills
    /// the player with large, centered (synced) lyrics over the
    /// adaptive backdrop. Apple Music's dedicated lyrics view.
    @State private var lyricsFullscreen: Bool = false
    /// Volume level to restore when the speaker icon un-mutes.
    @State private var preMuteVolume: Double = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum BottomTab: String, CaseIterable, Identifiable {
        case upNext = "Up Next"
        case lyrics = "Lyrics"
        case related = "Related"
        case context = "Context"
        var id: String { rawValue }
    }

    /// Mirrors YT Music's "Tune" popover, simplified to the dimensions we
    /// can actually source data for. The full YT-Music feature uses a
    /// continuous Familiar↔Discover slider + mood chips, both routed
    /// through protobuf-encoded `/next` params tokens that aren't
    /// publicly documented. Until those tokens are reverse-engineered,
    /// these three modes give the user something real:
    ///
    ///   - Related: the default radio queue from `/next`.
    ///   - Discover: the related-songs endpoint (broader artists).
    ///   - Familiar: radio queue filtered to artists already in playedHistory.
    enum QueueMode: String, CaseIterable, Identifiable {
        case related = "Related"
        case discover = "Discover"
        case familiar = "Familiar"
        var id: String { rawValue }
    }

    var body: some View {
        let track = env.player.currentTrack
        // Foreground content only — backdrops are .background modifiers
        // outside this VStack so they can ignoresSafeArea independently
        // without inflating the foreground's frame.
        VStack(spacing: 0) {
            topBar
            if lyricsFullscreen {
                fullscreenLyricsView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    leftPlayer
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    sidePane
                        .frame(width: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: lyricsFullscreen)
        // Fresh audio-format reading on open (the page also reports a
        // few seconds into every track).
        .task { await env.player.requestAudioFormat() }
        .background {
            // Backdrops as a background stack — entirely behind the
            // foreground; their sizes have no effect on the foreground's
            // layout. ZStack here is fine because it has no influence on
            // the VStack above.
            ZStack {
                Theme.Bg.base
                AsyncImage(url: track?.thumbnailURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill().blur(radius: 80).opacity(0.45)
                    } else {
                        LinearGradient(colors: [Color(white: 0.08), .black],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                // Adaptive accent wash (Apple Music signature): a
                // top-anchored gradient of the artwork's dominant
                // color, fading to black. Layered OVER the blurred
                // art so the hue reads clearly, UNDER the darkening
                // gradient so foreground text stays legible.
                // Cross-fades when the track (and thus color) changes.
                if let backdropColor {
                    LinearGradient(
                        colors: [backdropColor.opacity(0.55), backdropColor.opacity(0.12), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .transition(.opacity)
                }
                LinearGradient(
                    colors: [Color.black.opacity(0.45), Color.black.opacity(0.78)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: backdropColor)
        }
        .task(id: track?.videoId) {
            // Extract the accent color when the track changes. Runs
            // off the URLCache (warmed by the artwork AsyncImage), so
            // it's usually instant. nil clears the wash to the plain
            // black+blur fallback.
            guard let url = track?.thumbnailURL else {
                backdropColor = nil
                return
            }
            let color = await DominantColor.extract(from: url)
            // A cancelled task (fast Previous/Next skip) must not land
            // late and clobber the NEW track's color with nil — its
            // cancelled URL fetch surfaces as a nil result.
            guard !Task.isCancelled else { return }
            backdropColor = color
        }
        .preferredColorScheme(.dark)
        .onExitCommand {
            // Esc is layered: exit fullscreen lyrics first if it's
            // up, otherwise close the whole player.
            if lyricsFullscreen {
                lyricsFullscreen = false
            } else {
                env.player.isFullPlayerOpen = false
            }
        }
        .onChange(of: bottomTab) { _, newTab in
            if newTab == .lyrics { env.player.loadLyricsIfNeeded() }
            if newTab == .related { env.player.loadRelatedIfNeeded() }
            if newTab == .context { fireXRayIfNeeded() }
        }
        .onChange(of: queueMode) { _, mode in
            // "Discover" reuses the same `related` field that the Related
            // top-tab populates — fetch lazily on first selection so we
            // don't pay the cost when the user only ever uses Related.
            if mode == .discover { env.player.loadRelatedIfNeeded() }
        }
        // Reset X-Ray view state on track change so a cached bundle for
        // the new track paints (or a fresh request fires via the
        // debounced task below). The service's own cache means
        // back-and-forth between two tracks is instant.
        .onChange(of: env.player.currentTrack?.videoId) { _, _ in
            xrayRequestID = UUID()   // orphan any in-flight request
            xrayCards = nil
            xrayError = nil
            xrayLoading = false
        }
        // Debounced auto-fire: with the Context tab open, skipping
        // through tracks must not bill one LLM request per skip — and a
        // request fired the instant `currentTrack` changes can still
        // carry the PREVIOUS track's lyrics (the bridge only clears
        // them once /next returns). SwiftUI cancels the sleep when the
        // id changes, so only the track the user settles on fires; a
        // cache hit skips the debounce and paints instantly. The id
        // also covers configuring an API key while the tab is open.
        .task(id: "\(track?.videoId ?? "none")#\(env.hasLLMAPIKey)") {
            guard bottomTab == .context, env.hasLLMAPIKey else { return }
            if let vid = track?.videoId, env.xrayCardsService.cached(videoId: vid) != nil {
                fireXRayIfNeeded()
                return
            }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            fireXRayIfNeeded()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                env.player.isFullPlayerOpen = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Close")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.Fill.medium)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            // Esc is layered (see onExitCommand): in fullscreen lyrics
            // the Exit-fullscreen button owns .cancelAction instead —
            // key shortcuts dispatch via performKeyEquivalent BEFORE
            // onExitCommand ever sees the key, so an unconditional
            // shortcut here would close the whole player from
            // fullscreen lyrics. Exactly one .cancelAction is live at
            // a time.
            .keyboardShortcut(lyricsFullscreen ? nil : KeyboardShortcut.cancelAction)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Left column (artwork + title + scrubber + transport)

    private var leftPlayer: some View {
        let track = env.player.currentTrack
        return VStack(spacing: 22) {
            Spacer(minLength: 8)
            heroMedia(track: track)

            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayedTitle(track: track))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let vid = track?.videoId,
                       env.trackOverrides.hasOverride(for: vid) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Text.secondary)
                            .help("Metadata edited locally")
                            .accessibilityLabel("Metadata edited")
                    }
                }
                // Each credited artist is its own link (hover highlights
                // only that name; click opens THAT artist) — the previous
                // single link lit the whole credit string and could only
                // reach the first artist.
                ArtistLinkLine(
                    subtitle: displayedSubtitle(track: track),
                    primaryArtistId: track?.artistId,
                    fontSize: 14,
                    baseOpacity: 0.7
                )
                audioQualityBadge
                    .padding(.top, 6)
            }
            .padding(.horizontal, 32)
            .contextMenu { nowPlayingMenuItems }

            scrubber
                .frame(maxWidth: 480)
            playbackControls
                .padding(.top, 4)
            volumeBar
                .frame(maxWidth: 300)
                .padding(.top, 2)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Hero artwork. Riff intentionally does NOT surface the music video —
    /// see CLAUDE.md's "WKWebView is never visible after sign-in" rule.
    /// The earlier audio↔video toggle was the scoped exception and it
    /// caused architectural drift (chrome leakage, MSE stream switching,
    /// reparenting bugs); now removed. The "Watch music video" button
    /// in the corner of the hero replaces it — hands the URL off to
    /// the system browser so the video plays in a real browser tab
    /// instead of an embedded WebView Riff has to reparent.
    private func heroMedia(track: PlayerBridge.Track?) -> some View {
        // 320pt hero = 640px on Retina; the track thumbnail PlayerBridge
        // reports is typically 544px or smaller. Upscale via the =wN-hN
        // host rewrite for a crisp hero.
        AsyncImage(url: track?.thumbnailURL?.upscaledArtwork(to: 720)) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
            default: Theme.Fill.soft
            }
        }
        .frame(width: 320, height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.6), radius: 26, y: 10)
        .overlay(alignment: .bottomTrailing) {
            if let track, !track.videoId.isEmpty {
                Button {
                    if let url = URL(string: "https://music.youtube.com/watch?v=\(track.videoId)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Watch video")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.75))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Theme.Fill.strong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(10)
                .help("Open the music video in your browser")
            }
        }
        .contextMenu { nowPlayingMenuItems }
    }

    // MARK: - Right column (Up Next / Lyrics / Related side pane)

    private var sidePane: some View {
        VStack(spacing: 14) {
            // Tab pills along the top of the side pane.
            HStack(spacing: 0) {
                ForEach(BottomTab.allCases) { t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { bottomTab = t }
                    } label: {
                        VStack(spacing: 7) {
                            // Uppercase + tracked — YT Music web's watch-
                            // page tab treatment (UP NEXT / LYRICS / …).
                            Text(t.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .textCase(.uppercase)
                                .tracking(1.1)
                                .foregroundStyle(bottomTab == t ? Color.white : Theme.Text.tertiary)
                            Rectangle()
                                .fill(bottomTab == t ? Theme.red : Color.clear)
                                .frame(height: 2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().background(Theme.Fill.strong)

            // Selected tab content fills remaining height. Plain
            // ScrollView — UP NEXT renders first, so it's naturally
            // at the top on open; Recently Played sits below it, so
            // history is a scroll-DOWN away. (An earlier version
            // pinned UP NEXT via a ScrollViewReader while history
            // rendered above; the forced scroll landed at odd
            // positions — removed.)
            ScrollView {
                Group {
                    switch bottomTab {
                    case .upNext:  upNextContent
                    case .lyrics:  lyricsContent
                    case .related: relatedContent
                    case .context: contextContent
                    }
                }
                .id(bottomTab)
                .transition(.opacity)
                Spacer(minLength: 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Frost over a DARK base, not straight over the backdrop.
        // The adaptive color wash (F1) is saturated at the top; a
        // bare `.regularMaterial` picked that up and tinted the whole
        // Up Next pane the album's color, which read as "off". The
        // dark fill underneath keeps the frost neutral while still
        // giving the subtle translucency that separates the pane
        // from the artwork behind it.
        .background(.regularMaterial)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.red)
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.horizontal, 16)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.Fill.strong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, x: -4, y: 0)
    }

    // MARK: - Scrubber

    // Scrubber lives in its own View struct (ScrubberSection, end of
    // file) — @Observable tracks property access per view body, and
    // elapsed/duration mutate at ~4Hz. When this 2,100-line view read
    // them directly, the ENTIRE body re-evaluated four times a second
    // for the life of the player; isolated in a child, only the child
    // re-renders per tick.
    private var scrubber: some View { ScrubberSection() }

    /// Help-text label for the shuffle button, surfacing the Smart
    /// Shuffle state alongside regular shuffle so a hover hint tells
    /// the user both at once. Right-click toggles Smart Shuffle.
    private var shuffleHelpText: String {
        switch (env.player.shuffleEnabled, env.player.smartShuffleEnabled) {
        case (true, true):   return "Shuffle on · Smart Shuffle on (right-click to disable)"
        case (true, false):  return "Shuffle on (right-click for Smart Shuffle)"
        case (false, true):  return "Shuffle off · Smart Shuffle armed (right-click to disable)"
        case (false, false): return "Shuffle (right-click for Smart Shuffle)"
        }
    }

    /// Transport, in two tiers so the hierarchy reads at a glance: the
    /// primary row is the core playback transport (centered, large play
    /// hub); the secondary row holds the lighter utilities (like + the
    /// rate / output / sleep / playlist / more menus) at reduced weight
    /// so they no longer compete with prev/play/next.
    private var playbackControls: some View {
        VStack(spacing: 18) {
            primaryTransportRow
            secondaryUtilityRow
        }
    }

    private var primaryTransportRow: some View {
        HStack(spacing: 20) {
            // Shuffle — when ON, our `next()` plays a random upcoming
            // track instead of advancing to the page's natural next.
            // Right-click reveals the Smart Shuffle (B5) toggle: when
            // both shuffle AND smart shuffle are on, every 4th slot in
            // upNext becomes a /related recommendation marked with a
            // "+" badge in the QueueRow.
            controlButton(
                systemName: env.player.smartShuffleEnabled && env.player.shuffleEnabled
                    ? "shuffle.circle.fill"
                    : "shuffle",
                size: 18,
                tint: env.player.shuffleEnabled ? Theme.red : Theme.Text.secondary,
                help: shuffleHelpText
            ) {
                env.player.toggleShuffle()
            }
            .contextMenu {
                Button {
                    env.player.toggleSmartShuffle()
                } label: {
                    if env.player.smartShuffleEnabled {
                        Label("Disable Smart Shuffle", systemImage: "checkmark")
                    } else {
                        Label("Enable Smart Shuffle", systemImage: "sparkles")
                    }
                }
                Text("Smart Shuffle injects related-song suggestions every few slots when shuffle is on.")
            }
            // Skip-back -15s — useful for any track but especially podcasts.
            controlButton(systemName: "gobackward.15", size: 20, tint: Theme.Text.secondary, help: "Back 15 seconds") {
                Task { await env.player.skip(by: -15) }
            }
            controlButton(systemName: "backward.fill", size: 22, tint: .white, help: "Previous") {
                Task { await env.player.previous() }
            }
            ZStack {
                Circle().fill(Theme.red)
                    .frame(width: 64, height: 64)
                    .shadow(color: Theme.red.opacity(0.4), radius: 12, y: 4)
                Image(systemName: env.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: env.player.isPlaying ? 0 : 2)
            }
            .onTapGesture { Task { await env.player.togglePlay() } }
            .help(env.player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(env.player.isPlaying ? "Pause" : "Play")
            .accessibilityAddTraits(.isButton)
            controlButton(systemName: "forward.fill", size: 22, tint: .white, help: "Next") {
                Task { await env.player.next() }
            }
            // Skip-forward +30s.
            controlButton(systemName: "goforward.30", size: 20, tint: Theme.Text.secondary, help: "Forward 30 seconds") {
                Task { await env.player.skip(by: 30) }
            }
            // Repeat — currently two-state (off / one). The "1" badge
            // on `repeat.1` makes the active mode read at a glance.
            controlButton(
                systemName: env.player.repeatMode == .one ? "repeat.1" : "repeat",
                size: 18,
                tint: env.player.repeatMode == .off ? Theme.Text.secondary : Theme.red,
                help: env.player.repeatMode == .one ? "Repeat one"
                    : env.player.repeatMode == .all ? "Repeat all" : "Repeat"
            ) {
                Task {
                    await env.player.toggleRepeat()
                    // Mode feedback — a silently-persisting Repeat All
                    // made a looping album read as a queue bug.
                    switch env.player.repeatMode {
                    case .off: env.showToast("Repeat off")
                    case .all: env.showToast("Repeat all — the queue loops when it ends")
                    case .one: env.showToast("Repeat one — this song loops")
                    }
                }
            }
        }
    }

    private var secondaryUtilityRow: some View {
        HStack(spacing: 20) {
            controlButton(
                systemName: env.player.liked ? "heart.fill" : "heart",
                size: 18,
                tint: env.player.liked ? Theme.red : Theme.Text.secondary,
                help: env.player.liked ? "Unlike" : "Like"
            ) {
                Task { await env.player.toggleLike() }
            }
            playbackRateMenu
            audioOutputButton
            sleepTimerMenu
            addToPlaylistMenu
            moreMenu
        }
        // Lighter than the transport above — a tier of secondary actions,
        // not primary controls.
        .opacity(0.9)
    }

    /// Volume bar under the transport controls — the full player had no
    /// in-window volume control (only the mini-player slider and the
    /// ⌘↑/⌘↓ nudge shortcuts). Speaker icon click toggles mute,
    /// restoring the pre-mute level rather than snapping to 100%.
    private var volumeBar: some View {
        HStack(spacing: 8) {
            Button {
                if env.player.volume > 0 {
                    preMuteVolume = env.player.volume
                    Task { await env.player.setVolume(0) }
                } else {
                    Task { await env.player.setVolume(preMuteVolume > 0 ? preMuteVolume : 1.0) }
                }
            } label: {
                Image(systemName: env.player.volume == 0 ? "speaker.slash.fill"
                                   : env.player.volume < 0.5 ? "speaker.wave.1.fill"
                                   : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(env.player.volume == 0 ? "Unmute" : "Mute")
            Slider(
                value: Binding(
                    get: { env.player.volume },
                    set: { v in Task { await env.player.setVolume(v) } }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(Theme.Text.secondary)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(width: 18)
        }
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((env.player.volume * 100).rounded())) percent")
    }

    /// Sleep-timer menu. Shows the running countdown when armed (mm:ss),
    /// preset durations + mode submenu when idle. Mirrors YT Music
    /// mobile's sleep-timer affordance, plus two modes neither YTM
    /// desktop nor Spotify ship: gentle 10s fade-out, and stop after
    /// the current track ends. Persists for the session only — Apple
    /// Music, YT Music, Spotify all behave this way.
    private var sleepTimerMenu: some View {
        Menu {
            if env.player.sleepTimerRemaining != nil || env.player.endOfTrackArmed {
                Button("Cancel timer") { env.player.cancelSleepTimer() }
                Divider()
            }
            // End-of-track is its own discrete entry — it has no
            // countdown ("stop after this track ends" is the whole
            // semantics) so a top-level button reads cleaner than
            // burying it under a "minutes" submenu.
            Button(action: { env.player.setSleepTimer(minutes: 0, mode: .endOfTrack) }) {
                Label("End of current track", systemImage: "stop.circle")
            }
            Divider()
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Menu("\(minutes) min") {
                    Button("Stop") { env.player.setSleepTimer(minutes: minutes, mode: .hardStop) }
                    Button("Fade out (10s)") { env.player.setSleepTimer(minutes: minutes, mode: .fadeOut) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 16, weight: .semibold))
                if let remaining = env.player.sleepTimerRemaining {
                    Text(formatTimer(remaining))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                } else if env.player.endOfTrackArmed {
                    Text("EOT")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(sleepTimerActive ? Theme.red : Theme.Text.secondary)
            .frame(height: 40)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(sleepTimerHelp)
        // VoiceOver: read the mode + remaining as a single label,
        // and mark the value as updates-frequently so the countdown
        // ticks don't spam-announce every second. (U6)
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(sleepTimerHelp)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Whether the sleep-timer affordance should render in its
    /// "armed" tint. Either there's a live countdown, or we've
    /// elapsed the countdown of an `endOfTrack` timer and are
    /// awaiting the next track-ended event.
    private var sleepTimerActive: Bool {
        env.player.sleepTimerRemaining != nil || env.player.endOfTrackArmed
    }

    /// Tooltip text — reflects the active mode + remaining time so the
    /// user doesn't have to open the menu to remember what they armed.
    private var sleepTimerHelp: String {
        if let remaining = env.player.sleepTimerRemaining {
            let suffix: String
            switch env.player.sleepTimerMode {
            case .fadeOut: suffix = " (fade out)"
            case .endOfTrack: suffix = " (end of track)"
            default: suffix = ""
            }
            return "Sleep in \(formatTimer(remaining))\(suffix)"
        }
        if env.player.endOfTrackArmed {
            return "Sleeping after current track"
        }
        return "Sleep timer"
    }

    private func formatTimer(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "More" (•••) menu — surfaces Go to album / Go to artist / Start
    /// radio for the currently playing track without requiring the user
    /// to right-click. Mirrors YT Music's track-overflow affordance.
    /// Audio output / AirPlay route picker (B10).
    ///
    /// Audio is driven by WKWebView's `<video>` element, so the macOS
    /// system audio routing handles AirPlay at the OS level. The iOS
    /// `AVRoutePickerView` API does not exist on macOS, and surfacing a
    /// CoreAudio-enumerated device popover from inside the app would
    /// not include AirPlay receivers (which only the Sound preference
    /// pane fully surfaces). The pragmatic v1 is a transport-row button
    /// that opens System Settings → Sound → Output, where AirPlay
    /// devices, Bluetooth output, and built-in speakers all live in
    /// one consistent picker the user already trusts.
    ///
    /// Falls back to opening the generic Sound preference pane if the
    /// modern URL is rejected by the OS (older macOS releases).
    private var audioOutputButton: some View {
        Button {
            openSoundOutputSettings()
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Text.secondary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Audio output (opens System Settings → Sound)")
    }

    /// Opens macOS Sound → Output settings. Tries the modern
    /// `com.apple.preference.sound` URL first, falls back to the legacy
    /// `.prefPane` bundle if the URL handler isn't registered.
    private func openSoundOutputSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.sound?Output"
        if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
            return
        }
        // Fallback: open the Sound prefpane bundle directly.
        let fallback = URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane")
        NSWorkspace.shared.open(fallback)
    }

    private var moreMenu: some View {
        Menu {
            nowPlayingMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Text.secondary)
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 36, height: 40)
        .disabled(env.player.currentTrack == nil)
        .help("More")
    }

    /// Reusable menu builder for the currently-playing track. Synthesizes
    /// a MediaItem from PlayerBridge.Track so we can defer to the shared
    /// TrackContextMenu component (Start radio / Play next / Add to queue
    /// / Go to album / Go to artist / Add to playlist).
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

    /// "Add to Playlist…" menu — only meaningful when signed in. Loads the
    /// user's playlists lazily on first open.
    private var addToPlaylistMenu: some View {
        Menu {
            if !env.isSignedIn {
                Text("Sign in to add tracks to your playlists.")
            } else {
                Button("New Playlist…") {
                    env.newPlaylistSource = .currentTrack
                    env.isNewPlaylistSheetPresented = true
                }
                Divider()
                if env.userPlaylistsLoading {
                    Text("Loading…")
                } else if env.userPlaylists.isEmpty {
                    Text("No playlists yet.")
                } else {
                    ForEach(env.userPlaylists) { pl in
                        Button(pl.title) {
                            // Capture the track at tap time — it can
                            // change before the Task runs, and a nil
                            // current track must not toast "Added".
                            guard let track = env.player.currentTrack else { return }
                            let videoId = track.videoId
                            Task {
                                // Toast both outcomes, same copy as
                                // TrackContextMenu — a silent add read
                                // as "did that even work?"
                                do {
                                    try await env.innerTube.addToPlaylist(
                                        videoId: videoId,
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
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Text.secondary)
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 36, height: 40)
        .onAppear { env.loadUserPlaylistsIfNeeded() }
        .help("Add to playlist")
    }

    /// Playback-speed picker. 1× by default; useful for podcasts at 1.25–2×.
    /// Replaces the inert shuffle button which we don't have a real backend
    /// for yet (YT Music's shuffle is server-driven inside the queue).
    ///
    /// Podcast pill variant: when the current track's kind is spoken
    /// (podcast episode), a single tap cycles through the common
    /// podcast speeds (1×→1.25×→1.5×→1.75×→2×→1×), Overcast-style,
    /// so the user doesn't have to open a menu for the primary
    /// action. Right-click / long-press keeps the full menu.
    private var playbackRateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                Button {
                    Task { await env.player.setPlaybackRate(rate) }
                } label: {
                    let label = rate == 1.0 ? "Normal" : Self.formatRate(rate) + "×"
                    if env.player.playbackRate == rate {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Text(env.player.playbackRate == 1.0 ? "1×" : Self.formatRate(env.player.playbackRate) + "×")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(env.player.playbackRate == 1.0 ? Theme.Text.secondary : Theme.red)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: 60, height: 40)
        .help(env.player.currentKind == .spoken
              ? "Playback speed (tap to cycle)"
              : "Playback speed")
        .overlay {
            // When podcast mode is active, layer an invisible tap
            // handler that runs FIRST — SwiftUI hit-tests overlays
            // above the labeled Menu, so this catches primary
            // clicks. Right-click still opens the Menu (SwiftUI's
            // built-in behavior) because it goes through the
            // Menu's own contextual handler, not this button.
            if env.player.currentKind == .spoken {
                Button {
                    let presets: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]
                    let currentRate = env.player.playbackRate
                    let nextIdx = (presets.firstIndex { abs($0 - currentRate) < 0.01 } ?? -1) + 1
                    let next = presets[nextIdx % presets.count]
                    Task { await env.player.setPlaybackRate(next) }
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static func formatRate(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rate))
            : String(format: "%g", rate)
    }

    private func controlButton(systemName: String, size: CGFloat, tint: Color, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        // Route the help tooltip into VoiceOver too — every
        // transport button call site already passes a meaningful
        // `help` string ("Play", "Previous", "Skip forward 30s",
        // etc.), so mirror it into the accessibility label so
        // VoiceOver reads the same intent, not the raw SF Symbol
        // name.
        .accessibilityLabel(help ?? systemName)
    }

    // MARK: - Tab content

    @State private var tunePopoverOpen: Bool = false
    /// "Recently played" (rendered below Up Next) shows the last few
    /// rows by default; "Show all" expands the full session log.
    /// Keeps the pane from feeling like a log file while still
    /// giving access to everything.
    @State private var historyExpanded: Bool = false
    private static let historyDefaultLimit = 4

    private var queueModeLabel: some View {
        Text(queueModeHeader)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(Theme.Text.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// What's actually streaming — "OPUS · 160 KBPS" — read from the
    /// page's own player. When the page was offered a better format than
    /// it's playing, the tooltip says so (usually: the 256 kbps tier
    /// needs YouTube Premium). Hidden until the first report lands.
    @ViewBuilder
    private var audioQualityBadge: some View {
        if let f = env.player.audioFormat, let label = f.label {
            let tip: String = {
                var t = "Streaming \(label)"
                if f.isBelowBestAvailable, let best = f.bestLabel {
                    t += ". This track also offers \(best) — YouTube's top tier needs Premium."
                }
                if env.player.audioQualityPreference == .high {
                    t += " Highest quality is on: hidden video is capped."
                }
                return t
            }()
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                Text(label.uppercased())
                if f.isBelowBestAvailable {
                    Image(systemName: "arrow.up.circle")
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.Text.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().strokeBorder(Theme.Fill.strong, lineWidth: 1))
            .help(tip)
            .accessibilityLabel(tip)
        }
    }

    /// The top taste-model reason the current track is in a Riff Blend.
    private var blendReasonForCurrentTrack: String? {
        guard let t = env.player.currentTrack else { return nil }
        let item = MediaItem(id: t.videoId, kind: .song, title: t.title, subtitle: t.subtitle,
                             thumbnailURL: t.thumbnailURL, albumId: t.albumId, artistId: t.artistId)
        return TasteProfile.build(from: env.player.playedEntries).reasons(for: item).first
    }

    /// Autoplay switch — YT web's watch-page queue toggle, wired to the
    /// existing `autoplayEnabled` setting (same one as Settings →
    /// Playback). OFF stops playback when the queue runs out instead of
    /// extending it with related tracks.
    private var autoplayToggle: some View {
        Toggle(isOn: Binding(
            get: { env.player.autoplayEnabled },
            set: { env.player.setAutoplayEnabled($0) }
        )) {
            Text("Autoplay")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Text.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.red)
        .fixedSize()
        .help("When on, the queue auto-extends with similar music as it nears the end.")
        .accessibilityLabel("Autoplay")
    }

    /// Save / Clear / Build / Tune — mirrors YT Music's popover-driven
    /// pattern instead of always-visible mode pills.
    @ViewBuilder
    private var queueHeaderChips: some View {
                // "Save queue" — YT Music's Up-Next save affordance.
                // Disabled when there's nothing to save, hidden when
                // the user is anonymous (the createPlaylist endpoint
                // requires a SAPISID cookie session anyway).
                if env.isSignedIn, !env.player.upNext.isEmpty {
                    Button {
                        env.newPlaylistSource = .queue
                        env.isNewPlaylistSheetPresented = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Save")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.Fill.soft)
                        .foregroundStyle(Theme.Text.secondary)
                        .clipShape(Capsule())
                        // Never wrap a chip label mid-word ("Sav e") when
                        // four chips share the pane header; overflow is
                        // absorbed by the section title instead.
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("Save these tracks as a new playlist")
                }
                // "Clear" — empties Up Next (user + server regions).
                // The playing track is unaffected; for radio, YT's
                // autoplay continues, matching YT Music's own
                // clear-queue behavior.
                if !env.player.upNext.isEmpty {
                    Button {
                        Task { await env.player.clearUpNext() }
                        env.showToast("Queue cleared")
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Clear")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.Fill.soft)
                        .foregroundStyle(Theme.Text.secondary)
                        .clipShape(Capsule())
                        // Never wrap a chip label mid-word ("Sav e") when
                        // four chips share the pane header; overflow is
                        // absorbed by the section title instead.
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("Remove all upcoming tracks")
                }
                // "✨ Build" — opens the AI Queue Builder sheet.
                // Discoverable but unobtrusive: same chip shape as
                // Save / Tune, sparkles icon hints at the AI nature.
                // Always visible (the sheet itself handles the
                // "no API key" empty state) so users can find the
                // feature before they've configured it.
                Button {
                    env.isQueueBuilderSheetPresented = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Build")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.Fill.soft)
                    .foregroundStyle(Theme.Text.secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Build a queue from a vibe with AI")
                .fixedSize()

                Button {
                    tunePopoverOpen = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Tune")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.Fill.soft)
                    .foregroundStyle(Theme.Text.secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .popover(isPresented: $tunePopoverOpen, arrowEdge: .top) {
                    TunePopover(
                        chips: env.player.availableChips,
                        selectedChipId: env.player.selectedChipId,
                        onSelectChip: { chip in env.player.applyChip(chip) },
                        fallbackSelection: $queueMode
                    )
                }
    }

    private var upNextContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // "Playing from <album/playlist>" + Save — YT web's watch-page
            // queue header. Only when the queue context came from a named
            // tracklist (playTracks with a sourceTitle); radio and bare
            // single-track contexts show nothing here.
            if let src = env.player.queueSourceTitle {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Playing from")
                            .font(.system(size: 9, weight: .semibold))
                            .textCase(.uppercase)
                            .tracking(1.2)
                            .foregroundStyle(Theme.Text.tertiary)
                        Text(src)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        // Blend transparency: why THIS song is in the mix,
                        // from the same taste model that picked it. Click
                        // opens the full "Your Taste" view.
                        if src == "Riff Blend", let why = blendReasonForCurrentTrack {
                            Button {
                                env.isTasteSheetPresented = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                    Text(why)
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Text.secondary)
                                .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help("Why this song? Open Your Taste")
                        }
                    }
                    Spacer()
                    if let pid = env.player.queueSourcePlaylistId, !pid.isEmpty {
                        let saved = env.isSavedToLibrary(pid)
                        Button {
                            env.toggleSavedToLibrary(playlistId: pid, title: src)
                        } label: {
                            Label(saved ? "Saved" : "Save",
                                  systemImage: saved ? "checkmark" : "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(saved ? Theme.red : .white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().strokeBorder(Theme.Fill.strong, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(saved ? "Remove from your library" : "Save to your library")
                    }
                }
                .padding(.horizontal, 4)
                Divider().background(Theme.Fill.medium)
            }
            // Header: mode label + Save / Clear / Build / Tune chips.
            // One row when the pane is wide enough; otherwise the label
            // takes its own line above the chips. Chips are fixed-size
            // so they never wrap mid-word ("Buil d", "Tu ne") and the
            // label truncates instead of breaking ("INSTRUM ENTAL").
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    queueModeLabel
                    Spacer()
                    queueHeaderChips
                    autoplayToggle
                }
                VStack(alignment: .leading, spacing: 8) {
                    queueModeLabel
                    HStack(spacing: 6) {
                        queueHeaderChips
                        autoplayToggle
                        Spacer(minLength: 0)
                    }
                }
            }

            // Compose the queue around the current track: previously played
            // above (faded), upcoming below. Both lists exclude the
            // currently-playing videoId so it never appears twice — going
            // back to a previously-played track was making it show in both
            // sections. The "upcoming" list source switches based on the
            // selected mode pill (see QueueMode docs).
            let currentId = env.player.currentTrack?.videoId
            // Blank-row guard applied to BOTH lists: entries archived
            // (or queued) before metadata landed have an empty title
            // and no artwork — they render as anonymous slots. Drop
            // them everywhere so neither section shows visual noise.
            //
            // History legally repeats videoIds (A, B, A), so its rows
            // can't be ForEach-keyed by videoId alone — that logged
            // "ID occurs multiple times" and mis-animated rows. Keep
            // each entry's index in the FULL, unfiltered history (it
            // only shifts when the cap trims the front, unlike an
            // index into the filtered suffix window) and key rows by
            // "index-videoId".
            let historyRows = Array(env.player.playedHistory.enumerated()).filter { pair in
                pair.element.id != currentId
                    && !pair.element.title.trimmingCharacters(in: .whitespaces).isEmpty
                    && pair.element.thumbnailURL != nil
            }
            let upcoming = upcomingList(currentId: currentId).filter {
                !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
            }
            // Queue-mutating affordances (drag-reorder, Move Up/Down,
            // Remove) only make sense when the rows really are the
            // page's queue — i.e. `upcomingList` returned `upNext`.
            // The Discover lens (no chips) shows `related` rows;
            // "editing" those is a no-op that ends in a false
            // "Couldn't remove" error toast.
            let upcomingIsQueue = !env.player.availableChips.isEmpty || queueMode != .discover
            let showRadioHint = upcoming.isEmpty
                && env.player.isRadioContext
                && currentId != nil
            // Radio: anchor the compact autoplay banner at the TOP of the
            // pane (where a queue would be) so it reads as the "up next"
            // state, instead of floating in the gap under a short
            // Recently Played list. Recently Played follows beneath it.
            if showRadioHint {
                radioAutoplayHint
            }
            // Recently played — the session log. Capped by default;
            // "Show all" reveals the rest. Default lens only (a tuned
            // variant's curation isn't a history).
            if !historyRows.isEmpty, isDefaultLens {
                HStack(spacing: 6) {
                    Text("Recently played")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(Theme.Text.tertiary)
                    Spacer()
                    if historyRows.count > Self.historyDefaultLimit {
                        Button(historyExpanded ? "Show fewer" : "Show all (\(historyRows.count))") {
                            historyExpanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Text.secondary)
                    }
                }
                .padding(.horizontal, 4)
                // Chronological (oldest → newest) so the most
                // recently-played track sits at the BOTTOM of the
                // section, right above "Up next". Capped view keeps
                // the last N (closest to now).
                let shown = historyExpanded
                    ? historyRows
                    : Array(historyRows.suffix(Self.historyDefaultLimit))
                queueList(
                    shown.map(\.element),
                    faded: true,
                    rowKeys: shown.map { "\($0.offset)-\($0.element.id)" }
                )
                // Divider only when an Up Next list follows — otherwise a
                // trailing divider dangles under radio/empty states.
                if !upcoming.isEmpty {
                    Divider().background(Theme.Fill.medium)
                        .padding(.vertical, 4)
                }
            }
            if !upcoming.isEmpty {
                Text(upcomingHeader)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(Theme.Text.tertiary)
                    .padding(.horizontal, 4)
                queueList(upcoming, faded: false, reorderable: upcomingIsQueue)
            }
            // Nothing to show and not a radio context → neutral empty hint.
            if historyRows.isEmpty && upcoming.isEmpty && !showRadioHint {
                emptyHint(emptyHintText)
            }
        }
    }

    /// Shown in the Up Next tab for radio contexts, where we deliberately
    /// don't display an upcoming queue: a radio's next tracks are
    /// non-deterministic (the WebView plays its own radio, which an
    /// independent /next call can't reproduce), so any list we drew would
    /// not match what actually plays. Truthful placeholder until Phase 2
    /// mirrors the page's real queue. Explicit Play next / Add to queue
    /// items still appear above this (they live in the user region).
    private var radioAutoplayHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Text.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Autoplay radio")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Text.secondary)
                Text("Next tracks are chosen automatically as the station plays. Use “Play next” or “Add to queue” to line up specific songs.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.Fill.soft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Fill.medium, lineWidth: 1)
        )
        .padding(.horizontal, 4)
    }

    /// Returns the upcoming list excluding the currently-playing track.
    /// When YT served a chip cloud, `upNext` already reflects whichever
    /// chip is active (PlayerBridge.applyChip re-fetches /next on chip
    /// selection), so we just hand back upNext. Without chips we fall
    /// back to the local QueueMode lenses.
    private func upcomingList(currentId: String?) -> [MediaItem] {
        if !env.player.availableChips.isEmpty {
            return env.player.upNext.filter { $0.id != currentId }
        }
        switch queueMode {
        case .related:
            return env.player.upNext.filter { $0.id != currentId }
        case .discover:
            return env.player.related.filter { $0.id != currentId }
        case .familiar:
            // Build the set of artist names heard earlier in this session
            // and intersect with the radio queue. Case-insensitive so
            // "Bruno Mars" and "bruno mars" still match. Empty when the
            // user hasn't played anything yet — handled by the empty-hint
            // text below.
            let known = Set(env.player.playedHistory.map { $0.subtitle.lowercased() })
            return env.player.upNext.filter {
                $0.id != currentId && known.contains($0.subtitle.lowercased())
            }
        }
    }

    /// Section header shown above the upcoming list. "Up next" by default;
    /// the modes get their own labels so the user can tell at a glance
    /// which lens they're looking at.
    private var upcomingHeader: String {
        switch queueMode {
        case .related:  return "Up next"
        case .discover: return "More like this"
        case .familiar: return "From artists you've played"
        }
    }

    /// Top-of-pane label shown left of the Tune button. When YT served a
    /// chip cloud and one is selected, show that chip's label (e.g.
    /// "Discover" / "Telugu" / "2010s"). Otherwise fall back to the
    /// local QueueMode label.
    private var queueModeHeader: String {
        if let id = env.player.selectedChipId,
           let chip = env.player.availableChips.first(where: { $0.id == id }) {
            // "All" reads as just "Up next" to keep the default state quiet.
            return chip.id == "All" ? "Up next" : chip.label
        }
        switch queueMode {
        case .related:  return "Up next"
        case .discover: return "Discover"
        case .familiar: return "Familiar"
        }
    }

    /// True when we're in the default (untuned) lens — either YT's "All"
    /// chip is active, or no chips are available and the local mode is
    /// `.related`. Drives the "Recently played" gate.
    private var isDefaultLens: Bool {
        if !env.player.availableChips.isEmpty {
            return (env.player.selectedChipId ?? "All") == "All"
        }
        return queueMode == .related
    }

    /// Empty-state text varies by mode so we explain *why* nothing's
    /// here rather than a generic "Queue empty".
    private var emptyHintText: String {
        switch queueMode {
        case .related:
            return "Queue empty."
        case .discover:
            return "No discoveries yet — try again in a moment."
        case .familiar:
            return "Play a few tracks first so we know what's familiar."
        }
    }

    private var lyricsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Translate toggle + "Create card" share a header row.
            // Both surfaces only render when there are REAL lyrics to
            // act on — `lyricsLines` is filled by every successful
            // fetch, while the plain `lyrics` string can also hold the
            // "Lyrics not available." UI sentinel, which must not
            // enable Translate / Create card.
            if !env.player.lyricsLoading, !env.player.lyricsLines.isEmpty {
                HStack(spacing: 12) {
                    translationToolbar
                    Spacer()
                    Button {
                        lyricsFullscreen = true
                    } label: {
                        Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Text.secondary)
                    .help("Show lyrics fullscreen")
                    Button {
                        env.isLyricCardSheetPresented = true
                    } label: {
                        Label("Create card", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Text.secondary)
                }
            }
            Group {
                if env.player.lyricsLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading lyrics…")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
                } else if env.player.lyricsTimed && !env.player.lyricsLines.isEmpty {
                    syncedLyrics
                } else if let text = env.player.lyrics, !text.isEmpty {
                    plainLyricsWithTranslation(text)
                } else {
                    emptyHint("Lyrics not available for this track.")
                }
            }
        }
        // Reset on track change. The refire is NOT immediate: at this
        // instant `env.player.lyricsLines` can still hold the PREVIOUS
        // track's lines (the bridge only clears them once /next
        // returns), so an immediate request would translate the wrong
        // song and cache it under the new videoId. The debounced
        // .task(id:) below fires once the track settles.
        .onChange(of: env.player.currentTrack?.videoId) { _, _ in
            translationRequestID = UUID()   // orphan any in-flight request
            translation = nil
            translationError = nil
            translationLoading = false
        }
        .onChange(of: env.translationLanguage) { _, _ in
            translationRequestID = UUID()
            translation = nil
            translationError = nil
            translationLoading = false
            if env.lyricsTranslationEnabled { fireTranslateIfNeeded() }
        }
        .onChange(of: env.lyricsTranslationEnabled) { _, newValue in
            if newValue { fireTranslateIfNeeded() } else {
                // Toggling off doesn't drop the cache — flipping back
                // on should be free. Just hide.
                translationRequestID = UUID()
                translation = nil
                translationError = nil
                translationLoading = false
            }
        }
        // Lyrics often land asynchronously after the tab opens — if
        // translation is enabled at that moment, fire as soon as the
        // first batch of lines arrives.
        .onChange(of: env.player.lyricsLines.count) { _, _ in
            if env.lyricsTranslationEnabled, translation == nil {
                fireTranslateIfNeeded()
            }
        }
        // Debounced track-change work: re-request the new track's
        // lyrics (idempotent; a no-op until the bridge has cleared the
        // previous track's) and, once the track settles, fire the
        // translation. SwiftUI cancels the sleep when the id changes,
        // so tracks the user skips past never start a billed request.
        // A cache hit paints instantly, without the debounce.
        .task(id: env.player.currentTrack?.videoId) {
            env.player.loadLyricsIfNeeded()
            if env.lyricsTranslationEnabled,
               let vid = env.player.currentTrack?.videoId,
               env.lyricsTranslator.cached(videoId: vid, language: env.translationLanguage) != nil {
                fireTranslateIfNeeded()   // cache hit — instant paint
            }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            env.player.loadLyricsIfNeeded()
            if env.lyricsTranslationEnabled, translation == nil, !translationLoading {
                fireTranslateIfNeeded()
            }
        }
        .onAppear {
            if env.lyricsTranslationEnabled { fireTranslateIfNeeded() }
        }
    }

    /// Translation toolbar: a single toggle when AI is configured, a
    /// hint pointing to Settings otherwise. The picker for the target
    /// language lives in Settings (B3 spec) so users don't relitigate
    /// the choice on every song.
    @ViewBuilder
    private var translationToolbar: some View {
        if env.hasLLMAPIKey {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { env.lyricsTranslationEnabled },
                    set: { env.lyricsTranslationEnabled = $0 }
                )) {
                    HStack(spacing: 4) {
                        Image(systemName: "character.bubble")
                            .font(.system(size: 11))
                        Text("Translate")
                            .font(.system(size: 12, weight: .medium))
                        Text("(\(env.translationLanguage))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.red)
                .help("Translate lyrics line-by-line via Claude. Change target language in Settings → AI features.")
                if translationLoading {
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            Button {
                env.isSettingsSheetPresented = true
            } label: {
                Label("Translate — configure API key in Settings",
                      systemImage: "character.bubble")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.Text.tertiary)
            .help("Add an Anthropic API key in Settings → AI features to unlock lyric translation.")
        }
    }

    /// Plain-text (non-timed) lyrics with optional per-line translation
    /// rendered beneath each source line. We render line-by-line — even
    /// for the plain case — so each translation slot can carry its own
    /// optional pronunciation row.
    @ViewBuilder
    private func plainLyricsWithTranslation(_ text: String) -> some View {
        let sourceLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sourceLines.enumerated()), id: \.offset) { idx, line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.isEmpty ? "♪" : line)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    translatedSubtitle(at: idx, selectable: true)
                }
            }
        }
        .lineSpacing(5)
    }

    /// Optional translated subtitle for a given source-line index.
    /// Renders nothing when translation is off, errored, or the index
    /// is out of range of what the model returned.
    ///
    /// `selectable` is false on the synced (karaoke) path, where the
    /// row carries a tap-to-seek gesture: a selectable Text would
    /// consume the mouse-down itself and the tap would never fire.
    /// An outer .textSelection(.disabled) would NOT be enough — the
    /// innermost modifier wins, so selectability must be decided here.
    @ViewBuilder
    private func translatedSubtitle(at idx: Int, selectable: Bool) -> some View {
        if env.lyricsTranslationEnabled,
           let lines = translation?.lines,
           idx < lines.count {
            let entry = lines[idx]
            if !entry.translated.isEmpty || (entry.pronunciation?.isEmpty == false) {
                let column = VStack(alignment: .leading, spacing: 1) {
                    if let pron = entry.pronunciation, !pron.isEmpty {
                        Text(pron)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                    if !entry.translated.isEmpty {
                        Text(entry.translated)
                            .font(.system(size: 12, weight: .regular))
                            .italic()
                            .foregroundStyle(Theme.red.opacity(0.9))
                    }
                }
                .padding(.leading, 4)
                if selectable {
                    column.textSelection(.enabled)
                } else {
                    column
                }
            }
        }
        if env.lyricsTranslationEnabled, idx == 0, let err = translationError {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.85))
                .padding(.top, 2)
        }
    }

    /// Kick off a translation request for the current track + language
    /// using whatever lyric lines we have. Idempotent against the
    /// translator's cache; safe to call from multiple .onChange hooks.
    private func fireTranslateIfNeeded() {
        guard env.lyricsTranslationEnabled, env.hasLLMAPIKey else { return }
        guard let track = env.player.currentTrack else { return }
        // Translate only the structured `lyricsLines` — every
        // successful fetch fills them (the plain `lyrics` blob is
        // derived from them, so indices line up), while a lyrics-less
        // track leaves them empty and stores the "Lyrics not
        // available." UI sentinel in `lyrics`. That sentinel must
        // never be sent to the model as if it were a verse.
        guard !env.player.lyricsLines.isEmpty else { return }
        let lines = env.player.lyricsLines.map(\.text)
        let videoId = track.videoId
        let language = env.translationLanguage
        // Cache hit — render synchronously without flickering loader.
        if let hit = env.lyricsTranslator.cached(videoId: videoId, language: language) {
            translationRequestID = UUID()   // orphan any stale in-flight request
            translation = hit
            translationError = nil
            translationLoading = false
            return
        }
        translationLoading = true
        translationError = nil
        // Every completion path checks this token so a superseded
        // request (newer request started, or track/language changed)
        // can neither commit its result nor surface its error — and
        // never touches the spinner the newer request now owns.
        let requestID = UUID()
        translationRequestID = requestID
        let translator = env.lyricsTranslator
        Task { @MainActor in
            do {
                let result = try await translator.translate(
                    videoId: videoId,
                    language: language,
                    lines: lines
                )
                // Only commit if this is still the newest request and
                // the track + language still match — the user may have
                // skipped while we waited.
                guard translationRequestID == requestID,
                      env.player.currentTrack?.videoId == videoId,
                      env.translationLanguage == language else { return }
                translation = result
                translationError = nil
                translationLoading = false
            } catch is CancellationError {
                // Cancellation is not an error the user should see.
                if translationRequestID == requestID { translationLoading = false }
            } catch let err as LLMError {
                guard translationRequestID == requestID else { return }
                translationError = err.errorDescription ?? "Translation failed."
                translationLoading = false
            } catch LyricsTranslator.ParseError.noJSONArray {
                guard translationRequestID == requestID else { return }
                translationError = "Couldn't parse the model's response."
                translationLoading = false
            } catch {
                guard translationRequestID == requestID else { return }
                translationError = "Translation failed: \(error.localizedDescription)"
                translationLoading = false
            }
        }
    }

    // MARK: - X-Ray context cards (B4)

    /// "Track details" — the factual card premium players lead with:
    /// album (linked), year, length, and your own listening stats from
    /// the journal. Honest scope: YouTube Music doesn't expose writer /
    /// producer credits through the endpoints Riff uses, so this shows
    /// what is verifiably known rather than inventing a credits list.
    @ViewBuilder
    private var trackDetailsCard: some View {
        if let track = env.player.currentTrack {
            let entries = env.player.playedEntries.filter { $0.item.id == track.videoId }
            let match = entries.last?.item ?? env.player.upNext.first(where: { $0.id == track.videoId })
            let segments = track.subtitle
                .split(whereSeparator: { $0 == "·" || $0 == "•" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let albumName: String? = segments.count >= 2 ? segments[1] : nil
            VStack(alignment: .leading, spacing: 10) {
                Text("Track details")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(Theme.Text.tertiary)
                VStack(alignment: .leading, spacing: 6) {
                    detailRow("Artist") {
                        ArtistLinkLine(subtitle: segments.first ?? track.subtitle, primaryArtistId: track.artistId, fontSize: 12, baseOpacity: 0.9)
                    }
                    if let albumName, !Self.detailKindLabels.contains(albumName.lowercased()) {
                        detailRow("Album") {
                            if let albumId = track.albumId {
                                Button(albumName) { env.navigateToBrowseId(albumId, kind: .album, fallbackTitle: albumName) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Text.secondary)
                                    .help("Open album")
                            } else {
                                Text(albumName).font(.system(size: 12)).foregroundStyle(Theme.Text.secondary)
                            }
                        }
                    }
                    if let year = match?.year {
                        detailRow("Year") { Text(String(year)).font(.system(size: 12)).foregroundStyle(Theme.Text.secondary) }
                    }
                    if env.player.duration > 0 {
                        detailRow("Length") {
                            Text(Self.formatLength(env.player.duration)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Text.secondary)
                        }
                    }
                    if !entries.isEmpty {
                        detailRow("Your plays") {
                            Text("\(entries.count)× · first \(Self.relative(entries.first!.playedAt)) · last \(Self.relative(entries.last!.playedAt))")
                                .font(.system(size: 12)).foregroundStyle(Theme.Text.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Fill.soft)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.Fill.medium, lineWidth: 1))
            .padding(.bottom, 16)
        }
    }

    private static let detailKindLabels: Set<String> = ["song", "video", "album", "single", "ep", "playlist", "artist", "episode", "podcast"]
    private static let detailRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()
    private static func relative(_ date: Date) -> String {
        detailRelativeFormatter.localizedString(for: date, relativeTo: Date())
    }
    private static func formatLength(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func detailRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(width: 72, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// "Context" tab: magazine-style stack of LLM-generated cards
    /// covering people / place / era / sample / trivia for the current
    /// track. Gated on a configured API key — without one, shows a
    /// short hint pointing to Settings.
    @ViewBuilder
    private var contextContent: some View {
        trackDetailsCard
        if !env.hasLLMAPIKey {
            VStack(alignment: .leading, spacing: 10) {
                Text("X-Ray")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Configure an Anthropic API key in Settings to surface context cards — people, places, era, samples, trivia — for the current song.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    env.isSettingsSheetPresented = true
                } label: {
                    Label("Open Settings", systemImage: "key.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let bundle = xrayCards {
            xrayCardsList(bundle)
        } else if xrayLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the room…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Text.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
        } else if let err = xrayError {
            VStack(alignment: .leading, spacing: 10) {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { fireXRayIfNeeded(force: true) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            // No onAppear fire here — this branch re-appears on every
            // track-change reset, and an immediate fire would defeat
            // the debounced .task(id:) in `body`. Tab-open (onChange of
            // bottomTab) and the debounced task cover all entry paths.
            emptyHint("Pick a track to surface context.")
        }
    }

    /// Vertical stack of `Card` views with subtle hairline dividers
    /// between them, magazine-style. No accent leaks beyond Theme.red
    /// — the per-kind icon is the only chromatic differentiator.
    @ViewBuilder
    private func xrayCardsList(_ bundle: XRayCardsService.Bundle) -> some View {
        if bundle.cards.isEmpty {
            emptyHint("No context cards for this track.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(bundle.cards.enumerated()), id: \.element.id) { idx, card in
                    xrayCardView(card)
                        .padding(.vertical, 14)
                    if idx < bundle.cards.count - 1 {
                        Divider().background(Theme.Fill.strong)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func xrayCardView(_ card: XRayCardsService.Card) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: card.kind.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.red)
                Text(card.kind.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Text.tertiary)
            }
            if !card.title.isEmpty {
                Text(card.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.body.isEmpty {
                Text(card.body)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Kick off an X-Ray request for the current track. Idempotent
    /// against the service's per-videoId cache; calling from multiple
    /// hooks (tab open, track-change) is safe. `force` re-fires after
    /// an error even when state already shows a previous failure.
    private func fireXRayIfNeeded(force: Bool = false) {
        guard env.hasLLMAPIKey else { return }
        guard let track = env.player.currentTrack else { return }
        let videoId = track.videoId
        // Cache hit — render synchronously, no loader flash.
        if !force, let hit = env.xrayCardsService.cached(videoId: videoId) {
            xrayRequestID = UUID()   // orphan any stale in-flight request
            xrayCards = hit
            xrayError = nil
            xrayLoading = false
            return
        }
        if xrayLoading { return }
        xrayLoading = true
        xrayError = nil
        xrayCards = nil
        // See translationRequestID — a superseded request must not
        // touch state a newer request now owns.
        let requestID = UUID()
        xrayRequestID = requestID
        let title = track.title
        let artist = track.subtitle
        // Only real lyric lines feed the prompt — the plain `lyrics`
        // string can hold the "Lyrics not available." UI sentinel
        // (see fireTranslateIfNeeded); X-Ray handles nil lyrics fine.
        let lyricLines: [String]? = env.player.lyricsLines.isEmpty
            ? nil
            : env.player.lyricsLines.map(\.text)
        let service = env.xrayCardsService
        Task { @MainActor in
            do {
                let bundle = try await service.cards(
                    videoId: videoId,
                    title: title,
                    artist: artist,
                    lyrics: lyricLines
                )
                // Only commit if this is still the newest request and
                // the track is still the same — the user may have
                // skipped while we waited.
                guard xrayRequestID == requestID,
                      env.player.currentTrack?.videoId == videoId else { return }
                xrayCards = bundle
                xrayError = nil
                xrayLoading = false
            } catch is CancellationError {
                // Cancellation is not an error the user should see.
                if xrayRequestID == requestID { xrayLoading = false }
            } catch let err as LLMError {
                guard xrayRequestID == requestID else { return }
                xrayError = err.errorDescription ?? "X-Ray failed."
                xrayLoading = false
            } catch XRayCardsService.ParseError.noJSONArray {
                guard xrayRequestID == requestID else { return }
                xrayError = "Couldn't parse the model's response."
                xrayLoading = false
            } catch {
                guard xrayRequestID == requestID else { return }
                xrayError = "X-Ray failed: \(error.localizedDescription)"
                xrayLoading = false
            }
        }
    }

    /// Fullscreen lyrics layout — reuses the synced/plain lyric
    /// renderers (so karaoke fill + auto-scroll work identically) but
    /// centered in a wide column over the adaptive backdrop, with an
    /// exit control. Apple Music's dedicated lyrics screen.
    private var fullscreenLyricsView: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(env.player.currentTrack?.title ?? "")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(env.player.currentTrack?.subtitle ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    lyricsFullscreen = false
                } label: {
                    Label("Exit fullscreen", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Text.secondary)
                }
                .buttonStyle(.borderless)
                // Owns Esc while fullscreen lyrics is up (the top-bar
                // Close button's shortcut is nil'd out in this mode).
                .keyboardShortcut(.cancelAction)
                .help("Exit fullscreen lyrics (Esc)")
            }
            ScrollView(showsIndicators: false) {
                Group {
                    if env.player.lyricsTimed && !env.player.lyricsLines.isEmpty {
                        syncedLyrics
                    } else if let text = env.player.lyrics, !text.isEmpty {
                        plainLyricsWithTranslation(text)
                    } else {
                        emptyHint("Lyrics not available for this track.")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)   // center the 640 column
                .padding(.vertical, 24)
            }
        }
    }

    /// Synced lyrics view — highlights the line whose time-range covers
    /// `env.player.elapsed` and auto-scrolls it into view as playback
    /// advances. Within the active line, words fill left-to-right via
    /// per-word interpolation against the line's duration (B2).
    private var syncedLyrics: some View {
        let lines = env.player.lyricsLines
        return ScrollViewReader { proxy in
            // Re-anchor whenever the player reports a new elapsed value.
            // Between polls (~1Hz) we extrapolate locally so the active
            // line's per-word fill stays smooth at ~30fps. Paused while
            // playback is paused: the extrapolation freezes at the
            // anchor anyway, so ticking 30×/s would rebuild every lyric
            // line for identical output. A resume/seek re-anchors via
            // the `.progress`-driven onChange below, which also restarts
            // the schedule (isPlaying is @Observable-tracked here).
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !env.player.isPlaying)) { context in
                let elapsedMs = extrapolatedElapsedMs(at: context.date)
                let activeIndex = LyricsKaraoke.activeLyricIndex(
                    for: elapsedMs, in: lines
                )
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                        karaokeLine(
                            line: line,
                            idx: idx,
                            activeIndex: activeIndex,
                            elapsedMs: elapsedMs,
                            lines: lines
                        )
                        .id(line.id)
                    }
                }
                .onChange(of: activeIndex) { _, newIndex in
                    guard newIndex >= 0, newIndex < lines.count else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(lines[newIndex].id, anchor: .center)
                    }
                }
            }
            .onChange(of: env.player.elapsed) { _, newValue in
                anchorElapsed = newValue
                anchorAt = Date()
            }
            // Re-anchor on play/pause flips. Without this, `anchorAt`
            // keeps its pre-pause timestamp, so the first tick after a
            // resume extrapolates `now - anchorAt` (capped at 2s) and
            // the active-line fill jumps ahead until the next ~1Hz poll.
            .onChange(of: env.player.isPlaying) { _, _ in
                anchorElapsed = env.player.elapsed
                anchorAt = Date()
            }
            .onAppear {
                anchorElapsed = env.player.elapsed
                anchorAt = Date()
            }
        }
    }

    /// Render one lyric line. The active line gets a word-by-word fill
    /// (white → translucent) sweeping left-to-right over the line's
    /// duration. Tap anywhere on a line to seek to that line's start.
    @ViewBuilder
    private func karaokeLine(
        line: InnerTubeClient.LyricLine,
        idx: Int,
        activeIndex: Int,
        elapsedMs: Double,
        lines: [InnerTubeClient.LyricLine]
    ) -> some View {
        let isActive = idx == activeIndex
        let display = line.text.isEmpty ? "♪" : line.text
        let inactiveOpacity: Double = abs(idx - activeIndex) <= 1 ? 0.7 : 0.4

        VStack(alignment: .leading, spacing: 2) {
            Group {
                if isActive {
                    let progress = LyricsKaraoke.lineProgress(
                        elapsedMs: elapsedMs, idx: idx, in: lines
                    )
                    KaraokeLineView(text: display, progress: progress)
                        .font(.system(size: 14, weight: .semibold))
                } else {
                    Text(display)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.white.opacity(inactiveOpacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // No .textSelection here: on macOS selectable Text consumes
            // mouse-down to begin a selection, so the row's tap-to-seek
            // gesture would only fire on the empty space past the
            // glyphs. Copy/select stays available on the plain-lyrics
            // path, which has no tap gesture.
            // Inline translation + optional pronunciation, indented
            // slightly so the source line still reads as the "primary"
            // text. Renders nothing when translation is off / loading.
            translatedSubtitle(at: idx, selectable: false)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            seekToLyric(at: idx)
        }
        .help("Jump to this line")
    }

    /// Estimate elapsed in ms using the bridge's last polled value plus
    /// the elapsed wall-clock time since we observed it. The bridge polls
    /// at ~1Hz; without extrapolation the active-line fill ticks in
    /// 1s steps. While paused we freeze at the anchor value so the fill
    /// doesn't keep advancing through the line. Drift over a 3-5s line
    /// is imperceptible — it's corrected on the next poll.
    private func extrapolatedElapsedMs(at now: Date) -> Double {
        if env.player.isPlaying {
            let delta = now.timeIntervalSince(anchorAt)
            // Cap the extrapolation at 2s of drift — beyond that something
            // has stalled and we'd rather wait for the next real poll than
            // sweep past lines that haven't started.
            let bounded = max(0, min(2.0, delta))
            return (anchorElapsed + bounded) * 1000.0
        } else {
            return anchorElapsed * 1000.0
        }
    }

    /// Seek to the start of the lyric line at `idx`. Computes a
    /// fraction since `PlayerBridge.seek(to:)` takes a 0…1 value.
    private func seekToLyric(at idx: Int) {
        let lines = env.player.lyricsLines
        guard idx >= 0, idx < lines.count, let startMs = lines[idx].startMs else { return }
        let duration = env.player.duration
        guard duration > 0 else { return }
        let fraction = max(0, min(1, Double(startMs) / 1000.0 / duration))
        Task { await env.player.seek(to: fraction) }
    }

    private var relatedContent: some View {
        Group {
            if env.player.related.isEmpty && env.player.relatedSections.isEmpty {
                emptyHint("Looking for related tracks…")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    // Surface "Other versions" / "Other performances" —
                    // the live, acoustic, and cover variants of the
                    // current track that YT Music already returns on
                    // /next's Related tab. Previously dropped on the
                    // floor by the flat scanForMediaItems pass; now
                    // rendered as a horizontal rail above the related
                    // queue so users can jump between performances of
                    // the same song without leaving Now Playing.
                    if let perfs = otherPerformancesSection {
                        otherPerformancesRail(perfs)
                    }
                    if !env.player.related.isEmpty {
                        queueList(env.player.related)
                    }
                }
            }
        }
    }

    /// Pick the "Other versions" / "Other performances" shelf from the
    /// related sections by title match. YT Music uses both labels
    /// depending on locale and content; the case-insensitive contains
    /// check covers both without locking in a specific spelling.
    private var otherPerformancesSection: HomeSection? {
        for section in env.player.relatedSections {
            let lower = section.title.lowercased()
            if lower.contains("other version") || lower.contains("other performance") {
                return section
            }
        }
        return nil
    }

    /// Compact horizontal rail of variant tiles for the "Other
    /// performances" row. Doesn't reuse HomeSectionRow because the
    /// side pane is only ~380px wide — a Home-sized 180×180 carousel
    /// would only fit two tiles. These tiles are 130×130 with a tight
    /// caption so 3-4 read at once before scrolling.
    private func otherPerformancesRail(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(section.items) { item in
                        Button {
                            Task { await env.player.play(item: item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AsyncImage(url: item.thumbnailURL?.upscaledArtwork(to: 240)) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Theme.Fill.soft
                                    }
                                }
                                .frame(width: 110, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb))
                                Text(item.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.Text.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .frame(width: 110, alignment: .leading)
                            .help("\(item.title) — \(item.subtitle)")
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackContextMenu(item: item) }
                    }
                }
            }
        }
    }

    /// Renders a track list styled as queue rows. `reorderable` marks a
    /// list whose rows really live in the playback queue: it enables
    /// drag-reorder AND the queue-mutating actions (Move Up/Down,
    /// Remove from queue). History, the Related tab, and the Discover
    /// lens pass false — their rows are NOT in the queue, so those
    /// actions were silent no-ops ending in a false "Couldn't remove"
    /// toast. Non-mutating actions (Play next / Add to queue) stay on
    /// every row. `rowKeys` overrides ForEach identity for lists that
    /// can legally repeat a videoId (history); defaults to the item
    /// ids, which upNext/related keep unique.
    private func queueList(
        _ items: [MediaItem],
        faded: Bool = false,
        reorderable: Bool = false,
        rowKeys: [String]? = nil
    ) -> some View {
        let keys = rowKeys ?? items.map(\.id)
        let currentId = env.player.currentTrack?.videoId
        let visibleIds = items.map(\.id)
        return LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.element) { pos, _ in
                let item = items[pos]
                let isCurrent = item.id == currentId
                let isDropTarget = dragHoverTargetId == item.id
                Button {
                    // `skipTo` (not `play`) preserves rows above the
                    // tap. Jump-to-row should behave as "skip forward
                    // to N", not "clear queue and play N with fresh
                    // radio around it". `skipTo` pre-removes the
                    // item from the queue so the trackChanged
                    // `consumeUpTo` becomes a no-op. (C1)
                    Task { await env.player.skipTo(item: item) }
                } label: {
                    queueRow(item: item, isCurrent: isCurrent, allowsQueueEdits: reorderable)
                        .opacity(faded ? 0.6 : 1.0)
                        .overlay(alignment: .top) {
                            // Insertion indicator when a drag is
                            // hovering above this row. 2pt red bar
                            // matches the brand accent and reads
                            // clearly against the dark background.
                            if reorderable && isDropTarget {
                                Rectangle()
                                    .fill(Theme.red)
                                    .frame(height: 2)
                                    .offset(y: -3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .modifier(QueueDragReorderModifier(
                    enabled: reorderable && !isCurrent,
                    itemId: item.id,
                    hoverTargetId: $dragHoverTargetId,
                    onDrop: { droppedId in
                        performReorder(dropped: droppedId, before: item.id, visibleIds: visibleIds)
                    }
                ))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    isCurrent
                        ? "Now playing: \(item.title) by \(item.subtitle)"
                        : "\(item.title) by \(item.subtitle)"
                )
                .accessibilityHint(isCurrent ? "" : "Double tap to jump to this track.")
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                .contextMenu {
                    // Full track menu plus queue-specific reorder/remove
                    // operations underneath — but ONLY for rows that are
                    // actually in the queue (see the doc comment above).
                    // omitPrimaryPlay because the row's tap already plays
                    // it; keep "Start radio" so the user can break out of
                    // the current queue.
                    TrackContextMenu(item: item, omitPrimaryPlay: true)
                    if reorderable {
                        Divider()
                        Button("Move Up") { env.player.moveInQueue(videoId: item.id, by: -1) }
                            .disabled(isCurrent)
                        Button("Move Down") { env.player.moveInQueue(videoId: item.id, by: 1) }
                            .disabled(isCurrent)
                        Button("Remove from Queue") {
                            Task { await env.player.removeFromQueue(videoId: item.id) }
                        }
                        .disabled(isCurrent)  // can't remove the playing track
                    }
                }
            }
        }
        // Rows slide when the queue consumes/reorders instead of popping.
        .animation(reduceMotion ? nil : Theme.Motion.list, value: keys)
    }

    /// Compute a drop destination index and hand it to the bridge.
    /// The caller has already validated `dropped != nil` (drop
    /// modifier only fires with a non-empty payload). "Before" the
    /// target row places the dropped item at that row's index; if
    /// the dropped item was previously above the target, SwiftUI's
    /// `Array.move(fromOffsets:toOffset:)` semantics handle the
    /// offset shift so no manual adjustment is needed here.
    private func performReorder(dropped: String, before targetId: String, visibleIds: [String]) {
        guard dropped != targetId,
              let sourceIdx = visibleIds.firstIndex(of: dropped),
              let targetIdx = visibleIds.firstIndex(of: targetId) else { return }
        env.player.reorderQueue(
            visibleIds: visibleIds,
            from: IndexSet(integer: sourceIdx),
            to: targetIdx
        )
    }

    private func queueRow(item: MediaItem, isCurrent: Bool, allowsQueueEdits: Bool) -> some View {
        // B5: rows that came from /related via Smart Shuffle get a
        // "+" badge so the user can tell at a glance that this slot
        // is a suggestion rather than the playlist's own next track.
        let isSmartShuffleInjected = env.player.smartShuffleInjectedIds.contains(item.id)
        return HStack(spacing: 10) {
            ZStack {
                AsyncImage(url: item.thumbnailURL?.upscaledArtwork(to: 120)) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        // Placeholder — an SF Symbol on a subtle
                        // fill reads as "no artwork yet" instead
                        // of "broken/missing tile". Cheaper than
                        // a shimmer and unambiguous.
                        ZStack {
                            Theme.Fill.soft
                            Image(systemName: "music.note")
                                .font(.system(size: 14, weight: .light))
                                .foregroundStyle(Theme.Text.disabled)
                        }
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                // Equalizer-style overlay on the active row.
                if isCurrent {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.black.opacity(0.5))
                        .frame(width: 36, height: 36)
                    Image(systemName: env.player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.red)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(env.displayTitle(for: item))
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? Theme.red : Color.white)
                        .lineLimit(1)
                    if env.hasMetadataOverride(item) {
                        Image(systemName: "pencil")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.Text.secondary)
                            .help("Metadata edited locally")
                            .accessibilityLabel("Metadata edited")
                    }
                }
                // Artist line is its own click target (Spotify-style):
                // clicking it opens the artist page instead of playing
                // the row. Button-inside-row wins the hit test over the
                // row's tap gesture, so the rest of the row still plays.
                QueueArtistLink(
                    label: env.displaySubtitle(for: item),
                    item: item
                )
            }
            Spacer()
            // Inline row actions (Spotify-style "⋯"): the same queue
            // operations were right-click-only before.
            if !isCurrent {
                Menu {
                    Button("Play next") {
                        env.player.playNext(item: item)
                        env.showToast("Playing next: \(item.title)")
                    }
                    Button("Add to queue") {
                        env.player.addToQueueEnd(item: item)
                        env.showToast("Added to queue: \(item.title)")
                    }
                    // Removal only offered on rows that are actually in
                    // the queue — history/Related/Discover rows aren't,
                    // and "removing" them only produced an error toast.
                    if allowsQueueEdits {
                        Divider()
                        Button("Remove from queue", role: .destructive) {
                            Task { await env.player.removeFromQueue(videoId: item.id) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Text.tertiary)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("Queue actions")
                .accessibilityLabel("Queue actions for \(item.title)")
            }
            // Row duration — YT-web queue rows carry one on the right.
            // Present for /next-fetched and page-mirrored rows; absent
            // (renders nothing) for rows whose source had no lengthText.
            if let secs = item.durationSeconds {
                Text(secs >= 3600
                     ? String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
                     : String(format: "%d:%02d", secs / 60, secs % 60))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(isCurrent ? 0.8 : 0.5))
            }
            if isSmartShuffleInjected {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Theme.red)
                    .clipShape(Circle())
                    .help("Smart Shuffle suggestion")
                    .accessibilityLabel("Smart Shuffle suggestion")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(isCurrent ? Theme.red.opacity(0.10) : Theme.Fill.faint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb))
    }

    /// D2 — Now Playing big title routed through any per-videoId
    /// override. Falls back to the original `track.title` (or em-dash
    /// when there's no track at all).
    private func displayedTitle(track: PlayerBridge.Track?) -> String {
        guard let track else { return "—" }
        return env.trackOverrides.overriddenTitle(for: track.videoId) ?? track.title
    }

    /// Now Playing subtitle ("Artist · Album · Year"). When an artist
    /// or album override exists we splice the first one/two segments
    /// to match how rows render elsewhere.
    private func displayedSubtitle(track: PlayerBridge.Track?) -> String {
        guard let track else { return "" }
        let artist = env.trackOverrides.overriddenArtist(for: track.videoId)
        let album = env.trackOverrides.overriddenAlbum(for: track.videoId)
        if artist == nil && album == nil { return track.subtitle }
        var segments = track.subtitle
            .split(whereSeparator: { $0 == "·" || $0 == "•" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if segments.isEmpty {
            segments = ["", ""]
        } else if segments.count == 1 {
            segments.append("")
        }
        if let a = artist { segments[0] = a }
        if let a = album, segments.count >= 2 { segments[1] = a }
        while let last = segments.last, last.isEmpty {
            segments.removeLast()
        }
        return segments.joined(separator: " · ")
    }

    /// Best-effort artist name for the now-playing artist link. Prefers a
    /// local override; otherwise parses the subtitle by stripping a
    /// leading media-type token ("Song", "Video", …) and taking the first
    /// remaining segment. Used as the search fallback name when the track
    /// carries no artistId. Empty only when the subtitle is empty.
    private func artistName(track: PlayerBridge.Track?) -> String {
        guard let track else { return "" }
        if let a = env.trackOverrides.overriddenArtist(for: track.videoId) { return a }
        let typeTokens: Set<String> = [
            "song", "video", "album", "single", "ep",
            "playlist", "artist", "episode", "podcast"
        ]
        let segments = track.subtitle
            .split(whereSeparator: { $0 == "·" || $0 == "•" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return segments.first(where: { !typeTokens.contains($0.lowercased()) })
            ?? segments.first
            ?? ""
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Text.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }
}

/// The scrubber + time labels, isolated from NowPlayingView so its
/// ~4Hz elapsed/duration reads only re-render THIS view, not the
/// 2,100-line parent body (see the `scrubber` accessor comment).
private struct ScrubberSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var scrubbing: Double? = nil

    var body: some View {
        // Sanitize against NaN/±inf. `<video>.duration` is NaN until a new
        // track's metadata loads, and Swift's `max(NaN, x)` returns NaN
        // (NaN fails every comparison) — so `0...duration` would trap with
        // "Range requires lowerBound <= upperBound". Never let a non-finite
        // value reach the Range or the Slider binding.
        let rawDuration = env.player.duration
        let duration = (rawDuration.isFinite && rawDuration > 0) ? rawDuration : 0.001
        let rawElapsed = scrubbing ?? env.player.elapsed
        let displayed = min(max(rawElapsed.isFinite ? rawElapsed : 0, 0), duration)
        return VStack(spacing: 6) {
            ScrubberSlider(
                value: Binding(
                    get: { displayed },
                    set: { scrubbing = $0 }
                ),
                range: 0...duration,
                onCommit: { value in
                    scrubbing = nil
                    Task { await env.player.seek(to: value / duration) }
                }
            )
            HStack {
                Text(format(time: displayed))
                Spacer()
                Text("-" + format(time: max(0, duration - displayed)))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.Text.secondary)
        }
    }

    private func format(time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Clickable artist line inside a queue row. Hover underlines +
/// brightens; click opens the artist page (by id when the row carries
/// one, else name-resolved via search — see `navigateToArtist`). The
/// name passed for resolution is the first subtitle segment (artist
/// comes first in "Artist · Album · Year").
private struct QueueArtistLink: View {
    let label: String
    let item: MediaItem

    var body: some View {
        ArtistLinkLine(subtitle: label, primaryArtistId: item.artistId, fontSize: 10, baseOpacity: 0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
    }
}

private struct ScrubberSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let progress = max(0, min(1, (value - range.lowerBound) / span))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Fill.strong).frame(height: 4)
                Capsule().fill(Color.white).frame(width: geo.size.width * progress, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: max(0, geo.size.width * progress - 6))
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let p = max(0, min(1, g.location.x / geo.size.width))
                        value = range.lowerBound + Double(p) * span
                    }
                    .onEnded { _ in onCommit(value) }
            )
            // Keyboard seek: left/right arrows nudge by 5 seconds.
            // Only fires when the scrubber has focus (Tab into it).
            .focusable(true)
            .onKeyPress(.leftArrow) {
                nudge(by: -5)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                nudge(by: 5)
                return .handled
            }
            // VoiceOver: expose as an adjustable value so the user
            // can swipe up/down (or arrow ±) to seek. Reads out as
            // "Playback position, 1:23 of 3:45" — mm:ss format.
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatted(value)) of \(formatted(range.upperBound))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(by: 5)
                case .decrement: nudge(by: -5)
                @unknown default: break
                }
            }
        }
        .frame(height: 18)
    }

    /// Move the scrubber by `seconds` (positive = forward) and
    /// commit — used by both keyboard arrows and VoiceOver
    /// adjustable action.
    private func nudge(by seconds: Double) {
        let next = max(range.lowerBound, min(range.upperBound, value + seconds))
        value = next
        onCommit(next)
    }

    /// mm:ss formatter — mirrors NowPlayingView.format(time:) so
    /// VoiceOver reads "1:23 of 3:45" instead of raw seconds.
    private func formatted(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Tune popover

/// Popover that mirrors YT Music's "Tune your queue" affordance. Shown
/// when the user taps the Tune button at the top of the Up Next pane.
///
/// Two display modes:
///
/// 1. **Real chips** — when YT served a `subHeaderChipCloud` for the
///    current watch context (typical for radio queues), we render
///    every chip the server gave us. Tapping a chip re-issues `/next`
///    with that chip's protobuf-encoded `(playlistId, params)` and
///    refreshes Up Next with the resulting variant. This is exactly
///    what music.youtube.com does on the web.
///
/// 2. **Local fallback** — when no chip cloud was returned (e.g. on
///    explicit playlists or podcasts where YT doesn't offer a Tune
///    affordance), fall back to a 3-position picker driven entirely
///    by data Riff already has: All / Discover (related endpoint) /
///    Familiar (history-filtered radio queue). Less rich than YT's
///    chips but better than nothing.
private struct TunePopover: View {
    let chips: [InnerTubeClient.QueueChip]
    let selectedChipId: String?
    let onSelectChip: (InnerTubeClient.QueueChip) -> Void
    @Binding var fallbackSelection: NowPlayingView.QueueMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider().background(Theme.Fill.medium)
            if chips.isEmpty {
                fallbackSection
            } else {
                chipsSection
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("Tune your queue")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.red)
        }
    }

    /// Real YT-served chips. We don't try to bucket them into
    /// "familiarity" vs "mood" sections — YT itself renders them as a
    /// single flat cloud, with "All" first and the rest in whatever
    /// order the server chose (the order encodes locality / language
    /// signals we shouldn't second-guess).
    private var chipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Variant")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(Theme.Text.secondary)
            FlowLayout(spacing: 6) {
                ForEach(chips) { chip in
                    let isSelected = (selectedChipId ?? chips.first(where: \.isSelected)?.id) == chip.id
                    Button {
                        onSelectChip(chip)
                    } label: {
                        Text(chip.label)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSelected ? Theme.Selected.fill : Theme.Fill.soft)
                            .foregroundStyle(isSelected ? Theme.Selected.text : Theme.Text.secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Tap a chip to retune the queue. The currently-playing track keeps playing.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Local 3-position picker — used when YT didn't serve a chip cloud.
    /// Order goes Familiar → Mix → Discover so it reads as a continuum.
    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Familiarity")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(Theme.Text.secondary)
            HStack(spacing: 6) {
                ForEach(NowPlayingView.QueueMode.allCases) { mode in
                    Button {
                        fallbackSelection = mode
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: icon(for: mode))
                                .font(.system(size: 13, weight: .semibold))
                            Text(label(for: mode))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(fallbackSelection == mode ? Theme.red : Theme.Fill.soft)
                        .foregroundStyle(fallbackSelection == mode ? Color.white : Theme.Text.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(description(for: fallbackSelection))
                .font(.system(size: 11))
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Fallback metadata

    private func icon(for mode: NowPlayingView.QueueMode) -> String {
        switch mode {
        case .familiar: return "person.crop.circle.badge.checkmark"
        case .related:  return "music.note.list"
        case .discover: return "sparkles"
        }
    }

    private func label(for mode: NowPlayingView.QueueMode) -> String {
        switch mode {
        case .familiar: return "Familiar"
        case .related:  return "Mix"
        case .discover: return "Discover"
        }
    }

    private func description(for mode: NowPlayingView.QueueMode) -> String {
        switch mode {
        case .familiar:
            return "Only show tracks by artists you've already played this session."
        case .related:
            return "The default radio queue — a balanced mix anchored on the current track."
        case .discover:
            return "Lean into broader, less-familiar recommendations."
        }
    }
}

/// Lightweight flow layout — wraps chips onto multiple rows when they
/// don't fit horizontally. Used by the mood chips above.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
