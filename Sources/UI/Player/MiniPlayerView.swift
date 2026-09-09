import SwiftUI

/// The pinned playback strip at the bottom of the window. Tap anywhere to
/// expand into NowPlayingView. Visual goals (per YT Music iOS):
///   - thin red progress line across the very top
///   - generous 56pt artwork with rounded corners + subtle shadow
///   - ample horizontal padding so the controls don't feel cramped
///   - whole strip is tappable but the action buttons short-circuit hits
struct MiniPlayerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let track = env.player.currentTrack
        VStack(spacing: 0) {
            // Edge-to-edge progress line.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                    Rectangle()
                        .fill(Theme.red)
                        .frame(width: geo.size.width * env.player.progress)
                }
                // Click (or drag-release) to seek — desktop players all
                // treat the bottom-bar progress line as a scrubber.
                // contentShape widens the 2pt line's hit area.
                // highPriorityGesture, NOT .gesture: the whole mini
                // player carries an onTapGesture that opens the full
                // player, and a plain gesture lost to it — clicking the
                // bar opened the full screen instead of seeking.
                .contentShape(Rectangle())
                .highPriorityGesture(
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
            .accessibilityLabel("Playback progress")
            .accessibilityHint("Click to seek")

            HStack(spacing: 14) {
                AsyncImage(url: track?.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "—")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    Text(track?.subtitle ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)

                controlButton(systemName: "backward.fill", size: 16, help: "Previous") {
                    Task { await env.player.previous() }
                }
                controlButton(
                    systemName: env.player.isPlaying ? "pause.fill" : "play.fill",
                    size: 22,
                    help: env.player.isPlaying ? "Pause" : "Play"
                ) {
                    Task { await env.player.togglePlay() }
                }
                controlButton(systemName: "forward.fill", size: 16, help: "Next") {
                    Task { await env.player.next() }
                }

                // Volume slider — compact, on the trailing edge so it's
                // out of the way of the primary playback controls.
                HStack(spacing: 6) {
                    Image(systemName: env.player.volume == 0 ? "speaker.slash.fill"
                                       : env.player.volume < 0.5 ? "speaker.wave.1.fill"
                                       : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 18)
                    Slider(
                        value: Binding(
                            get: { env.player.volume },
                            set: { v in Task { await env.player.setVolume(v) } }
                        ),
                        in: 0...1
                    )
                    .controlSize(.small)
                    .frame(width: 84)
                    .tint(.white)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int((env.player.volume * 100).rounded())) percent")
                }
                .padding(.leading, 8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.92))
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .onTapGesture { env.player.isFullPlayerOpen = true }
            // The tap-to-expand was invisible to assistive tech: the
            // mini player exposed no accessible element at all, so
            // VoiceOver users had no way to open Now Playing / the
            // queue. Expose the expand action explicitly (transport +
            // volume keep their own labels as children).
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "Now playing: \(track?.title ?? "nothing"). \(track?.subtitle ?? "")"
            )
            .accessibilityHint("Opens the full player and queue")
            .accessibilityAction(named: "Open Now Playing") {
                env.player.isFullPlayerOpen = true
            }
            // Right-click on the mini bar surfaces the now-playing
            // version of YT Music's track menu — Go to album/artist
            // are the high-value entries here, so the user can jump
            // away from the current track without having to expand
            // the full player first.
            .contextMenu { nowPlayingMenuItems }
        }
    }

    /// Menu items operating on the *currently playing* track. Synthesizes
    /// a MediaItem from PlayerBridge.Track so we can reuse
    /// TrackContextMenu's logic; the menu won't appear if there's no
    /// current track because the strip itself isn't visible then.
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
            // omitPrimaryPlay: it's already playing.
            TrackContextMenu(item: item, omitPrimaryPlay: true)
        }
    }

    private func controlButton(systemName: String, size: CGFloat, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}
