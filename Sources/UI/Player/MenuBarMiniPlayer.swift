import SwiftUI
import AppKit

/// Compact popover surfaced from the system menu bar via MenuBarExtra.
/// Gives users transport + scrubber + open-mini-player without bringing
/// the main Riff window forward.
///
/// Mirrors FloatingMiniPlayerView semantics but is a thinner, fixed-size
/// popover since the system menu bar cannot host an arbitrarily-resizable
/// surface.
///
/// Reads from the same env.player; no second WKWebView, no duplicated
/// state, honors the architectural rule.
struct MenuBarMiniPlayer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let track = env.player.currentTrack
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                artwork(url: track?.thumbnailURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track?.subtitle ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            // Progress + timestamps. Hidden in the resting state so the
            // popover stays compact when nothing is loaded.
            if env.player.hasTrack {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.Fill.strong)
                            Capsule()
                                .fill(Theme.red)
                                .frame(width: geo.size.width * env.player.progress)
                        }
                        // Click to seek from the popover.
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
                    .frame(height: 6)
                    HStack {
                        Text(format(env.player.elapsed))
                        Spacer()
                        Text("-" + format(max(0, env.player.duration - env.player.elapsed)))
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 20) {
                Spacer()
                modeToggle(
                    systemName: "shuffle",
                    on: env.player.shuffleEnabled,
                    help: env.player.shuffleEnabled ? "Turn shuffle off" : "Turn shuffle on"
                ) { env.player.toggleShuffle() }
                transport(systemName: "backward.fill", size: 14, help: "Previous") {
                    Task { await env.player.previous() }
                }
                .disabled(!env.player.hasTrack)

                transport(
                    systemName: env.player.isPlaying ? "pause.fill" : "play.fill",
                    size: 20,
                    help: env.player.isPlaying ? "Pause" : "Play"
                ) {
                    Task { await env.player.togglePlay() }
                }
                .disabled(!env.player.hasTrack)

                transport(systemName: "forward.fill", size: 14, help: "Next") {
                    Task { await env.player.next() }
                }
                .disabled(!env.player.hasTrack)
                modeToggle(
                    systemName: env.player.repeatMode == .one ? "repeat.1" : "repeat",
                    on: env.player.repeatMode != .off,
                    help: env.player.repeatMode == .off ? "Turn repeat on" : "Turn repeat off"
                ) { Task { await env.player.toggleRepeat() } }
                Spacer()
            }

            // Volume — compact slider so the menu-bar popover can adjust
            // loudness without opening the main window.
            HStack(spacing: 8) {
                Image(systemName: env.player.volume == 0 ? "speaker.slash.fill"
                                   : env.player.volume < 0.5 ? "speaker.wave.1.fill"
                                   : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Slider(
                    value: Binding(
                        get: { env.player.volume },
                        set: { v in Task { await env.player.setVolume(v) } }
                    ),
                    in: 0...1
                )
                .controlSize(.mini)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((env.player.volume * 100).rounded())) percent")

            // Chip strip (Tune / mood chips returned by /next). Only
            // rendered when YT sent chips for the current watch
            // context. Compact horizontal scroll so a large cloud
            // (Familiar / Discover / All / Popular / decade / …)
            // doesn't blow up the popover width.
            if !env.player.availableChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(env.player.availableChips) { chip in
                            miniChip(chip: chip)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxHeight: 26)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                // Smart Shuffle toggle — inline, with a checkmark
                // instead of hiding in a submenu. Grouped with the
                // other queue-shaping toggles up top would be
                // cleaner, but the compact icon row can't carry a
                // long "Smart Shuffle" label.
                menuRow(
                    label: "Smart Shuffle",
                    systemImage: "wand.and.rays",
                    trailing: env.player.smartShuffleEnabled ? "checkmark" : nil
                ) {
                    env.player.toggleSmartShuffle()
                }

                // Sleep timer submenu — presets + Cancel when armed.
                Menu {
                    if env.player.sleepTimerRemaining != nil {
                        Button {
                            env.player.cancelSleepTimer()
                        } label: {
                            Label("Cancel timer", systemImage: "xmark.circle")
                        }
                        Divider()
                    }
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                        Button("Sleep in \(minutes) min") {
                            env.player.setSleepTimer(minutes: minutes, mode: .fadeOut)
                        }
                    }
                } label: {
                    Label(
                        sleepTimerLabel,
                        systemImage: env.player.sleepTimerRemaining != nil ? "moon.zzz.fill" : "moon.zzz"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)

                // Crossfade submenu.
                Menu {
                    ForEach(PlayerBridge.crossfadePresets, id: \.self) { seconds in
                        let label = seconds == 0 ? "Off" : "\(Int(seconds)) sec"
                        Button {
                            Task { await env.player.setCrossfadeSeconds(seconds) }
                        } label: {
                            if seconds == env.player.crossfadeSeconds {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                } label: {
                    Label("Crossfade: \(crossfadeLabel)", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)

                // Playback rate submenu.
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                        Button {
                            Task { await env.player.setPlaybackRate(rate) }
                        } label: {
                            if abs(rate - env.player.playbackRate) < 0.01 {
                                Label(rateLabel(rate), systemImage: "checkmark")
                            } else {
                                Text(rateLabel(rate))
                            }
                        }
                    }
                } label: {
                    Label("Speed: \(rateLabel(env.player.playbackRate))", systemImage: "speedometer")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)

                // Volume normalization toggle.
                menuRow(
                    label: "Volume normalization",
                    systemImage: "speaker.wave.2.fill",
                    trailing: env.player.normalizationEnabled ? "checkmark" : nil
                ) {
                    Task { await env.player.setNormalizationEnabled(!env.player.normalizationEnabled) }
                }

                if env.player.hasTrack {
                    Divider()
                    menuRow(
                        label: env.player.liked ? "Unlike" : "Like",
                        systemImage: env.player.liked ? "heart.fill" : "heart"
                    ) {
                        Task { await env.player.toggleLike() }
                    }
                    if env.isSignedIn, !env.player.upNext.isEmpty {
                        menuRow(
                            label: "Save queue as playlist",
                            systemImage: "square.and.arrow.down"
                        ) {
                            env.newPlaylistSource = .queue
                            env.isNewPlaylistSheetPresented = true
                        }
                    }
                }

                Divider()
                Button {
                    openWindow(id: "mini-player")
                } label: {
                    Label("Open Mini Player", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("M", modifiers: [.command, .option])

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Riff", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("Q", modifiers: .command)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 300)
    }

    private var sleepTimerLabel: String {
        guard let remaining = env.player.sleepTimerRemaining else { return "Sleep timer" }
        let minutes = Int(ceil(remaining / 60))
        return "Sleep in \(minutes) min"
    }

    private var crossfadeLabel: String {
        env.player.crossfadeSeconds == 0 ? "Off" : "\(Int(env.player.crossfadeSeconds))s"
    }

    private func rateLabel(_ rate: Double) -> String {
        // 1.0 → "1×", 1.25 → "1.25×". Trim redundant zeros.
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return (f.string(from: rate as NSNumber) ?? "\(rate)") + "×"
    }

    private func miniChip(chip: InnerTubeClient.QueueChip) -> some View {
        let selected = chip.id == env.player.selectedChipId
        return Button {
            env.player.applyChip(chip)
        } label: {
            Text(chip.label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Theme.red : Theme.Fill.medium)
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func modeToggle(systemName: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Theme.red : .primary.opacity(0.8))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func menuRow(label: String, systemImage: String, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func artwork(url: URL?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                .fill(Theme.Fill.medium)
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
    }

    private func transport(
        systemName: String,
        size: CGFloat,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Label rendered next to the system menu bar clock. SF Symbol that mirrors
/// transport state: music.note when nothing is loaded, play.fill while
/// playing, pause.fill when paused. MenuBarExtra label only takes Views,
/// not NSImages, so we stick to SF Symbols for native chrome.
struct MenuBarMiniPlayerLabel: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Image(systemName: iconName)
    }

    private var iconName: String {
        if env.player.hasTrack {
            return env.player.isPlaying ? "play.fill" : "pause.fill"
        }
        return "music.note"
    }
}
